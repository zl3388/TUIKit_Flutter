import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bootstrap/offline_bootstrap.dart';
import '../data/wecom_data_source_service.dart';
import '../data/wecom_database_package.dart';
import '../data/wecom_identity_repository.dart';
import 'offline_theme.dart';

class AdminConsolePage extends StatefulWidget {
  const AdminConsolePage({
    required this.environment,
    required this.onEnvironmentReload,
    super.key,
  });

  final OfflineEnvironment environment;
  final Future<void> Function() onEnvironmentReload;

  @override
  State<AdminConsolePage> createState() => _AdminConsolePageState();
}

class _AdminConsolePageState extends State<AdminConsolePage> {
  WeComSavedDataSource? _savedSource;
  var _hasDefaultKey = false;
  var _loadingState = true;
  var _processing = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    try {
      final results = await Future.wait<Object?>([
        widget.environment.wecomDataSources.loadSelectedSource(),
        widget.environment.wecomDataSources.hasDefaultRawKey(),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _savedSource = results[0] as WeComSavedDataSource?;
        _hasDefaultKey = results[1]! as bool;
        _loadingState = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _loadingState = false);
      _showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final datasetId = widget.environment.wecomRuntime?.datasetId;
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
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: Text(datasetId == null ? '未选择数据源' : '当前数据集'),
                subtitle: datasetId == null
                    ? null
                    : Text(
                        datasetId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              if (_savedSource != null) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('源目录'),
                  subtitle: Text(
                    _savedSource!.sourceLocator,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const Divider(height: 1),
              ListTile(
                key: const Key('select-data-source'),
                enabled: !_processing,
                onTap: _processing ? null : _selectSource,
                leading: const Icon(Icons.drive_folder_upload_outlined),
                title: const Text('选择或切换数据源'),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('refresh-data-source'),
                enabled: !_processing && !_loadingState && _savedSource != null,
                onTap:
                    _processing || _savedSource == null ? null : _refreshSource,
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('刷新当前源目录'),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
        if (_processing) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 24),
        Text(
          '解密密钥',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            key: const Key('default-key-status'),
            enabled: !_processing && !_loadingState,
            onTap: _hasDefaultKey ? _clearDefaultKey : null,
            leading: Icon(
              _hasDefaultKey ? Icons.key_rounded : Icons.key_off_outlined,
            ),
            title: Text(_hasDefaultKey ? '已配置默认密钥' : '未配置默认密钥'),
            trailing: _hasDefaultKey
                ? IconButton(
                    tooltip: '清除默认密钥',
                    onPressed: _processing ? null : _clearDefaultKey,
                    icon: const Icon(Icons.delete_outline_rounded),
                  )
                : null,
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
            onTap: widget.environment.adminAccess.exitAdminMode,
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

  Future<void> _selectSource() async {
    try {
      final selected = await widget.environment.wecomSourceDirectories.choose();
      if (selected == null || !mounted) {
        return;
      }
      await _prepareAndActivate(
        selected.directory,
        sourceLocator: selected.locator,
      );
    } catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  Future<void> _refreshSource() async {
    final options = await _requestImportOptions(_savedSource!.sourceLocator);
    if (options == null || !mounted) {
      return;
    }
    await _runActivation(
      () => widget.environment.wecomDataSources.prepareSaved(
        temporaryRawKeyHex: options.rawKeyHex,
      ),
      options,
    );
  }

  Future<void> _prepareAndActivate(
    Directory directory, {
    required String sourceLocator,
  }) async {
    final options = await _requestImportOptions(sourceLocator);
    if (options == null || !mounted) {
      return;
    }
    await _runActivation(
      () => widget.environment.wecomDataSources.prepare(
        directory,
        sourceLocator: sourceLocator,
        temporaryRawKeyHex: options.rawKeyHex,
      ),
      options,
    );
  }

  Future<void> _runActivation(
    Future<WeComPreparedDataSource> Function() prepare,
    _ImportOptions options,
  ) async {
    setState(() => _processing = true);
    try {
      final prepared = await prepare();
      int? corporationId;
      if (prepared.identityResolution.selected == null &&
          prepared.identityResolution.candidates.isNotEmpty) {
        corporationId = await _chooseCorporation(
          prepared.identityResolution.candidates,
        );
        if (corporationId == null) {
          return;
        }
      }
      final result = await widget.environment.wecomDataSources.activate(
        prepared,
        selectedCorporationId: corporationId,
        defaultRawKeyToSave: options.rememberKey ? options.rawKeyHex : null,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_activationMessage(result.status))),
      );
      await widget.onEnvironmentReload();
    } catch (error) {
      if (mounted) {
        _showError(error);
      }
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  Future<_ImportOptions?> _requestImportOptions(String path) async {
    final controller = TextEditingController();
    var rememberKey = false;
    final result = await showModalBottomSheet<_ImportOptions>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
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
                  '导入数据源',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('temporary-raw-key'),
                  controller: controller,
                  obscureText: true,
                  maxLength: 32,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'[0-9a-fA-F]'),
                    ),
                  ],
                  decoration: const InputDecoration(
                    labelText: '临时密钥（可选）',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  onChanged: (_) => setSheetState(() {
                    if (controller.text.isEmpty) {
                      rememberKey = false;
                    }
                  }),
                ),
                CheckboxListTile(
                  key: const Key('remember-default-key'),
                  contentPadding: EdgeInsets.zero,
                  value: rememberKey,
                  onChanged: controller.text.isEmpty
                      ? null
                      : (value) => setSheetState(
                            () => rememberKey = value ?? false,
                          ),
                  title: const Text('成功后设为默认密钥'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key('confirm-data-source-import'),
                  onPressed: () {
                    final key = controller.text.trim();
                    if (key.isNotEmpty && key.length != 32) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('密钥必须是 32 位十六进制字符')),
                      );
                      return;
                    }
                    Navigator.of(context).pop(
                      _ImportOptions(
                        rawKeyHex: key.isEmpty ? null : key,
                        rememberKey: rememberKey,
                      ),
                    );
                  },
                  child: const Text('继续'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<int?> _chooseCorporation(
    List<WeComDatasetIdentity> candidates,
  ) {
    return showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择企业'),
        children: [
          for (final candidate in candidates)
            SimpleDialogOption(
              key: Key('corporation-${candidate.corporationId}'),
              onPressed: () =>
                  Navigator.of(context).pop(candidate.corporationId),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  candidate.corporationName.isEmpty
                      ? '企业 ${candidate.corporationId}'
                      : candidate.corporationName,
                ),
                subtitle: Text('${candidate.corporationId}'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _clearDefaultKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除默认密钥'),
        content: const Text('之后导入加密数据源时需要重新输入密钥。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.environment.wecomDataSources.clearDefaultRawKey();
      if (mounted) {
        setState(() => _hasDefaultKey = false);
      }
    } catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  String _activationMessage(WeComDataSourceActivationStatus status) {
    return switch (status) {
      WeComDataSourceActivationStatus.activated => '数据源已启用',
      WeComDataSourceActivationStatus.migrated => '数据源已更新，本地修改已迁移',
      WeComDataSourceActivationStatus.switched => '数据源已切换',
      WeComDataSourceActivationStatus.unchanged => '数据源已刷新',
    };
  }

  void _showError(Object error) {
    final message = switch (error) {
      WeComDataSourceException(:final code) => switch (code) {
          WeComDataSourceIssueCode.invalidSourceDirectory =>
            '请选择包含 Data 的账号目录，或直接选择 Data 目录',
          WeComDataSourceIssueCode.invalidKeyFormat => '密钥必须是 32 位十六进制字符',
          WeComDataSourceIssueCode.identityUnavailable => '数据源中没有可用的当前用户身份',
          WeComDataSourceIssueCode.corporationSelectionRequired => '需要明确选择一个企业',
          WeComDataSourceIssueCode.corporationSwitchDeferred =>
            '当前版本暂不支持在同一数据集内切换企业',
          WeComDataSourceIssueCode.activeIdentityUnavailable => '当前活动数据源缺少有效身份',
          WeComDataSourceIssueCode.activeDatasetChanged => '数据源已被其他操作切换，请重试',
          WeComDataSourceIssueCode.migrationConflict => '本地修改与新快照冲突，仍保留原数据源',
          WeComDataSourceIssueCode.savedSourceUnavailable => '已保存的源目录不可用',
        },
      WeComPackageException(:final code, :final fileName) => switch (code) {
          WeComPackageIssueCode.decryptionKeyRequired => '加密数据源需要解密密钥',
          WeComPackageIssueCode.decryptionFailed => '密钥不正确或数据库无法解密',
          WeComPackageIssueCode.encryptedWalUnsupported =>
            '暂不支持带非空 WAL 的加密数据库${fileName == null ? '' : '：$fileName'}',
          WeComPackageIssueCode.requiredFileMissing =>
            '数据源缺少必要数据库${fileName == null ? '' : '：$fileName'}',
          WeComPackageIssueCode.sourceChanged => '导入期间源数据发生变化，请重试',
          _ => '数据源校验失败${fileName == null ? '' : '：$fileName'}',
        },
      _ => '操作失败，请检查数据源后重试',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _ImportOptions {
  const _ImportOptions({
    required this.rawKeyHex,
    required this.rememberKey,
  });

  final String? rawKeyHex;
  final bool rememberKey;
}
