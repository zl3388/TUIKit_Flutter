import 'package:flutter/material.dart';

import '../data/wecom_conversation_editor.dart';
import '../domain/models.dart';
import '../state/admin_access_controller.dart';
import '../state/offline_demo_store.dart';

class AdminConversationBatchPage extends StatefulWidget {
  const AdminConversationBatchPage({
    required this.store,
    required this.editor,
    required this.adminAccess,
    super.key,
  });

  final OfflineDemoStore store;
  final WeComConversationEditor editor;
  final AdminAccessController adminAccess;

  @override
  State<AdminConversationBatchPage> createState() =>
      _AdminConversationBatchPageState();
}

class _AdminConversationBatchPageState
    extends State<AdminConversationBatchPage> {
  final _searchController = TextEditingController();
  final _selected = <String>{};
  var _filter = _ConversationFilter.all;
  var _processing = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final visible = _visibleConversations(widget.store.conversations);
        return Scaffold(
          appBar: AppBar(
            title: const Text('会话批量管理'),
            actions: [
              IconButton(
                key: const Key('select-visible-conversations'),
                tooltip: '选择当前筛选结果',
                onPressed: visible.isEmpty || _processing
                    ? null
                    : () => setState(
                          () => _selected.addAll(
                            visible.map((conversation) => conversation.id),
                          ),
                        ),
                icon: const Icon(Icons.select_all_rounded),
              ),
              IconButton(
                key: const Key('clear-conversation-selection'),
                tooltip: '清除选择',
                onPressed: _selected.isEmpty || _processing
                    ? null
                    : () => setState(_selected.clear),
                icon: const Icon(Icons.deselect_rounded),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  key: const Key('conversation-batch-search'),
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '搜索会话名称或 ID',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.clear_rounded),
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: _ConversationFilter.values.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final filter = _ConversationFilter.values[index];
                    return FilterChip(
                      key: Key('conversation-filter-${filter.name}'),
                      selected: _filter == filter,
                      onSelected: _processing
                          ? null
                          : (_) => setState(() => _filter = filter),
                      label: Text(filter.label),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: visible.isEmpty
                    ? const Center(child: Text('没有符合条件的会话'))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final conversation = visible[index];
                          return CheckboxListTile(
                            key: Key(
                              'batch-conversation-${conversation.id}',
                            ),
                            value: _selected.contains(conversation.id),
                            onChanged: _processing
                                ? null
                                : (selected) => setState(() {
                                      if (selected == true) {
                                        _selected.add(conversation.id);
                                      } else {
                                        _selected.remove(conversation.id);
                                      }
                                    }),
                            secondary: Icon(
                              conversation.type == 'group'
                                  ? Icons.groups_outlined
                                  : Icons.chat_bubble_outline_rounded,
                            ),
                            title: Text(
                              conversation.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _conversationSubtitle(conversation),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            controlAffinity: ListTileControlAffinity.trailing,
                          );
                        },
                      ),
              ),
              if (_processing) const LinearProgressIndicator(minHeight: 2),
              SafeArea(
                top: false,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 64),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: const Border(
                      top: BorderSide(color: Color(0xFFE1E7EA)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text('已选择 ${_selected.length} 项')),
                      PopupMenuButton<_BatchConversationAction>(
                        key: const Key('conversation-batch-actions'),
                        enabled: _selected.isNotEmpty && !_processing,
                        tooltip: '批量设置',
                        onSelected: _apply,
                        itemBuilder: (context) => [
                          for (final action in _BatchConversationAction.values)
                            PopupMenuItem(
                              value: action,
                              child: Row(
                                children: [
                                  Icon(action.icon, size: 20),
                                  const SizedBox(width: 12),
                                  Text(action.label),
                                ],
                              ),
                            ),
                        ],
                        icon: const Icon(Icons.tune_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<OfflineConversation> _visibleConversations(
    List<OfflineConversation> conversations,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    return conversations.where((conversation) {
      if (query.isNotEmpty &&
          !conversation.title.toLowerCase().contains(query) &&
          !conversation.id.toLowerCase().contains(query)) {
        return false;
      }
      return switch (_filter) {
        _ConversationFilter.all => true,
        _ConversationFilter.group => conversation.type == 'group',
        _ConversationFilter.single => conversation.type == 'single',
        _ConversationFilter.pinned => conversation.isPinned,
        _ConversationFilter.muted => conversation.isMuted,
      };
    }).toList(growable: false);
  }

  String _conversationSubtitle(OfflineConversation conversation) {
    final states = <String>[
      conversation.id,
      if (conversation.isPinned) '已置顶',
      if (conversation.isMuted) '免打扰',
    ];
    return states.join(' · ');
  }

  Future<void> _apply(_BatchConversationAction action) async {
    if (!widget.adminAccess.isAdmin) {
      _showMessage('管理会话已结束，请重新进入管理模式');
      return;
    }
    setState(() => _processing = true);
    try {
      final edit = await widget.editor.updateFlags(
        conversationIds: Set<String>.from(_selected),
        isPinned: action.isPinned,
        isMuted: action.isMuted,
      );
      var refreshFailed = false;
      try {
        await widget.store.refreshConversations();
      } catch (_) {
        refreshFailed = true;
      }
      if (!mounted) {
        return;
      }
      setState(_selected.clear);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            refreshFailed
                ? '${action.label}已保存，但列表刷新失败'
                : '${action.label}已保存到本地',
          ),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undo(edit),
          ),
        ),
      );
    } on WeComConversationNoChangesException {
      _showMessage('所选会话已经是目标状态');
    } catch (_) {
      _showMessage('批量操作失败');
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  Future<void> _undo(WeComConversationBatchEdit edit) async {
    if (!widget.adminAccess.isAdmin) {
      _showMessage('管理会话已结束，无法撤销');
      return;
    }
    try {
      await widget.editor.undoBatch(edit);
      var refreshFailed = false;
      try {
        await widget.store.refreshConversations();
      } catch (_) {
        refreshFailed = true;
      }
      _showMessage(refreshFailed ? '已撤销，但列表刷新失败' : '已撤销批量操作');
    } catch (_) {
      _showMessage('撤销失败');
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

enum _ConversationFilter {
  all('全部'),
  group('群聊'),
  single('单聊'),
  pinned('已置顶'),
  muted('免打扰');

  const _ConversationFilter(this.label);

  final String label;
}

enum _BatchConversationAction {
  pin('设为置顶', Icons.push_pin_outlined, isPinned: true),
  unpin('取消置顶', Icons.push_pin_rounded, isPinned: false),
  mute('设为免打扰', Icons.notifications_off_outlined, isMuted: true),
  unmute('取消免打扰', Icons.notifications_outlined, isMuted: false);

  const _BatchConversationAction(
    this.label,
    this.icon, {
    this.isPinned,
    this.isMuted,
  });

  final String label;
  final IconData icon;
  final bool? isPinned;
  final bool? isMuted;
}
