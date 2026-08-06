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

  test('creates only the approved technical operation log', () async {
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
      ],
    );
    expect(await database.connection.getVersion(), WeComOverlaySchema.version);
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
