import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'wecom_database_package.dart';
import 'wecom_identity_repository.dart';
import 'wecom_overlay_contract_validator.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

enum WeComIncrementalMergeIssueCode {
  sameDataset,
  packageChanged,
  unsupportedTarget,
  invalidOverlay,
}

class WeComIncrementalMergeException implements Exception {
  const WeComIncrementalMergeException(
    this.code,
    this.message, {
    this.fileName,
    this.revisionId,
    this.cause,
  });

  final WeComIncrementalMergeIssueCode code;
  final String message;
  final String? fileName;
  final int? revisionId;
  final Object? cause;

  @override
  String toString() {
    final file = fileName == null ? '' : ' [$fileName]';
    final revision = revisionId == null ? '' : ' [revision=$revisionId]';
    return 'WeComIncrementalMergeException.${code.name}'
        '$file$revision: $message';
  }
}

enum WeComIncrementalConflictKind {
  baseFingerprintMismatch,
  concurrentInsert,
  remoteDelete,
  localDeleteRemoteUpdate,
  localReplaceRemoteUpdate,
  fieldUpdate,
}

enum WeComPlannedOverlayOperationType {
  upsert,
  tombstone,
}

class WeComIncrementalMergeConflict {
  WeComIncrementalMergeConflict({
    required this.kind,
    required this.databaseName,
    required this.tableName,
    required Map<String, Object?> rowKey,
    required List<int> sourceRevisionIds,
    required List<String> conflictingColumns,
    required this.oldBaseRowSha256,
    required this.newBaseRowSha256,
  })  : rowKey = Map.unmodifiable(rowKey),
        sourceRevisionIds = List.unmodifiable(sourceRevisionIds),
        conflictingColumns = List.unmodifiable(conflictingColumns);

  final WeComIncrementalConflictKind kind;
  final String databaseName;
  final String tableName;
  final Map<String, Object?> rowKey;
  final List<int> sourceRevisionIds;
  final List<String> conflictingColumns;
  final String oldBaseRowSha256;
  final String newBaseRowSha256;
}

class WeComPlannedOverlayOperation {
  WeComPlannedOverlayOperation({
    required this.type,
    required this.databaseName,
    required this.tableName,
    required Map<String, Object?> rowKey,
    required Map<String, Object?>? values,
    required this.baseRowSha256,
    required List<int> sourceRevisionIds,
  })  : rowKey = Map.unmodifiable(rowKey),
        values = values == null ? null : Map.unmodifiable(values),
        sourceRevisionIds = List.unmodifiable(sourceRevisionIds);

  final WeComPlannedOverlayOperationType type;
  final String databaseName;
  final String tableName;
  final Map<String, Object?> rowKey;
  final Map<String, Object?>? values;
  final String baseRowSha256;
  final List<int> sourceRevisionIds;
}

class WeComIncrementalMergePlan {
  WeComIncrementalMergePlan({
    required this.oldDatasetId,
    required this.newDatasetId,
    required this.identityScope,
    required this.sourceRevisionCount,
    required List<WeComPlannedOverlayOperation> operations,
    required List<WeComIncrementalMergeConflict> conflicts,
  })  : operations = List.unmodifiable(operations),
        conflicts = List.unmodifiable(conflicts);

  final String oldDatasetId;
  final String newDatasetId;
  final WeComIdentityScope identityScope;
  final int sourceRevisionCount;
  final List<WeComPlannedOverlayOperation> operations;
  final List<WeComIncrementalMergeConflict> conflicts;

  bool get canApply => conflicts.isEmpty;
}

