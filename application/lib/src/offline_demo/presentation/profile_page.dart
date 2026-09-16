import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import '../state/admin_access_controller.dart';
import 'offline_widgets.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const _tapWindow = Duration(seconds: 4);
  static const _requiredTaps = 7;

  DateTime? _tapWindowStartedAt;
  var _versionTapCount = 0;

  @override
  Widget build(BuildContext context) {
    final profile = widget.environment.store.profile;
    if (profile == null) {
      return _IdentityUnavailable(
        isAdmin: widget.environment.adminAccess.isAdmin,
        onVersionTap: _handleVersionTap,
      );
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
        OfflineInfoTile(
          icon: Icons.admin_panel_settings_outlined,
          label: '权限模式',
          value: widget.environment.adminAccess.isAdmin ? '管理模式' : '用户模式',
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
        const SizedBox(height: 12),
        OfflineInfoTile(
          key: const Key('offline-version-entry'),
          icon: Icons.info_outline_rounded,
          label: '版本',
          value: '1.0.0',
          onTap: _handleVersionTap,
        ),
      ],
    );
  }

  void _handleVersionTap() {
    final now = DateTime.now();
    final startedAt = _tapWindowStartedAt;
    if (startedAt == null || now.difference(startedAt) > _tapWindow) {
      _tapWindowStartedAt = now;
      _versionTapCount = 1;
    } else {
      _versionTapCount += 1;
    }
    if (_versionTapCount < _requiredTaps) {
      return;
    }
    _tapWindowStartedAt = null;
    _versionTapCount = 0;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AdminAccessSheet(
        controller: widget.environment.adminAccess,
      ),
    );
  }
}

class _AdminAccessSheet extends StatefulWidget {
  const _AdminAccessSheet({required this.controller});

  final AdminAccessController controller;

  @override
  State<_AdminAccessSheet> createState() => _AdminAccessSheetState();
}

class _AdminAccessSheetState extends State<_AdminAccessSheet> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  var _submitting = false;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.controller.requiresPinSetup;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              setup ? '设置管理口令' : '输入管理口令',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('admin-pin-field'),
              controller: _pinController,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              textInputAction:
                  setup ? TextInputAction.next : TextInputAction.done,
              onSubmitted: setup ? null : (_) => _submit(),
              decoration: InputDecoration(
                labelText: '口令',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
            if (setup) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin-pin-confirm-field'),
                controller: _confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: '确认口令',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('admin-pin-submit'),
              onPressed: _submitting ? null : _submit,
              child: Text(_submitting ? '处理中' : '确认'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final setup = widget.controller.requiresPinSetup;
    if (setup && _pinController.text != _confirmController.text) {
      setState(() => _error = '两次输入不一致');
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    final result = setup
        ? await widget.controller.setupPin(_pinController.text)
        : await widget.controller.authenticate(_pinController.text);
    if (!mounted) {
      return;
    }
    if (result == AdminAuthenticationResult.granted) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _submitting = false;
      _error = switch (result) {
        AdminAuthenticationResult.invalid => '口令错误',
        AdminAuthenticationResult.locked => '尝试次数过多，请稍后重试',
        AdminAuthenticationResult.invalidInput => '请输入口令',
        AdminAuthenticationResult.requiresSetup => '请先设置本机口令',
        AdminAuthenticationResult.granted => null,
      };
    });
  }
}

class _IdentityUnavailable extends StatelessWidget {
  const _IdentityUnavailable({
    required this.isAdmin,
    required this.onVersionTap,
  });

  final bool isAdmin;
  final VoidCallback onVersionTap;

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
        const SizedBox(height: 80),
        OfflineInfoTile(
          icon: Icons.admin_panel_settings_outlined,
          label: '权限模式',
          value: isAdmin ? '管理模式' : '用户模式',
        ),
        const SizedBox(height: 12),
        OfflineInfoTile(
          key: const Key('offline-version-entry'),
          icon: Icons.info_outline_rounded,
          label: '版本',
          value: '1.0.0',
          onTap: onVersionTap,
        ),
      ],
    );
  }
}
