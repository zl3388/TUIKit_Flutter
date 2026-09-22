import 'wecom_database_package.dart';

class WeComOverlayTarget {
  const WeComOverlayTarget({
    required this.columns,
    required this.primaryKey,
  });

  final List<WeComColumnContract> columns;
  final List<WeComColumnContract> primaryKey;
}

class WeComOverlayContractValidator {
  WeComOverlayContractValidator(this._contract);

  static const compatibleCopyTargets = <String>{
    'user.db/user_table',
    'session.db/conversation_table',
    'session.db/unread_conversation_table',
    'session.db/conversation_user_table',
  };

  static const localOnlyTargets = <String>{
    'forever_store.db/announce_table',
  };

  static const incrementalMergeTargets = <String>{
    ...compatibleCopyTargets,
    ...localOnlyTargets,
  };

  static const _ftsShadowSuffixes = <String>[
    'config',
    'content',
    'data',
    'docsize',
    'idx',
  ];

  final WeComPackageContract _contract;

  WeComOverlayTarget resolveTarget(String databaseName, String tableName) {
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
    return WeComOverlayTarget(columns: columns, primaryKey: primaryKey);
  }

  Map<String, Object?> canonicalRowKey(
    WeComOverlayTarget target,
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

  Map<String, Object?> canonicalValues(
    WeComOverlayTarget target,
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
}
