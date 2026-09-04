import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'offline_widgets.dart';

class GroupDirectoryPage extends StatelessWidget {
  const GroupDirectoryPage({
    required this.groups,
    required this.loadMembers,
    super.key,
  });

  final List<OfflineConversation> groups;
  final Future<List<OfflineConversationMember>> Function(String groupId)
      loadMembers;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('群聊')),
      body: ListView.separated(
        itemCount: groups.length,
        separatorBuilder: (context, index) => const Divider(indent: 76),
        itemBuilder: (context, index) {
          final group = groups[index];
          return Material(
            color: Colors.white,
            child: ListTile(
              key: Key('group-${group.id}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => GroupDetailPage(
                    group: group,
                    loadMembers: loadMembers,
                  ),
                ),
              ),
              leading: OfflineAvatar(
                id: group.id,
                label: group.title,
                size: 44,
                icon: Icons.groups_rounded,
              ),
              title: Text(
                group.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: group.lastMessagePreview.isEmpty
                  ? null
                  : Text(
                      group.lastMessagePreview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
          );
        },
      ),
    );
  }
}

class GroupDetailPage extends StatefulWidget {
  const GroupDetailPage({
    required this.group,
    required this.loadMembers,
    super.key,
  });

  final OfflineConversation group;
  final Future<List<OfflineConversationMember>> Function(String groupId)
      loadMembers;

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> {
  late Future<List<OfflineConversationMember>> _members;

  @override
  void initState() {
    super.initState();
    _members = widget.loadMembers(widget.group.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.group.title)),
      body: FutureBuilder<List<OfflineConversationMember>>(
        future: _members,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _GroupState(
              icon: Icons.error_outline_rounded,
              label: '群成员读取失败',
              onRefresh: _reload,
            );
          }
          final members = snapshot.data ?? const [];
          if (members.isEmpty) {
            return _GroupState(
              icon: Icons.people_outline_rounded,
              label: '暂无群成员',
              onRefresh: _reload,
            );
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: members.length + 1,
              separatorBuilder: (context, index) => index == 0
                  ? const SizedBox.shrink()
                  : const Divider(indent: 76),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _MemberHeader(count: members.length);
                }
                final member = members[index - 1];
                return Material(
                  color: Colors.white,
                  child: ListTile(
                    leading: OfflineAvatar(
                      id: member.userId,
                      label: member.displayName,
                      size: 44,
                    ),
                    title: Text(
                      member.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: member.isAdmin ? const Text('管理员') : null,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _reload() async {
    setState(() {
      _members = widget.loadMembers(widget.group.id);
    });
    await _members;
  }
}

class _MemberHeader extends StatelessWidget {
  const _MemberHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        '成员 · $count',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF64727A),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _GroupState extends StatelessWidget {
  const _GroupState({
    required this.icon,
    required this.label,
    required this.onRefresh,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 160),
          Icon(icon, size: 42, color: const Color(0xFF64727A)),
          const SizedBox(height: 12),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF64727A),
                ),
          ),
        ],
      ),
    );
  }
}
