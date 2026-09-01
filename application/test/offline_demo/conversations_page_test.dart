import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:application/src/offline_demo/presentation/conversations_page.dart';
import 'package:application/src/offline_demo/state/offline_demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('read-only message history does not expose a composer',
      (tester) async {
    final store = OfflineDemoStore(
      OfflineRepositoryBundle(
        conversationRepository: const _ReadOnlyMessageRepository(),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          conversation: _conversation,
          currentProfileId: '1',
          store: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已读取消息'), findsOneWidget);
    expect(find.text('[文件] report.pdf · 2.0 KB'), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('发送'), findsNothing);
  });
}

const _conversation = OfflineConversation(
  id: 'S:1_2',
  type: 'single',
  title: 'Peer',
  lastMessagePreview: '已读取消息',
  lastMessageAt: null,
  draftText: '',
  unreadCount: 0,
  isPinned: false,
  isMuted: false,
);

class _ReadOnlyMessageRepository extends UnavailableConversationRepository {
  const _ReadOnlyMessageRepository();

  @override
  bool get isAvailable => true;

  @override
  Set<ConversationFeature> get features => const {
        ConversationFeature.messages,
      };

  @override
  Future<List<OfflineMessage>> listMessages(String conversationId) async => [
        OfflineMessage(
          id: '1',
          conversationId: conversationId,
          senderProfileId: '2',
          senderName: 'Peer',
          kind: 'text',
          text: '已读取消息',
          sentAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          status: '',
          isRecalled: false,
        ),
        OfflineMessage(
          id: '2',
          conversationId: conversationId,
          senderProfileId: '2',
          senderName: 'Peer',
          kind: 'file',
          text: '[文件] report.pdf · 2.0 KB',
          sentAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
          status: '',
          isRecalled: false,
        ),
      ];
}
