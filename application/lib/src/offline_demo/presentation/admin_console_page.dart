import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import 'offline_theme.dart';

class AdminConsolePage extends StatelessWidget {
  const AdminConsolePage({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final datasetId = environment.wecomRuntime?.datasetId;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '数据源',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(datasetId == null ? '未选择数据源' : '当前数据集'),
            subtitle: datasetId == null
                ? null
                : Text(
                    datasetId,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          '管理会话',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            key: const Key('exit-admin-mode'),
            onTap: environment.adminAccess.exitAdminMode,
            leading: const Icon(
              Icons.logout_rounded,
              color: OfflineTheme.accent,
            ),
            title: const Text('退出管理模式'),
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
        ),
      ],
    );
  }
}
