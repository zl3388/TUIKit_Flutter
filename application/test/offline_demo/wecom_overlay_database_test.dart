import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const datasetId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  late Directory temporaryDirectory;
  late String databasePath;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_overlay_');
    databasePath = p.join(temporaryDirectory.path, 'overlay.db');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('creates only approved technical overlay metadata', () async {
    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    final tableNames = await _schemaObjectNames(database, 'table');
    final indexNames = await _schemaObjectNames(database, 'index');
    final triggerNames = await _schemaObjectNames(database, 'trigger');
    final columns = await database.connection.rawQuery(
      'PRAGMA table_info(${WeComOverlaySchema.operationsTable})',
    );

    expect(tableNames, WeComOverlaySchema.expectedTables);
    expect(indexNames, WeComOverlaySchema.expectedIndexes);
    expect(triggerNames, WeComOverlaySchema.expectedTriggers);
    expect(
      columns.map((row) => row['name']),
      [
        'revision_id',
        'dataset_id',
        'database_name',
        'table_name',
        'row_key_json',
        'operation',
        'values_json',
        'base_row_sha256',
        'reverts_revision_id',
        'created_at_micros',
        'identity_corp_id',
        'identity_user_id',
      ],
    );
    expect(
      await _columnNames(database, WeComOverlaySchema.mergeAttemptsTable),
      [
        'merge_id',
        'old_dataset_id',
        'new_dataset_id',
        'source_revision_count',
        'status',
        'first_applied_revision_id',
        'last_applied_revision_id',
        'conflict_count',
        'created_at_micros',
        'identity_corp_id',
        'identity_user_id',
      ],
    );
    expect(
      await _columnNames(database, WeComOverlaySchema.mergeConflictsTable),
      [
        'conflict_id',
        'merge_id',
        'database_name',
        'table_name',
        'row_key_json',
        'kind',
        'source_revision_ids_json',
        'conflicting_columns_json',
        'old_base_row_sha256',
        'new_base_row_sha256',
        'created_at_micros',
      ],
    );
    expect(
      await _columnNames(
        database,
        WeComOverlaySchema.datasetActivationsTable,
      ),
      [
        'activation_id',
        'previous_dataset_id',
        'dataset_id',
        'merge_id',
        'current_corp_id',
        'current_user_id',
        'created_at_micros',
      ],
    );
    expect(await database.connection.getVersion(), WeComOverlaySchema.version);
    expect(
      Sqflite.firstIntValue(
        await database.connection.rawQuery('PRAGMA foreign_keys'),
      ),
      1,
    );
  });

  test('operation history is append-only and undo is another revision',
      () async {
    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    final firstRevision = await _insertOperation(
      database,
      datasetId: datasetId,
      operation: 'upsert',
      valuesJson: '{"content":"updated"}',
    );
    final undoRevision = await _insertOperation(
      database,
      datasetId: datasetId,
      operation: 'tombstone',
      revertsRevisionId: firstRevision,
    );

    expect(undoRevision, greaterThan(firstRevision));
    await expectLater(
      database.connection.update(
        WeComOverlaySchema.operationsTable,
        {'values_json': '{"content":"mutated"}'},
        where: 'revision_id = ?',
        whereArgs: [firstRevision],
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      database.connection.delete(
        WeComOverlaySchema.operationsTable,
        where: 'revision_id = ?',
        whereArgs: [firstRevision],
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      Sqflite.firstIntValue(
        await database.connection.rawQuery(
          'SELECT COUNT(*) FROM ${WeComOverlaySchema.operationsTable}',
        ),
      ),
      2,
    );
  });

  test('rejects malformed technical metadata and invalid revisions', () async {
    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    await expectLater(
      _insertOperation(
        database,
        datasetId: 'not-a-dataset-id',
        operation: 'upsert',
        valuesJson: '{}',
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      _insertOperation(
        database,
        datasetId: datasetId,
        operation: 'upsert',
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      _insertOperation(
        database,
        datasetId: datasetId,
        operation: 'upsert',
        valuesJson: '{}',
        baseRowSha256: 'invalid-digest',
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      _insertOperation(
        database,
        datasetId: datasetId,
        operation: 'tombstone',
        valuesJson: '{}',
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      _insertOperation(
        database,
        datasetId: datasetId,
        operation: 'tombstone',
        revertsRevisionId: 99,
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('enforces technical foreign keys and merge identity uniqueness',
      () async {
    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);
    const newDatasetId =
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    final createdAt = DateTime.now().toUtc().microsecondsSinceEpoch;

    await database.connection.insert(
      WeComOverlaySchema.mergeAttemptsTable,
      {
        'old_dataset_id': datasetId,
        'new_dataset_id': newDatasetId,
        'identity_corp_id': 100,
        'identity_user_id': 1,
        'source_revision_count': 0,
        'status': 'conflicted',
        'conflict_count': 1,
        'created_at_micros': createdAt,
      },
    );
    await expectLater(
      database.connection.insert(
        WeComOverlaySchema.mergeAttemptsTable,
        {
          'old_dataset_id': datasetId,
          'new_dataset_id': newDatasetId,
          'identity_corp_id': 100,
          'identity_user_id': 1,
          'source_revision_count': 0,
          'status': 'conflicted',
          'conflict_count': 1,
          'created_at_micros': createdAt + 1,
        },
      ),
      throwsA(isA<DatabaseException>()),
    );
    await database.connection.insert(
      WeComOverlaySchema.mergeAttemptsTable,
      {
        'old_dataset_id': datasetId,
        'new_dataset_id': newDatasetId,
        'identity_corp_id': 200,
        'identity_user_id': 2,
        'source_revision_count': 0,
        'status': 'conflicted',
        'conflict_count': 1,
        'created_at_micros': createdAt + 2,
      },
    );
    await expectLater(
      database.connection.insert(
        WeComOverlaySchema.mergeConflictsTable,
        {
          'merge_id': 999,
          'database_name': 'user.db',
          'table_name': 'user_table',
          'row_key_json': '{"id":1}',
          'kind': 'fieldUpdate',
          'source_revision_ids_json': '[]',
          'conflicting_columns_json': '["name"]',
          'old_base_row_sha256': datasetId,
          'new_base_row_sha256': newDatasetId,
          'created_at_micros': createdAt + 2,
        },
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('requires identity metadata for new operations and merge attempts',
      () async {
    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);
    final createdAt = DateTime.now().toUtc().microsecondsSinceEpoch;

    await expectLater(
      database.connection.insert(
        WeComOverlaySchema.operationsTable,
        {
          'dataset_id': datasetId,
          'database_name': 'user.db',
          'table_name': 'user_table',
          'row_key_json': '{"id":1}',
          'operation': 'tombstone',
          'created_at_micros': createdAt,
        },
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      database.connection.insert(
        WeComOverlaySchema.mergeAttemptsTable,
        {
          'old_dataset_id': datasetId,
          'new_dataset_id': datasetId,
          'source_revision_count': 0,
          'status': 'applied',
          'conflict_count': 0,
          'created_at_micros': createdAt,
        },
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('upgrades version 1 without changing operation history', () async {
    final rawDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (database, version) =>
            WeComOverlaySchema.createVersion1(database),
      ),
    );
    await rawDatabase.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': datasetId,
        'database_name': 'message.db',
        'table_name': 'message_table',
        'row_key_json': '{"id":1}',
        'operation': 'upsert',
        'values_json': '{"content":"legacy"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
    await rawDatabase.close();

    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    expect(await database.connection.getVersion(), WeComOverlaySchema.version);
    expect(await _schemaObjectNames(database, 'table'),
        WeComOverlaySchema.expectedTables);
    expect(
      await database.connection.query(WeComOverlaySchema.operationsTable),
      hasLength(1),
    );
    expect(
      await database.connection.query(WeComOverlaySchema.mergeAttemptsTable),
      isEmpty,
    );
  });

  test('upgrades version 2 activations without inventing an identity',
      () async {
    final rawDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 2,
        singleInstance: false,
        onCreate: (database, version) async {
          await WeComOverlaySchema.createVersion1(database);
          for (final statement in WeComOverlaySchema.version2CreateStatements) {
            await database.execute(statement);
          }
        },
      ),
    );
    await rawDatabase.insert(
      WeComOverlaySchema.datasetActivationsTable,
      {
        'previous_dataset_id': null,
        'dataset_id': datasetId,
        'merge_id': null,
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
    await rawDatabase.close();

    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);
    final activation = (await database.connection.query(
      WeComOverlaySchema.datasetActivationsTable,
    ))
        .single;

    expect(await database.connection.getVersion(), WeComOverlaySchema.version);
    expect(activation['dataset_id'], datasetId);
    expect(activation['current_corp_id'], isNull);
    expect(activation['current_user_id'], isNull);
  });

  test('upgrades version 3 operations for one unambiguous identity', () async {
    final rawDatabase = await _openVersion3Database(databasePath);
    await rawDatabase.insert(
      WeComOverlaySchema.datasetActivationsTable,
      {
        'previous_dataset_id': null,
        'dataset_id': datasetId,
        'merge_id': null,
        'current_corp_id': 100,
        'current_user_id': 1,
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
    await rawDatabase.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': datasetId,
        'database_name': 'user.db',
        'table_name': 'user_table',
        'row_key_json': '{"id":1}',
        'operation': 'upsert',
        'values_json': '{"name":"legacy"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
    await rawDatabase.close();

    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);
    final operation = (await database.connection.query(
      WeComOverlaySchema.operationsTable,
    ))
        .single;

    expect(operation['identity_corp_id'], 100);
    expect(operation['identity_user_id'], 1);
  });

  test('does not assign ambiguous version 3 operations to an identity',
      () async {
    final rawDatabase = await _openVersion3Database(databasePath);
    for (final identity in const [(100, 1), (200, 2)]) {
      await rawDatabase.insert(
        WeComOverlaySchema.datasetActivationsTable,
        {
          'previous_dataset_id': identity.$1 == 100 ? null : datasetId,
          'dataset_id': datasetId,
          'merge_id': null,
          'current_corp_id': identity.$1,
          'current_user_id': identity.$2,
          'created_at_micros':
              DateTime.now().toUtc().microsecondsSinceEpoch + identity.$1,
        },
      );
    }
    await rawDatabase.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': datasetId,
        'database_name': 'user.db',
        'table_name': 'user_table',
        'row_key_json': '{"id":1}',
        'operation': 'upsert',
        'values_json': '{"name":"ambiguous"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
    await rawDatabase.close();

    final database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);
    final operation = (await database.connection.query(
      WeComOverlaySchema.operationsTable,
    ))
        .single;

    expect(operation['identity_corp_id'], isNull);
    expect(operation['identity_user_id'], isNull);
  });

  test('reopening preserves the append-only revision history', () async {
    var database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await _insertOperation(
      database,
      datasetId: datasetId,
      operation: 'upsert',
      valuesJson: '{"content":"persisted"}',
    );
    await database.close();

    database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    expect(
      await database.connection.query(WeComOverlaySchema.operationsTable),
      hasLength(1),
    );
  });
}

Future<List<String>> _columnNames(
  WeComOverlayDatabase database,
  String tableName,
) async {
  final rows = await database.connection.rawQuery(
    'PRAGMA table_info($tableName)',
  );
  return rows.map((row) => row['name']! as String).toList(growable: false);
}

Future<List<String>> _schemaObjectNames(
  WeComOverlayDatabase database,
  String type,
) async {
  final rows = await database.connection.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_%' "
    'ORDER BY name',
    [type],
  );
  return rows.map((row) => row['name']! as String).toList(growable: false);
}

Future<int> _insertOperation(
  WeComOverlayDatabase database, {
  required String datasetId,
  required String operation,
  String? valuesJson,
  String? baseRowSha256,
  int? revertsRevisionId,
}) {
  return database.connection.insert(
    WeComOverlaySchema.operationsTable,
    {
      'dataset_id': datasetId,
      'identity_corp_id': 100,
      'identity_user_id': 1,
      'database_name': 'message.db',
      'table_name': 'message_table',
      'row_key_json': '{"id":1}',
      'operation': operation,
      'values_json': valuesJson,
      'base_row_sha256': baseRowSha256,
      'reverts_revision_id': revertsRevisionId,
      'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
    },
  );
}

Future<Database> _openVersion3Database(String databasePath) {
  return databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 3,
      singleInstance: false,
      onCreate: (database, version) async {
        await WeComOverlaySchema.createVersion1(database);
        for (final statement in WeComOverlaySchema.version2CreateStatements) {
          await database.execute(statement);
        }
        for (final statement in WeComOverlaySchema.version3UpgradeStatements) {
          await database.execute(statement);
        }
      },
    ),
  );
}
