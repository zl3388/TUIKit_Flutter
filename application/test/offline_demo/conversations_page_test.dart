import 'dart:io';

import 'package:application/src/offline_demo/data/offline_database.dart';
import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/domain/repositories.dart';
import 'package:application/src/offline_demo/presentation/conversations_page.dart';
import 'package:application/src/offline_demo/state/offline_demo_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late OfflineDatabase database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_conversation_page_',
    );
    database = await OfflineDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(temporaryDirectory.path, 'offline.db'),
    );
  });

  tearDown(() async {
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  testWidgets('read-only message history does not expose a composer',
      (tester) async {
    final store = OfflineDemoStore(
      OfflineRepositoryBundle(
        database,
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
      ];
}
