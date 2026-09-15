import 'dart:io';

import 'package:application/src/offline_demo/bootstrap/offline_bootstrap.dart';
import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';
import 'wecom_message_test_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory mediaRoot;
  late Directory wecomRoot;
  late WeComPackageContract contract;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_offline_bootstrap_');
    mediaRoot = Directory(p.join(temporaryDirectory.path, 'media'));
    wecomRoot = Directory(p.join(temporaryDirectory.path, 'wecom'));
    contract = _contract();
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('does not fall back to schema v2 business data without an activation',
      () async {
    final environment = await OfflineBootstrap.create(
      factory: databaseFactoryFfi,
      mediaRootDirectory: mediaRoot,
      wecomRootDirectory: wecomRoot,
      wecomContract: contract,
    );

    expect(environment.store.contactsAvailable, isFalse);
    expect(environment.store.conversationsAvailable, isFalse);
    expect(environment.store.identityAvailable, isFalse);
    expect(environment.store.activityAvailable, isFalse);
    expect(environment.store.profile, isNull);
    expect(environment.store.contacts, isEmpty);
    expect(environment.store.conversations, isEmpty);
    expect(environment.store.notifications, isEmpty);
    expect(environment.store.announcements, isEmpty);
    expect(environment.store.callRecords, isEmpty);
    expect(environment.wecomRuntime, isNull);

    await environment.close();
    await environment.close();
  });

  test('loads the active merged directory and closes all databases', () async {
    final imported = await _importAndActivate(
      temporaryDirectory: temporaryDirectory,
      wecomRoot: wecomRoot,
      contract: contract,
    );

    final environment = await OfflineBootstrap.create(
      factory: databaseFactoryFfi,
      mediaRootDirectory: mediaRoot,
      wecomRootDirectory: wecomRoot,
      wecomContract: contract,
    );

    expect(environment.store.contactsAvailable, isTrue);
    expect(environment.store.conversationsAvailable, isTrue);
    expect(environment.store.activityAvailable, isFalse);
    expect(environment.wecomRuntime?.datasetId, imported.datasetId);
    expect(environment.store.contacts, hasLength(1));
    expect(environment.store.contacts.single.id, '1');
    expect(environment.store.contacts.single.displayName, 'Overlay contact');
    expect(environment.store.contacts.single.account, 'contact.account');
    expect(environment.store.contacts.single.organizationName, 'Example Corp');
    expect(environment.store.contacts.single.departmentName, 'Engineering');
    expect(environment.store.contacts.single.jobTitle, 'Developer');
    expect(environment.store.organizationUnits, hasLength(1));
    expect(environment.store.organizationUnits.single.name, 'Engineering');
    expect(environment.store.organizationUnits.single.parentId, isNull);
    expect(environment.store.profile?.displayName, 'Base contact');
    expect(environment.store.profile?.corporationName, 'Example Corporation');
    expect(environment.store.profile?.department, 'Engineering');
    expect(environment.store.profile?.title, 'Developer');
    expect(environment.store.profile?.account, 'current');
    expect(environment.store.conversations, hasLength(1));
    expect(environment.store.notifications, isEmpty);
    expect(environment.store.announcements, isEmpty);
    expect(environment.store.callRecords, isEmpty);
    expect(environment.store.conversations.single.title, 'Example room');
    expect(environment.store.conversations.single.unreadCount, 2);
    expect(
      environment.store.supportsConversationFeature(ConversationFeature.pin),
      isTrue,
    );
    expect(
      environment.store.supportsConversationFeature(
        ConversationFeature.markRead,
      ),
      isFalse,
    );
    expect(
      environment.store.supportsConversationFeature(
        ConversationFeature.sendText,
      ),
      isTrue,
    );
    final members = await environment.store.membersFor('R:example');
    expect(members, hasLength(1));
    expect(members.single.displayName, 'Overlay contact');

    await environment.store.setConversationPinned('R:example', true);
    await environment.store.setConversationMuted('R:example', true);
    expect(environment.store.conversations.single.isPinned, isTrue);
    expect(environment.store.conversations.single.isMuted, isTrue);
    final simulated = await environment.store.sendTextMessage(
      conversationId: 'R:example',
      text: 'local only',
    );
    expect(simulated.text, 'local only');
    expect(simulated.progressSource.name, 'localSimulation');
    expect(
      (await environment.store.messagesFor('R:example'))
          .where((message) => message.text == 'local only'),
      hasLength(1),
    );
    final sourceMessageDatabase = await databaseFactoryFfi.openDatabase(
      imported.databaseFile('message.db').path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    expect(
      Sqflite.firstIntValue(
        await sourceMessageDatabase.rawQuery(
          'SELECT COUNT(*) FROM message_table',
        ),
      ),
      1,
    );
    await sourceMessageDatabase.close();

    await environment.close();
    await environment.close();

    final reopened = await OfflineBootstrap.create(
      factory: databaseFactoryFfi,
      mediaRootDirectory: mediaRoot,
      wecomRootDirectory: wecomRoot,
      wecomContract: contract,
    );
    expect(reopened.store.conversations.single.isPinned, isTrue);
    expect(reopened.store.conversations.single.isMuted, isTrue);
    await reopened.close();
  });

  test('repairs active package corruption without losing activation or overlay',
      () async {
    final imported = await _importAndActivate(
      temporaryDirectory: temporaryDirectory,
      wecomRoot: wecomRoot,
      contract: contract,
    );
    await imported.databaseFile('user.db').writeAsBytes(
      const [0],
      mode: FileMode.append,
      flush: true,
    );

    await expectLater(
      OfflineBootstrap.create(
        factory: databaseFactoryFfi,
        mediaRootDirectory: mediaRoot,
        wecomRootDirectory: wecomRoot,
        wecomContract: contract,
      ),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.existingPackageCorrupt,
        ),
      ),
    );

    final importer = WeComDatabasePackageImporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    final repaired = await importer.repairImportedPackage(
      sourceDirectory: Directory(
        p.join(temporaryDirectory.path, 'source'),
      ),
      destinationRoot: wecomRoot,
      datasetId: imported.datasetId,
    );
    expect(repaired.datasetId, imported.datasetId);
    expect(repaired.reusedExisting, isFalse);

    final environment = await OfflineBootstrap.create(
      factory: databaseFactoryFfi,
      mediaRootDirectory: mediaRoot,
      wecomRootDirectory: wecomRoot,
      wecomContract: contract,
    );
    expect(environment.wecomRuntime?.datasetId, imported.datasetId);
    expect(environment.store.contacts.single.displayName, 'Overlay contact');
    expect(environment.store.conversations.single.title, 'Example room');
    await environment.close();
  });
}

