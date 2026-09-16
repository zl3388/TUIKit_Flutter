import 'dart:io';

import 'package:application/src/offline_demo/bootstrap/offline_bootstrap.dart';
import 'package:application/src/offline_demo/data/local_media_store.dart';
import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
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
            home: OfflineHome(environment: fixture.environment),
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
            home: OfflineHome(environment: fixture.environment),
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
        expect(find.text('未选择数据源'), findsOneWidget);
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
        home: OfflineHome(environment: fixture.environment),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();

    expect(find.text('未选择企业身份'), findsOneWidget);
    expect(find.byKey(const Key('offline-version-entry')), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  static Future<_HomeFixture> create({bool identityAvailable = true}) async {
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
