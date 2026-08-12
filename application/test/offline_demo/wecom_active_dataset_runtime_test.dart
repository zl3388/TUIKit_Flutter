import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_merge_planner.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_migration_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory destinationRoot;
  late WeComPackageContract contract;
  late WeComDatabasePackageImporter importer;
  late WeComOverlayDatabase overlayDatabase;
  late WeComActiveDatasetResolver resolver;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_runtime_');
    destinationRoot = Directory(p.join(temporaryDirectory.path, 'imports'));
    contract = _contract();
    importer = WeComDatabasePackageImporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    resolver = WeComActiveDatasetResolver(
      destinationRoot: destinationRoot,
      packageImporter: importer,
      databaseFactory: databaseFactoryFfi,
      overlayDatabase: overlayDatabase,
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('requires an explicit initial dataset activation', () async {
    await expectLater(
      resolver.openActive(),
      throwsA(
        isA<WeComActiveDatasetException>().having(
          (error) => error.code,
          'code',
          WeComActiveDatasetIssueCode.noActiveDataset,
        ),
      ),
    );
  });

  test('activates once and assembles repositories for that dataset', () async {
    final initial = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'initial',
      contactName: 'Base contact',
      conversationName: 'Base room',
    );
    final other = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'other',
      contactName: 'Other contact',
      conversationName: 'Other room',
    );

    expect(await resolver.ensureInitialDataset(initial.datasetId), isTrue);
    expect(await resolver.ensureInitialDataset(initial.datasetId), isFalse);
    await expectLater(
      resolver.ensureInitialDataset(other.datasetId),
      throwsA(
        isA<WeComActiveDatasetException>().having(
          (error) => error.code,
          'code',
          WeComActiveDatasetIssueCode.activeDatasetMismatch,
        ),
      ),
    );
    expect(
      await _activationCount(overlayDatabase),
      1,
    );

    await overlayDatabase.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': initial.datasetId,
        'database_name': 'user.db',
        'table_name': 'user_table',
        'row_key_json': '{"id":1}',
        'operation': 'upsert',
        'values_json': '{"name":"Local contact"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    final runtime = await resolver.openActive();
    expect(runtime.datasetId, initial.datasetId);
    expect(
      (await runtime.directory.listInternalContacts()).single.displayName,
      'Local contact',
    );
    expect(
      (await runtime.conversations.listConversations()).single.displayName,
      'Base room',
    );
    await runtime.close();
    await runtime.close();

    final reopened = await resolver.openActive();
    expect(reopened.datasetId, initial.datasetId);
    await reopened.close();
  });

  test('uses the latest dataset selected by an applied migration', () async {
    final oldPackage = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'old',
      contactName: 'Old contact',
      conversationName: 'Old room',
    );
    final newPackage = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'new',
      contactName: 'New contact',
      conversationName: 'New room',
    );
    await resolver.ensureInitialDataset(oldPackage.datasetId);

    final migrations = WeComIncrementalMigrationService(
      overlayDatabase: overlayDatabase,
      planner: WeComIncrementalMergePlanner(
        contract: contract,
        databaseFactory: databaseFactoryFfi,
      ),
    );
    final result = await migrations.migrate(
      oldBasePackage: oldPackage,
      newBasePackage: newPackage,
    );
    expect(result.applied, isTrue);

    final runtime = await resolver.openActive();
    expect(runtime.datasetId, newPackage.datasetId);
    expect(
      (await runtime.directory.listInternalContacts()).single.displayName,
      'New contact',
    );
    expect(
      (await runtime.conversations.listConversations()).single.displayName,
      'New room',
    );
    await runtime.close();
  });

  test('rejects an active package whose imported file changed', () async {
    final imported = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'corrupt',
      contactName: 'Contact',
      conversationName: 'Room',
    );
    await resolver.ensureInitialDataset(imported.datasetId);
    await imported.databaseFile('user.db').writeAsBytes(
      const [0],
      mode: FileMode.append,
      flush: true,
    );

    await expectLater(
      resolver.openActive(),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.existingPackageCorrupt,
        ),
      ),
    );
  });
}

Future<int> _activationCount(WeComOverlayDatabase overlayDatabase) async {
  final rows = await overlayDatabase.connection.query(
    WeComOverlaySchema.datasetActivationsTable,
    columns: ['activation_id'],
  );
  return rows.length;
}

Future<WeComImportedPackage> _importPackage(
  Directory root,
  WeComDatabasePackageImporter importer, {
  required String name,
  required String contactName,
  required String conversationName,
}) async {
  final source = await Directory(p.join(root.path, name)).create();
  await _createUserDatabase(source, contactName);
  await _createSessionDatabase(source, conversationName);
  return importer.importPackage(
    sourceDirectory: source,
    destinationRoot: Directory(p.join(root.path, 'imports')),
  );
}

