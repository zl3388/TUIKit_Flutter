import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:application/src/offline_demo/presentation/conversations_page.dart';
import 'package:application/src/offline_demo/presentation/offline_theme.dart';
import 'package:application/src/offline_demo/state/offline_demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
    expect(find.byKey(const Key('media-message-2')), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    expect(find.byKey(const Key('media-message-3')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('media-message-5')),
      160,
    );
    expect(find.byKey(const Key('media-message-4')), findsOneWidget);
    expect(find.byKey(const Key('media-message-5')), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('发送'), findsNothing);
  });

  for (final width in [320.0, 1024.0]) {
    testWidgets('media messages remain readable at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = OfflineDemoStore(
        OfflineRepositoryBundle(
          conversationRepository: const _ReadOnlyMessageRepository(
            longFileName: true,
          ),
        ),
      );
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: OfflineTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: ConversationPage(
            conversation: _conversation,
            currentProfileId: '1',
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      for (final entry in {
        '2': '文件消息',
        '3': '图片消息',
        '4': '视频消息',
        '5': '语音消息',
      }.entries) {
        final content = find.byKey(Key('media-message-${entry.key}'));
        await tester.scrollUntilVisible(content, 120, scrollable: scrollable);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(content);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(width));
        final node = tester.getSemantics(content);
        expect(node.label, contains(entry.value));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
        final text = tester.widget<Text>(
          find.descendant(of: content, matching: find.byType(Text)),
        );
        expect(text.maxLines, isNull);
      }
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.byTooltip('播放'), findsNothing);
    });
  }

  testWidgets('opens only verified local media attachments', (tester) async {
    final opener = _RecordingAttachmentOpener();
    final store = OfflineDemoStore(
      OfflineRepositoryBundle(
        conversationRepository: const _ReadOnlyMessageRepository(
          exposeAttachments: true,
        ),
        attachmentOpener: opener,
      ),
    );
    addTearDown(store.dispose);
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

    final available = find.byKey(
      const Key('media-attachment-0:2:0'),
    );
    final missing = find.byKey(
      const Key('media-attachment-0:2:1'),
    );
    expect(available, findsOneWidget);
    expect(missing, findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('missing.pdf'), findsOneWidget);
    expect(find.text('离线文件不可用'), findsOneWidget);
    expect(
      tester.getSemantics(available).getSemanticsData().hasAction(
            SemanticsAction.tap,
          ),
      isTrue,
    );
    expect(
      tester.getSemantics(missing).getSemanticsData().hasAction(
            SemanticsAction.tap,
          ),
      isFalse,
    );

    await tester.tap(available);
    await tester.pump();
    expect(opener.opened.map((attachment) => attachment.id), ['0:2:0']);
    await tester.tap(missing);
    await tester.pump();
    expect(opener.opened, hasLength(1));
  });

  testWidgets('labels evidence-backed message progress icons', (tester) async {
    final store = OfflineDemoStore(
      OfflineRepositoryBundle(
        conversationRepository: const _ReadOnlyMessageRepository(
          exposeProgress: true,
        ),
      ),
    );
    addTearDown(store.dispose);
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('media-message-4')),
      160,
    );

    expect(find.byTooltip('2 人已读'), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(find.byTooltip('撤销本地模拟消息'), findsNothing);
  });

  testWidgets('separates messages only at local calendar-day boundaries',
      (tester) async {
    final store = OfflineDemoStore(
      OfflineRepositoryBundle(
        conversationRepository: const _ReadOnlyMessageRepository(
          splitAcrossDays: true,
        ),
      ),
    );
    addTearDown(store.dispose);
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

    expect(find.byKey(const Key('message-date-separator-1')), findsOneWidget);
    expect(find.byKey(const Key('message-date-separator-2')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('message-date-separator-4')),
      160,
    );
    expect(find.byKey(const Key('message-date-separator-3')), findsNothing);
    expect(find.byKey(const Key('message-date-separator-4')), findsOneWidget);
    expect(find.byKey(const Key('message-date-separator-5')), findsNothing);
    expect(find.text('2026-09-14'), findsOneWidget);
    expect(find.text('2026-09-15'), findsOneWidget);
  });

  testWidgets('renders quote context and recalled state without actions',
      (tester) async {
    final store = OfflineDemoStore(
      OfflineRepositoryBundle(
        conversationRepository: const _ReadOnlyMessageRepository(
          exposeAdvancedMessages: true,
        ),
      ),
    );
    addTearDown(store.dispose);
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('reply-preview-6')),
      160,
    );

    expect(find.text('父消息预览'), findsOneWidget);
    expect(find.byKey(const Key('reply-preview-6')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('撤回片段'), 160);
    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
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
  const _ReadOnlyMessageRepository({
    this.longFileName = false,
    this.exposeAttachments = false,
    this.exposeProgress = false,
    this.splitAcrossDays = false,
    this.exposeAdvancedMessages = false,
  });

  final bool longFileName;
  final bool exposeAttachments;
  final bool exposeProgress;
  final bool splitAcrossDays;
  final bool exposeAdvancedMessages;

  @override
  bool get isAvailable => true;

  @override
  Set<ConversationFeature> get features => {
        ConversationFeature.messages,
        if (exposeAttachments) ConversationFeature.attachments,
      };

  @override
  Future<List<OfflineAttachment>> listAttachments(String messageId) async {
    if (!exposeAttachments || messageId != '2') {
      return const [];
    }
    return const [
      OfflineAttachment(
        id: '0:2:0',
        messageId: '2',
        kind: 'file',
        relativePath: 'File/2026-09/report.pdf',
        fileName: 'report.pdf',
        sizeBytes: 2048,
        localPath: r'C:\managed\report.pdf',
      ),
      OfflineAttachment(
        id: '0:2:1',
        messageId: '2',
        kind: 'file',
        relativePath: 'File/2026-09/missing.pdf',
        fileName: 'missing.pdf',
        sizeBytes: 1024,
        unavailableReason: 'missing',
      ),
    ];
  }

  @override
  Future<List<OfflineMessage>> listMessages(String conversationId) async => [
        OfflineMessage(
          id: '1',
          conversationId: conversationId,
          senderProfileId: '2',
          senderName: 'Peer',
          kind: 'text',
          text: '已读取消息',
          sentAt: _sentAt(1000, 14, 10),
          status: '',
          isRecalled: false,
        ),
        OfflineMessage(
          id: '2',
          conversationId: conversationId,
          senderProfileId: '2',
          senderName: 'Peer',
          kind: 'file',
          text: longFileName
              ? '[文件] 这是一个需要完整换行显示的文件名_Quarterly_Report_2026_Final.pdf · 2.0 KB'
              : '[文件] report.pdf · 2.0 KB',
          sentAt: _sentAt(2000, 14, 11),
          status: '',
          isRecalled: false,
        ),
        OfflineMessage(
          id: '3',
          conversationId: conversationId,
          senderProfileId: '2',
          senderName: 'Peer',
          kind: 'image',
          text: '[图片] 640×480 · 2.0 KB',
          sentAt: _sentAt(3000, 14, 12),
          status: '',
          isRecalled: false,
        ),
        OfflineMessage(
          id: '4',
          conversationId: conversationId,
          senderProfileId: '1',
          senderName: 'Me',
          kind: 'video',
          text: '[视频] 30 秒 · 1920×1080 · 1.0 MB',
          sentAt: _sentAt(4000, 15, 9),
          status: '',
          isRecalled: false,
          progress: exposeProgress
              ? OfflineMessageProgress.peerRead
              : OfflineMessageProgress.none,
          progressSource: exposeProgress
              ? OfflineMessageProgressSource.weComObservation
              : OfflineMessageProgressSource.none,
          peerReaderCount: exposeProgress ? 2 : 0,
        ),
        OfflineMessage(
          id: '5',
          conversationId: conversationId,
          senderProfileId: '2',
          senderName: 'Peer',
          kind: 'voice',
          text: '[语音] 12 秒',
          sentAt: _sentAt(5000, 15, 10),
          status: '',
          isRecalled: false,
        ),
        if (exposeAdvancedMessages)
          OfflineMessage(
            id: '6',
            conversationId: conversationId,
            senderProfileId: '2',
            senderName: 'Peer',
            kind: 'text',
            text: '引用回复',
            sentAt: _sentAt(6000, 15, 11),
            status: '',
            isRecalled: false,
            replyToMessageId: '1',
            replyPreview: '父消息预览',
          ),
        if (exposeAdvancedMessages)
          OfflineMessage(
            id: '7',
            conversationId: conversationId,
            senderProfileId: '2',
            senderName: 'Peer',
            kind: 'text',
            text: '撤回片段',
            sentAt: _sentAt(7000, 15, 12),
            status: '',
            isRecalled: true,
          ),
      ];

  DateTime _sentAt(int fallbackMillis, int day, int hour) => splitAcrossDays
      ? DateTime(2026, 9, day, hour)
      : DateTime.fromMillisecondsSinceEpoch(fallbackMillis, isUtc: true);
}

class _RecordingAttachmentOpener implements AttachmentOpener {
  final opened = <OfflineAttachment>[];

  @override
  Future<void> open(OfflineAttachment attachment) async {
    opened.add(attachment);
  }
}
