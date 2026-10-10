import 'package:application/src/offline_demo/data/wecom_overlay_history_service.dart';
import 'package:application/src/offline_demo/presentation/admin_history_page.dart';
import 'package:application/src/offline_demo/state/admin_access_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AdminAccessController admin;
  late _History history;
  var refreshes = 0;
  setUp(() async {
    admin = AdminAccessController(
        credentialStore: _Credentials(), buildPin: '0000');
    await admin.initialize();
    await admin.authenticate('0000');
    history = _History();
    refreshes = 0;
  });
  tearDown(() => admin.dispose());

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: AdminHistoryPage(
            history: history,
            adminAccess: admin,
            onChanged: () async {
              refreshes++;
            })));
    await tester.pumpAndSettle();
  }

  testWidgets('narrow screen shows differences and confirms persisted undo',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('history-fields-1')));
    await tester.pumpAndSettle();
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Edited'), findsOneWidget);
    await tester.tap(find.byKey(const Key('undo-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(history.undos, 0);
    await tester.tap(find.byKey(const Key('undo-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-history-undo')));
    await tester.pumpAndSettle();
    expect(history.undos, 1);
    expect(refreshes, 1);
    expect(find.text('修订历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters message and simulation logs without mixing IDs',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('消息'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history-fields-1')), findsNothing);
    expect(find.byKey(const Key('history-messages-1')), findsOneWidget);
    await tester.tap(find.text('模拟'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history-simulations-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only revisions explain the unavailable undo',
      (tester) async {
    history.reason = '请先撤销同一记录的后续修订';
    await open(tester, scale: 1.5);
    await tester.tap(find.byKey(const Key('history-fields-1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('undo-history')));
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('undo-history')))
            .onPressed,
        isNull);
    expect(find.text(history.reason!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'expiry hides history and disables writes even with a detail open',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('history-fields-1')));
    await tester.pumpAndSettle();
    admin.exitAdminMode();
    await tester.pumpAndSettle();
    expect(find.text('管理会话已失效'), findsOneWidget);
    expect(find.byKey(const Key('undo-history')), findsNothing);
    expect(history.undos, 0);
  });

  testWidgets('failed undo stays on the detail and leaves the list intact',
      (tester) async {
    history.fail = true;
    await open(tester);
    await tester.tap(find.byKey(const Key('history-fields-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('undo-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-history-undo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未撤销'), findsOneWidget);
    expect(find.byKey(const Key('undo-history')), findsOneWidget);
    expect(refreshes, 0);
    expect(tester.takeException(), isNull);
  });
}

class _History implements WeComOverlayHistoryService {
  int undos = 0;
  bool fail = false;
  String? reason;
  WeComHistoryEntry entry(WeComHistoryKind kind) => WeComHistoryEntry(kind, {
        'revision_id': 1,
        'edit_id': 1,
        'event_id': 1,
        'operation': 'upsert',
        'action': 'add',
        'event_type': 'scheduledCall',
        'database_name': 'user.db',
        'table_name': 'user_table',
        'row_key_json': '{"id":1}',
        'conversation_id': 'R:1',
        'target_key': 'overlay:1',
        'event_key': 'call:1',
        'created_at_micros': DateTime.utc(2026).microsecondsSinceEpoch,
      });
  @override
  Future<List<WeComHistoryEntry>> list(WeComHistoryKind kind,
          {int offset = 0}) async =>
      [entry(kind)];
  @override
  Future<WeComHistoryDetail> detail(WeComHistoryKind kind, int id) async =>
      WeComHistoryDetail(entry(kind), const {'name': 'Original'},
          const {'name': 'Edited'}, reason);
  @override
  Future<void> undo(WeComHistoryKind kind, int id) async {
    if (fail) throw StateError('Later edit');
    undos++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Credentials implements AdminCredentialStore {
  @override
  Future<AdminPinCredential?> load() async => null;
  @override
  Future<void> save(AdminPinCredential credential) async {}
}