abstract final class WeComBaseRowFingerprint {
  static String compute(
    WeComOverlayTarget target,
    Map<String, Object?>? row,
  ) {
    final payload = <Object?>['wecom-base-row-v1'];
    if (row == null) {
      payload.add('absent');
    } else {
      for (final column in target.columns) {
        if (!row.containsKey(column.name)) {
          throw FormatException(
            'Base row is missing contract column: ${column.name}',
          );
        }
      }
      payload.add([
        for (final column in target.columns)
          [column.name, ..._encodeValue(row[column.name])],
      ]);
    }
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  static List<Object?> _encodeValue(Object? value) {
    if (value == null) {
      return const ['null'];
    }
    if (value is int) {
      return ['integer', value.toString()];
    }
    if (value is double) {
      if (!value.isFinite) {
        throw const FormatException('SQLite REAL value must be finite');
      }
      return ['real', value.toString()];
    }
    if (value is String) {
      return ['text', value];
    }
    if (value is List<int>) {
      return ['blob', base64Encode(value)];
    }
    throw FormatException(
      'Unsupported SQLite storage value: ${value.runtimeType}',
    );
  }
}

class WeComIncrementalMergePlanner {
  WeComIncrementalMergePlanner({
    required WeComPackageContract contract,
    required DatabaseFactory databaseFactory,
  })  : _contract = contract,
        _databaseFactory = databaseFactory,
        _validator = WeComOverlayContractValidator(contract);

  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  final WeComPackageContract _contract;
  final DatabaseFactory _databaseFactory;
  final WeComOverlayContractValidator _validator;

  Future<WeComIncrementalMergePlan> plan({
    required WeComImportedPackage oldBasePackage,
    required WeComImportedPackage newBasePackage,
    required WeComOverlayDatabase overlayDatabase,
    required WeComIdentityScope identityScope,
  }) async {
    identityScope.validate();
    if (oldBasePackage.datasetId == newBasePackage.datasetId) {
      throw const WeComIncrementalMergeException(
        WeComIncrementalMergeIssueCode.sameDataset,
        'Incremental merge requires a different base dataset',
      );
    }

    await _verifyPackage(oldBasePackage);
    await _verifyPackage(newBasePackage);

    final rows = await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      where: 'dataset_id = ? AND identity_corp_id = ? '
          'AND identity_user_id = ?',
      whereArgs: [
        oldBasePackage.datasetId,
        identityScope.corporationId,
        identityScope.userId,
      ],
      orderBy: 'revision_id',
    );
    final groups = <String, _RowChange>{};
    for (final row in rows) {
      final operation = _parseOperation(row);
      final key = '${operation.databaseName}/${operation.tableName}/'
          '${jsonEncode(operation.rowKey)}';
      groups
          .putIfAbsent(
            key,
            () => _RowChange(
              databaseName: operation.databaseName,
              tableName: operation.tableName,
              target: operation.target,
              rowKey: operation.rowKey,
            ),
          )
          .operations
          .add(operation);
    }

    final plannedOperations = <WeComPlannedOverlayOperation>[];
    final conflicts = <WeComIncrementalMergeConflict>[];
    final oldConnections = <String, Database>{};
    final newConnections = <String, Database>{};
    try {
      for (final change in groups.values) {
        final oldDatabase = oldConnections[change.databaseName] ??=
            await oldBasePackage.openReadOnly(
          change.databaseName,
          factory: _databaseFactory,
        );
        final newDatabase = newConnections[change.databaseName] ??=
            await newBasePackage.openReadOnly(
          change.databaseName,
          factory: _databaseFactory,
        );
        final oldRow = await _readRow(oldDatabase, change);
        final newRow = await _readRow(newDatabase, change);
        _planRow(
          change,
          oldRow,
          newRow,
          plannedOperations,
          conflicts,
        );
      }
    } finally {
      for (final database in oldConnections.values) {
        await database.close();
      }
      for (final database in newConnections.values) {
        await database.close();
      }
    }

    await _verifyPackage(oldBasePackage);
    await _verifyPackage(newBasePackage);
    return WeComIncrementalMergePlan(
      oldDatasetId: oldBasePackage.datasetId,
      newDatasetId: newBasePackage.datasetId,
      identityScope: identityScope,
      sourceRevisionCount: rows.length,
      operations: plannedOperations,
      conflicts: conflicts,
    );
  }

