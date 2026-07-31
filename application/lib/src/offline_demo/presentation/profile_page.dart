import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import 'offline_widgets.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final profile = environment.store.profile!;
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
                    Text(
                      '${profile.department} · ${profile.title}',
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
        const OfflineInfoTile(
          icon: Icons.person_outline_rounded,
          label: '身份',
          value: '默认离线用户',
        ),
        OfflineInfoTile(
          icon: Icons.workspaces_outline,
          label: '场景',
          value: environment.store.scenarioName,
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
