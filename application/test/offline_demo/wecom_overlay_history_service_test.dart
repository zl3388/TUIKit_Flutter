import 'dart:convert';
import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_message_overlay_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_history_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

const _scope = WeComIdentityScope(corporationId: 100, userId: 1);

void main() {
  late Directory root;
  late WeComImportedPackage base;
  late WeComOverlayDatabase overlay;
  late WeComPackageContract contract;
  var admin = true;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tui_history_');
    contract = WeComPackageContract(
        formatVersion: 1,
        scope: 'history tests',
        databases: identityDatabaseContracts());
    final source = await Directory(p.join(root.path, 'source')).create();
    await createIdentityDatabases(source, contactName: 'Base');
    final importer = WeComDatabasePackageImporter(
        contract: contract, databaseFactory: databaseFactoryFfi);
    final imports = Directory(p.join(root.path, 'imports'));
    base = await importer.importPackage(
        sourceDirectory: source, destinationRoot: imports);
    overlay = await WeComOverlayDatabase.open(
        factory: databaseFactoryFfi,
        databasePath: p.join(root.path, 'overlay.db'));
    await WeComActiveDatasetResolver(
            destinationRoot: imports,
            packageImporter: importer,
            databaseFactory: databaseFactoryFfi,
            overlayDatabase: overlay)
        .ensureInitialDataset(base.datasetId);
    admin = true;
  });
  tearDown(() async {
    await overlay.close();
    await root.delete(recursive: true);
  });

  WeComOverlayHistoryService history(
          {String scene = 'default',
          WeComIdentityScope scope = _scope,
          bool Function()? allowed}) =>
      WeComOverlayHistoryService(
          overlay: overlay.forScene(scene),
          base: base,
          factory: databaseFactoryFfi,
          contract: contract,
          scope: scope,
          canEdit: allowed ?? () => admin);
  WeComOverlayCommandService commands(
          {String scene = 'default', WeComIdentityScope scope = _scope}) =>
      WeComOverlayCommandService(
          overlayDatabase: overlay.forScene(scene),
          contract: contract,
          identityScope: scope);
  Future<int> field(Map<String, Object?> values, {String? dataset}) =>
      commands().upsert(
          datasetId: dataset ?? base.datasetId,
          databaseName: 'user.db',
          tableName: 'user_table',
          rowKey: const {'id': 1},
          values: values);
  WeComMessageOverlayRepository messages() => WeComMessageOverlayRepository(
      overlayDatabase: overlay, identityScope: _scope);
  WeComLocalSimulationRepository simulation() => WeComLocalSimulationRepository(
      overlayDatabase: overlay, identityScope: _scope);

  test(
      'field differences and successive undo survive restart without base writes',
      () async {
    final beforeHashes = {
      for (final name in base.files.keys)
        name: sha256
            .convert(await base.databaseFile(name).readAsBytes())
            .toString()
    };
    final first = await field({'real_name': 'First'});
    final second = await field({'real_name': 'Second', 'position': 'Changed'});
    var detail = await history().detail(WeComHistoryKind.fields, second);
    expect(detail.before['real_name'], 'First');
    expect(detail.after, {'real_name': 'Second', 'position': 'Changed'});
    expect(detail.undoReason, isNull);
    await expectLater(
        history().undo(WeComHistoryKind.fields, first), throwsStateError);
    await overlay.close();
    overlay = await WeComOverlayDatabase.open(
        factory: databaseFactoryFfi,
        databasePath: p.join(root.path, 'overlay.db'));
    await history().undo(WeComHistoryKind.fields, second);
    detail = await history().detail(WeComHistoryKind.fields, first);
    expect(detail.undoReason, isNull);
    await history().undo(WeComHistoryKind.fields, first);
    final rows = await overlay.connection
        .query(WeComOverlaySchema.operationsTable, orderBy: 'revision_id');
    expect(rows, hasLength(4));
    expect(await history().fieldRecordCount(), 4);
    expect(rows.last['reverts_revision_id'], first);
    final db = await base.openReadOnly('user.db', factory: databaseFactoryFfi);
    final original = (await db.query('user_table', where: 'id = 1')).single;
    await db.close();
    expect(jsonDecode(rows.last['values_json']! as String),
        {'real_name': original['real_name']});
    for (final name in base.files.keys) {
      expect(
          sha256
              .convert(await base.databaseFile(name).readAsBytes())
              .toString(),
          beforeHashes[name]);
    }
    await expectLater(
        history().undo(WeComHistoryKind.fields, first), throwsStateError);
  });

  test('history is paged and isolated by kind, scene and exact identity',
      () async {
    final ids =
        await commands().appendBatch(datasetId: base.datasetId, mutations: [
      for (var i = 0; i < 55; i++)
        WeComOverlayMutation.upsert(
            databaseName: 'user.db',
            tableName: 'user_table',
            rowKey: const {'id': 1},
            values: {'real_name': 'Name $i'})
    ]);
    await commands(scene: 'other').upsert(
        datasetId: base.datasetId,
        databaseName: 'user.db',
        tableName: 'user_table',
        rowKey: const {'id': 1},
        values: const {'real_name': 'Other scene'});
    await commands(
            scope: const WeComIdentityScope(corporationId: 100, userId: 2))
        .upsert(
            datasetId: base.datasetId,
            databaseName: 'user.db',
            tableName: 'user_table',
            rowKey: const {'id': 1},
            values: const {'real_name': 'Other user'});
    final page = await history().list(WeComHistoryKind.fields);
    final tail = await history().list(WeComHistoryKind.fields, offset: 50);
    expect(page.map((e) => e.id), ids.reversed.take(50));
    expect(tail.map((e) => e.id), ids.reversed.skip(50));
    expect(await history().list(WeComHistoryKind.messages), isEmpty);
    await expectLater(history().list(WeComHistoryKind.fields, offset: -1),
        throwsArgumentError);
    await expectLater(history().detail(WeComHistoryKind.fields, ids.last + 1),
        throwsStateError);
  });

  test('message add, replace and hide can be undone in persisted stack order',
      () async {
    final add = await messages().append(
        conversationId: 'R:1',
        targetKey: 'overlay:1',
        action: 'add',
        state: WeComMessageOverlayState.text(
            senderId: '2', text: 'Peer', sentAt: DateTime.utc(2026)));
    final replace = await messages().append(
        conversationId: 'R:1',
        targetKey: 'overlay:1',
        action: 'replace',
        state: WeComMessageOverlayState.text(
            senderId: '1', text: 'Me', sentAt: DateTime.utc(2026)));
    final hide = await messages().append(
        conversationId: 'R:1',
        targetKey: 'overlay:1',
        action: 'hide',
        state: const WeComMessageOverlayState.hidden());
    await expectLater(history().undo(WeComHistoryKind.messages, add.editId),
        throwsStateError);
    final detail =
        await history().detail(WeComHistoryKind.messages, hide.editId);
    expect(detail.before['text'], 'Me');
    expect(detail.after['mode'], 'hidden');
    for (final edit in [hide, replace, add]) {
      await history().undo(WeComHistoryKind.messages, edit.editId);
    }
    final rows = await overlay.connection
        .query(WeComOverlaySchema.messageEditsTable, orderBy: 'edit_id');
    expect(rows, hasLength(6));
    expect(rows.last['state_json'],
        const WeComMessageOverlayState.hidden().encode());
    expect(
        await messages().apply(
            conversationId: 'R:1',
            messages: [],
            baseTargetKeys: {},
            senderNames: {}),
        isEmpty);
    await expectLater(history().undo(WeComHistoryKind.messages, add.editId),
        throwsStateError);
    final reverse = await history()
        .detail(WeComHistoryKind.messages, rows.last['edit_id']! as int);
    expect(reverse.undoReason, isNotNull);
  });

  test('base message undo restores inheritance, not a fabricated base text',
      () async {
    final edit = await messages().append(
        conversationId: 'R:1',
        targetKey: 'base:1:hash',
        action: 'hide',
        state: const WeComMessageOverlayState.hidden());
    final detail =
        await history().detail(WeComHistoryKind.messages, edit.editId);
    expect(detail.before, {'mode': 'inherit'});
    await history().undo(WeComHistoryKind.messages, edit.editId);
    expect(
        (await overlay.connection.query(WeComOverlaySchema.messageEditsTable,
                orderBy: 'edit_id'))
            .last['state_json'],
        const WeComMessageOverlayState.inherit().encode());
  });

  test(
      'simulation cancellation appends one reverse event and preserves originals',
      () async {
    final exchange = await simulation().enqueueTextExchange(
        conversationId: 'R:1', senderProfileId: '1', text: 'Test');
    final call = await simulation().scheduleCall(
        peerProfileId: '2',
        scheduledAt: DateTime.now().add(const Duration(days: 1)));
    final entries = await history().list(WeComHistoryKind.simulations);
    for (final entry in entries) {
      expect((await history().detail(entry.kind, entry.id)).undoReason, isNull);
      await history().undo(entry.kind, entry.id);
      await expectLater(history().undo(entry.kind, entry.id), throwsStateError);
    }
    expect(await simulation().listExchanges(), isEmpty);
    expect(await simulation().listCalls(), isEmpty);
    final rows = await overlay.connection
        .query(WeComOverlaySchema.simulationEventsTable);
    expect(rows, hasLength(4));
    final reverse = rows.last;
    final difference = await history()
        .detail(WeComHistoryKind.simulations, reverse['event_id']! as int);
    expect(difference.before['event_type'], 'textExchange');
    expect(difference.after['event_type'], 'cancelExchange');
    expect(rows.map((e) => e['event_key']),
        containsAll([exchange.eventKey, call.eventKey]));
  });

  test(
      'old datasets, unknown fields and non-LIFO legacy histories are read only',
      () async {
    final old = await field({'real_name': 'Old'}, dataset: 'b' * 64);
    final unknown = await field({'name': 'Not in editor'});
    for (final id in [old, unknown]) {
      expect((await history().detail(WeComHistoryKind.fields, id)).undoReason,
          isNotNull);
      await expectLater(
          history().undo(WeComHistoryKind.fields, id), throwsStateError);
    }
    final first = await field({'real_name': 'First'});
    await field({'real_name': 'Newer'});
    await commands().upsert(
        datasetId: base.datasetId,
        databaseName: 'user.db',
        tableName: 'user_table',
        rowKey: const {'id': 1},
        values: const {'real_name': 'Old inverse'},
        revertsRevisionId: first);
    expect((await history().detail(WeComHistoryKind.fields, first)).undoReason,
        contains('顺序不一致'));
  });

  test('undo rechecks later edits after the detail screen was loaded',
      () async {
    final first = await field({'real_name': 'First'});
    expect((await history().detail(WeComHistoryKind.fields, first)).undoReason,
        isNull);
    await field({'real_name': 'Later'});
    await expectLater(
        history().undo(WeComHistoryKind.fields, first), throwsStateError);
    expect(await overlay.connection.query(WeComOverlaySchema.operationsTable),
        hasLength(2));
  });

  test('expired management and switched identity or scene cannot read or undo',
      () async {
    final id = await field({'real_name': 'Keep'});
    admin = false;
    await expectLater(
        history().list(WeComHistoryKind.fields), throwsStateError);
    await expectLater(
        history().undo(WeComHistoryKind.fields, id), throwsStateError);
    admin = true;
    await expectLater(history(scene: 'other').undo(WeComHistoryKind.fields, id),
        throwsStateError);
    await expectLater(
        history(scope: const WeComIdentityScope(corporationId: 200, userId: 1))
            .list(WeComHistoryKind.fields),
        throwsStateError);
    await overlay.connection
        .insert(WeComOverlaySchema.datasetActivationsTable, {
      'previous_dataset_id': base.datasetId,
      'dataset_id': base.datasetId,
      'scene_id': 'other',
      'current_corp_id': 100,
      'current_user_id': 1,
      'created_at_micros': DateTime.now().microsecondsSinceEpoch,
    });
    await expectLater(
        history().undo(WeComHistoryKind.fields, id), throwsStateError);
    expect(await overlay.connection.query(WeComOverlaySchema.operationsTable),
        hasLength(1));
  });

  test('expiry during difference reconstruction aborts the write', () async {
    final id = await field({'real_name': 'Keep'});
    var checks = 0;
    await expectLater(
        history(allowed: () => ++checks < 3).undo(WeComHistoryKind.fields, id),
        throwsStateError);
    expect(await overlay.connection.query(WeComOverlaySchema.operationsTable),
        hasLength(1));
  });

  test('failed reverse insert leaves the original history intact', () async {
    final id = await field({'real_name': 'Keep'});
    final original =
        await overlay.connection.query(WeComOverlaySchema.operationsTable);
    await overlay.connection.execute(
        'CREATE TRIGGER block_reverse BEFORE INSERT ON '
        '${WeComOverlaySchema.operationsTable} BEGIN SELECT RAISE(ABORT, \'blocked\'); END');
    await expectLater(history().undo(WeComHistoryKind.fields, id),
        throwsA(isA<DatabaseException>()));
    expect(await overlay.connection.query(WeComOverlaySchema.operationsTable),
        original);
  });
}
