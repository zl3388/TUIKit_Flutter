import 'package:application/src/offline_demo/domain/repositories.dart';
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
}
