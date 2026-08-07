import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_conversation_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_conversations_');
    databasePath = p.join(temporaryDirectory.path, 'session.db');
    await _createFixture(databasePath);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('maps display names, raw states, stable sorting, and pagination',
      () async {
    final database = await _openFixture(databasePath);
    addTearDown(database.close);
    final repository = WeComConversationRepository(database);

    final conversations = await repository.listConversations();

    expect(
      conversations.map((conversation) => conversation.id),
      ['R:remark', 'S:blank', 'R:name'],
    );
    expect(
      conversations.map((conversation) => conversation.displayName),
      ['Remark override', '', 'Name fallback'],
    );
    expect(conversations.first.lastMessageId, isNull);
    expect(conversations.first.pinnedFlag, 0);
    expect(conversations.first.blockedFlag, 1);
    expect(conversations.first.status, 1);
    expect(conversations.first.foldStatus, 0);
    expect(conversations.first.unreadState!.beginCursor, 40);
    expect(conversations.first.unreadState!.currentCursor, 43);
    expect(conversations.first.unreadState!.unreadCount, 3);
    expect(conversations[1].unreadState, isNull);
    expect(conversations.last.pinnedFlag, 1);
    expect(conversations.last.foldStatus, 1);

    final page = await repository.listConversations(limit: 2, offset: 1);
    expect(page.map((conversation) => conversation.id), ['S:blank', 'R:name']);
  });

  test('maps conversation members without reinterpreting raw integer values',
      () async {
    final database = await _openFixture(databasePath);
    addTearDown(database.close);
    final repository = WeComConversationRepository(database);

    final members = await repository.listConversationMembers('R:remark');

    expect(members.map((member) => member.userId), [7, 9]);
    expect(members.first.joinTime, 1234);
    expect(members.first.gagType, 2);
    expect(members.first.nickname, isNull);
    expect(members.first.adminFlag, isNull);
    expect(members.last.nickname, 'Group name');
    expect(members.last.adminFlag, 3);
  });

  test('rejects conversation pagination outside the bounded query contract',
      () async {
    final database = await _openFixture(databasePath);
    addTearDown(database.close);
    final repository = WeComConversationRepository(database);

    await expectLater(repository.listConversations(limit: 0), throwsRangeError);
    await expectLater(
      repository.listConversations(
        limit: WeComConversationRepository.maxPageSize + 1,
      ),
      throwsRangeError,
    );
    await expectLater(
      repository.listConversations(offset: -1),
      throwsRangeError,
    );
  });
}

Future<Database> _openFixture(String path) {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
  );
}

Future<void> _createFixture(String path) async {
  final database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      singleInstance: false,
      onCreate: (database, version) async {
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
        await _seedFixture(database);
      },
    ),
  );
  await database.close();
}

Future<void> _seedFixture(Database database) async {
  final batch = database.batch();
  batch.insert('conversation_table', {
    'con_numeric_id': 20,
    'id': 'R:name',
    'name': 'Name fallback',
    'roomname_remark': '',
    'last_message_time': 200,
    'last_message_id': 22,
    'is_sticked': 1,
    'is_blocked': 0,
    'status': 0,
    'fold_status': 1,
  });
  batch.insert('conversation_table', {
    'con_numeric_id': 10,
    'id': 'R:remark',
    'name': 'Ignored name',
    'roomname_remark': 'Remark override',
    'last_message_time': 300,
    'last_message_id': null,
    'is_sticked': 0,
    'is_blocked': 1,
    'status': 1,
    'fold_status': 0,
  });
  batch.insert('conversation_table', {
    'con_numeric_id': 30,
    'id': 'S:blank',
    'name': '',
    'roomname_remark': '',
    'last_message_time': 200,
    'last_message_id': 23,
  });
  batch.insert('unread_conversation_table', {
    'conversation_id': 'R:remark',
    'begin_cursor': 40,
    'current_cursor': 43,
    'unread_count': 3,
  });
  batch.insert('unread_conversation_table', {
    'conversation_id': 'R:name',
    'begin_cursor': 50,
    'current_cursor': 50,
    'unread_count': 0,
  });
  batch.insert('conversation_user_table', {
    'conversation_id': 'R:remark',
    'user_id': 9,
    'join_time': 2345,
    'gag_type': 0,
    'nick_name': 'Group name',
    'is_admin': 3,
  });
  batch.insert('conversation_user_table', {
    'conversation_id': 'R:remark',
    'user_id': 7,
    'join_time': 1234,
    'gag_type': 2,
    'nick_name': null,
    'is_admin': null,
  });
  await batch.commit(noResult: true);
}
