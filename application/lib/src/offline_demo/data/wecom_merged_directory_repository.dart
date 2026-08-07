import 'dart:convert';

import '../domain/wecom_directory_models.dart';
import 'wecom_directory_repository.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComMergedDirectoryRepository {
  const WeComMergedDirectoryRepository({
    required this.datasetId,
    required WeComDirectoryRepository baseRepository,
    required WeComOverlayDatabase overlayDatabase,
  })  : _baseRepository = baseRepository,
        _overlayDatabase = overlayDatabase;

  static const _databaseName = 'user.db';
  static const _tableName = 'user_table';

  final String datasetId;
  final WeComDirectoryRepository _baseRepository;
  final WeComOverlayDatabase _overlayDatabase;

  Future<List<WeComInternalContact>> listInternalContacts({
    int limit = WeComDirectoryRepository.maxPageSize,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > WeComDirectoryRepository.maxPageSize) {
      throw RangeError.range(
        limit,
        1,
        WeComDirectoryRepository.maxPageSize,
        'limit',
      );
    }
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Must not be negative');
    }

    final baseContacts = await _readAllBaseContacts();
    final baseById = <int, WeComInternalContact>{
      for (final contact in baseContacts) contact.id: contact,
    };
    final visible = <int, _ContactState>{
      for (final contact in baseContacts)
        contact.id: _ContactState.fromContact(contact),
    };
    final operations = await _overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      columns: ['row_key_json', 'operation', 'values_json'],
      where: 'dataset_id = ? AND database_name = ? AND table_name = ?',
      whereArgs: [datasetId, _databaseName, _tableName],
      orderBy: 'revision_id',
    );

    for (final operation in operations) {
      final rowKey = _decodeObject(
        operation['row_key_json']! as String,
        'row_key_json',
      );
      final id = rowKey['id'];
      if (rowKey.length != 1 || id is! int) {
        throw const FormatException('Invalid user_table overlay row key');
      }

      switch (operation['operation']) {
        case 'tombstone':
          visible.remove(id);
        case 'upsert':
          final valuesJson = operation['values_json'];
          if (valuesJson is! String) {
            throw const FormatException('Overlay upsert values are missing');
          }
          final state = visible[id] ??
              (baseById[id] == null
                  ? _ContactState.empty(id)
                  : _ContactState.fromContact(baseById[id]!));
          state.apply(_decodeObject(valuesJson, 'values_json'));
          visible[id] = state;
        default:
          throw FormatException(
            'Unsupported overlay operation: ${operation['operation']}',
          );
      }
    }

    final contacts = visible.values
        .map((state) => state.toContact())
        .toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));
    if (offset >= contacts.length) {
      return const [];
    }
    final requestedEnd = offset + limit;
    final end = requestedEnd < contacts.length ? requestedEnd : contacts.length;
    return List<WeComInternalContact>.unmodifiable(
      contacts.sublist(offset, end),
    );
  }

  Future<List<WeComInternalContact>> _readAllBaseContacts() async {
    final contacts = <WeComInternalContact>[];
    var offset = 0;
    while (true) {
      final page = await _baseRepository.listInternalContacts(offset: offset);
      contacts.addAll(page);
      if (page.length < WeComDirectoryRepository.maxPageSize) {
        return contacts;
      }
      offset += page.length;
    }
  }

  Map<String, Object?> _decodeObject(String source, String fieldName) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw FormatException('$fieldName must be a JSON object');
    }
    return Map<String, Object?>.from(decoded);
  }
}

class _ContactState {
  _ContactState({
    required this.id,
    required this.name,
    this.realName,
    this.account,
    this.externalCorporationName,
    this.externalJob,
  });

  factory _ContactState.fromContact(WeComInternalContact contact) {
    return _ContactState(
      id: contact.id,
      name: contact.name,
      realName: contact.realName,
      account: contact.account,
      externalCorporationName: contact.externalCorporationName,
      externalJob: contact.externalJob,
    );
  }

  factory _ContactState.empty(int id) {
    return _ContactState(
      id: id,
      name: '',
      realName: '',
      account: '',
      externalCorporationName: '',
      externalJob: '',
    );
  }

  final int id;
  String name;
  String? realName;
  String? account;
  String? externalCorporationName;
  String? externalJob;

  void apply(Map<String, Object?> values) {
    if (values.containsKey('name')) {
      name = _requiredString(values['name'], 'name');
    }
    if (values.containsKey('real_name')) {
      realName = _nullableString(values['real_name'], 'real_name');
    }
    if (values.containsKey('account')) {
      account = _nullableString(values['account'], 'account');
    }
    if (values.containsKey('external_corp_name')) {
      externalCorporationName = _nullableString(
        values['external_corp_name'],
        'external_corp_name',
      );
    }
    if (values.containsKey('external_job')) {
      externalJob = _nullableString(values['external_job'], 'external_job');
    }
  }

  WeComInternalContact toContact() {
    return WeComInternalContact.fromFields(
      id: id,
      name: name,
      realName: realName,
      account: account,
      externalCorporationName: externalCorporationName,
      externalJob: externalJob,
    );
  }

  static String _requiredString(Object? value, String fieldName) {
    if (value is! String) {
      throw FormatException('$fieldName must be a string');
    }
    return value;
  }

  static String? _nullableString(Object? value, String fieldName) {
    if (value != null && value is! String) {
      throw FormatException('$fieldName must be a nullable string');
    }
    return value as String?;
  }
}
