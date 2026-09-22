import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_database_package_exporter.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory sourceDirectory;
  late Directory destinationDirectory;
  late WeComPackageContract contract;
  late WeComDatabasePackageImporter importer;
  late WeComImportedPackage basePackage;
  late WeComOverlayDatabase overlayDatabase;
  late WeComOverlayCommandService commands;
  late WeComDatabasePackageExporter exporter;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_export_');
    sourceDirectory =
        await Directory(p.join(temporaryDirectory.path, 'source')).create();
    destinationDirectory =
        Directory(p.join(temporaryDirectory.path, 'compatible-copy'));
    contract = _contract();
    importer = WeComDatabasePackageImporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    await _createSourcePackage(sourceDirectory);
    basePackage = await importer.importPackage(
      sourceDirectory: sourceDirectory,
      destinationRoot: Directory(p.join(temporaryDirectory.path, 'imports')),
    );
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    commands = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
    );
    exporter = WeComDatabasePackageExporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('exports certified revisions as a re-importable compatible package',
      () async {
    final baseBefore = await _snapshotPackage(basePackage);
    await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Alicia'},
    );
    await commands.tombstone(
      datasetId: basePackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 2},
    );
    await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 3},
      values: const {'name': 'Overlay only'},
    );
    await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 3},
      values: const {'account': 'new-account'},
    );
    await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 10},
      values: const {'name': 'Renamed room', 'last_message_time': 300},
    );
    await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'session.db',
      tableName: 'unread_conversation_table',
      rowKey: const {'conversation_id': 'conv-a'},
      values: const {'unread_message_count': 5},
    );
    await commands.tombstone(
      datasetId: basePackage.datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_user_table',
      rowKey: const {'conversation_id': 'conv-a', 'user_id': 1},
    );
    final lastAppliedRevision = await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_user_table',
      rowKey: const {'conversation_id': 'conv-a', 'user_id': 2},
      values: const {'role': 2},
    );
    await commands.upsert(
      datasetId:
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      databaseName: 'user.db',
      tableName: 'user_table',
      rowKey: const {'id': 1},
      values: const {'name': 'Other dataset'},
    );

    final exported = await exporter.export(
      basePackage: basePackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
      destinationDirectory: destinationDirectory,
    );

    expect(exported.appliedRevisionCount, 8);
    expect(exported.lastAppliedRevisionId, lastAppliedRevision);
    expect(await _snapshotPackage(basePackage), baseBefore);
    expect(
      (await destinationDirectory.list().toList())
          .map((entity) => p.basename(entity.path))
          .toList()
        ..sort(),
      ['session.db', 'user.db'],
    );
    expect(
      await overlayDatabase.connection.rawQuery(
        'SELECT COUNT(*) AS count FROM ${WeComOverlaySchema.operationsTable}',
      ),
      [
        {'count': 9}
      ],
    );

    final reimported = await importer.importPackage(
      sourceDirectory: destinationDirectory,
      destinationRoot: Directory(p.join(temporaryDirectory.path, 'reimport')),
    );
    expect(reimported.datasetId, exported.datasetId);
    await _expectExportedRows(reimported);
  });

  test('rejects unclassified targets without creating an export', () async {
    final baseBefore = await _snapshotPackage(basePackage);
    await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_dept_tableV2',
      rowKey: const {'user_id': 1, 'department_id': 10},
      values: const {'status': 1},
    );

    await expectLater(
      exporter.export(
        basePackage: basePackage,
        overlayDatabase: overlayDatabase,
        identityScope: const WeComIdentityScope(
          corporationId: 100,
          userId: 1,
        ),
        destinationDirectory: destinationDirectory,
      ),
      throwsA(
        isA<WeComExportException>().having(
          (error) => error.code,
          'code',
          WeComExportIssueCode.unsupportedTarget,
        ),
      ),
    );

    expect(await destinationDirectory.exists(), isFalse);
    expect(await _snapshotPackage(basePackage), baseBefore);
  });

  test('ignores revisions owned by another identity', () async {
    final otherIdentityCommands = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
      identityScope: const WeComIdentityScope(
        corporationId: 200,
        userId: 2,
      ),
    );
    await otherIdentityCommands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'user.db',
      tableName: 'user_dept_tableV2',
      rowKey: const {'user_id': 1, 'department_id': 10},
      values: const {'status': 1},
    );

    final exported = await exporter.export(
      basePackage: basePackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
      destinationDirectory: destinationDirectory,
    );

    expect(exported.appliedRevisionCount, 0);
    expect(exported.lastAppliedRevisionId, isNull);
    expect(exported.datasetId, basePackage.datasetId);
  });

  test('does not include local simulation metadata in compatible exports',
      () async {
    final simulation = WeComLocalSimulationRepository(
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
      now: () => DateTime.utc(2026, 9, 15, 8),
    );
    await simulation.enqueueTextExchange(
      conversationId: 'conv-a',
      senderProfileId: '1',
      peerProfileId: '2',
      text: 'local only',
    );

    final exported = await exporter.export(
      basePackage: basePackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
      destinationDirectory: destinationDirectory,
    );

    expect(exported.appliedRevisionCount, 0);
    expect(exported.lastAppliedRevisionId, isNull);
    expect(exported.datasetId, basePackage.datasetId);
    expect(
      (await destinationDirectory.list().toList())
          .map((entity) => p.basename(entity.path))
          .toList()
        ..sort(),
      ['session.db', 'user.db'],
    );
  });

  test('does not include local-only announcement overlays in exports',
      () async {
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': basePackage.datasetId,
        'identity_corp_id': 100,
        'identity_user_id': 1,
        'database_name': 'forever_store.db',
        'table_name': 'announce_table',
        'row_key_json': '{"id":10}',
        'operation': 'upsert',
        'values_json': '{"subject":"Local only","summary":"Summary"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    final exported = await exporter.export(
      basePackage: basePackage,
      overlayDatabase: overlayDatabase,
      identityScope: const WeComIdentityScope(
        corporationId: 100,
        userId: 1,
      ),
      destinationDirectory: destinationDirectory,
    );

    expect(exported.appliedRevisionCount, 0);
    expect(exported.lastAppliedRevisionId, isNull);
    expect(exported.datasetId, basePackage.datasetId);
  });

  test('constraint failures leave the base and destination unchanged',
      () async {
    final baseBefore = await _snapshotPackage(basePackage);
    await commands.upsert(
      datasetId: basePackage.datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 20},
      values: const {'id': 'conv-a'},
    );

    await expectLater(
      exporter.export(
        basePackage: basePackage,
        overlayDatabase: overlayDatabase,
        identityScope: const WeComIdentityScope(
          corporationId: 100,
          userId: 1,
        ),
        destinationDirectory: destinationDirectory,
      ),
      throwsA(
        isA<WeComExportException>().having(
          (error) => error.code,
          'code',
          WeComExportIssueCode.applyFailed,
        ),
      ),
    );

    expect(await destinationDirectory.exists(), isFalse);
    expect(await _snapshotPackage(basePackage), baseBefore);
    expect(
      await temporaryDirectory
          .list()
          .where(
              (entity) => p.basename(entity.path).startsWith('.wecom-export-'))
          .isEmpty,
      isTrue,
    );
  });

  test('malformed certified revisions fail before an export is created',
      () async {
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': basePackage.datasetId,
        'identity_corp_id': 100,
        'identity_user_id': 1,
        'database_name': 'user.db',
        'table_name': 'user_table',
        'row_key_json': '{not-json',
        'operation': 'upsert',
        'values_json': '{"name":"Invalid"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    await expectLater(
      exporter.export(
        basePackage: basePackage,
        overlayDatabase: overlayDatabase,
        identityScope: const WeComIdentityScope(
          corporationId: 100,
          userId: 1,
        ),
        destinationDirectory: destinationDirectory,
      ),
      throwsA(
        isA<WeComExportException>().having(
          (error) => error.code,
          'code',
          WeComExportIssueCode.invalidOverlay,
        ),
      ),
    );
    expect(await destinationDirectory.exists(), isFalse);
  });
}

