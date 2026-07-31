import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../state/offline_demo_store.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class ConversationsPage extends StatelessWidget {
  const ConversationsPage({required this.store, super.key});

  final OfflineDemoStore store;

  @override
  Widget build(BuildContext context) {
    final profile = store.profile!;
    return Column(
      children: [
        _WorkspaceSummary(
          profile: profile,
          unreadConversations: store.unreadConversationCount,
          unreadNotifications: store.unreadNotificationCount,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: store.load,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: store.conversations.length,
              separatorBuilder: (context, index) => const Divider(indent: 80),
              itemBuilder: (context, index) {
                final conversation = store.conversations[index];
                return _ConversationTile(
                  conversation: conversation,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => ConversationPage(
                        conversation: conversation,
                        currentProfileId: profile.id,
                        store: store,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _WorkspaceSummary extends StatelessWidget {
  const _WorkspaceSummary({
    required this.profile,
    required this.unreadConversations,
    required this.unreadNotifications,
  });

  final OfflineProfile profile;
  final int unreadConversations;
  final int unreadNotifications;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Row(
        children: [
          OfflineAvatar(id: profile.id, label: profile.displayName, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${profile.displayName}，早上好',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${profile.department} · ${profile.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64727A),
                      ),
                ),
              ],
            ),
          ),
          _Metric(value: '$unreadConversations', label: '未读'),
          const SizedBox(width: 14),
          _Metric(value: '$unreadNotifications', label: '通知'),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label $value',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: OfflineTheme.primary,
                  fontWeight: FontWeight.w800,
                ),
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF64727A),
                ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.onTap});

  final OfflineConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: conversation.isPinned ? const Color(0xFFF7FBFA) : Colors.white,
      child: ListTile(
        onTap: onTap,
        leading: OfflineAvatar(
          id: conversation.id,
          label: conversation.title,
          size: 48,
          icon: conversation.type == 'group' ? Icons.groups_rounded : null,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatTime(conversation.lastMessageAt),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: const Color(0xFF7A878D),
                  ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  conversation.lastMessagePreview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF64727A)),
                ),
              ),
              if (conversation.isMuted) ...[
                const SizedBox(width: 8),
                const Icon(Icons.notifications_off_outlined, size: 16),
              ],
              if (conversation.unreadCount > 0) ...[
                const SizedBox(width: 8),
                Badge.count(count: conversation.unreadCount),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ConversationPage extends StatelessWidget {
  const ConversationPage({
    required this.conversation,
    required this.currentProfileId,
    required this.store,
    super.key,
  });

  final OfflineConversation conversation;
  final String currentProfileId;
  final OfflineDemoStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(conversation.title)),
      body: FutureBuilder<List<OfflineMessage>>(
        future: store.messagesFor(conversation.id),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('消息加载失败'));
          }
          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 2.5));
          }
          final messages = snapshot.requireData;
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            itemCount: messages.length,
            itemBuilder: (context, index) {
              final message = messages[index];
              if (message.kind == 'system') {
                return _SystemMessage(message: message);
              }
              return _MessageBubble(
                message: message,
                isMine: message.senderProfileId == currentProfileId,
              );
            },
          );
        },
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isMine});

  final OfflineMessage message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine) ...[
            OfflineAvatar(
              id: message.senderProfileId,
              label: message.senderName,
              size: 36,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isMine)
                  Padding(
                    padding: const EdgeInsets.only(left: 3, bottom: 4),
                    child: Text(
                      message.senderName,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: const Color(0xFF64727A),
                          ),
                    ),
                  ),
                Container(
                  constraints: const BoxConstraints(maxWidth: 440),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMine ? const Color(0xFFDDF4F0) : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isMine
                          ? const Color(0xFFBCE5DD)
                          : const Color(0xFFE2E8E7),
                    ),
                  ),
                  child: Text(message.text),
                ),
                const SizedBox(height: 3),
                Text(
                  formatTime(message.sentAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: const Color(0xFF849096),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SystemMessage extends StatelessWidget {
  const _SystemMessage({required this.message});

  final OfflineMessage message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Center(
        child: Text(
          message.text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF708087),
              ),
        ),
      ),
    );
  }
}
