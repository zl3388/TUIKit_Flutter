import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_merge_planner.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_migration_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';
import 'wecom_message_test_fixture.dart';

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
    expect(
      (await runtime.messages.listConversationMessages(1)).single.messageId,
      1,
    );
    final profile = await runtime.identity.currentProfile();
    expect(profile.displayName, 'Base contact');
    expect(profile.corporationName, 'Example Corporation');
    await runtime.close();
    await runtime.close();

    final reopened = await resolver.openActive();
    expect(reopened.datasetId, initial.datasetId);
    await reopened.close();
  });

  test('requires explicit selection for multiple corporations and can switch',
      () async {
    final imported = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'multiple',
      contactName: 'First user',
      conversationName: 'Room',
      multipleCorporations: true,
    );

    await expectLater(
      resolver.ensureInitialDataset(imported.datasetId),
      throwsA(
        isA<WeComActiveDatasetException>().having(
          (error) => error.code,
          'code',
          WeComActiveDatasetIssueCode.identityRequired,
        ),
      ),
    );
    expect(await _activationCount(overlayDatabase), 0);

    final inspection = await resolver.inspectIdentity(imported.datasetId);
    expect(
      inspection.status,
      WeComIdentityResolutionStatus.ambiguousNoConfig,
    );
    expect(inspection.candidates, hasLength(2));

    await resolver.ensureInitialDataset(
      imported.datasetId,
      selectedCorporationId: testCorporationId,
    );
    await resolver.selectCorporation(
      datasetId: imported.datasetId,
      corporationId: 200,
    );
    expect(await _activationCount(overlayDatabase), 2);

    final runtime = await resolver.openActive();
    expect((await runtime.identity.currentProfile()).id, '2');
    await runtime.close();
  });

  test('repairs a legacy activation only after resolving its identity',
      () async {
    final imported = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'legacy-activation',
      contactName: 'Current user',
      conversationName: 'Room',
    );
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.datasetActivationsTable,
      {
        'previous_dataset_id': null,
        'dataset_id': imported.datasetId,
        'merge_id': null,
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );

    await expectLater(
      resolver.openActive(),
      throwsA(
        isA<WeComActiveDatasetException>().having(
          (error) => error.code,
          'code',
          WeComActiveDatasetIssueCode.identityRequired,
        ),
      ),
    );
    expect(await resolver.ensureInitialDataset(imported.datasetId), isTrue);
    expect(await _activationCount(overlayDatabase), 2);

    final runtime = await resolver.openActive();
    expect((await runtime.identity.currentProfile()).id, '1');
    await runtime.close();
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
      identityResolver: WeComIdentityResolver(databaseFactoryFfi),
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

  test('reopens an imported media companion with the active dataset', () async {
    final imported = await _importPackage(
      temporaryDirectory,
      importer,
      name: 'with-media',
      contactName: 'Current user',
      conversationName: 'Room',
      includeMedia: true,
    );
    await resolver.ensureInitialDataset(imported.datasetId);
    final wxWorkRoot = Directory(p.join(temporaryDirectory.path, 'WXWork'));
    final account = await _createMediaAccount(wxWorkRoot);
    addTearDown(account.connection.close);

    final snapshot = await resolver.importMediaSnapshot(
      datasetId: imported.datasetId,
      wxWorkRoot: wxWorkRoot,
    );
    expect(snapshot.referencedFileCount, 1);
    expect(snapshot.copiedFileCount, 1);

    final runtime = await resolver.openActive();
    expect(runtime.media, isNotNull);
    final message = (await runtime.messages.findMessagesById([1]))[1]!;
    final attachments = await runtime.media!.listMessageAttachments(message);
    expect(attachments, hasLength(1));
    expect(attachments.single.location.isAvailable, isTrue);
    expect(
      attachments.single.location.file!.path,
      startsWith(snapshot.mediaRoot.path),
    );
    await runtime.close();

    final reopened = await resolver.openActive();
    expect(reopened.media, isNotNull);
    await reopened.close();
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
  bool multipleCorporations = false,
  bool includeMedia = false,
}) async {
  final source = await Directory(p.join(root.path, name)).create();
  await createIdentityDatabases(source, contactName: contactName);
  if (multipleCorporations) {
    await addIdentityCandidate(
      source,
      corporationId: 200,
      userId: 2,
      name: 'Second user',
    );
  }
  await _createSessionDatabase(source, conversationName);
  await _createFileDatabase(source, includeMedia: includeMedia);
  await createMessageDatabases(
    source,
    conversationNumericId: 1,
    messages: [
      TestWeComMessage(
        messageId: 1,
        serverId: 1,
        sequence: 1,
        senderId: 1,
        conversationId: 'R:1',
        contentType: includeMedia ? 15 : 0,
        sendTime: 100,
        content: [
          0x0a,
          0x09,
          0x08,
          0x00,
          0x12,
          0x05,
          0x0a,
          0x03,
          0xe5,
          0x86,
          0x8d,
        ],
      ),
    ],
  );
  return importer.importPackage(
    sourceDirectory: source,
    destinationRoot: Directory(p.join(root.path, 'imports')),
  );
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
      ...identityDatabaseContracts(),
      WeComDatabaseContract(
        fileName: 'file.db',
        allowEmpty: false,
        tables: {
          'file_table4': [
            testColumn(
              'origin',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            testColumn(
              'message_id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 2,
            ),
            testColumn(
              'file_index',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 3,
            ),
            testColumn('message_type', 'INTEGER', notNull: true),
            testColumn('server_id', 'TEXT', notNull: true),
            testColumn('name', 'TEXT', notNull: true),
            testColumn('size', 'INTEGER', notNull: true),
            testColumn('receive_time', 'INTEGER', notNull: true),
            testColumn('md5', 'TEXT', notNull: true),
          ],
        },
        indexes: const {},
      ),
      WeComDatabaseContract(
        fileName: 'session.db',
        allowEmpty: false,
        tables: {
          'conversation_table': [
            testColumn('con_numeric_id', 'INTEGER', primaryKeyPosition: 1),
            testColumn('id', 'TEXT', notNull: true),
            testColumn('name', 'TEXT', notNull: true),
            testColumn('is_sticked', 'INTEGER', notNull: true),
            testColumn('last_message_time', 'INTEGER'),
            testColumn('last_message_id', 'INTEGER'),
            testColumn('is_blocked', 'INTEGER', notNull: true),
            testColumn('status', 'INTEGER', notNull: true),
            testColumn('roomname_remark', 'TEXT'),
            testColumn('fold_status', 'INTEGER'),
          ],
          'unread_conversation_table': [
            testColumn(
              'conversation_id',
              'TEXT',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            testColumn('begin_cursor', 'INTEGER', notNull: true),
            testColumn('current_cursor', 'INTEGER', notNull: true),
            testColumn('unread_count', 'INTEGER', notNull: true),
          ],
          'conversation_user_table': [
            testColumn(
              'conversation_id',
              'TEXT',
              notNull: true,
              primaryKeyPosition: 1,
            ),
            testColumn(
              'user_id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 2,
            ),
            testColumn('join_time', 'INTEGER', notNull: true),
            testColumn('gag_type', 'INTEGER', notNull: true),
            testColumn('nick_name', 'TEXT'),
            testColumn('is_admin', 'INTEGER'),
          ],
        },
        indexes: const {},
      ),
      ...messageDatabaseContracts(),
    ],
  );
}

Future<void> _createFileDatabase(
  Directory source, {
  required bool includeMedia,
}) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'file.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute('''
CREATE TABLE file_table4 (
  origin INTEGER NOT NULL DEFAULT 0,
  message_id INTEGER NOT NULL DEFAULT 0,
  file_index INTEGER NOT NULL DEFAULT 0,
  message_type INTEGER NOT NULL DEFAULT 0,
  server_id TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL DEFAULT '',
  size INTEGER NOT NULL DEFAULT 0,
  receive_time INTEGER NOT NULL DEFAULT 0,
  md5 TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (origin, message_id, file_index)
)
''');
  if (includeMedia) {
    final bytes = [1, 2, 3, 4];
    await database.insert('file_table4', {
      'origin': 0,
      'message_id': 1,
      'file_index': 0,
      'message_type': 0,
      'server_id': '',
      'name': 'report.pdf',
      'size': bytes.length,
      'receive_time': 100,
      'md5': md5.convert(bytes).toString(),
    });
  }
  await database.close();
}

Future<_MediaAccountFixture> _createMediaAccount(Directory wxWorkRoot) async {
  final account = Directory(p.join(wxWorkRoot.path, 'selected_account'));
  final cacheFile = File(
    p.join(account.path, 'Cache', 'File', '1970-01', 'report.pdf'),
  );
  await cacheFile.create(recursive: true);
  final bytes = [1, 2, 3, 4];
  await cacheFile.writeAsBytes(bytes);
  await Directory(p.join(account.path, 'Data')).create();
  final mappingDirectory =
      await Directory(p.join(account.path, 'CacheMapping')).create();
  final mappingFile = File(
    p.join(mappingDirectory.path, '11111111111111111111111111111111.db'),
  );
  final connection = await databaseFactoryFfi.openDatabase(
    mappingFile.path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await connection.rawQuery('PRAGMA journal_mode=WAL');
  await connection.rawQuery('PRAGMA wal_autocheckpoint=0');
  await connection.execute('''
CREATE TABLE mapping (
  type integer default 0 not null,
  key text default '' not null,
  file_name text default '',
  last_modify_time integer default 0 not null,
  file_md5 integer default 0 not null,
  primary key (type,key)
)
''');
  await connection.execute(
    'CREATE INDEX file_md5_index_ on mapping (file_md5)',
  );
  await connection.execute(
    'CREATE INDEX file_name_index_ on mapping (file_name)',
  );
  await connection.insert('mapping', {
    'type': 1,
    'key': 'file-key',
    'file_name': '${account.path}\\Cache\\File\\1970-01\\report.pdf',
    'last_modify_time': 1,
    'file_md5': md5.convert(bytes).toString(),
  });
  return _MediaAccountFixture(connection);
}

class _MediaAccountFixture {
  const _MediaAccountFixture(this.connection);

  final Database connection;
}