Future<void> _createUserDatabase(
  Directory source,
  String contactName,
) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'user.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute(
    'CREATE TABLE user_table ('
    'id INTEGER PRIMARY KEY, '
    "real_name TEXT NOT NULL DEFAULT '', "
    "name TEXT NOT NULL DEFAULT '', "
    "account TEXT NOT NULL DEFAULT '', "
    "external_corp_name TEXT NOT NULL DEFAULT '', "
    "external_job TEXT NOT NULL DEFAULT ''"
    ')',
  );
  await database.insert(
    'user_table',
    {
      'id': 1,
      'name': contactName,
    },
  );
  await database.close();
}

Future<void> _createSessionDatabase(
  Directory source,
  String conversationName,
) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'session.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute(
    'CREATE TABLE conversation_table ('
    'con_numeric_id INTEGER PRIMARY KEY, '
    "id TEXT NOT NULL DEFAULT '', "
    "name TEXT NOT NULL DEFAULT '', "
    'is_sticked INTEGER NOT NULL DEFAULT 0, '
    'last_message_time INTEGER DEFAULT 0, '
    'last_message_id INTEGER DEFAULT 0, '
    'is_blocked INTEGER NOT NULL DEFAULT 0, '
    'status INTEGER NOT NULL DEFAULT 0, '
    "roomname_remark TEXT DEFAULT '', "
    'fold_status INTEGER DEFAULT 0'
    ')',
  );
  await database.execute(
    'CREATE TABLE unread_conversation_table ('
    "conversation_id TEXT PRIMARY KEY NOT NULL DEFAULT '', "
    'begin_cursor INTEGER NOT NULL DEFAULT 0, '
    'current_cursor INTEGER NOT NULL DEFAULT 0, '
    'unread_count INTEGER NOT NULL DEFAULT 0'
    ')',
  );
  await database.execute(
    'CREATE TABLE conversation_user_table ('
    "conversation_id TEXT NOT NULL DEFAULT '', "
    'user_id INTEGER NOT NULL DEFAULT 0, '
    'join_time INTEGER NOT NULL DEFAULT 0, '
    'gag_type INTEGER NOT NULL DEFAULT 0, '
    "nick_name TEXT DEFAULT '', "
    'is_admin INTEGER DEFAULT 0, '
    'PRIMARY KEY (conversation_id, user_id)'
    ')',
  );
  await database.insert(
    'conversation_table',
    {
      'con_numeric_id': 1,
      'id': 'R:1',
      'name': conversationName,
      'last_message_time': 100,
      'last_message_id': 1,
    },
  );
  await database.close();
}

WeComPackageContract _contract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'active dataset runtime test',
    databases: [
      WeComDatabaseContract(
        fileName: 'user.db',
        allowEmpty: false,
        tables: {
          'user_table': [
            _column('id', 'INTEGER', primaryKeyPosition: 1),
            _column('real_name', 'TEXT', notNull: true),
            _column('name', 'TEXT', notNull: true),
            _column('account', 'TEXT', notNull: true),
            _column('external_corp_name', 'TEXT', notNull: true),
            _column('external_job', 'TEXT', notNull: true),
          ],
        },
        indexes: const {},
      ),
      WeComDatabaseContract(
        fileName: 'session.db',
        allowEmpty: false,
        tables: {
          'conversation_table': [
            _column('con_numeric_id', 'INTEGER', primaryKeyPosition: 1),
            _column('id', 'TEXT', notNull: true),
            _column('name', 'TEXT', notNull: true),
            _column('is_sticked', 'INTEGER', notNull: true),
            _column('last_message_time', 'INTEGER'),
            _column('last_message_id', 'INTEGER'),
            _column('is_blocked', 'INTEGER', notNull: true),
            _column('status', 'INTEGER', notNull: true),
            _column('roomname_remark', 'TEXT'),
            _column('fold_status', 'INTEGER'),
          ],
          'unread_conversation_table': [
            _column(
              'conversation_id',
              'TEXT',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            _column('begin_cursor', 'INTEGER', notNull: true),
            _column('current_cursor', 'INTEGER', notNull: true),
            _column('unread_count', 'INTEGER', notNull: true),
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
            _column('join_time', 'INTEGER', notNull: true),
            _column('gag_type', 'INTEGER', notNull: true),
            _column('nick_name', 'TEXT'),
            _column('is_admin', 'INTEGER'),
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
