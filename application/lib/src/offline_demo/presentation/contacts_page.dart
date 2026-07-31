import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../state/offline_demo_store.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({required this.store, super.key});

  final OfflineDemoStore store;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: store.load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: store.contacts.length,
        separatorBuilder: (context, index) => const Divider(indent: 76),
        itemBuilder: (context, index) {
          final contact = store.contacts[index];
          return Material(
            color: Colors.white,
            child: ListTile(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => ContactDetailPage(contact: contact),
                ),
              ),
              leading: OfflineAvatar(
                id: contact.profile.id,
                label: contact.profile.displayName,
                size: 44,
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      contact.profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (contact.isFavorite) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.star_rounded,
                      size: 17,
                      color: OfflineTheme.accent,
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                '${contact.orgUnitName} · ${contact.profile.title}',
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

  final OfflineContact contact;

  @override
  Widget build(BuildContext context) {
    final profile = contact.profile;
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
                  id: profile.id,
                  label: profile.displayName,
                  size: 72,
                ),
                const SizedBox(height: 14),
                Text(
                  profile.displayName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${profile.department} · ${profile.title}',
                  style: const TextStyle(color: Color(0xFF64727A)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OfflineInfoTile(
            icon: Icons.apartment_rounded,
            label: '部门',
            value: contact.orgUnitName,
          ),
          OfflineInfoTile(
            icon: Icons.badge_outlined,
            label: '职位',
            value: profile.title,
          ),
          OfflineInfoTile(
            icon: Icons.phone_outlined,
            label: '手机',
            value: profile.phone ?? '未设置',
          ),
          OfflineInfoTile(
            icon: Icons.mail_outline_rounded,
            label: '邮箱',
            value: profile.email ?? '未设置',
          ),
        ],
      ),
    );
  }
}
