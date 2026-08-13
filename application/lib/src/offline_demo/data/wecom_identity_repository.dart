import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../domain/repositories.dart';
import 'wecom_database_package.dart';

enum WeComIdentityResolutionStatus {
  resolved,
  noCandidates,
  ambiguousNoConfig,
  ambiguousNoMatch,
}

enum WeComIdentityIssueCode {
  invalidCorporationInfo,
  invalidExplicitSelection,
  selectedUserMissing,
  selectedUserCorporationMismatch,
}

class WeComIdentityException implements Exception {
  const WeComIdentityException(this.code, this.message, {this.cause});

  final WeComIdentityIssueCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'WeComIdentityException.${code.name}: $message';
}

class WeComDatasetIdentity {
  const WeComDatasetIdentity({
    required this.corporationId,
    required this.userId,
    required this.corporationShortName,
    required this.corporationFullName,
  });

  final int corporationId;
  final int userId;
  final String corporationShortName;
  final String corporationFullName;

  String get corporationName => corporationFullName.isNotEmpty
      ? corporationFullName
      : corporationShortName;
}

class WeComIdentityResolution {
  WeComIdentityResolution({
    required this.status,
    required List<WeComDatasetIdentity> candidates,
    this.selected,
  }) : candidates = List.unmodifiable(candidates);

  final WeComIdentityResolutionStatus status;
  final List<WeComDatasetIdentity> candidates;
  final WeComDatasetIdentity? selected;
}

class WeComIdentityResolver {
  const WeComIdentityResolver(this._databaseFactory);

  final DatabaseFactory _databaseFactory;

  Future<WeComIdentityResolution> resolve({
    required WeComImportedPackage package,
    File? configFile,
    int? selectedCorporationId,
  }) async {
    final candidates = await listCandidates(package);
    WeComDatasetIdentity? selected;
    if (selectedCorporationId != null) {
      selected = _candidateForCorporation(candidates, selectedCorporationId);
      if (selected == null) {
        throw WeComIdentityException(
          WeComIdentityIssueCode.invalidExplicitSelection,
          'Selected corporation is not present in the imported dataset',
        );
      }
    } else if (candidates.isEmpty) {
      return WeComIdentityResolution(
        status: WeComIdentityResolutionStatus.noCandidates,
        candidates: candidates,
      );
    } else if (candidates.length == 1) {
      selected = candidates.single;
    } else {
      final configuredCorporationId = await _readConfiguredCorporationId(
        configFile,
      );
      if (configuredCorporationId == null) {
        return WeComIdentityResolution(
          status: WeComIdentityResolutionStatus.ambiguousNoConfig,
          candidates: candidates,
        );
      }
      selected = _candidateForCorporation(
        candidates,
        configuredCorporationId,
      );
      if (selected == null) {
        return WeComIdentityResolution(
          status: WeComIdentityResolutionStatus.ambiguousNoMatch,
          candidates: candidates,
        );
      }
    }

    await _validateUser(package: package, identity: selected);
    return WeComIdentityResolution(
      status: WeComIdentityResolutionStatus.resolved,
      candidates: candidates,
      selected: selected,
    );
  }

  Future<List<WeComDatasetIdentity>> listCandidates(
    WeComImportedPackage package,
  ) async {
    final database = await package.openReadOnly(
      'company.db',
      factory: _databaseFactory,
    );
    try {
      final rows = await database.query(
        'self_corp_list_table',
        columns: ['corpany_id', 'self_corp_info'],
        orderBy: 'corpany_id',
      );
      final candidates = <WeComDatasetIdentity>[];
      for (final row in rows) {
        final columnCorporationId = row['corpany_id'];
        final blob = row['self_corp_info'];
        if (columnCorporationId is! int || blob is! List<int>) {
          throw const WeComIdentityException(
            WeComIdentityIssueCode.invalidCorporationInfo,
            'Corporation identity row has invalid field types',
          );
        }
        final fields = _WireFields(Uint8List.fromList(blob));
        final corporationId = fields.firstVarint(1);
        final userId = fields.firstVarint(2);
        if (corporationId == null ||
            corporationId != columnCorporationId ||
            userId == null ||
            userId <= 0) {
          throw const WeComIdentityException(
            WeComIdentityIssueCode.invalidCorporationInfo,
            'self_corp_info does not contain a valid field 1/field 2 pair',
          );
        }
        candidates.add(
          WeComDatasetIdentity(
            corporationId: corporationId,
            userId: userId,
            corporationShortName: fields.firstString(3) ?? '',
            corporationFullName: fields.firstString(24) ?? '',
          ),
        );
      }
      return List.unmodifiable(candidates);
    } on WeComIdentityException {
      rethrow;
    } catch (error) {
      throw WeComIdentityException(
        WeComIdentityIssueCode.invalidCorporationInfo,
        'Could not decode corporation identity metadata',
        cause: error,
      );
    } finally {
      await database.close();
    }
  }

  Future<void> validate({
    required WeComImportedPackage package,
    required WeComDatasetIdentity identity,
  }) async {
    final candidates = await listCandidates(package);
    final persisted = _candidateForCorporation(
      candidates,
      identity.corporationId,
    );
    if (persisted == null || persisted.userId != identity.userId) {
      throw const WeComIdentityException(
        WeComIdentityIssueCode.invalidExplicitSelection,
        'Selected corporation/user pair is not present in company.db',
      );
    }

    await _validateUser(package: package, identity: identity);
  }

