import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({
    required this.contactsAvailable,
    required this.contacts,
    required this.onRefresh,
    super.key,
  });

  final bool contactsAvailable;
  final List<DirectoryContact> contacts;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (!contactsAvailable) {
      return _ContactsState(
        onRefresh: onRefresh,
        icon: Icons.storage_outlined,
        label: '未选择联系人数据',
      );
    }
    if (contacts.isEmpty) {
      return _ContactsState(
        onRefresh: onRefresh,
        icon: Icons.people_outline_rounded,
        label: '暂无联系人',
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: contacts.length,
        separatorBuilder: (context, index) => const Divider(indent: 76),
        itemBuilder: (context, index) {
          final contact = contacts[index];
          final summary = _contactSummary(contact);
          return Material(
            color: Colors.white,
            child: ListTile(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => ContactDetailPage(contact: contact),
                ),
              ),
              leading: OfflineAvatar(
                id: contact.id,
                label: _contactLabel(contact),
                size: 44,
              ),
              title: Text(
                _contactLabel(contact),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: summary == null
                  ? null
                  : Text(
                      summary,
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

class ContactDetailPage extends StatelessWidget {
  const ContactDetailPage({required this.contact, super.key});

  final DirectoryContact contact;

  @override
  Widget build(BuildContext context) {
    final summary = _contactSummary(contact, includeAccount: false);
    return Scaffold(
      appBar: AppBar(title: const Text('联系人详情')),
      body: ListView(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                OfflineAvatar(
                  id: contact.id,
                  label: _contactLabel(contact),
                  size: 72,
                ),
                const SizedBox(height: 14),
                Text(
                  _contactLabel(contact),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                if (summary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    style: const TextStyle(color: Color(0xFF64727A)),
                  ),
                ],
              ],
            ),
          ),
          if (contact.account != null ||
              contact.organizationName != null ||
              contact.jobTitle != null)
            const SizedBox(height: 12),
          if (contact.account case final account?)
            OfflineInfoTile(
              icon: Icons.alternate_email_rounded,
              label: '账号',
              value: account,
            ),
          if (contact.organizationName case final organization?)
            OfflineInfoTile(
              icon: Icons.apartment_rounded,
              label: '企业',
              value: organization,
            ),
          if (contact.jobTitle case final jobTitle?)
            OfflineInfoTile(
              icon: Icons.badge_outlined,
              label: '职位',
              value: jobTitle,
            ),
        ],
      ),
    );
  }
}

class _ContactsState extends StatelessWidget {
  const _ContactsState({
    required this.onRefresh,
    required this.icon,
    required this.label,
  });

  final Future<void> Function() onRefresh;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
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
                  Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _contactLabel(DirectoryContact contact) {
  return contact.displayName.isEmpty ? '未命名联系人' : contact.displayName;
}

String? _contactSummary(
  DirectoryContact contact, {
  bool includeAccount = true,
}) {
  final parts = [
    contact.organizationName,
    contact.jobTitle,
    if (includeAccount) contact.account,
  ].whereType<String>().toList(growable: false);
  return parts.isEmpty ? null : parts.join(' · ');
}
