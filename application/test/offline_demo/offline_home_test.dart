import 'dart:async';
import 'dart:io';

import 'package:application/src/offline_demo/bootstrap/offline_bootstrap.dart';
import 'package:application/src/offline_demo/data/local_media_store.dart';
import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_data_source_service.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_database_package_exporter.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_local_simulation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_history_service.dart';
import 'package:application/src/offline_demo/data/wecom_restricted_export_service.dart';
import 'package:application/src/offline_demo/data/wecom_source_directory_access.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:application/src/offline_demo/offline_demo_app.dart';
import 'package:application/src/offline_demo/presentation/offline_home.dart';
import 'package:application/src/offline_demo/presentation/offline_theme.dart';
import 'package:application/src/offline_demo/state/admin_access_controller.dart';
import 'package:application/src/offline_demo/state/offline_demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets(
      'admin revision count refreshes on store changes and ignores stale reads',
      (tester) async {
    final history = _CounterHistory();
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(history: history)))!;
    addTearDown(fixture.close);
    await tester
        .runAsync(() => fixture.environment.adminAccess.setupPin('0000'));
    await tester.pumpWidget(MaterialApp(
        theme: OfflineTheme.light,
        home: OfflineHome(
            environment: fixture.environment,
            onEnvironmentReload: () async {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理').last);
    await tester.pumpAndSettle();
    final count = find.byKey(const Key('overlay-revision-count'));
    expect(tester.widget<Text>(count).data, '0');
    history.value = 2;
    await fixture.environment.store.refreshContacts();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '2');
    final stale = Completer<int>();
    history.next = stale.future;
    await fixture.environment.store.refreshContacts();
    history.next = null;
    history.value = 3;
    await fixture.environment.store.refreshContacts();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '3');
    stale.complete(1);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(count).data, '3');
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 1024.0]) {
    testWidgets(
      'navigates contacts, advanced messages, calls, and attachments at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = (await tester.runAsync(_HomeFixture.create))!;
        addTearDown(fixture.close);

        await tester.pumpWidget(
          MaterialApp(
            theme: OfflineTheme.light,
            home: OfflineHome(
              environment: fixture.environment,
              onEnvironmentReload: () async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Project room'), findsOneWidget);
        await tester.tap(find.text('Project room'));
        await tester.pumpAndSettle();
        expect(find.text('跨页面消息'), findsOneWidget);
        expect(find.text('Alice: 原始消息'), findsOneWidget);
        expect(find.text('引用回复'), findsOneWidget);
        expect(find.text('Alice 撤回了一条消息'), findsOneWidget);
        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('2026-09-15'), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('media-attachment-0:2:0')),
        );
        await tester.pump();
        expect(fixture.opener.opened.map((attachment) => attachment.id), [
          '0:2:0',
        ]);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('通讯录').last);
        await tester.pumpAndSettle();
        expect(find.text('Alice'), findsOneWidget);

        await tester.tap(find.text('Alice'));
        await tester.pumpAndSettle();
        expect(find.text('联系人详情'), findsOneWidget);
        expect(find.text('Engineering'), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('工作台').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('通话记录'));
        await tester.pumpAndSettle();
        expect(find.text('Alice'), findsOneWidget);
        expect(find.textContaining('呼入 · 未接'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'enters and exits local admin mode at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = (await tester.runAsync(_HomeFixture.create))!;
        addTearDown(fixture.close);

        await tester.pumpWidget(
          MaterialApp(
            theme: OfflineTheme.light,
            home: OfflineHome(
              environment: fixture.environment,
              onEnvironmentReload: () async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('我的').last);
        await tester.pumpAndSettle();
        final versionEntry = find.byKey(const Key('offline-version-entry'));
        for (var tap = 0; tap < 6; tap += 1) {
          await tester.tap(versionEntry);
        }
        await tester.pump();
        expect(find.text('设置管理口令'), findsNothing);

        await tester.tap(versionEntry);
        await tester.pumpAndSettle();
        expect(find.text('设置管理口令'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('admin-pin-field')),
          '2468',
        );
        await tester.enterText(
          find.byKey(const Key('admin-pin-confirm-field')),
          '2468',
        );
        await tester.tap(find.byKey(const Key('admin-pin-submit')));
        await tester.pumpAndSettle();

        expect(find.text('管理模式'), findsWidgets);
        expect(find.text('管理'), findsWidgets);
        await tester.tap(find.text('管理').last);
        await tester.pumpAndSettle();
        expect(find.text('概览'), findsOneWidget);
        expect(find.text('1 人'), findsOneWidget);
        expect(find.text('1 个会话'), findsOneWidget);
        expect(
          find.byKey(const Key('open-conversation-batch-manager')),
          findsOneWidget,
        );
        expect(find.text('未选择数据源'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('exit-admin-mode')),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.ensureVisible(find.byKey(const Key('exit-admin-mode')));
        await tester.pumpAndSettle();
        expect(find.text('退出管理模式'), findsOneWidget);
        await tester.tap(find.byKey(const Key('exit-admin-mode')));
        await tester.pumpAndSettle();
        expect(find.text('管理'), findsNothing);
        expect(find.text('退出管理模式'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('keeps the admin entry available without an active identity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = (await tester.runAsync(
      () => _HomeFixture.create(identityAvailable: false),
    ))!;
    addTearDown(fixture.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: OfflineTheme.light,
        home: OfflineHome(
          environment: fixture.environment,
          onEnvironmentReload: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();

    expect(find.text('未选择企业身份'), findsOneWidget);
    expect(find.byKey(const Key('offline-version-entry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rebinds admin updates after reloading the active environment',
      (tester) async {
    final first = (await tester.runAsync(_HomeFixture.create))!;
    final second = (await tester.runAsync(_HomeFixture.create))!;
    addTearDown(first.close);
    addTearDown(second.close);
    final next = Completer<OfflineEnvironment>();
    var loads = 0;
    await tester.pumpWidget(OfflineDemoApp(
      loadEnvironment: () =>
          ++loads == 1 ? Future.value(first.environment) : next.future,
    ));
    await tester.pumpAndSettle();
    await first.environment.adminAccess.setupPin('0000');
    await tester.pumpAndSettle();
    expect(find.text('管理模式'), findsOneWidget);

    final reload = tester
        .widget<OfflineHome>(find.byType(OfflineHome))
        .onEnvironmentReload();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(OfflineHome), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    next.complete(second.environment);
    await tester.runAsync(() => reload);
    await tester.pumpAndSettle();
    expect(find.text('管理模式'), findsNothing);
    await second.environment.adminAccess.setupPin('0000');
    await tester.pumpAndSettle();
    expect(find.text('管理模式'), findsOneWidget);
    second.environment.adminAccess.exitAdminMode();
    await tester.pumpAndSettle();
    expect(find.text('管理模式'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('restricted export confirms its scope and handles save results',
      (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final export = _ControlledExport();
    final fixture = (await tester
        .runAsync(() => _HomeFixture.create(restrictedExport: export)))!;
    addTearDown(fixture.close);
    await fixture.environment.adminAccess.setupPin('0000');
    await tester.pumpWidget(MaterialApp(
      theme: OfflineTheme.light,
      home: OfflineHome(
          environment: fixture.environment, onEnvironmentReload: () async {}),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理').last);
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('export-restricted-copy'));
    await tester.scrollUntilVisible(entry, 300,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.textContaining('不等于场景备份'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(export.calls, 0);

    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-restricted-export')));
    await tester.pump();
    expect(export.calls, 1);
    expect(tester.widget<ListTile>(entry).enabled, isFalse);
    export.result.complete(3);
    await tester.pumpAndSettle();
    expect(find.text('数据库副本已保存，应用 3 条字段修订'), findsOneWidget);
    expect(tester.widget<ListTile>(entry).enabled, isTrue);

    export.result = Completer<int?>();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-restricted-export')));
    await tester.pump();
    export.result.completeError(StateError('expired session'));
    await tester.pumpAndSettle();
    expect(find.text('管理会话或活动场景已改变，请重新进入管理模式后重试'), findsOneWidget);
    expect(tester.widget<ListTile>(entry).enabled, isTrue);

    export.result = Completer<int?>();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-restricted-export')));
    await tester.pump();
    export.result.completeError(const WeComExportException(
      WeComExportIssueCode.unsupportedTarget,
      'Uncertified department membership revision',
    ));
    await tester.pumpAndSettle();
    expect(find.text('当前场景含尚未认证的字段修订，无法导出数据库副本'), findsOneWidget);
    expect(tester.widget<ListTile>(entry).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a scheduled incoming call when its local time arrives',
      (tester) async {
    var now = DateTime.utc(2026, 9, 29, 8);
    final fixture = (await tester.runAsync(
      () => _HomeFixture.create(simulationNow: () => now),
    ))!;
    addTearDown(fixture.close);
    final simulation = fixture.environment.wecomSimulation!;
    final call = await tester.runAsync(() => simulation.scheduleCall(
          peerProfileId: '2',
          scheduledAt: now.add(const Duration(hours: 1)),
        ));

    await tester.pumpWidget(MaterialApp(
      theme: OfflineTheme.light,
      home: OfflineHome(
        environment: fixture.environment,
        onEnvironmentReload: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('语音来电'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = call!.scheduledAt;
    await tester.runAsync(fixture.environment.store.refreshCallRecords);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('语音来电'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('语音来电'), findsOneWidget);
    expect(find.byKey(const Key('reject-simulated-call')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  });
}

class _HomeFixture {
  const _HomeFixture({
    required this.environment,
    required this.opener,
    required this.root,
  });

  final OfflineEnvironment environment;
  final _RecordingAttachmentOpener opener;
  final Directory root;

  static Future<_HomeFixture> create({
    bool identityAvailable = true,
    DateTime Function()? simulationNow,
    WeComRestrictedExportService? restrictedExport,
    WeComOverlayHistoryService? history,
  }) async {
    final root = await Directory.systemTemp.createTemp('tui_offline_home_');
    final mediaRoot = Directory(p.join(root.path, 'media'));
    final wecomRoot = await Directory(p.join(root.path, 'wecom')).create();
    final verifiedFile = File(p.join(root.path, 'verified', 'report.pdf'));
    await verifiedFile.create(recursive: true);
    await verifiedFile.writeAsString('verified attachment');
    final overlay = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(wecomRoot.path, WeComOverlayDatabase.fileName),
    );
    final simulation = simulationNow == null
        ? null
        : WeComLocalSimulationRepository(
            overlayDatabase: overlay,
            identityScope:
                const WeComIdentityScope(corporationId: 100, userId: 1),
            now: simulationNow,
          );
    final opener = _RecordingAttachmentOpener();
    final repositories = OfflineRepositoryBundle(
      identityRepository: identityAvailable
          ? const _IdentityRepository()
          : const UnavailableIdentityRepository(),
      contactRepository: const _ContactRepository(),
      conversationRepository: _ConversationRepository(verifiedFile.path),
      activityRepository: const _ActivityRepository(),
      attachmentOpener: opener,
    );
    final store = OfflineDemoStore(repositories);
    await store.load();
    final adminAccess = AdminAccessController(
      credentialStore: _MemoryAdminCredentialStore(),
    );
    await adminAccess.initialize();
    final importer = WeComDatabasePackageImporter(
      contract: WeComPackageContract(
        formatVersion: 1,
        scope: 'offline home widget test',
        databases: [],
      ),
      databaseFactory: databaseFactoryFfi,
    );
    final environment = OfflineEnvironment(
      mediaStore: await LocalMediaStore.forRoot(mediaRoot),
      repositories: repositories,
      store: store,
      adminAccess: adminAccess,
      wecomOverlayDatabase: overlay,
      wecomDatasetResolver: WeComActiveDatasetResolver(
        destinationRoot: wecomRoot,
        packageImporter: importer,
        databaseFactory: databaseFactoryFfi,
        overlayDatabase: overlay,
      ),
      wecomDataSources: const _UnavailableDataSourceManager(),
      wecomSourceDirectories: const _UnavailableSourceDirectoryAccess(),
      wecomSimulation: simulation,
      wecomRestrictedExport: restrictedExport,
      wecomHistory: history,
    );
    return _HomeFixture(
      environment: environment,
      opener: opener,
      root: root,
    );
  }

  Future<void> close() async {
    environment.store.dispose();
    await environment.close();
    await root.delete(recursive: true);
  }
}

class _CounterHistory implements WeComOverlayHistoryService {
  int value = 0;
  Future<int>? next;
  @override
  Future<int> fieldRecordCount() => next ?? Future.value(value);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledExport implements WeComRestrictedExportService {
  var calls = 0;
  var result = Completer<int?>();

  @override
  Future<int?> export() {
    calls++;
    return result.future;
  }
}

class _IdentityRepository extends UnavailableIdentityRepository {
  const _IdentityRepository();

  @override
  bool get isAvailable => true;

  @override
  Future<OfflineProfile> currentProfile() async => const OfflineProfile(
        id: 'self',
        displayName: 'Current user',
        title: 'Developer',
        department: 'Engineering',
        status: '',
      );
}

class _ContactRepository extends UnavailableContactRepository {
  const _ContactRepository();

  static const contact = DirectoryContact(
    id: 'alice',
    displayName: 'Alice',
    account: 'alice',
    organizationName: 'Example Corp',
    departmentName: 'Engineering',
    jobTitle: 'Developer',
  );

  @override
  bool get isAvailable => true;

  @override
  Future<List<DirectoryContact>> listContacts({
    String? organizationUnitId,
  }) async =>
      const [contact];
}

class _ConversationRepository extends UnavailableConversationRepository {
  const _ConversationRepository(this.localPath);

  final String localPath;

  @override
  bool get isAvailable => true;

  @override
  Set<ConversationFeature> get features => const {
        ConversationFeature.messages,
        ConversationFeature.attachments,
      };

  @override
  Future<List<OfflineConversation>> listConversations() async => [
        OfflineConversation(
          id: 'S:self_alice',
          type: 'single',
          title: 'Project room',
          lastMessagePreview: '[文件] report.pdf',
          lastMessageAt: DateTime(2026, 9, 15, 10),
          draftText: '',
          unreadCount: 1,
          isPinned: false,
          isMuted: false,
        ),
      ];

  @override
  Future<List<OfflineMessage>> listMessages(String conversationId) async => [
        OfflineMessage(
          id: '1',
          conversationId: conversationId,
          senderProfileId: 'alice',
          senderName: 'Alice',
          kind: 'text',
          text: '跨页面消息',
          sentAt: DateTime(2026, 9, 15, 9),
          status: '',
          isRecalled: false,
        ),
        OfflineMessage(
          id: '2',
          conversationId: conversationId,
          senderProfileId: 'alice',
          senderName: 'Alice',
          kind: 'file',
          text: '[文件] report.pdf · 19 B',
          sentAt: DateTime(2026, 9, 15, 10),
          status: '',
          isRecalled: false,
        ),
        OfflineMessage(
          id: '3',
          conversationId: conversationId,
          senderProfileId: 'self',
          senderName: 'Current user',
          kind: 'text',
          text: '引用回复',
          sentAt: DateTime(2026, 9, 15, 11),
          status: '',
          isRecalled: false,
          replyToMessageId: '1',
          replyPreview: 'Alice: 原始消息',
        ),
        OfflineMessage(
          id: '4',
          conversationId: conversationId,
          senderProfileId: 'alice',
          senderName: 'Alice',
          kind: 'text',
          text: 'Alice 撤回了一条消息',
          sentAt: DateTime(2026, 9, 15, 12),
          status: '',
          isRecalled: true,
        ),
      ];

  @override
  Future<List<OfflineAttachment>> listAttachments(String messageId) async =>
      messageId == '2'
          ? [
              OfflineAttachment(
                id: '0:2:0',
                messageId: messageId,
                kind: 'file',
                relativePath: 'File/2026-09/report.pdf',
                fileName: 'report.pdf',
                sizeBytes: 19,
                localPath: localPath,
              ),
            ]
          : const [];
}

class _ActivityRepository extends UnavailableActivityRepository {
  const _ActivityRepository();

  @override
  Set<ActivityFeature> get features => const {ActivityFeature.calls};

  @override
  Future<List<OfflineCallRecord>> listCallRecords() async => [
        OfflineCallRecord(
          id: 'call-1',
          peerName: 'Alice',
          type: 'voice',
          direction: 'incoming',
          startedAt: DateTime(2026, 9, 15, 13),
          durationSeconds: 0,
          status: 'missed',
        ),
      ];
}

class _RecordingAttachmentOpener implements AttachmentOpener {
  final opened = <OfflineAttachment>[];

  @override
  Future<void> open(OfflineAttachment attachment) async {
    opened.add(attachment);
  }
}

class _MemoryAdminCredentialStore implements AdminCredentialStore {
  AdminPinCredential? credential;

  @override
  Future<AdminPinCredential?> load() async => credential;

  @override
  Future<void> save(AdminPinCredential credential) async {
    this.credential = credential;
  }
}

class _UnavailableDataSourceManager implements WeComDataSourceManager {
  const _UnavailableDataSourceManager();

  @override
  Future<void> clearDefaultRawKey() async {}

  @override
  Future<bool> hasDefaultRawKey() async => false;

  @override
  Future<WeComSavedDataSource?> loadSelectedSource() async => null;

  @override
  Future<WeComPreparedDataSource> prepare(
    Directory selectedDirectory, {
    String? sourceLocator,
    String? temporaryRawKeyHex,
  }) =>
      throw UnimplementedError();

  @override
  Future<WeComPreparedDataSource> prepareSaved({
    String? temporaryRawKeyHex,
  }) =>
      throw UnimplementedError();

  @override
  Future<WeComDataSourceActivationResult> activate(
    WeComPreparedDataSource prepared, {
    int? selectedCorporationId,
    String? defaultRawKeyToSave,
  }) =>
      throw UnimplementedError();
}

class _UnavailableSourceDirectoryAccess implements WeComSourceDirectoryAccess {
  const _UnavailableSourceDirectoryAccess();

  @override
  Future<WeComSelectedSourceDirectory?> choose() => throw UnimplementedError();

  @override
  Future<Directory> resolve(String locator) => throw UnimplementedError();
}
