import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'wecom_database_package.dart';
import 'wecom_overlay_database.dart';
import 'wecom_overlay_schema.dart';

class WeComOverlayCommandService {
  WeComOverlayCommandService({
    required WeComOverlayDatabase overlayDatabase,
    required WeComPackageContract contract,
  })  : _overlayDatabase = overlayDatabase,
        _contract = contract;

  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _ftsShadowSuffixes = <String>[
    'config',
    'content',
    'data',
    'docsize',
    'idx',
  ];

  final WeComOverlayDatabase _overlayDatabase;
  final WeComPackageContract _contract;

  Future<int> upsert({
    required String datasetId,
    required String databaseName,
    required String tableName,
    required Map<String, Object?> rowKey,
    required Map<String, Object?> values,
    String? baseRowSha256,
    int? revertsRevisionId,
  }) {
    return _append(
      datasetId: datasetId,
      databaseName: databaseName,
      tableName: tableName,
      rowKey: rowKey,
      operation: 'upsert',
      values: values,
      baseRowSha256: baseRowSha256,
      revertsRevisionId: revertsRevisionId,
    );
  }

  Future<int> tombstone({
    required String datasetId,
    required String databaseName,
    required String tableName,
    required Map<String, Object?> rowKey,
    String? baseRowSha256,
    int? revertsRevisionId,
  }) {
    return _append(
      datasetId: datasetId,
      databaseName: databaseName,
      tableName: tableName,
      rowKey: rowKey,
      operation: 'tombstone',
      baseRowSha256: baseRowSha256,
      revertsRevisionId: revertsRevisionId,
    );
  }

  Future<int> _append({
    required String datasetId,
    required String databaseName,
    required String tableName,
    required Map<String, Object?> rowKey,
    required String operation,
    Map<String, Object?>? values,
    String? baseRowSha256,
    int? revertsRevisionId,
  }) async {
    _validateSha256(datasetId, 'datasetId');
    if (baseRowSha256 != null) {
      _validateSha256(baseRowSha256, 'baseRowSha256');
    }
    if (revertsRevisionId != null && revertsRevisionId < 1) {
      throw ArgumentError.value(
        revertsRevisionId,
        'revertsRevisionId',
        'Must be positive',
      );
    }

    final target = _resolveTarget(databaseName, tableName);
    final rowKeyJson = jsonEncode(_canonicalRowKey(target, rowKey));
    final valuesJson =
        values == null ? null : jsonEncode(_canonicalValues(target, values));

    return _overlayDatabase.connection.transaction((transaction) async {
      if (revertsRevisionId != null) {
        await _validateRevertTarget(
          transaction,
          revisionId: revertsRevisionId,
          datasetId: datasetId,
          databaseName: databaseName,
          tableName: tableName,
          rowKeyJson: rowKeyJson,
        );
      }
      return transaction.insert(
        WeComOverlaySchema.operationsTable,
        {
          'dataset_id': datasetId,
          'database_name': databaseName,
          'table_name': tableName,
          'row_key_json': rowKeyJson,
          'operation': operation,
          'values_json': valuesJson,
          'base_row_sha256': baseRowSha256,
          'reverts_revision_id': revertsRevisionId,
          'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
        },
      );
    });
  }

  _OverlayTarget _resolveTarget(String databaseName, String tableName) {
    WeComDatabaseContract? database;
    for (final candidate in _contract.databases) {
      if (candidate.fileName == databaseName) {
        database = candidate;
        break;
      }
    }
    if (database == null) {
      throw ArgumentError.value(
        databaseName,
        'databaseName',
        'Not present in the active WeCom schema contract',
      );
    }

    final columns = database.tables[tableName];
    if (columns == null) {
      throw ArgumentError.value(
        tableName,
        'tableName',
        'Not present in $databaseName',
      );
    }
    if (_isManagedFtsTable(database, tableName)) {
      throw UnsupportedError(
        'FTS virtual and shadow tables are managed by SQLite: '
        '$databaseName/$tableName',
      );
    }

    final primaryKey = columns
        .where((column) => column.primaryKeyPosition > 0)
        .toList(growable: false)
      ..sort(
        (left, right) =>
            left.primaryKeyPosition.compareTo(right.primaryKeyPosition),
      );
    if (primaryKey.isEmpty) {
      throw UnsupportedError(
        'Tables without a documented primary key are read-only: '
        '$databaseName/$tableName',
      );
    }
    for (final column in primaryKey) {
      _ensureSupportedColumn(column, '$databaseName/$tableName primary key');
    }
    return _OverlayTarget(columns: columns, primaryKey: primaryKey);
  }

