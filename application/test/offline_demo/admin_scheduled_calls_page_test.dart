import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:application/src/offline_demo/presentation/admin_scheduled_calls_page.dart';
import 'package:application/src/offline_demo/state/admin_access_controller.dart';
import 'package:application/src/offline_demo/state/offline_demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late WeComOverlayDatabase database;
  late WeComLocalSimulationRepository simulation;
  late AdminAccessController adminAccess;
  late OfflineDemoStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tui_call_admin_');
    database = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: p.join(directory.path, 'overlay.db'),
    );
    simulation = WeComLocalSimulationRepository(
      overlayDatabase: database,
      identityScope: const WeComIdentityScope(corporationId: 100, userId: 1),
    );
    adminAccess = AdminAccessController(
      credentialStore: _MemoryAdminCredentialStore(),
      buildPin: '0000',
    );
    await adminAccess.initialize();
    await adminAccess.authenticate('0000');
    store = OfflineDemoStore(OfflineRepositoryBundle());
    store.contacts = const [DirectoryContact(id: '2', displayName: '测试联系人')];
  });

  tearDown(() async {
    store.dispose();
    adminAccess.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  testWidgets('admin schedules and cancels a call on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AdminScheduledCallsPage(
        store: store,
        simulation: simulation,
        adminAccess: adminAccess,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('scheduled-call-contact')), '测试');
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试联系人').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduled-call-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-call')));
    await tester.pumpAndSettle();

    expect(await simulation.listCalls(), hasLength(1));
    expect(find.textContaining('待来电'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final call = (await simulation.listCalls()).single;
    await tester.tap(find.byKey(Key('cancel-call-${call.eventKey}')));
    await tester.pumpAndSettle();
    expect(await simulation.listCalls(), isEmpty);
  });
}

class _MemoryAdminCredentialStore implements AdminCredentialStore {
  @override
  Future<AdminPinCredential?> load() async => null;

  @override
  Future<void> save(AdminPinCredential credential) async {}
}
