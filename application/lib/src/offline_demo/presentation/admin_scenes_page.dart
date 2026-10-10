import 'package:flutter/material.dart';

import '../data/wecom_scene_service.dart';

class AdminScenesPage extends StatefulWidget {
  const AdminScenesPage({
    required this.scenes,
    required this.onEnvironmentReload,
    super.key,
  });

  final WeComSceneService scenes;
  final Future<void> Function() onEnvironmentReload;

  @override
  State<AdminScenesPage> createState() => _AdminScenesPageState();
}

class _AdminScenesPageState extends State<AdminScenesPage> {
  List<WeComOverlayScene> _items = const [];
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final items = await widget.scenes.list();
      if (mounted) {
        setState(() {
          _items = items;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        _error();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('场景与快照'),
          actions: [
            IconButton(
              key: const Key('create-scene'),
              tooltip: '新建场景',
              onPressed: _busy ? null : () => _create(),
              icon: const Icon(Icons.add_rounded),
            ),
            IconButton(
              key: const Key('save-scene-snapshot'),
              tooltip: '保存快照',
              onPressed: _busy ? null : _snapshot,
              icon: const Icon(Icons.bookmark_add_outlined),
            ),
            IconButton(
              key: const Key('reset-scene'),
              tooltip: '重置为基础数据',
              onPressed: _busy ? null : _reset,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
        body: Column(children: [
          if (_busy) const LinearProgressIndicator(),
          Expanded(
              child: ListView(children: [
            for (final snapshot in [false, true]) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(snapshot ? '命名快照' : '场景',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              if (!_items.any((item) => item.isSnapshot == snapshot))
                const ListTile(title: Text('暂无记录')),
              for (final item
                  in _items.where((item) => item.isSnapshot == snapshot))
                ListTile(
                  key: Key('scene-${item.id}'),
                  leading: Icon(item.id == widget.scenes.activeSceneId
                      ? Icons.radio_button_checked_rounded
                      : snapshot
                          ? Icons.bookmark_outline_rounded
                          : Icons.layers_outlined),
                  title: Text(item.name),
                  subtitle: Text(
                      '${_date(item.createdAt.toLocal())} · ${item.datasetId.substring(0, 8)}'),
                  trailing: PopupMenuButton<String>(
                    tooltip: snapshot ? '快照操作' : '场景操作',
                    enabled: !_busy,
                    onSelected: (action) {
                      if (action == 'switch') {
                        _run(() => widget.scenes.switchScene(item.id),
                            reloadEnvironment: true);
                      } else {
                        _create(source: item);
                      }
                    },
                    itemBuilder: (_) => [
                      if (!snapshot && item.id != widget.scenes.activeSceneId)
                        const PopupMenuItem(
                            value: 'switch', child: Text('切换到此场景')),
                      PopupMenuItem(
                          value: 'copy',
                          child: Text(snapshot ? '恢复为新场景' : '复制场景')),
                    ],
                  ),
                ),
            ],
          ])),
        ]),
      );

  Future<void> _create({WeComOverlayScene? source}) async {
    final name = await _nameDialog(
      source == null
          ? '新建场景'
          : source.isSnapshot
              ? '恢复快照'
              : '复制场景',
      initial: source == null
          ? ''
          : '${source.name} ${source.isSnapshot ? '恢复' : '副本'}',
    );
    if (name == null || !mounted) return;
    await _run(
      () => widget.scenes.create(name, copyFromSceneId: source?.id),
      reloadEnvironment: true,
    );
  }

  Future<void> _snapshot() async {
    final name = await _nameDialog('保存快照');
    if (name == null || !mounted) return;
    await _run(() => widget.scenes.saveSnapshot(name));
  }

  Future<void> _reset() async {
    final current =
        _items.where((item) => item.id == widget.scenes.activeSceneId).first;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置当前场景'),
        content: const Text('将恢复基础数据的显示状态。当前修订、消息编辑和模拟会先保存为快照。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('重置')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() => widget.scenes.reset(current.name),
        reloadEnvironment: true);
  }

  Future<String?> _nameDialog(String title, {String initial = ''}) async {
    var name = initial.length > 60 ? initial.substring(0, 60) : initial;
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Form(
          key: form,
          child: TextFormField(
            key: const Key('scene-name'),
            initialValue: name,
            onChanged: (value) => name = value,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(labelText: '名称'),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请输入名称' : null,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
            key: const Key('confirm-scene-name'),
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.of(context).pop(name.trim());
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _run(Future<Object?> Function() action,
      {bool reloadEnvironment = false}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      if (reloadEnvironment) {
        Navigator.of(context).pop();
        await widget.onEnvironmentReload();
      } else {
        await _reload();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        _error();
      }
    }
  }

  void _error() => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('操作失败，请确认管理会话、身份和基础数据仍然有效')),
      );

  String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}