Future<WeComImportedPackage> _importAndActivate({
  required Directory temporaryDirectory,
  required Directory wecomRoot,
  required WeComPackageContract contract,
}) async {
  final source = await Directory(
    p.join(temporaryDirectory.path, 'source'),
  ).create();
  await createIdentityDatabases(
    source,
    contactName: 'Base contact',
    externalCorporationName: 'Example Corp',
    externalJob: 'Engineer',
  );
  await _createSessionDatabase(source);
  await createMessageDatabases(
    source,
    conversationNumericId: 1,
    messages: const [
      TestWeComMessage(
        messageId: 10,
        serverId: 10,
        sequence: 10,
        senderId: testCurrentUserId,
        conversationId: 'R:example',
        sendTime: 1700000000,
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

  final importer = WeComDatabasePackageImporter(
    contract: contract,
    databaseFactory: databaseFactoryFfi,
  );
  final imported = await importer.importPackage(
    sourceDirectory: source,
    destinationRoot: wecomRoot,
  );
  final overlay = await WeComOverlayDatabase.open(
    factory: databaseFactoryFfi,
    databasePath: p.join(wecomRoot.path, WeComOverlayDatabase.fileName),
  );
  try {
    final resolver = WeComActiveDatasetResolver(
      destinationRoot: wecomRoot,
      packageImporter: importer,
      databaseFactory: databaseFactoryFfi,
      overlayDatabase: overlay,
    );
    await resolver.ensureInitialDataset(imported.datasetId);
    await overlay.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': imported.datasetId,
        'identity_corp_id': testCorporationId,
        'identity_user_id': testCurrentUserId,
        'database_name': 'user.db',
        'table_name': 'user_table',
        'row_key_json': '{"id":1}',
        'operation': 'upsert',
        'values_json': '{"real_name":"Overlay contact"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
  } finally {
    await overlay.close();
  }
  return imported;
}

Future<void> _createSessionDatabase(Directory source) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'session.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute('''
CREATE TABLE conversation_table (
  con_numeric_id INTEGER PRIMARY KEY NOT NULL,
  id TEXT NOT NULL DEFAULT '' UNIQUE,
  name TEXT NOT NULL DEFAULT '',
  is_sticked INTEGER NOT NULL DEFAULT 0,
  last_message_time INTEGER DEFAULT 0,
  last_message_id INTEGER DEFAULT 0,
  is_blocked INTEGER NOT NULL DEFAULT 0,
  status INTEGER NOT NULL DEFAULT 0,
  roomname_remark TEXT DEFAULT '',
  fold_status INTEGER DEFAULT 0
)
''');
  await database.execute('''
CREATE TABLE unread_conversation_table (
  conversation_id TEXT PRIMARY KEY NOT NULL DEFAULT '',
  begin_cursor INTEGER NOT NULL DEFAULT 0,
  current_cursor INTEGER NOT NULL DEFAULT 0,
  unread_count INTEGER NOT NULL DEFAULT 0
)
''');
  await database.execute('''
CREATE TABLE conversation_user_table (
  conversation_id TEXT NOT NULL DEFAULT '',
  user_id INTEGER NOT NULL DEFAULT 0,
  join_time INTEGER NOT NULL DEFAULT 0,
  gag_type INTEGER NOT NULL DEFAULT 0,
  nick_name TEXT DEFAULT '',
  is_admin INTEGER DEFAULT 0,
  PRIMARY KEY (conversation_id, user_id)
)
''');
  await database.execute('''
CREATE TABLE draft_table_1 (
  conversation_id TEXT DEFAULT '' PRIMARY KEY,
  content
)
''');
  await database.insert('conversation_table', {
    'con_numeric_id': 1,
    'id': 'R:example',
    'name': 'Example room',
    'last_message_time': 1700000000,
    'last_message_id': 10,
  });
  await database.insert('unread_conversation_table', {
    'conversation_id': 'R:example',
    'begin_cursor': 8,
    'current_cursor': 10,
    'unread_count': 2,
  });
  await database.insert('conversation_user_table', {
    'conversation_id': 'R:example',
    'user_id': testCurrentUserId,
    'join_time': 1600000000,
    'gag_type': 0,
    'nick_name': '',
    'is_admin': 0,
  });
  await database.close();
}

WeComPackageContract _contract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'offline bootstrap test',
    databases: [
      ...identityDatabaseContracts(),
      WeComDatabaseContract(
        fileName: 'session.db',
        allowEmpty: false,
        tables: {
          'conversation_table': [
            testColumn(
              'con_numeric_id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 1,
            ),
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
          'draft_table_1': [
            testColumn(
              'conversation_id',
              'TEXT',
              primaryKeyPosition: 1,
            ),
            testColumn('content', ''),
          ],
        },
        indexes: const {},
      ),
      ...messageDatabaseContracts(),
    ],
  );
}
