import 'dart:io';

import 'package:application/src/offline_demo/data/offline_database.dart';
import 'package:application/src/offline_demo/data/offline_schema.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_offline_db_');
    databasePath = p.join(temporaryDirectory.path, 'test.db');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('schema v1 creates all core tables and deterministic seed data',
      () async {
    final database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    final tableRows = await database.connection.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final tableNames = tableRows.map((row) => row['name']).toSet();
    expect(tableNames, containsAll(OfflineSchema.expectedTables));

    final repositories = OfflineRepositoryBundle(database);
    final profile = await repositories.identity.currentProfile();
    final contacts = await repositories.contacts.listContacts();
    final conversations = await repositories.conversations.listConversations();
    final messages = await repositories.conversations.listMessages(
      'conversation_product',
    );
    final notifications = await repositories.activity.listNotifications();
    final announcements = await repositories.activity.listAnnouncements();
    final calls = await repositories.activity.listCallRecords();

    expect(profile.displayName, '林墨');
    expect(contacts, hasLength(4));
    expect(conversations, hasLength(4));
    expect(messages, hasLength(3));
    expect(notifications, hasLength(3));
    expect(announcements, hasLength(2));
    expect(calls, hasLength(2));
  });

  test('reopening preserves edits and does not duplicate seed rows', () async {
    var database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await database.connection.update(
      'profiles',
      {
        'display_name': '自定义身份',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: ['profile_current'],
    );
    await database.close();

    database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    final repositories = OfflineRepositoryBundle(database);
    final profile = await repositories.identity.currentProfile();
    final profileCount = Sqflite.firstIntValue(
      await database.connection.rawQuery('SELECT COUNT(*) FROM profiles'),
    );

    expect(profile.displayName, '自定义身份');
    expect(profileCount, 5);
  });

  test('failed transaction rolls back the complete edit', () async {
    final database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);

    final before = Sqflite.firstIntValue(
      await database.connection.rawQuery('SELECT COUNT(*) FROM profiles'),
    );

    await expectLater(
      database.connection.transaction((txn) async {
        await txn.insert('profiles', {
          'id': 'profile_rollback',
          'display_name': '不应保留',
          'title': '',
          'department': '',
          'status': 'active',
          'created_at': '2026-07-30T00:00:00.000Z',
          'updated_at': '2026-07-30T00:00:00.000Z',
        });
        throw StateError('rollback');
      }),
      throwsStateError,
    );

    final after = Sqflite.firstIntValue(
      await database.connection.rawQuery('SELECT COUNT(*) FROM profiles'),
    );
    expect(after, before);
  });

  test('text send updates messages and conversation across reopen', () async {
    final sentAt = DateTime.utc(2026, 7, 31, 12, 30);
    var database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(() async {
      if (database.connection.isOpen) {
        await database.close();
      }
    });

    var repositories = OfflineRepositoryBundle(database);
    final sent = await repositories.conversations.sendTextMessage(
      conversationId: 'conversation_product',
      senderProfileId: 'profile_current',
      text: '  本地发送持久化验证  ',
      sentAt: sentAt,
    );
    final messages = await repositories.conversations.listMessages(
      'conversation_product',
    );
    final conversation = (await repositories.conversations.listConversations())
        .singleWhere((item) => item.id == 'conversation_product');

    expect(sent.text, '本地发送持久化验证');
    expect(sent.status, 'sent');
    expect(messages.last.id, sent.id);
    expect(conversation.lastMessagePreview, sent.text);
    expect(conversation.lastMessageAt, sentAt);

    await database.close();
    database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    repositories = OfflineRepositoryBundle(database);

    final reopenedMessages = await repositories.conversations.listMessages(
      'conversation_product',
    );
    final reopenedConversation =
        (await repositories.conversations.listConversations())
            .singleWhere((item) => item.id == 'conversation_product');

    expect(reopenedMessages.last.id, sent.id);
    expect(reopenedConversation.lastMessagePreview, sent.text);
    expect(reopenedConversation.lastMessageAt, sentAt);
  });

  test('failed text send does not leave a partial message', () async {
    final database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    addTearDown(database.close);
    final repositories = OfflineRepositoryBundle(database);
    final before = Sqflite.firstIntValue(
      await database.connection.rawQuery('SELECT COUNT(*) FROM messages'),
    );

    await expectLater(
      repositories.conversations.sendTextMessage(
        conversationId: 'conversation_missing',
        senderProfileId: 'profile_current',
        text: '不应写入',
      ),
      throwsA(isA<DatabaseException>()),
    );

    final after = Sqflite.firstIntValue(
      await database.connection.rawQuery('SELECT COUNT(*) FROM messages'),
    );
    expect(after, before);
  });
}
