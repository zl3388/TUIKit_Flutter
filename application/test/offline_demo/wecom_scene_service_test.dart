import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_database_package_exporter.dart';
import 'package:application/src/offline_demo/data/wecom_directory_repository.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_merge_planner.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_migration_service.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_merged_directory_repository.dart';
import 'package:application/src/offline_demo/data/wecom_message_overlay_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:application/src/offline_demo/data/wecom_scene_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

const _scope = WeComIdentityScope(corporationId: 100, userId: 1);

void main() {
  late Directory root;
  late Directory imports;
  late WeComOverlayDatabase overlay;
  late WeComPackageContract contract;
  late WeComDatabasePackageImporter importer;
  late WeComImportedPackage base;
  late bool admin;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tui_wecom_scenes_');
    imports = Directory(p.join(root.path, 'imports'));
    contract = WeComPackageContract(
      formatVersion: 1,
      scope: 'scene test',
      databases: identityDatabaseContracts(),
    );
    importer = WeComDatabasePackageImporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    final source = await Directory(p.join(root.path, 'source')).create();
    await createIdentityDatabases(source, contactName: 'Base');
    base = await importer.importPackage(
      sourceDirectory: source,
      destinationRoot: imports,
    );
    overlay = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(root.path, 'overlay.db'),
    );
    admin = true;
    await WeComActiveDatasetResolver(
      destinationRoot: imports,
      packageImporter: importer,
      databaseFactory: databaseFactoryFfi,
      overlayDatabase: overlay,
    ).ensureInitialDataset(base.datasetId);
  });
  tearDown(() async {
    await overlay.close();
    await root.delete(recursive: true);
  });

  WeComSceneService service(String id, {String? datasetId}) =>
      WeComSceneService(
        overlayDatabase: overlay.forScene(id),
        datasetResolver: WeComActiveDatasetResolver(
          destinationRoot: imports,
          packageImporter: importer,
          databaseFactory: databaseFactoryFfi,
          overlayDatabase: overlay.forScene(id),
        ),
        identityScope: _scope,
        datasetId: datasetId ?? base.datasetId,
        canEdit: () => admin,
      );

  WeComOverlayCommandService commands(String id) => WeComOverlayCommandService(
        overlayDatabase: overlay.forScene(id),
        contract: contract,
        identityScope: _scope,
      );
  WeComLocalSimulationRepository simulations(String id) =>
      WeComLocalSimulationRepository(
        overlayDatabase: overlay.forScene(id),
        identityScope: _scope,
      );
  WeComMessageOverlayRepository messages(String id) =>
      WeComMessageOverlayRepository(
        overlayDatabase: overlay.forScene(id),
        identityScope: _scope,
      );

  Future<String> contactName(String id, {WeComImportedPackage? package}) async {
    final selected = package ?? base;
    final db = await databaseFactoryFfi.openDatabase(
      selected.databaseFile('user.db').path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final contacts = await WeComMergedDirectoryRepository(
        datasetId: selected.datasetId,
        identityScope: _scope,
        baseRepository: WeComDirectoryRepository(db),
        overlayDatabase: overlay.forScene(id),
      ).listInternalContacts();
      return contacts.single.displayName;
    } finally {
      await db.close();
    }
  }

  Future<List<String>> messageTexts(String id) async =>
      (await messages(id).apply(
        conversationId: 'R:1',
        messages: const [],
        baseTargetKeys: const {},
        senderNames: const {'1': 'Self', '2': 'Peer'},
      ))
          .map((item) => item.text)
          .toList();

  Future<int> nameRevision(String id, String name, {int? reverts}) =>
      commands(id).upsert(
        datasetId: base.datasetId,
        databaseName: 'user.db',
        tableName: 'user_table',
        rowKey: const {'id': 1},
        values: {'name': name},
        revertsRevisionId: reverts,
      );

  test('empty scene isolates all logs and switching preserves the default',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    await nameRevision('default', 'Edited');
    await messages('default').append(
      conversationId: 'R:1',
      targetKey: 'overlay:message',
      action: 'add',
      state: WeComMessageOverlayState.text(
          senderId: '2', text: 'Local message', sentAt: DateTime.utc(2026)),
    );
    await simulations('default').enqueueTextExchange(
        conversationId: 'R:1', senderProfileId: '1', text: 'Simulation');

    final created = await scenes.create('Empty');
    expect(await contactName(created.id), 'Base');
    expect(await messageTexts(created.id), isEmpty);
    expect(await simulations(created.id).listExchanges(), isEmpty);
    await nameRevision(created.id, 'Only empty scene');
    await service(created.id).switchScene('default');
    expect(await contactName('default'), 'Edited');
    expect(await messageTexts('default'), ['Local message']);
    expect(await simulations('default').listExchanges(), hasLength(1));
    expect(await contactName(created.id), 'Only empty scene');
  });

  test('copy remaps undo and cancellation references without changing history',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    final revision = await nameRevision('default', 'Temporary');
    await nameRevision('default', 'Base', reverts: revision);
    final edit = await messages('default').append(
      conversationId: 'R:1',
      targetKey: 'overlay:undone',
      action: 'add',
      state: WeComMessageOverlayState.text(
          senderId: '1', text: 'Undo me', sentAt: DateTime.utc(2026)),
    );
    await messages('default').undo(edit);
    final cancelled = await simulations('default').enqueueTextExchange(
        conversationId: 'R:1', senderProfileId: '1', text: 'Cancelled');
    await simulations('default').cancelTextExchange(cancelled.eventKey);
    final call = await simulations('default').scheduleCall(
        peerProfileId: '2',
        scheduledAt: DateTime.now().add(const Duration(days: 1)));
    await simulations('default').cancelCall(call.eventKey);
    final visible = await simulations('default').enqueueTextExchange(
        conversationId: 'R:1', senderProfileId: '1', text: 'Visible');

    final copy = await scenes.create('Copy', copyFromSceneId: 'default');
    expect(await contactName(copy.id), 'Base');
    expect(await messageTexts(copy.id), isEmpty);
    expect(await simulations(copy.id).listCalls(), isEmpty);
    expect((await simulations(copy.id).listExchanges()).single.eventKey,
        visible.eventKey);
    for (final log in [
      ('overlay_operations', 'revision_id', 'reverts_revision_id'),
      ('overlay_simulation_events', 'event_id', 'reverts_event_id'),
      ('overlay_message_edits', 'edit_id', 'reverts_edit_id'),
    ]) {
      final copied = await overlay.connection.query(log.$1,
          where: 'scene_id = ?', whereArgs: [copy.id], orderBy: log.$2);
      final ids = copied.map((row) => row[log.$2]).toSet();
      expect(copied.where((row) => row[log.$3] != null), isNotEmpty);
      for (final row in copied.where((row) => row[log.$3] != null)) {
        expect(ids, contains(row[log.$3]));
      }
    }
    await simulations(copy.id).cancelTextExchange(visible.eventKey);
    expect(await simulations(copy.id).listExchanges(), isEmpty);
    expect(await simulations('default').listExchanges(), hasLength(1));
    await expectLater(nameRevision(copy.id, 'Invalid undo', reverts: revision),
        throwsStateError);
  });

  test('snapshot freezes all logs and restores as a separate editable scene',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    await nameRevision('default', 'Frozen');
    final snapshot = await scenes.saveSnapshot('Checkpoint');
    await nameRevision('default', 'Later');
    expect(snapshot.isSnapshot, isTrue);
    expect(await contactName(snapshot.id), 'Frozen');
    await expectLater(scenes.switchScene(snapshot.id), throwsStateError);
    await expectLater(nameRevision(snapshot.id, 'Tampered'),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        simulations(snapshot.id).enqueueTextExchange(
            conversationId: 'R:1', senderProfileId: '1', text: 'Tampered'),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        messages(snapshot.id).append(
            conversationId: 'R:1',
            targetKey: 'overlay:tampered',
            action: 'add',
            state: WeComMessageOverlayState.text(
                senderId: '1', text: 'Tampered', sentAt: DateTime.utc(2026))),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        overlay.connection.insert(WeComOverlaySchema.datasetActivationsTable, {
          'scene_id': snapshot.id,
          'dataset_id': base.datasetId,
          'current_corp_id': 100,
          'current_user_id': 1,
          'created_at_micros': 1,
        }),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        overlay.connection.update(
            WeComOverlaySchema.scenesTable, {'kind': 'scene'},
            where: 'scene_id = ?', whereArgs: [snapshot.id]),
        throwsA(isA<DatabaseException>()));
    final restored =
        await scenes.create('Restored', copyFromSceneId: snapshot.id);
    expect(restored.isSnapshot, isFalse);
    expect(await contactName(restored.id), 'Frozen');
    await nameRevision(restored.id, 'Restored edit');
    expect(await contactName(snapshot.id), 'Frozen');
    expect(await contactName('default'), 'Later');
  });

  test('reset saves a frozen checkpoint and appends an empty scene atomically',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    await nameRevision('default', 'Before reset');
    await scenes.reset('Clean');
    final list = await scenes.list();
    final snapshot = list.singleWhere((item) => item.isSnapshot);
    final empty = list.singleWhere((item) => item.name == 'Clean');
    expect(snapshot.name, '重置前 Clean');
    expect(await contactName(snapshot.id), 'Before reset');
    expect(await contactName('default'), 'Before reset');
    expect(await contactName(empty.id), 'Base');
    expect(
        (await overlay.connection.query(
                WeComOverlaySchema.datasetActivationsTable,
                orderBy: 'activation_id DESC',
                limit: 1))
            .single['scene_id'],
        empty.id);
  });

  test('reopening selects the persisted scene without closing shared wrappers',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    final created = await scenes.create('Persisted');
    await nameRevision(created.id, 'Persisted edit');
    await overlay.forScene(created.id).close();
    expect(await contactName(created.id), 'Persisted edit');
    await overlay.close();
    overlay = await WeComOverlayDatabase.open(
        factory: databaseFactoryFfi,
        databasePath: p.join(root.path, 'overlay.db'));
    expect(overlay.sceneId, created.id);
    expect(await contactName(overlay.sceneId), 'Persisted edit');
  });

  test(
      'admin expiry, stale services and other identities cannot activate scenes',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    admin = false;
    await expectLater(scenes.create('Denied'), throwsStateError);
    await expectLater(scenes.saveSnapshot('Denied'), throwsStateError);
    await expectLater(scenes.reset('Denied'), throwsStateError);
    admin = true;
    final created = await scenes.create('Active');
    await expectLater(scenes.saveSnapshot('Stale'), throwsStateError);
    final other = WeComSceneService(
        overlayDatabase: overlay.forScene(created.id),
        datasetResolver: WeComActiveDatasetResolver(
            destinationRoot: imports,
            packageImporter: importer,
            databaseFactory: databaseFactoryFfi,
            overlayDatabase: overlay),
        identityScope: const WeComIdentityScope(corporationId: 200, userId: 2),
        datasetId: base.datasetId,
        canEdit: () => true);
    expect(await other.list(), isEmpty);
    await expectLater(other.switchScene(created.id), throwsStateError);
    await expectLater(
        other.create('Cross identity', copyFromSceneId: created.id),
        throwsStateError);
    await expectLater(service(created.id).create('  '), throwsArgumentError);
  });

  test(
      'refresh advances only the active scene; snapshots keep the old baseline',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    final snapshot = await scenes.saveSnapshot('Old base');
    final copy = await scenes.create('Refresh me', copyFromSceneId: 'default');
    await nameRevision(copy.id, 'Overlay name');
    final source = await Directory(p.join(root.path, 'updated')).create();
    await createIdentityDatabases(source,
        contactName: 'Base', account: 'changed');
    final updated = await importer.importPackage(
        sourceDirectory: source, destinationRoot: imports);
    final result = await WeComIncrementalMigrationService(
      overlayDatabase: overlay.forScene(copy.id),
      planner: WeComIncrementalMergePlanner(
          contract: contract, databaseFactory: databaseFactoryFfi),
      identityResolver: WeComIdentityResolver(databaseFactoryFfi),
    ).migrate(oldBasePackage: base, newBasePackage: updated);
    expect(result.applied, isTrue);
    final list = await scenes.list();
    expect(list.singleWhere((item) => item.id == copy.id).datasetId,
        updated.datasetId);
    expect(list.singleWhere((item) => item.id == snapshot.id).datasetId,
        base.datasetId);
    expect(list.singleWhere((item) => item.id == 'default').datasetId,
        base.datasetId);
    expect(await contactName(copy.id, package: updated), 'Overlay name');
    await service(copy.id, datasetId: updated.datasetId).switchScene('default');
    expect(await contactName('default'), 'Base');
    await nameRevision('default', 'Overlay name');
    final defaultResult = await WeComIncrementalMigrationService(
      overlayDatabase: overlay.forScene('default'),
      planner: WeComIncrementalMergePlanner(
          contract: contract, databaseFactory: databaseFactoryFfi),
      identityResolver: WeComIdentityResolver(databaseFactoryFfi),
    ).migrate(oldBasePackage: base, newBasePackage: updated);
    expect(defaultResult.applied, isTrue);
    expect(defaultResult.mergeId, isNot(result.mergeId));
    expect(await contactName('default', package: updated), 'Overlay name');
  });

  test('reset rolls back checkpoint and scene creation if activation fails',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    await nameRevision('default', 'Keep me');
    await overlay.connection.execute('CREATE TRIGGER test_block_activation '
        'BEFORE INSERT ON ${WeComOverlaySchema.datasetActivationsTable} '
        "BEGIN SELECT RAISE(ABORT, 'test activation failure'); END");
    await expectLater(
        scenes.reset('Failed reset'), throwsA(isA<DatabaseException>()));
    expect((await scenes.list()).map((item) => item.id), ['default']);
    expect(await contactName('default'), 'Keep me');
    expect(await overlay.connection.query(WeComOverlaySchema.operationsTable),
        hasLength(1));
  });

  test(
      'restricted export includes only the selected scene and leaves bases intact',
      () async {
    final scenes = service('default');
    await scenes.ensureDefaultScene();
    await nameRevision('default', 'Default edit');
    final empty = await scenes.create('Export scene');
    await nameRevision(empty.id, 'Export edit');
    final originalHash =
        sha256.convert(await base.databaseFile('user.db').readAsBytes());
    final exported = await WeComDatabasePackageExporter(
            contract: contract, databaseFactory: databaseFactoryFfi)
        .export(
      basePackage: base,
      overlayDatabase: overlay.forScene(empty.id),
      identityScope: _scope,
      destinationDirectory: Directory(p.join(root.path, 'export')),
    );
    expect(exported.appliedRevisionCount, 1);
    final db = await databaseFactoryFfi.openDatabase(
        p.join(root.path, 'export', 'user.db'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    expect((await db.query('user_table')).single['name'], 'Export edit');
    await db.close();
    expect(sha256.convert(await base.databaseFile('user.db').readAsBytes()),
        originalHash);
    expect(await contactName('default'), 'Default edit');
  });
}
