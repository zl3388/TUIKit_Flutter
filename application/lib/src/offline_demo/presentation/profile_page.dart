import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import 'offline_widgets.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final profile = environment.store.profile;
    if (profile == null) {
      return const _IdentityUnavailable();
    }
    final organization = [
      profile.corporationName,
      profile.department,
      profile.title,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return ListView(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(22),
          child: Row(
            children: [
              OfflineAvatar(
                id: profile.id,
                label: profile.displayName,
                size: 64,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 5),
                    if (organization.isNotEmpty)
                      Text(
                        organization,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF64727A)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OfflineInfoTile(
          icon: Icons.person_outline_rounded,
          label: '账号',
          value: profile.account?.isNotEmpty == true ? profile.account! : '未设置',
        ),
        const OfflineInfoTile(
          icon: Icons.cloud_off_outlined,
          label: '运行模式',
          value: '完全离线',
        ),
        const OfflineInfoTile(
          icon: Icons.admin_panel_settings_outlined,
          label: '权限模式',
          value: '用户模式',
        ),
        const SizedBox(height: 12),
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
    );
  }
}

class _IdentityUnavailable extends StatelessWidget {
  const _IdentityUnavailable();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(
          Icons.badge_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 16),
        Text(
          '未选择企业身份',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }
}
