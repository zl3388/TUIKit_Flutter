import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import 'activity_pages.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class WorkbenchPage extends StatelessWidget {
  const WorkbenchPage({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final store = environment.store;
    final tools = <_WorkbenchTool>[
      _WorkbenchTool(
        label: '通知中心',
        icon: Icons.notifications_none_rounded,
        color: OfflineTheme.primary,
        badge: store.unreadNotificationCount,
        open: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => NotificationsPage(store: store),
          ),
        ),
      ),
      _WorkbenchTool(
        label: '企业公告',
        icon: Icons.campaign_outlined,
        color: OfflineTheme.secondary,
        open: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => AnnouncementsPage(store: store),
          ),
        ),
      ),
      _WorkbenchTool(
        label: '通话记录',
        icon: Icons.call_outlined,
        color: const Color(0xFFB45309),
        open: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => CallRecordsPage(store: store),
          ),
        ),
      ),
      _WorkbenchTool(
        label: '场景数据',
        icon: Icons.storage_outlined,
        color: const Color(0xFF7C3AED),
        open: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => ScenarioPage(environment: environment),
          ),
        ),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 560
                ? 3
                : 2;
        const gap = 12.0;
        final tileWidth =
            (constraints.maxWidth - 32 - gap * (columns - 1)) / columns;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '常用应用',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: tools
                  .map(
                    (tool) => SizedBox(
                      width: tileWidth,
                      child: _ToolTile(tool: tool),
                    ),
                  )
                  .toList(growable: false),
            ),
            const SizedBox(height: 24),
            Text(
              '最新公告',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: List.generate(store.announcements.length, (index) {
                  final announcement = store.announcements[index];
                  return Column(
                    children: [
                      ListTile(
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
                        ),
                        subtitle: Text(
                          '${announcement.authorName} · '
                          '${formatDate(announcement.publishedAt)}',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                      ),
                      if (index != store.announcements.length - 1)
                        const Divider(indent: 56),
                    ],
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool});

  final _WorkbenchTool tool;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: tool.open,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 106,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Badge(
                  isLabelVisible: tool.badge > 0,
                  label: Text('${tool.badge}'),
                  child: Icon(tool.icon, size: 30, color: tool.color),
                ),
                Text(
                  tool.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkbenchTool {
  const _WorkbenchTool({
    required this.label,
    required this.icon,
    required this.color,
    required this.open,
    this.badge = 0,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback open;
  final int badge;
}