  Map<String, Object?> _canonicalRowKey(
    _OverlayTarget target,
    Map<String, Object?> rowKey,
  ) {
    final expectedNames =
        target.primaryKey.map((column) => column.name).toSet();
    if (rowKey.length != expectedNames.length ||
        !rowKey.keys.toSet().containsAll(expectedNames)) {
      throw ArgumentError.value(
        rowKey.keys.toList(growable: false),
        'rowKey',
        'Must contain exactly the documented primary-key fields',
      );
    }

    final canonical = <String, Object?>{};
    for (final column in target.primaryKey) {
      final value = rowKey[column.name];
      if (value == null) {
        throw ArgumentError.value(value, column.name, 'Primary key is null');
      }
      _validateScalar(column, value);
      canonical[column.name] = value;
    }
    return canonical;
  }

  Map<String, Object?> _canonicalValues(
    _OverlayTarget target,
    Map<String, Object?> values,
  ) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'Must not be empty');
    }

    final columnsByName = <String, WeComColumnContract>{
      for (final column in target.columns) column.name: column,
    };
    final primaryKeyNames =
        target.primaryKey.map((column) => column.name).toSet();
    for (final entry in values.entries) {
      final value = entry.value;
      final column = columnsByName[entry.key];
      if (column == null) {
        throw ArgumentError.value(
          entry.key,
          'values',
          'Field is not present in the documented table',
        );
      }
      if (primaryKeyNames.contains(entry.key)) {
        throw ArgumentError.value(
          entry.key,
          'values',
          'Primary-key fields belong in rowKey',
        );
      }
      _ensureSupportedColumn(column, 'overlay values');
      if (value == null && column.notNull) {
        throw ArgumentError.value(
          value,
          entry.key,
          'Documented NOT NULL field cannot be null',
        );
      }
      if (value != null) {
        _validateScalar(column, value);
      }
    }

    final canonical = <String, Object?>{};
    for (final column in target.columns) {
      if (values.containsKey(column.name)) {
        canonical[column.name] = values[column.name];
      }
    }
    return canonical;
  }

  bool _isManagedFtsTable(
    WeComDatabaseContract database,
    String tableName,
  ) {
    for (final virtualTable in database.expectedFtsTokenizers.keys) {
      if (tableName == virtualTable) {
        return true;
      }
      for (final suffix in _ftsShadowSuffixes) {
        if (tableName == '${virtualTable}_$suffix') {
          return true;
        }
      }
    }
    return false;
  }

  void _ensureSupportedColumn(
    WeComColumnContract column,
    String context,
  ) {
    if (column.type != 'INTEGER' &&
        column.type != 'TEXT' &&
        column.type != 'REAL' &&
        column.type != 'NUMERIC') {
      throw UnsupportedError(
        'BLOB and undeclared column encodings are read-only in $context: '
        '${column.name}',
      );
    }
  }

  void _validateScalar(WeComColumnContract column, Object value) {
    final matches = switch (column.type) {
      'INTEGER' => value is int,
      'TEXT' => value is String,
      'REAL' || 'NUMERIC' => value is num,
      _ => false,
    };
    if (!matches || (value is double && !value.isFinite)) {
      throw ArgumentError.value(
        value,
        column.name,
        'Does not match documented ${column.type} scalar type',
      );
    }
  }

  Future<void> _validateRevertTarget(
    Transaction transaction, {
    required int revisionId,
    required String datasetId,
    required String databaseName,
    required String tableName,
    required String rowKeyJson,
  }) async {
    final rows = await transaction.query(
      WeComOverlaySchema.operationsTable,
      columns: [
        'dataset_id',
        'database_name',
        'table_name',
        'row_key_json',
      ],
      where: 'revision_id = ?',
      whereArgs: [revisionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Reverted overlay revision does not exist: $revisionId');
    }
    final row = rows.single;
    if (row['dataset_id'] != datasetId ||
        row['database_name'] != databaseName ||
        row['table_name'] != tableName ||
        row['row_key_json'] != rowKeyJson) {
      throw StateError(
        'A revert must target the same dataset, table, and row key',
      );
    }
  }

  void _validateSha256(String value, String name) {
    if (!_sha256Pattern.hasMatch(value)) {
      throw ArgumentError.value(value, name, 'Must be a lowercase SHA-256');
    }
  }
}

class _OverlayTarget {
  const _OverlayTarget({
    required this.columns,
    required this.primaryKey,
  });

  final List<WeComColumnContract> columns;
  final List<WeComColumnContract> primaryKey;
}