Future<void> _expectExportedRows(WeComImportedPackage package) async {
  final user = await package.openReadOnly(
    'user.db',
    factory: databaseFactoryFfi,
  );
  try {
    expect(
      await user.rawQuery(
        'SELECT id, real_name, name, account FROM user_table ORDER BY id',
      ),
      [
        {'id': 1, 'real_name': '', 'name': 'Alicia', 'account': 'alice'},
        {
          'id': 3,
          'real_name': '',
          'name': 'Overlay only',
          'account': 'new-account',
        },
      ],
    );
  } finally {
    await user.close();
  }

  final session = await package.openReadOnly(
    'session.db',
    factory: databaseFactoryFfi,
  );
  try {
    expect(
      await session.rawQuery(
        'SELECT con_numeric_id, id, name, last_message_time '
        'FROM conversation_table ORDER BY con_numeric_id',
      ),
      [
        {
          'con_numeric_id': 10,
          'id': 'conv-a',
          'name': 'Renamed room',
          'last_message_time': 300,
        },
        {
          'con_numeric_id': 20,
          'id': 'conv-b',
          'name': 'Second room',
          'last_message_time': 200,
        },
      ],
    );
    expect(
      await session.rawQuery(
        'SELECT conversation_id, unread_message_count '
        'FROM unread_conversation_table',
      ),
      [
        {'conversation_id': 'conv-a', 'unread_message_count': 5}
      ],
    );
    expect(
      await session.rawQuery(
        'SELECT conversation_id, user_id, role, join_time '
        'FROM conversation_user_table',
      ),
      [
        {
          'conversation_id': 'conv-a',
          'user_id': 2,
          'role': 2,
          'join_time': 0,
        }
      ],
    );
  } finally {
    await session.close();
  }
}

Future<Map<String, String>> _snapshotPackage(
  WeComImportedPackage package,
) async {
  final snapshot = <String, String>{};
  for (final name in package.files.keys) {
    snapshot[name] =
        (await sha256.bind(package.databaseFile(name).openRead()).first)
            .toString();
  }
  return snapshot;
}

