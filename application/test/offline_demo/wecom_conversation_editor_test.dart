import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_conversation_editor.dart';
import 'package:application/src/offline_demo/data/wecom_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
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
  const identity = WeComIdentityScope(corporationId: 100, userId: 1);
  late Directory temporaryDirectory;
  late Database baseDatabase;
  late WeComOverlayDatabase overlayDatabase;
  late WeComMergedConversationRepository conversations;
  late WeComConversationEditor editor;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_conversation_editor_');
    final basePath = p.join(temporaryDirectory.path, 'session.db');
    await _createBase(basePath);
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
    conversations = WeComMergedConversationRepository(
      datasetId: datasetId,
      identityScope: identity,
      baseRepository: WeComConversationRepository(baseDatabase),
      overlayDatabase: overlayDatabase,
    );
    editor = WeComConversationEditor(
      datasetId: datasetId,
      conversations: conversations,
      commands: WeComOverlayCommandService(
        overlayDatabase: overlayDatabase,
        contract: contract,
        identityScope: identity,
      ),
      simulation: WeComLocalSimulationRepository(
        overlayDatabase: overlayDatabase,
        identityScope: identity,
      ),
    );
  });

  tearDown(() async {
    await overlayDatabase.close();
    await baseDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('updates selected flags atomically and appends an inverse batch',
      () async {
    final edit = await editor.updateFlags(
      conversationIds: const {'R:one', 'S:1_2'},
      isPinned: true,
      isMuted: false,
    );

    expect(edit.revisionIds, hasLength(2));
    var projected = await conversations.listConversations();
    final byId = {for (final item in projected) item.id: item};
    expect(byId['R:one']!.pinnedFlag, 1);
    expect(byId['R:one']!.blockedFlag, 0);
    expect(byId['S:1_2']!.pinnedFlag, 1);
    expect(byId['S:1_2']!.blockedFlag, 0);
    final base = await baseDatabase.query(
      'conversation_table',
      columns: ['id', 'is_sticked', 'is_blocked'],
      orderBy: 'con_numeric_id',
    );
    expect(base[0]['is_sticked'], 0);
    expect(base[1]['is_blocked'], 1);

    await editor.undoBatch(edit);

    projected = await conversations.listConversations();
    final restored = {for (final item in projected) item.id: item};
    expect(restored['R:one']!.pinnedFlag, 0);
    expect(restored['R:one']!.blockedFlag, 0);
    expect(restored['S:1_2']!.pinnedFlag, 1);
    expect(restored['S:1_2']!.blockedFlag, 1);
    final revisions = await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
      orderBy: 'revision_id',
    );
    expect(revisions, hasLength(4));
    expect(revisions[2]['reverts_revision_id'], edit.revisionIds[0]);
    expect(revisions[3]['reverts_revision_id'], edit.revisionIds[1]);
    await expectLater(editor.undoBatch(edit), throwsStateError);
  });

  test('rejects empty, missing, and no-op selections without partial writes',
      () async {
    await expectLater(
      editor.updateFlags(conversationIds: const {}, isPinned: true),
      throwsArgumentError,
    );
    await expectLater(
      editor.updateFlags(
        conversationIds: const {'R:one', 'missing'},
        isMuted: true,
      ),
      throwsStateError,
    );
    await expectLater(
      editor.updateFlags(
        conversationIds: const {'R:one'},
        isPinned: false,
        isMuted: false,
      ),
      throwsA(isA<WeComConversationNoChangesException>()),
    );
    final revisions = await overlayDatabase.connection.query(
      WeComOverlaySchema.operationsTable,
    );
    expect(revisions, isEmpty);
  });

  test('keeps batch projections isolated to the active identity', () async {
    await editor.updateFlags(
      conversationIds: const {'R:one'},
      isPinned: true,
    );
    final otherIdentity = WeComMergedConversationRepository(
      datasetId: datasetId,
      identityScope: const WeComIdentityScope(corporationId: 200, userId: 2),
      baseRepository: WeComConversationRepository(baseDatabase),
      overlayDatabase: overlayDatabase,
    );

    expect((await conversations.listConversations()).first.pinnedFlag, 1);
    expect((await otherIdentity.listConversations()).first.pinnedFlag, 0);
  });
}

Future<void> _createBase(String path) async {
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
    'id': 'R:one',
    'name': 'Room one',
    'last_message_time': 200,
    'is_sticked': 0,
    'is_blocked': 0,
  });
  await database.insert('conversation_table', {
    'con_numeric_id': 2,
    'id': 'S:1_2',
    'name': 'Direct two',
    'last_message_time': 100,
    'is_sticked': 1,
    'is_blocked': 1,
  });
  await database.close();
}