  Future<void> _validateUser({
    required WeComImportedPackage package,
    required WeComDatasetIdentity identity,
  }) async {
    final database = await package.openReadOnly(
      'user.db',
      factory: _databaseFactory,
    );
    try {
      final rows = await database.query(
        'user_table',
        columns: ['id', 'corp_id'],
        where: 'id = ?',
        whereArgs: [identity.userId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const WeComIdentityException(
          WeComIdentityIssueCode.selectedUserMissing,
          'Selected current user is missing from user_table',
        );
      }
      if (rows.single['corp_id'] != identity.corporationId) {
        throw const WeComIdentityException(
          WeComIdentityIssueCode.selectedUserCorporationMismatch,
          'Selected current user does not belong to the selected corporation',
        );
      }
    } finally {
      await database.close();
    }
  }

  WeComDatasetIdentity? _candidateForCorporation(
    List<WeComDatasetIdentity> candidates,
    int corporationId,
  ) {
    for (final candidate in candidates) {
      if (candidate.corporationId == corporationId) {
        return candidate;
      }
    }
    return null;
  }

  Future<int?> _readConfiguredCorporationId(File? configFile) async {
    if (configFile == null || !await configFile.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await configFile.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final config = decoded['config'];
      if (config is! Map) {
        return null;
      }
      final value = config['LoginCompanyId'];
      return value is String ? int.tryParse(value) : null;
    } catch (_) {
      return null;
    }
  }
}

class WeComCurrentIdentityRepository implements IdentityRepository {
  const WeComCurrentIdentityRepository(this._database, this.identity);

  final Database _database;
  final WeComDatasetIdentity identity;

  @override
  bool get isAvailable => true;

  @override
  Future<OfflineProfile> currentProfile() async {
    final rows = await _database.query(
      'user_table',
      columns: [
        'id',
        'real_name',
        'name',
        'account',
        'mobile',
        'email',
        'position',
        'pb_content',
      ],
      where: 'id = ?',
      whereArgs: [identity.userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('The selected WeCom user no longer exists.');
    }
    final user = rows.single;
    final pbContent = user['pb_content'];
    final fields = pbContent is List<int>
        ? _WireFields(Uint8List.fromList(pbContent))
        : null;
    final memberships = await _database.rawQuery(
      '''
SELECT ud.job, d.name AS department_name
FROM user_dept_tableV2 ud
JOIN department_tableV2 d ON d.id = ud.department_id
WHERE ud.user_id = ?
ORDER BY ud.is_main_job DESC, ud.sort ASC, ud.department_id ASC
LIMIT 1
''',
      [identity.userId],
    );
    final membership = memberships.isEmpty ? null : memberships.single;

    final topLevelAccount = _text(user['account']);
    final displayName = _firstNonEmpty([
      _text(user['real_name']),
      _text(user['name']),
      topLevelAccount,
    ]);
    final job = _firstNonEmpty([
      _text(membership?['job']),
      _text(user['position']),
    ]);
    final mobile = _firstNonEmpty([
      _text(user['mobile']),
      fields?.firstString(5),
    ]);
    final email = _firstNonEmpty([
      fields?.firstString(3),
      _text(user['email']),
    ]);

    return OfflineProfile(
      id: identity.userId.toString(),
      displayName: displayName,
      title: job,
      department: _text(membership?['department_name']),
      status: '',
      account: _firstNonEmpty([fields?.firstString(32), topLevelAccount]),
      corporationName: identity.corporationName,
      phone: mobile.isEmpty ? null : mobile,
      email: email.isEmpty ? null : email,
    );
  }

  static String _text(Object? value) => value is String ? value : '';

  static String _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }
}

class _WireFields {
  _WireFields(this._bytes) {
    _parse();
  }

  final Uint8List _bytes;
  final Map<int, List<int>> _varints = {};
  final Map<int, List<Uint8List>> _lengthDelimited = {};
  var _offset = 0;

  int? firstVarint(int fieldNumber) => _varints[fieldNumber]?.firstOrNull;

  String? firstString(int fieldNumber) {
    final value = _lengthDelimited[fieldNumber]?.firstOrNull;
    return value == null ? null : utf8.decode(value);
  }

  void _parse() {
    while (_offset < _bytes.length) {
      final key = _readVarint();
      final fieldNumber = key >> 3;
      final wireType = key & 7;
      if (fieldNumber == 0) {
        throw const FormatException('Invalid protobuf field number');
      }
      switch (wireType) {
        case 0:
          (_varints[fieldNumber] ??= []).add(_readVarint());
          break;
        case 1:
          _skip(8);
          break;
        case 2:
          final length = _readVarint();
          if (length < 0 || _offset + length > _bytes.length) {
            throw const FormatException('Invalid protobuf field length');
          }
          (_lengthDelimited[fieldNumber] ??= []).add(
            Uint8List.sublistView(_bytes, _offset, _offset + length),
          );
          _offset += length;
          break;
        case 5:
          _skip(4);
          break;
        default:
          throw FormatException('Unsupported protobuf wire type $wireType');
      }
    }
  }

  int _readVarint() {
    var value = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      if (_offset >= _bytes.length) {
        throw const FormatException('Truncated protobuf varint');
      }
      final byte = _bytes[_offset++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return value;
      }
    }
    throw const FormatException('Protobuf varint is too long');
  }

  void _skip(int length) {
    if (_offset + length > _bytes.length) {
      throw const FormatException('Truncated protobuf field');
    }
    _offset += length;
  }
}
