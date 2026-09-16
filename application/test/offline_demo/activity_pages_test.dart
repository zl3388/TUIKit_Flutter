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
