import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../state/offline_demo_store.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({required this.store, super.key});

  final OfflineDemoStore store;

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  final _searchController = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openConversation(OfflineConversation conversation) async {
    try {
      if (conversation.unreadCount > 0) {
        await widget.store.markConversationRead(conversation.id);
      }
      if (!mounted) {
        return;
      }
      final current = widget.store.conversations
          .singleWhere((item) => item.id == conversation.id);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ConversationPage(
            conversation: current,
            currentProfileId: widget.store.profile!.id,
            store: widget.store,
          ),
        ),
      );
      await widget.store.refreshConversations();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('会话操作失败：$error')),
        );
      }
    }
  }

  Future<void> _handleConversationAction(
    OfflineConversation conversation,
    _ConversationAction action,
  ) async {
    try {
      switch (action) {
        case _ConversationAction.togglePinned:
          await widget.store.setConversationPinned(
            conversation.id,
            !conversation.isPinned,
          );
          break;
        case _ConversationAction.toggleMuted:
          await widget.store.setConversationMuted(
            conversation.id,
            !conversation.isMuted,
          );
          break;
        case _ConversationAction.markRead:
          await widget.store.markConversationRead(conversation.id);
          break;
        case _ConversationAction.delete:
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('删除会话'),
              content: Text('将删除“${conversation.title}”及其本地消息和附件。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            await widget.store.deleteConversation(conversation.id);
          }
          break;
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('会话操作失败：$error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final profile = store.profile!;
    final query = _query.trim().toLowerCase();
    final conversations = query.isEmpty
        ? store.conversations
        : store.conversations.where((conversation) {
            return conversation.title.toLowerCase().contains(query) ||
                conversation.lastMessagePreview.toLowerCase().contains(query);
          }).toList(growable: false);

    return Column(
      children: [
        _WorkspaceSummary(
          profile: profile,
          unreadConversations: store.unreadConversationCount,
          unreadNotifications: store.unreadNotificationCount,
        ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: '搜索会话',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: store.load,
            child: conversations.isEmpty
                ? const _EmptyConversationSearch()
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: conversations.length,
                    separatorBuilder: (context, index) =>
                        const Divider(indent: 80),
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      return _ConversationTile(
                        conversation: conversation,
                        onTap: () => _openConversation(conversation),
                        onAction: (action) =>
                            _handleConversationAction(conversation, action),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _EmptyConversationSearch extends StatelessWidget {
  const _EmptyConversationSearch();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 96),
        Icon(
          Icons.search_off_rounded,
          size: 40,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(
          '未找到会话',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF64727A),
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

enum _ConversationAction { togglePinned, toggleMuted, markRead, delete }

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.onTap,
    required this.onAction,
  });

  final OfflineConversation conversation;
  final VoidCallback onTap;
  final ValueChanged<_ConversationAction> onAction;

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
            SizedBox.square(
              dimension: 38,
              child: PopupMenuButton<_ConversationAction>(
                tooltip: '会话操作',
                padding: EdgeInsets.zero,
                onSelected: onAction,
                icon: const Icon(Icons.more_vert_rounded, size: 20),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _ConversationAction.togglePinned,
                    child: _MenuLabel(
                      icon: conversation.isPinned
                          ? Icons.push_pin_outlined
                          : Icons.push_pin_rounded,
                      label: conversation.isPinned ? '取消置顶' : '置顶',
                    ),
                  ),
                  PopupMenuItem(
                    value: _ConversationAction.toggleMuted,
                    child: _MenuLabel(
                      icon: conversation.isMuted
                          ? Icons.notifications_outlined
                          : Icons.notifications_off_outlined,
                      label: conversation.isMuted ? '开启提醒' : '免打扰',
                    ),
                  ),
                  if (conversation.unreadCount > 0)
                    const PopupMenuItem(
                      value: _ConversationAction.markRead,
                      child: _MenuLabel(
                        icon: Icons.mark_chat_read_outlined,
                        label: '标为已读',
                      ),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: _ConversationAction.delete,
                    child: _MenuLabel(
                      icon: Icons.delete_outline_rounded,
                      label: '删除会话',
                      destructive: true,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Row(
            children: [
              Expanded(
                child: conversation.draftText.isEmpty
                    ? Text(
                        conversation.lastMessagePreview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF64727A)),
                      )
                    : Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(
                              text: '[草稿] ',
                              style: TextStyle(
                                color: Color(0xFFC35A20),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text: conversation.draftText,
                              style: const TextStyle(color: Color(0xFF64727A)),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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

class _MenuLabel extends StatelessWidget {
  const _MenuLabel({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class ConversationPage extends StatefulWidget {
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
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  late final TextEditingController _composerController;
  final _scrollController = ScrollController();
  List<OfflineMessage> _messages = const [];
  Object? _loadError;
  var _isLoading = true;
  var _isSending = false;
  var _canSend = false;
  Timer? _draftTimer;

  @override
  void initState() {
    super.initState();
    _composerController = TextEditingController(
      text: widget.conversation.draftText,
    )..addListener(_handleComposerChanged);
    _canSend = widget.conversation.draftText.trim().isNotEmpty;
    _loadMessages(scrollToEnd: true);
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    unawaited(_persistDraft());
    _composerController
      ..removeListener(_handleComposerChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleComposerChanged() {
    final canSend = _composerController.text.trim().isNotEmpty;
    if (canSend != _canSend) {
      setState(() => _canSend = canSend);
    }
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_persistDraft()),
    );
  }

  Future<void> _persistDraft() async {
    try {
      await widget.store.saveConversationDraft(
        widget.conversation.id,
        _composerController.text,
      );
    } catch (_) {
      // Draft persistence is best-effort while the composer is changing.
    }
  }

  Future<void> _loadMessages({bool scrollToEnd = false}) async {
    try {
      final messages = await widget.store.messagesFor(widget.conversation.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _messages = messages;
        _loadError = null;
        _isLoading = false;
      });
      if (scrollToEnd) {
        _scheduleScrollToEnd();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = error;
        _isLoading = false;
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _isSending) {
      return;
    }

    _draftTimer?.cancel();
    setState(() => _isSending = true);
    try {
      await widget.store.sendTextMessage(
        conversationId: widget.conversation.id,
        text: text,
      );
      _composerController.clear();
      await _loadMessages(scrollToEnd: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  void _scheduleScrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.title)),
      body: Column(
        children: [
          Expanded(child: _buildMessages(context)),
          _buildComposer(context),
        ],
      ),
    );
  }

  Widget _buildMessages(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }
    if (_loadError != null) {
      return Center(
        child: IconButton.filledTonal(
          tooltip: '重新加载消息',
          onPressed: () {
            setState(() => _isLoading = true);
            _loadMessages();
          },
          icon: const Icon(Icons.refresh_rounded),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMessages,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        itemCount: _messages.length,
        itemBuilder: (context, index) {
          final message = _messages[index];
          if (message.kind == 'system') {
            return _SystemMessage(message: message);
          }
          return _MessageBubble(
            message: message,
            isMine: message.senderProfileId == widget.currentProfileId,
          );
        },
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8E7))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _composerController,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: const InputDecoration(
                  hintText: '输入消息',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: 46,
              child: IconButton.filled(
                tooltip: '发送',
                onPressed: _canSend && !_isSending ? _sendMessage : null,
                icon: _isSending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ),
          ],
        ),
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatTime(message.sentAt),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: const Color(0xFF849096),
                          ),
                    ),
                    if (isMine) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.done_rounded,
                        size: 14,
                        color: Color(0xFF849096),
                      ),
                    ],
                  ],
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
