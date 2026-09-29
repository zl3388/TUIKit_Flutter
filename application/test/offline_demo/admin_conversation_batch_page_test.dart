import 'package:application/src/offline_demo/data/wecom_conversation_editor.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:application/src/offline_demo/presentation/admin_conversation_batch_page.dart';
import 'package:application/src/offline_demo/state/admin_access_controller.dart';
import 'package:application/src/offline_demo/state/offline_demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('filters and selects conversations on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final adminAccess = AdminAccessController(
      credentialStore: _MemoryAdminCredentialStore(),
      buildPin: '0000',
    );
    await adminAccess.initialize();
    await adminAccess.authenticate('0000');
    addTearDown(adminAccess.dispose);
    final store = OfflineDemoStore(OfflineRepositoryBundle());
    store.conversations = [
      OfflineConversation(
        id: 'R:project',
        type: 'group',
        title: 'Project room',
        lastMessagePreview: '',
        lastMessageAt: DateTime.utc(2026, 9, 28),
        draftText: '',
        unreadCount: 0,
        isPinned: true,
        isMuted: false,
      ),
      OfflineConversation(
        id: 'S:1_2',
        type: 'single',
        title: 'Alice',
        lastMessagePreview: '',
        lastMessageAt: DateTime.utc(2026, 9, 27),
        draftText: '',
        unreadCount: 0,
        isPinned: false,
        isMuted: true,
      ),
    ];
    addTearDown(store.dispose);
    final editor = _FakeConversationEditor();

    await tester.pumpWidget(
      MaterialApp(
        home: AdminConversationBatchPage(
          store: store,
          editor: editor,
          adminAccess: adminAccess,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Project room'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('conversation-batch-search')),
      'project',
    );
    await tester.pump();
    expect(find.text('Project room'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('conversation-batch-search')),
      '',
    );
    await tester.tap(
      find.byKey(const Key('conversation-filter-group')),
    );
    await tester.pump();
    expect(find.text('Project room'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);

    await tester.tap(
      find.byKey(const Key('select-visible-conversations')),
    );
    await tester.pump();
    expect(find.text('已选择 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('conversation-batch-actions')));
    await tester.pumpAndSettle();
    expect(find.text('设为置顶'), findsOneWidget);
    expect(find.text('取消置顶'), findsOneWidget);
    expect(find.text('设为免打扰'), findsOneWidget);
    expect(find.text('取消免打扰'), findsOneWidget);
    await tester.tap(find.text('设为置顶'));
    await tester.pumpAndSettle();
    expect(editor.lastConversationIds, {'R:project'});
    expect(editor.lastPinned, isTrue);
    expect(editor.lastMuted, isNull);
    expect(find.text('所选会话已经是目标状态'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    adminAccess.exitAdminMode();
    await tester.tap(find.byKey(const Key('conversation-batch-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为免打扰'));
    await tester.pumpAndSettle();
    expect(editor.lastMuted, isNull);
    expect(find.text('管理会话已结束，请重新进入管理模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakeConversationEditor implements WeComConversationEditor {
  Set<String>? lastConversationIds;
  bool? lastPinned;
  bool? lastMuted;

  @override
  String get datasetId => 'test';

  @override
  Future<void> cancelLocalMessage({
    required String conversationId,
    required String messageId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WeComConversationEdit> renameGroup({
    required String conversationId,
    required String roomNameRemark,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> undo(WeComConversationEdit edit) {
    throw UnimplementedError();
  }

  @override
  Future<void> undoBatch(WeComConversationBatchEdit edit) {
    throw UnimplementedError();
  }

  @override
  Future<WeComConversationBatchEdit> updateFlags({
    required Set<String> conversationIds,
    bool? isPinned,
    bool? isMuted,
  }) async {
    lastConversationIds = conversationIds;
    lastPinned = isPinned;
    lastMuted = isMuted;
    throw const WeComConversationNoChangesException();
  }
}

class _MemoryAdminCredentialStore implements AdminCredentialStore {
  @override
  Future<AdminPinCredential?> load() async => null;

  @override
  Future<void> save(AdminPinCredential credential) async {}
}