WeComPackageContract _contract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'export certification test',
    databases: [
      WeComDatabaseContract(
        fileName: 'user.db',
        allowEmpty: false,
        tables: {
          'user_table': [
            _column('id', 'INTEGER', notNull: true, primaryKeyPosition: 1),
            _column('real_name', 'TEXT', notNull: true),
            _column('name', 'TEXT', notNull: true),
            _column('account', 'TEXT', notNull: true),
            _column('external_corp_name', 'TEXT', notNull: true),
            _column('external_job', 'TEXT', notNull: true),
          ],
          'user_dept_tableV2': [
            _column(
              'user_id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            _column(
              'department_id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 2,
            ),
            _column('status', 'INTEGER', notNull: true),
          ],
        },
        indexes: const {},
      ),
      WeComDatabaseContract(
        fileName: 'session.db',
        allowEmpty: false,
        tables: {
          'conversation_table': [
            _column(
              'con_numeric_id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            _column('id', 'TEXT', notNull: true),
            _column('type', 'INTEGER', notNull: true),
            _column('name', 'TEXT', notNull: true),
            _column('roomname_remark', 'TEXT', notNull: true),
            _column('last_message_time', 'INTEGER', notNull: true),
          ],
          'unread_conversation_table': [
            _column(
              'conversation_id',
              'TEXT',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            _column('unread_message_count', 'INTEGER', notNull: true),
            _column('first_unread_message_id', 'INTEGER', notNull: true),
            _column('last_message_id', 'INTEGER', notNull: true),
          ],
          'conversation_user_table': [
            _column(
              'conversation_id',
              'TEXT',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            _column(
              'user_id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 2,
            ),
            _column('role', 'INTEGER', notNull: true),
            _column('join_time', 'INTEGER', notNull: true),
          ],
        },
        indexes: const {},
      ),
    ],
  );
}

WeComColumnContract _column(
  String name,
  String type, {
  bool notNull = false,
  int primaryKeyPosition = 0,
}) {
  return WeComColumnContract(
    name: name,
    type: type,
    notNull: notNull,
    primaryKeyPosition: primaryKeyPosition,
  );
}

Future<void> _createSourcePackage(Directory source) async {
  var database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'user.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute(
    'CREATE TABLE user_table ('
    'id INTEGER NOT NULL PRIMARY KEY, '
    "real_name TEXT NOT NULL DEFAULT '', "
    "name TEXT NOT NULL DEFAULT '', "
    "account TEXT NOT NULL DEFAULT '', "
    "external_corp_name TEXT NOT NULL DEFAULT '', "
    "external_job TEXT NOT NULL DEFAULT ''"
    ')',
  );
  await database.execute(
    'CREATE TABLE user_dept_tableV2 ('
    'user_id INTEGER NOT NULL, '
    'department_id INTEGER NOT NULL, '
    'status INTEGER NOT NULL DEFAULT 0, '
    'PRIMARY KEY (user_id, department_id)'
    ')',
  );
  await database.insert(
    'user_table',
    {'id': 1, 'name': 'Alice', 'account': 'alice'},
  );
  await database.insert(
    'user_table',
    {'id': 2, 'name': 'Bob', 'account': 'bob'},
  );
  await database.close();

  database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'session.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute(
    'CREATE TABLE conversation_table ('
    'con_numeric_id INTEGER NOT NULL PRIMARY KEY, '
    'id TEXT NOT NULL UNIQUE, '
    'type INTEGER NOT NULL DEFAULT 0, '
    "name TEXT NOT NULL DEFAULT '', "
    "roomname_remark TEXT NOT NULL DEFAULT '', "
    'last_message_time INTEGER NOT NULL DEFAULT 0'
    ')',
  );
  await database.execute(
    'CREATE TABLE unread_conversation_table ('
    'conversation_id TEXT NOT NULL PRIMARY KEY, '
    'unread_message_count INTEGER NOT NULL DEFAULT 0, '
    'first_unread_message_id INTEGER NOT NULL DEFAULT 0, '
    'last_message_id INTEGER NOT NULL DEFAULT 0'
    ')',
  );
  await database.execute(
    'CREATE TABLE conversation_user_table ('
    'conversation_id TEXT NOT NULL, '
    'user_id INTEGER NOT NULL, '
    'role INTEGER NOT NULL DEFAULT 0, '
    'join_time INTEGER NOT NULL DEFAULT 0, '
    'PRIMARY KEY (conversation_id, user_id)'
    ')',
  );
  await database.insert(
    'conversation_table',
    {
      'con_numeric_id': 10,
      'id': 'conv-a',
      'name': 'First room',
      'last_message_time': 100,
    },
  );
  await database.insert(
    'conversation_table',
    {
      'con_numeric_id': 20,
      'id': 'conv-b',
      'name': 'Second room',
      'last_message_time': 200,
    },
  );
  await database.insert(
    'unread_conversation_table',
    {'conversation_id': 'conv-a', 'unread_message_count': 1},
  );
  await database.insert(
    'conversation_user_table',
    {'conversation_id': 'conv-a', 'user_id': 1, 'role': 1},
  );
  await database.close();
}
