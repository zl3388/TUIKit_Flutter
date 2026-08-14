import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_merged_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_offline_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const datasetId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  late Directory temporaryDirectory;
  late Database baseDatabase;
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
      contacts: const _FixtureContacts(),
      commands: WeComOverlayCommandService(
        overlayDatabase: overlayDatabase,
        contract: contract,
      ),
    );
  });

  tearDown(() async {
    await baseDatabase.close();
    await overlayDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('maps confirmed session fields, peers, and members', () async {
    final conversations = await repository.listConversations();

    expect(repository.isAvailable, isTrue);
    expect(repository.features, {
      ConversationFeature.members,
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
    expect(
      conversations.last.lastMessageAt,
      DateTime.fromMillisecondsSinceEpoch(200000, isUtc: true),
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
  await database.insert('conversation_table', {
    'con_numeric_id': 1,
    'id': 'S:1_2',
    'name': '',
    'is_sticked': 0,
    'last_message_time': 200,
    'last_message_id': 2,
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
  await database.close();
}