  _ParsedOperation _parseOperation(Map<String, Object?> row) {
    final revisionId = row['revision_id'];
    final databaseName = row['database_name'];
    final tableName = row['table_name'];
    final operation = row['operation'];
    if (revisionId is! int ||
        databaseName is! String ||
        tableName is! String ||
        operation is! String) {
      throw const WeComIncrementalMergeException(
        WeComIncrementalMergeIssueCode.invalidOverlay,
        'Overlay revision metadata is malformed',
      );
    }
    if (!WeComOverlayContractValidator.incrementalMergeTargets
        .contains('$databaseName/$tableName')) {
      throw WeComIncrementalMergeException(
        WeComIncrementalMergeIssueCode.unsupportedTarget,
        'Overlay target has not passed incremental merge certification',
        fileName: databaseName,
        revisionId: revisionId,
      );
    }

    try {
      final target = _validator.resolveTarget(databaseName, tableName);
      final rowKey = _validator.canonicalRowKey(
        target,
        _decodeMap(row['row_key_json']),
      );
      Map<String, Object?>? values;
      if (operation == 'upsert') {
        values = _validator.canonicalValues(
          target,
          _decodeMap(row['values_json']),
        );
      } else if (operation != 'tombstone' || row['values_json'] != null) {
        throw const FormatException('Invalid overlay operation payload');
      }

      final baseRowSha256 = row['base_row_sha256'];
      if (baseRowSha256 != null &&
          (baseRowSha256 is! String ||
              !_sha256Pattern.hasMatch(baseRowSha256))) {
        throw const FormatException('Invalid base row fingerprint');
      }
      return _ParsedOperation(
        revisionId: revisionId,
        databaseName: databaseName,
        tableName: tableName,
        target: target,
        rowKey: rowKey,
        operation: operation,
        values: values,
        baseRowSha256: baseRowSha256 as String?,
      );
    } catch (error) {
      throw WeComIncrementalMergeException(
        WeComIncrementalMergeIssueCode.invalidOverlay,
        'Overlay revision does not match the active schema contract',
        fileName: databaseName,
        revisionId: revisionId,
        cause: error,
      );
    }
  }

