import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import '../data/wecom_announcement_editor.dart';
import '../domain/models.dart';
import '../state/offline_demo_store.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({required this.store, super.key});

  final OfflineDemoStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('通知中心')),
        body: !store.notificationsAvailable
            ? const _ActivityState(
                icon: Icons.notifications_none_rounded,
                label: '通知数据尚未映射',
              )
            : store.notifications.isEmpty
                ? const _ActivityState(
                    icon: Icons.notifications_none_rounded,
                    label: '暂无通知',
                  )
                : ListView.separated(
                    itemCount: store.notifications.length,
                    separatorBuilder: (context, index) =>
                        const Divider(indent: 64),
                    itemBuilder: (context, index) {
                      final notification = store.notifications[index];
                      return Material(
                        color: notification.isRead
                            ? Colors.white
                            : const Color(0xFFF2FAF8),
                        child: ListTile(
                          onTap: notification.isRead
                              ? null
                              : () =>
                                  store.markNotificationRead(notification.id),
                          leading: Icon(
                            _notificationIcon(notification.category),
                            color: notification.isRead
                                ? const Color(0xFF7A878D)
                                : OfflineTheme.primary,
                          ),
                          title: Text(
                            notification.title,
                            style: TextStyle(
                              fontWeight: notification.isRead
                                  ? FontWeight.w500
                                  : FontWeight.w700,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${notification.body}\n'
                              '${formatDateTime(notification.occurredAt)}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          isThreeLine: true,
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class AnnouncementsPage extends StatelessWidget {
  const AnnouncementsPage({
    required this.store,
    this.editor,
    super.key,
  });

  final OfflineDemoStore store;
  final WeComAnnouncementEditor? editor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('企业公告')),
        body: !store.announcementsAvailable
            ? const _ActivityState(
                icon: Icons.campaign_outlined,
                label: '公告数据尚未映射',
              )
            : store.announcements.isEmpty
                ? const _ActivityState(
                    icon: Icons.campaign_outlined,
                    label: '暂无公告',
                  )
                : ListView.separated(
                    itemCount: store.announcements.length,
                    separatorBuilder: (context, index) =>
                        const Divider(indent: 64),
                    itemBuilder: (context, index) {
                      final announcement = store.announcements[index];
                      return Material(
                        color: Colors.white,
                        child: ListTile(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) => AnnouncementDetailPage(
                                announcement: announcement,
                                editor: editor,
                                onChanged: () async {
                                  await store.refreshAnnouncements();
                                  return store.announcements.firstWhere(
                                    (item) => item.id == announcement.id,
                                  );
                                },
                              ),
                            ),
                          ),
                          leading: const Icon(
                            Icons.article_outlined,
                            color: OfflineTheme.secondary,
                          ),
                          title: Text(
                            announcement.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${announcement.authorName} · '
                            '${formatDate(announcement.publishedAt)}',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class AnnouncementDetailPage extends StatefulWidget {
  const AnnouncementDetailPage({
    required this.announcement,
    this.editor,
    this.onChanged,
    super.key,
  }) : assert(editor == null || onChanged != null);

  final OfflineAnnouncement announcement;
  final WeComAnnouncementEditor? editor;
  final Future<OfflineAnnouncement> Function()? onChanged;

  @override
  State<AnnouncementDetailPage> createState() => _AnnouncementDetailPageState();
}

class _AnnouncementDetailPageState extends State<AnnouncementDetailPage> {
  late OfflineAnnouncement _announcement;

  @override
  void initState() {
    super.initState();
    _announcement = widget.announcement;
  }

  @override
  Widget build(BuildContext context) {
    final announcement = _announcement;
    return Scaffold(
      appBar: AppBar(
        title: const Text('公告详情'),
        actions: [
          if (widget.editor != null)
            IconButton(
              key: const Key('edit-announcement'),
              tooltip: '编辑公告',
              onPressed: _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            announcement.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            '${announcement.authorName} · '
            '${formatDateTime(announcement.publishedAt)}',
            style: const TextStyle(color: Color(0xFF64727A)),
          ),
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 18),
          Text(
            announcement.summary,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.7),
          ),
          if (announcement.attachmentCount > 0) ...[
            const SizedBox(height: 18),
            Text(
              '附件 ${announcement.attachmentCount} 个',
              style: const TextStyle(color: Color(0xFF64727A)),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _edit() async {
    final editor = widget.editor!;
    final draft = await showDialog<_AnnouncementDraft>(
      context: context,
      builder: (context) => _AnnouncementEditDialog(
        announcement: _announcement,
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    try {
      final edit = await editor.updateContent(
        announcementId: _announcement.id,
        title: draft.title,
        summary: draft.summary,
      );
      await _refresh();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('公告修改仅保存在本地'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undo(edit),
          ),
        ),
      );
    } on WeComAnnouncementNoChangesException {
      _showMessage('没有需要保存的更改');
    } catch (_) {
      _showMessage('公告保存失败');
    }
  }

  Future<void> _undo(WeComAnnouncementEdit edit) async {
    try {
      await widget.editor!.undo(edit);
      await _refresh();
      if (mounted) {
        _showMessage('已撤销公告修改');
      }
    } catch (_) {
      if (mounted) {
        _showMessage('撤销失败');
      }
    }
  }

  Future<void> _refresh() async {
    final updated = await widget.onChanged?.call();
    if (mounted && updated != null) {
      setState(() => _announcement = updated);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _AnnouncementDraft {
  const _AnnouncementDraft({required this.title, required this.summary});

  final String title;
  final String summary;
}

class _AnnouncementEditDialog extends StatefulWidget {
  const _AnnouncementEditDialog({required this.announcement});

  final OfflineAnnouncement announcement;

  @override
  State<_AnnouncementEditDialog> createState() =>
      _AnnouncementEditDialogState();
}

class _AnnouncementEditDialogState extends State<_AnnouncementEditDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _summaryController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.announcement.title);
    _summaryController =
        TextEditingController(text: widget.announcement.summary);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('编辑公告'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('announcement-title'),
            controller: _titleController,
            decoration: const InputDecoration(labelText: '标题'),
          ),
          TextField(
            key: const Key('announcement-summary'),
            controller: _summaryController,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(labelText: '摘要'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('save-announcement'),
          onPressed: () => Navigator.of(context).pop(
            _AnnouncementDraft(
              title: _titleController.text,
              summary: _summaryController.text,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class CallRecordsPage extends StatelessWidget {
  const CallRecordsPage({required this.store, super.key});

  final OfflineDemoStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通话记录')),
      body: !store.callsAvailable
          ? const _ActivityState(
              icon: Icons.call_outlined,
              label: '通话数据尚未映射',
            )
          : store.callRecords.isEmpty
              ? const _ActivityState(
                  icon: Icons.call_outlined,
                  label: '暂无通话记录',
                )
              : ListView.separated(
                  itemCount: store.callRecords.length,
                  separatorBuilder: (context, index) =>
                      const Divider(indent: 76),
                  itemBuilder: (context, index) {
                    final record = store.callRecords[index];
                    final missed = record.status == 'missed';
                    final direction = switch (record.direction) {
                      'incoming' => '呼入',
                      'outgoing' => '呼出',
                      _ => '群聊',
                    };
                    final duration = switch (record.status) {
                      'missed' => '未接',
                      'rejected' => '已拒绝',
                      'cancelled_self' => '已取消',
                      'cancelled_peer' => '对方已取消',
                      _ when record.durationSeconds > 0 =>
                        formatDuration(record.durationSeconds),
                      _ => '未接通',
                    };
                    return Material(
                      color: Colors.white,
                      child: ListTile(
                        leading: OfflineAvatar(
                          id: record.id,
                          label: record.peerName,
                          size: 44,
                        ),
                        title: Text(
                          record.peerName,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: missed
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          '$direction · $duration · ${formatDateTime(record.startedAt)}',
                        ),
                        trailing: Icon(
                          record.type == 'video'
                              ? Icons.videocam_outlined
                              : Icons.call_outlined,
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class DataOverviewPage extends StatelessWidget {
  const DataOverviewPage({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final store = environment.store;
    return Scaffold(
      appBar: AppBar(title: const Text('数据概览')),
      body: ListView(
        children: [
          OfflineInfoTile(
            icon: Icons.storage_outlined,
            label: '数据源',
            value: environment.wecomRuntime == null ? '未选择' : 'WeCom 数据库包',
          ),
          OfflineInfoTile(
            icon: Icons.people_outline_rounded,
            label: '联系人',
            value: '${store.contacts.length}',
          ),
          OfflineInfoTile(
            icon: Icons.chat_bubble_outline_rounded,
            label: '会话',
            value: '${store.conversations.length}',
          ),
          OfflineInfoTile(
            icon: Icons.notifications_none_rounded,
            label: '通知',
            value: store.notificationsAvailable
                ? '${store.notifications.length}'
                : '未映射',
          ),
        ],
      ),
    );
  }
}

class _ActivityState extends StatelessWidget {
  const _ActivityState({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 42, color: OfflineTheme.primary),
                const SizedBox(height: 12),
                Text(label, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

IconData _notificationIcon(String category) => switch (category) {
      'task' => Icons.task_alt_rounded,
      'calendar' => Icons.event_outlined,
      _ => Icons.info_outline_rounded,
    };
