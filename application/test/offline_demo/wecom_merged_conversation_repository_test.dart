import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_merged_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const datasetId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const otherDatasetId =
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
  late WeComPackageContract contract;
  late Directory temporaryDirectory;
  late Database baseDatabase;
  late WeComOverlayDatabase overlayDatabase;
  late WeComOverlayCommandService commands;
  late WeComMergedConversationRepository repository;

  setUpAll(() async {
    sqfliteFfiInit();
    contract = WeComPackageContract.fromJsonString(
      await File(
        p.join(
          Directory.current.path,
          'assets',
          'offline_demo',
          'wecom_schema_contract.json',
        ),
      ).readAsString(),
    );
  });

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_merged_sessions_');
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
    commands = WeComOverlayCommandService(
      overlayDatabase: overlayDatabase,
      contract: contract,
    );
    repository = WeComMergedConversationRepository(
      datasetId: datasetId,
      baseRepository: WeComConversationRepository(baseDatabase),
      overlayDatabase: overlayDatabase,
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    await baseDatabase.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('projects conversation and unread revisions before stable pagination',
      () async {
    final renamedRevision = await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 1},
      values: const {
        'name': 'Temporary name',
        'roomname_remark': '',
        'last_message_time': 50,
      },
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 1},
      values: const {
        'name': 'Base one',
        'roomname_remark': '',
        'last_message_time': 300,
      },
      revertsRevisionId: renamedRevision,
    );
    final deletedRevision = await commands.tombstone(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 2},
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 2},
      values: const {'name': 'Restored two'},
      revertsRevisionId: deletedRevision,
    );
    await commands.tombstone(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 3},
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 4},
      values: const {
        'id': 'R:4',
        'name': 'Overlay four',
        'last_message_time': 400,
        'is_sticked': 1,
      },
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'unread_conversation_table',
      rowKey: const {'conversation_id': 'R:1'},
      values: const {
        'begin_cursor': 40,
        'current_cursor': 45,
        'unread_count': 5,
      },
    );
    await commands.tombstone(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'unread_conversation_table',
      rowKey: const {'conversation_id': 'R:2'},
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'unread_conversation_table',
      rowKey: const {'conversation_id': 'R:4'},
      values: const {'unread_count': 7},
    );

    final conversations = await repository.listConversations();

    expect(
        conversations.map((conversation) => conversation.numericId), [4, 1, 2]);
    expect(conversations.map((conversation) => conversation.displayName), [
      'Overlay four',
      'Base one',
      'Restored two',
    ]);
    expect(conversations.first.pinnedFlag, 1);
    expect(conversations.first.unreadState!.beginCursor, 0);
    expect(conversations.first.unreadState!.unreadCount, 7);
    expect(conversations[1].unreadState!.currentCursor, 45);
    expect(conversations[1].unreadState!.unreadCount, 5);
    expect(conversations.last.unreadState, isNull);

    final page = await repository.listConversations(limit: 2, offset: 1);
    expect(page.map((conversation) => conversation.numericId), [1, 2]);
  });

  test('projects member deletion, restoration, and overlay-only creation',
      () async {
    final deletedRevision = await commands.tombstone(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_user_table',
      rowKey: const {'conversation_id': 'R:1', 'user_id': 1},
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_user_table',
      rowKey: const {'conversation_id': 'R:1', 'user_id': 1},
      values: const {'gag_type': 2},
      revertsRevisionId: deletedRevision,
    );
    await commands.tombstone(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_user_table',
      rowKey: const {'conversation_id': 'R:1', 'user_id': 2},
    );
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_user_table',
      rowKey: const {'conversation_id': 'R:1', 'user_id': 3},
      values: const {'nick_name': 'Overlay member', 'is_admin': 3},
    );

    final members = await repository.listConversationMembers('R:1');

    expect(members.map((member) => member.userId), [1, 3]);
    expect(members.first.joinTime, 100);
    expect(members.first.gagType, 2);
    expect(members.first.nickname, 'Base member');
    expect(members.last.joinTime, 0);
    expect(members.last.nickname, 'Overlay member');
    expect(members.last.adminFlag, 3);
  });

  test('isolates datasets and validates merged pagination', () async {
    await commands.upsert(
      datasetId: otherDatasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 1},
      values: const {'roomname_remark': 'Other dataset'},
    );

    final conversations = await repository.listConversations();
    expect(conversations.first.displayName, 'Base one');
    await expectLater(repository.listConversations(limit: 0), throwsRangeError);
    await expectLater(
      repository.listConversations(offset: -1),
      throwsRangeError,
    );
  });

  test('does not cascade logical conversation id changes across tables',
      () async {
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 1},
      values: const {'id': 'R:renamed'},
    );

    final conversation = (await repository.listConversations()).first;
    expect(conversation.id, 'R:renamed');
    expect(conversation.unreadState, isNull);
    expect(await repository.listConversationMembers('R:renamed'), isEmpty);
    expect(
      (await repository.listConversationMembers('R:1'))
          .map((member) => member.userId),
      [1, 2],
    );
  });

  test('rejects duplicate logical conversation ids after projection', () async {
    await commands.upsert(
      datasetId: datasetId,
      databaseName: 'session.db',
      tableName: 'conversation_table',
      rowKey: const {'con_numeric_id': 2},
      values: const {'id': 'R:1'},
    );

    await expectLater(
      repository.listConversations(),
      throwsA(isA<StateError>()),
    );
  });

  test('fails diagnostically for malformed raw overlay JSON', () async {
    await overlayDatabase.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': datasetId,
        'database_name': 'session.db',
        'table_name': 'conversation_table',
        'row_key_json': '[]',
        'operation': 'tombstone',
        'values_json': null,
        'created_at_micros': 1,
      },
    );

    await expectLater(
      repository.listConversations(),
      throwsA(isA<FormatException>()),
    );
  });
}

Future<void> _createBaseFixture(String path) async {
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
        final batch = database.batch();
        batch.insert('conversation_table', {
          'con_numeric_id': 1,
          'id': 'R:1',
          'name': 'Base one',
          'last_message_time': 300,
          'last_message_id': 31,
        });
        batch.insert('conversation_table', {
          'con_numeric_id': 2,
          'id': 'R:2',
          'name': 'Base two',
          'last_message_time': 200,
          'last_message_id': 21,
        });
        batch.insert('conversation_table', {
          'con_numeric_id': 3,
          'id': 'R:3',
          'name': 'Base three',
          'last_message_time': 100,
          'last_message_id': 11,
        });
        batch.insert('unread_conversation_table', {
          'conversation_id': 'R:1',
          'begin_cursor': 30,
          'current_cursor': 30,
          'unread_count': 0,
        });
        batch.insert('unread_conversation_table', {
          'conversation_id': 'R:2',
          'begin_cursor': 20,
          'current_cursor': 21,
          'unread_count': 1,
        });
        batch.insert('conversation_user_table', {
          'conversation_id': 'R:1',
          'user_id': 1,
          'join_time': 100,
          'gag_type': 0,
          'nick_name': 'Base member',
          'is_admin': 0,
        });
        batch.insert('conversation_user_table', {
          'conversation_id': 'R:1',
          'user_id': 2,
          'join_time': 200,
          'gag_type': 0,
          'nick_name': 'Deleted member',
          'is_admin': 1,
        });
        await batch.commit(noResult: true);
      },
    ),
  );
  await database.close();
}