  Map<String, Object?> _decodeMap(Object? source) {
    if (source is! String) {
      throw const FormatException('Overlay JSON is missing');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Overlay JSON must be an object');
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<Map<String, Object?>?> _readRow(
    Database database,
    _RowChange change,
  ) async {
    final where = change.rowKey.keys
        .map((column) => '${_quoteIdentifier(column)} = ?')
        .join(' AND ');
    final rows = await database.query(
      change.tableName,
      columns: change.target.columns
          .map((column) => column.name)
          .toList(growable: false),
      where: where,
      whereArgs: change.rowKey.values.toList(growable: false),
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  void _planRow(
    _RowChange change,
    Map<String, Object?>? oldRow,
    Map<String, Object?>? newRow,
    List<WeComPlannedOverlayOperation> plannedOperations,
    List<WeComIncrementalMergeConflict> conflicts,
  ) {
    final oldFingerprint =
        WeComBaseRowFingerprint.compute(change.target, oldRow);
    final newFingerprint =
        WeComBaseRowFingerprint.compute(change.target, newRow);
    if (change.operations.any(
      (operation) =>
          operation.baseRowSha256 != null &&
          operation.baseRowSha256 != oldFingerprint,
    )) {
      conflicts.add(
        _conflict(
          change,
          WeComIncrementalConflictKind.baseFingerprintMismatch,
          oldFingerprint,
          newFingerprint,
        ),
      );
      return;
    }

    if (change.hasTombstone) {
      _planRowWithTombstone(
        change,
        oldRow,
        newRow,
        oldFingerprint,
        newFingerprint,
        plannedOperations,
        conflicts,
      );
      return;
    }

    final localValues = change.finalValues;
    if (oldRow == null) {
      if (newRow != null) {
        conflicts.add(
          _conflict(
            change,
            WeComIncrementalConflictKind.concurrentInsert,
            oldFingerprint,
            newFingerprint,
          ),
        );
      } else {
        plannedOperations.add(
          _upsert(change, localValues, newFingerprint),
        );
      }
      return;
    }
    if (newRow == null) {
      conflicts.add(
        _conflict(
          change,
          WeComIncrementalConflictKind.remoteDelete,
          oldFingerprint,
          newFingerprint,
        ),
      );
      return;
    }

    final migratedValues = <String, Object?>{};
    final conflictingColumns = <String>[];
    for (final column in change.target.columns) {
      if (!localValues.containsKey(column.name)) {
        continue;
      }
      final oldValue = oldRow[column.name];
      final newValue = newRow[column.name];
      final localValue = localValues[column.name];
      if (_valuesEqual(localValue, oldValue) ||
          _valuesEqual(localValue, newValue)) {
        continue;
      }
      if (_valuesEqual(oldValue, newValue)) {
        migratedValues[column.name] = localValue;
      } else {
        conflictingColumns.add(column.name);
      }
    }
    if (conflictingColumns.isNotEmpty) {
      conflicts.add(
        _conflict(
          change,
          WeComIncrementalConflictKind.fieldUpdate,
          oldFingerprint,
          newFingerprint,
          conflictingColumns: conflictingColumns,
        ),
      );
    } else if (migratedValues.isNotEmpty) {
      plannedOperations.add(
        _upsert(change, migratedValues, newFingerprint),
      );
    }
  }

  void _planRowWithTombstone(
    _RowChange change,
    Map<String, Object?>? oldRow,
    Map<String, Object?>? newRow,
    String oldFingerprint,
    String newFingerprint,
    List<WeComPlannedOverlayOperation> plannedOperations,
    List<WeComIncrementalMergeConflict> conflicts,
  ) {
    if (change.endsWithTombstone) {
      if (oldRow == null) {
        if (newRow != null) {
          conflicts.add(
            _conflict(
              change,
              WeComIncrementalConflictKind.concurrentInsert,
              oldFingerprint,
              newFingerprint,
            ),
          );
        }
        return;
      }
      if (newRow == null) {
        return;
      }
      if (!_rowsEqual(change.target, oldRow, newRow)) {
        conflicts.add(
          _conflict(
            change,
            WeComIncrementalConflictKind.localDeleteRemoteUpdate,
            oldFingerprint,
            newFingerprint,
          ),
        );
        return;
      }
      plannedOperations.add(_tombstone(change, newFingerprint));
      return;
    }

    if (oldRow == null) {
      if (newRow != null) {
        conflicts.add(
          _conflict(
            change,
            WeComIncrementalConflictKind.concurrentInsert,
            oldFingerprint,
            newFingerprint,
          ),
        );
      } else {
        plannedOperations.add(
          _upsert(change, change.finalValues, newFingerprint),
        );
      }
      return;
    }
    if (newRow == null) {
      conflicts.add(
        _conflict(
          change,
          WeComIncrementalConflictKind.remoteDelete,
          oldFingerprint,
          newFingerprint,
        ),
      );
      return;
    }
    if (!_rowsEqual(change.target, oldRow, newRow)) {
      conflicts.add(
        _conflict(
          change,
          WeComIncrementalConflictKind.localReplaceRemoteUpdate,
          oldFingerprint,
          newFingerprint,
        ),
      );
      return;
    }

    plannedOperations
      ..add(_tombstone(change, newFingerprint))
      ..add(_upsert(change, change.finalValues, newFingerprint));
  }

  WeComIncrementalMergeConflict _conflict(
    _RowChange change,
    WeComIncrementalConflictKind kind,
    String oldFingerprint,
    String newFingerprint, {
    List<String> conflictingColumns = const [],
  }) {
    return WeComIncrementalMergeConflict(
      kind: kind,
      databaseName: change.databaseName,
      tableName: change.tableName,
      rowKey: change.rowKey,
      sourceRevisionIds: change.sourceRevisionIds,
      conflictingColumns: conflictingColumns,
      oldBaseRowSha256: oldFingerprint,
      newBaseRowSha256: newFingerprint,
    );
  }

  WeComPlannedOverlayOperation _upsert(
    _RowChange change,
    Map<String, Object?> values,
    String newFingerprint,
  ) {
    return WeComPlannedOverlayOperation(
      type: WeComPlannedOverlayOperationType.upsert,
      databaseName: change.databaseName,
      tableName: change.tableName,
      rowKey: change.rowKey,
      values: values,
      baseRowSha256: newFingerprint,
      sourceRevisionIds: change.sourceRevisionIds,
    );
  }

  WeComPlannedOverlayOperation _tombstone(
    _RowChange change,
    String newFingerprint,
  ) {
    return WeComPlannedOverlayOperation(
      type: WeComPlannedOverlayOperationType.tombstone,
      databaseName: change.databaseName,
      tableName: change.tableName,
      rowKey: change.rowKey,
      values: null,
      baseRowSha256: newFingerprint,
      sourceRevisionIds: change.sourceRevisionIds,
    );
  }

  bool _rowsEqual(
    WeComOverlayTarget target,
    Map<String, Object?> left,
    Map<String, Object?> right,
  ) {
    for (final column in target.columns) {
      if (!_valuesEqual(left[column.name], right[column.name])) {
        return false;
      }
    }
    return true;
  }

  bool _valuesEqual(Object? left, Object? right) {
    if (left is List<int> && right is List<int>) {
      if (left.length != right.length) {
        return false;
      }
      for (var index = 0; index < left.length; index++) {
        if (left[index] != right[index]) {
          return false;
        }
      }
      return true;
    }
    return left == right;
  }

  String _quoteIdentifier(String value) {
    return '"${value.replaceAll('"', '""')}"';
  }

  Future<void> _verifyPackage(WeComImportedPackage package) async {
    final expectedNames =
        _contract.databases.map((database) => database.fileName).toSet();
    if (package.files.length != expectedNames.length ||
        !package.files.keys.toSet().containsAll(expectedNames)) {
      throw const WeComIncrementalMergeException(
        WeComIncrementalMergeIssueCode.packageChanged,
        'Imported dataset does not match the active package contract',
      );
    }

    for (final database in _contract.databases) {
      final metadata = package.files[database.fileName]!;
      final file = package.databaseFile(database.fileName);
      try {
        if (!await file.exists() ||
            await file.length() != metadata.sizeBytes ||
            await _hashFile(file) != metadata.sha256) {
          throw WeComIncrementalMergeException(
            WeComIncrementalMergeIssueCode.packageChanged,
            'Imported base database changed after validation',
            fileName: database.fileName,
          );
        }
      } on WeComIncrementalMergeException {
        rethrow;
      } catch (error) {
        throw WeComIncrementalMergeException(
          WeComIncrementalMergeIssueCode.packageChanged,
          'Could not verify imported base database',
          fileName: database.fileName,
          cause: error,
        );
      }
    }
  }

  Future<String> _hashFile(File file) async {
    return (await sha256.bind(file.openRead()).first).toString();
  }
}

class _ParsedOperation {
  const _ParsedOperation({
    required this.revisionId,
    required this.databaseName,
    required this.tableName,
    required this.target,
    required this.rowKey,
    required this.operation,
    required this.values,
    required this.baseRowSha256,
  });

  final int revisionId;
  final String databaseName;
  final String tableName;
  final WeComOverlayTarget target;
  final Map<String, Object?> rowKey;
  final String operation;
  final Map<String, Object?>? values;
  final String? baseRowSha256;
}

class _RowChange {
  _RowChange({
    required this.databaseName,
    required this.tableName,
    required this.target,
    required this.rowKey,
  });

  final String databaseName;
  final String tableName;
  final WeComOverlayTarget target;
  final Map<String, Object?> rowKey;
  final List<_ParsedOperation> operations = [];

  bool get hasTombstone =>
      operations.any((operation) => operation.operation == 'tombstone');

  bool get endsWithTombstone => operations.last.operation == 'tombstone';

  List<int> get sourceRevisionIds =>
      operations.map((operation) => operation.revisionId).toList();

  Map<String, Object?> get finalValues {
    var start = 0;
    for (var index = operations.length - 1; index >= 0; index--) {
      if (operations[index].operation == 'tombstone') {
        start = index + 1;
        break;
      }
    }
    final values = <String, Object?>{};
    for (var index = start; index < operations.length; index++) {
      values.addAll(operations[index].values ?? const {});
    }
    return values;
  }
}
