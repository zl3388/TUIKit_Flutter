import 'package:application/src/offline_demo/data/wecom_announcement_editor.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/presentation/activity_pages.dart';
import 'package:application/src/offline_demo/state/offline_demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late OfflineDemoStore store;

  setUp(() async {
    store = OfflineDemoStore(OfflineRepositoryBundle());
    await store.load();
  });

  testWidgets('notification page reports unavailable target data',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: NotificationsPage(store: store)),
    );

    expect(find.text('通知数据尚未映射'), findsOneWidget);
    expect(find.text('暂无通知'), findsNothing);
  });

  testWidgets('announcement page reports unavailable target data',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(store: store)),
    );

    expect(find.text('公告数据尚未映射'), findsOneWidget);
    expect(find.text('暂无公告'), findsNothing);
  });

  testWidgets('announcement page shows verified summary and attachment count',
      (tester) async {
    final announcementStore = OfflineDemoStore(
      OfflineRepositoryBundle(
        activityRepository: const _AnnouncementsOnly(),
      ),
    );
    await announcementStore.load();
    addTearDown(announcementStore.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(store: announcementStore)),
    );

    expect(find.text('公告标题'), findsOneWidget);
    expect(find.textContaining('研发部'), findsOneWidget);

    await tester.tap(find.text('公告标题'));
    await tester.pumpAndSettle();

    expect(find.text('公告摘要'), findsOneWidget);
    expect(find.text('附件 2 个'), findsOneWidget);
    expect(find.byKey(const Key('edit-announcement')), findsNothing);
  });

  testWidgets('announcement editor fits a narrow screen above the keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      MaterialApp(
        home: AnnouncementDetailPage(
          announcement: OfflineAnnouncement(
            id: '1',
            title: 'Long announcement title',
            summary: 'Long announcement summary',
            authorName: 'Publisher',
            publishedAt: DateTime.utc(2026, 9, 18),
            attachmentCount: 1,
            isRead: true,
          ),
          editor: _FakeAnnouncementEditor(),
          onChanged: () async => throw UnimplementedError(),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('edit-announcement')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('announcement-title')), findsOneWidget);
    expect(find.byKey(const Key('announcement-summary')), findsOneWidget);
    expect(find.byKey(const Key('save-announcement')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('save-announcement')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('save-announcement')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('call page reports unavailable target data', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: CallRecordsPage(store: store)),
    );

    expect(find.text('通话数据尚未映射'), findsOneWidget);
    expect(find.text('暂无通话记录'), findsNothing);
  });

  testWidgets('call-only capability does not enable other activity pages',
      (tester) async {
    final callStore = OfflineDemoStore(
      OfflineRepositoryBundle(activityRepository: const _CallsOnly()),
    );
    await callStore.load();
    addTearDown(callStore.dispose);

    expect(callStore.callsAvailable, isTrue);
    expect(callStore.notificationsAvailable, isFalse);
    expect(callStore.announcementsAvailable, isFalse);
    await tester.pumpWidget(
      MaterialApp(home: CallRecordsPage(store: callStore)),
    );

    expect(find.text('测试对端'), findsOneWidget);
    expect(find.textContaining('呼入 · 已拒绝'), findsOneWidget);
  });
}

class _AnnouncementsOnly implements ActivityRepository {
  const _AnnouncementsOnly();

  @override
  Set<ActivityFeature> get features => const {ActivityFeature.announcements};

  @override
  Future<List<OfflineAnnouncement>> listAnnouncements() async => [
        OfflineAnnouncement(
          id: '1',
          title: '公告标题',
          summary: '公告摘要',
          authorName: '研发部',
          publishedAt: DateTime.utc(2026, 9, 18),
          attachmentCount: 2,
          isRead: true,
        ),
      ];

  @override
  Future<List<OfflineCallRecord>> listCallRecords() async => const [];

  @override
  Future<List<OfflineNotification>> listNotifications() async => const [];

  @override
  Future<void> markNotificationRead(String notificationId) async {}
}

class _CallsOnly implements ActivityRepository {
  const _CallsOnly();

  @override
  Set<ActivityFeature> get features => const {ActivityFeature.calls};

  @override
  Future<List<OfflineAnnouncement>> listAnnouncements() async => const [];

  @override
  Future<List<OfflineCallRecord>> listCallRecords() async => [
        OfflineCallRecord(
          id: '1',
          peerName: '测试对端',
          type: 'voice',
          direction: 'incoming',
          startedAt: DateTime.utc(2026, 9, 15),
          durationSeconds: 0,
          status: 'rejected',
        ),
      ];

  @override
  Future<List<OfflineNotification>> listNotifications() async => const [];

  @override
  Future<void> markNotificationRead(String notificationId) async {}
}

class _FakeAnnouncementEditor implements WeComAnnouncementEditor {
  @override
  String get datasetId => 'test';

  @override
  Future<WeComAnnouncementEdit> updateContent({
    required String announcementId,
    required String title,
    required String summary,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> undo(WeComAnnouncementEdit edit) {
    throw UnimplementedError();
  }
}
