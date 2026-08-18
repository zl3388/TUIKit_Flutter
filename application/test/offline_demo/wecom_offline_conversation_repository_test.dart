import 'dart:convert';
import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_merged_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_message_repository.dart';
import 'package:application/src/offline_demo/data/wecom_offline_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_message_test_fixture.dart';

void main() {
  const datasetId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  late Directory temporaryDirectory;
  late Database baseDatabase;
  late Database messageDatabase;
  late Database lookupDatabase;
  late WeComOverlayDatabase overlayDatabase;
  late WeComOfflineConversationRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_wecom_offline_conversations_',
    );
    final basePath = p.join(temporaryDirectory.path, 'session.db');
    await _createBaseFixture(basePath);
    baseDatabase = await databaseFactoryFfi.openDatabase(
      basePath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    await createMessageDatabases(
      temporaryDirectory,
      conversationNumericId: 1,
      messages: const [
        TestWeComMessage(
          messageId: 1,
          serverId: 101,
          sequence: 10,
          senderId: 2,
          conversationId: 'S:1_2',
          sendTime: 10,
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
        TestWeComMessage(
          messageId: 3,
          serverId: 103,
          sequence: 30,
          senderId: 2,
          conversationId: 'S:1_2',
          contentType: 40,
          sendTime: 30,
          content: [
            0x08,
            0x02,
            0x10,
            0x03,
            0x1a,
            0x0f,
            0xe5,
            0xaf,
            0xb9,
            0xe6,
            0x96,
            0xb9,
            0xe5,
            0xb7,
            0xb2,
            0xe5,
            0x8f,
            0x96,
            0xe6,
            0xb6,
            0x88,
          ],
        ),
        TestWeComMessage(
          messageId: 2,
          serverId: 102,
          sequence: 20,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 20,
          flag: 131074,
          content: [
            0x0a,
            0x0c,
            0x08,
            0x00,
            0x12,
            0x08,
            0x0a,
            0x06,
            0xe5,
            0xa5,
            0xbd,
            0xe7,
            0x9a,
            0x84,
          ],
        ),
      ],
    );
    messageDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    lookupDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message_lookup.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    overlayDatabase = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'overlay.db'),
    );
    final contract = WeComPackageContract.fromJsonString(
      await File(
        p.join(
          Directory.current.path,
          'assets',
          'offline_demo',
          'wecom_schema_contract.json',
        ),
      ).readAsString(),
    );
    repository = WeComOfflineConversationRepository(
      datasetId: datasetId,
      currentUserId: 1,
      conversations: WeComMergedConversationRepository(
        datasetId: datasetId,
        baseRepository: WeComConversationRepository(baseDatabase),
        overlayDatabase: overlayDatabase,
      ),
      messages: WeComMessageRepository(
        messageDatabase: messageDatabase,
        lookupDatabase: lookupDatabase,
      ),
      contacts: const _FixtureContacts(),
      commands: WeComOverlayCommandService(
        overlayDatabase: overlayDatabase,
        contract: contract,
      ),
    );
  });

  tearDown(() async {
    await lookupDatabase.close();
    await messageDatabase.close();
    await baseDatabase.close();
    await overlayDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('maps confirmed session fields, peers, and members', () async {
    final conversations = await repository.listConversations();

    expect(repository.isAvailable, isTrue);
    expect(repository.features, {
      ConversationFeature.members,
      ConversationFeature.messages,
      ConversationFeature.pin,
      ConversationFeature.mute,
    });
    expect(conversations.map((item) => item.id), ['R:room', 'S:1_2']);
    expect(conversations.first.type, 'group');
    expect(conversations.first.title, 'Room');
    expect(conversations.first.lastMessageAt, isNull);
    expect(conversations.first.isPinned, isTrue);
    expect(conversations.last.type, 'single');
    expect(conversations.last.title, 'Peer');
    expect(conversations.last.unreadCount, 3);
    expect(conversations.last.isMuted, isTrue);
    expect(conversations.last.draftText, '111');
    expect(conversations.last.lastMessagePreview, '[通话] 对方已取消');
    expect(
      conversations.last.lastMessageAt,
      DateTime.fromMillisecondsSinceEpoch(30000, isUtc: true),
    );

    final members = await repository.listMembers('S:1_2');
    expect(members, hasLength(1));
    expect(members.single.userId, '2');
    expect(members.single.nickname, 'Peer nick');
    expect(members.single.displayName, 'Peer nick');
    expect(members.single.isAdmin, isTrue);
    expect(members.single.gagType, 2);
    expect(
      members.single.joinedAt,
      DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
    );

    final messages = await repository.listMessages('S:1_2');
    expect(
      messages.map((message) => message.text),
      ['再', '好的', '[通话] 对方已取消'],
    );
    expect(messages.map((message) => message.kind), ['text', 'text', 'call']);
    expect(messages.first.senderName, 'Peer');
    expect(messages[1].senderName, 'Current user');
    expect(messages.last.senderName, 'Peer');
    expect(messages.last.status, isEmpty);

    await expectLater(
      repository.sendTextMessage(
        conversationId: 'S:1_2',
        senderProfileId: '1',
        text: 'not written',
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('persists only certified pin and mute scalar revisions', () async {
    await repository.setPinned('S:1_2', true);
    await repository.setMuted('S:1_2', false);
    await repository.setPinned('S:1_2', true);
    await repository.setMuted('S:1_2', false);

    final conversations = await repository.listConversations();
    expect(conversations.map((item) => item.id), ['S:1_2', 'R:room']);
    expect(conversations.first.isPinned, isTrue);
    expect(conversations.first.isMuted, isFalse);
    final revisions = await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      columns: ['table_name', 'row_key_json', 'values_json'],
      orderBy: 'revision_id',
    );
    expect(revisions, hasLength(2));
    expect(revisions[0]['table_name'], 'conversation_table');
    expect(revisions[0]['row_key_json'], '{"con_numeric_id":1}');
    expect(revisions[0]['values_json'], '{"is_sticked":1}');
    expect(revisions[1]['values_json'], '{"is_blocked":0}');

    await expectLater(
      repository.markRead('S:1_2'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      repository.saveDraft('S:1_2', 'draft'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      repository.deleteConversation('S:1_2'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}

class _FixtureContacts implements ContactRepository {
  const _FixtureContacts();

  @override
  bool get isAvailable => true;

  @override
  Future<List<DirectoryContact>> listContacts() async => const [
        DirectoryContact(
          id: '1',
          displayName: 'Current user',
          account: 'current',
          organizationName: null,
          jobTitle: null,
        ),
        DirectoryContact(
          id: '2',
          displayName: 'Peer',
          account: 'peer',
          organizationName: null,
          jobTitle: null,
        ),
      ];
}

Future<void> _createBaseFixture(String path) async {
  final database = await databaseFactoryFfi.openDatabase(
    path,
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
    'id': 'S:1_2',
    'name': '',
    'is_sticked': 0,
    'last_message_time': 30,
    'last_message_id': 3,
    'is_blocked': 1,
  });
  await database.insert('conversation_table', {
    'con_numeric_id': 2,
    'id': 'R:room',
    'name': 'Room',
    'is_sticked': 1,
    'last_message_time': 0,
    'last_message_id': 0,
  });
  await database.insert('unread_conversation_table', {
    'conversation_id': 'S:1_2',
    'begin_cursor': 7,
    'current_cursor': 10,
    'unread_count': 3,
  });
  await database.insert('conversation_user_table', {
    'conversation_id': 'S:1_2',
    'user_id': 2,
    'join_time': 100,
    'gag_type': 2,
    'nick_name': 'Peer nick',
    'is_admin': 1,
  });
  await database.insert('draft_table_1', {
    'conversation_id': 'S:1_2',
    'content': base64Decode(
      'CiUIAhIfCh0IABIZChcKFTExMQAAAAAAAAAAAAAAAAAAAAAAAAAA',
    ),
  });
  await database.close();
}
