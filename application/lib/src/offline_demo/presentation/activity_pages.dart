import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
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
        body: ListView.separated(
          itemCount: store.notifications.length,
          separatorBuilder: (context, index) => const Divider(indent: 64),
          itemBuilder: (context, index) {
            final notification = store.notifications[index];
            return Material(
              color:
                  notification.isRead ? Colors.white : const Color(0xFFF2FAF8),
              child: ListTile(
                onTap: notification.isRead
                    ? null
                    : () => store.markNotificationRead(notification.id),
                leading: Icon(
                  _notificationIcon(notification.category),
                  color: notification.isRead
                      ? const Color(0xFF7A878D)
                      : OfflineTheme.primary,
                ),
                title: Text(
                  notification.title,
                  style: TextStyle(
                    fontWeight:
                        notification.isRead ? FontWeight.w500 : FontWeight.w700,
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
  const AnnouncementsPage({required this.store, super.key});

  final OfflineDemoStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('企业公告')),
      body: ListView.separated(
        itemCount: store.announcements.length,
        separatorBuilder: (context, index) => const Divider(indent: 64),
        itemBuilder: (context, index) {
          final announcement = store.announcements[index];
          return Material(
            color: Colors.white,
            child: ListTile(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => AnnouncementDetailPage(
                    announcement: announcement,
                  ),
                ),
              ),
              leading: Icon(
                announcement.isPinned
                    ? Icons.push_pin_rounded
                    : Icons.article_outlined,
                color: announcement.isPinned
                    ? OfflineTheme.accent
                    : OfflineTheme.secondary,
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
    );
  }
}

class AnnouncementDetailPage extends StatelessWidget {
  const AnnouncementDetailPage({required this.announcement, super.key});

  final OfflineAnnouncement announcement;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('公告详情')),
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
            announcement.body,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.7),
          ),
        ],
      ),
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
      body: ListView.separated(
        itemCount: store.callRecords.length,
        separatorBuilder: (context, index) => const Divider(indent: 76),
        itemBuilder: (context, index) {
          final record = store.callRecords[index];
          final missed = record.status == 'missed';
          final direction = record.direction == 'incoming' ? '呼入' : '呼出';
          final duration = record.durationSeconds == 0
              ? '未接通'
              : formatDuration(record.durationSeconds);
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
                  color: missed ? Theme.of(context).colorScheme.error : null,
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

class ScenarioPage extends StatelessWidget {
  const ScenarioPage({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final store = environment.store;
    return Scaffold(
      appBar: AppBar(title: const Text('场景数据')),
      body: ListView(
        children: [
          OfflineInfoTile(
            icon: Icons.layers_outlined,
            label: '场景',
            value: store.scenarioName,
          ),
          const OfflineInfoTile(
            icon: Icons.schema_outlined,
            label: 'Schema',
            value: 'v1',
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
            value: '${store.notifications.length}',
          ),
          OfflineInfoTile(
            icon: Icons.storage_outlined,
            label: '数据库',
            value: environment.database.path,
            allowWrap: true,
          ),
        ],
      ),
    );
  }
}

IconData _notificationIcon(String category) => switch (category) {
      'task' => Icons.task_alt_rounded,
      'calendar' => Icons.event_outlined,
      _ => Icons.info_outline_rounded,
    };
