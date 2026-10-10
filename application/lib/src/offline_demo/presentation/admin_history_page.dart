import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/wecom_overlay_history_service.dart';
import '../state/admin_access_controller.dart';

class AdminHistoryPage extends StatefulWidget {
  const AdminHistoryPage(
      {required this.history,
      required this.adminAccess,
      required this.onChanged,
      super.key});
  final WeComOverlayHistoryService history;
  final AdminAccessController adminAccess;
  final Future<void> Function() onChanged;

  @override
  State<AdminHistoryPage> createState() => _AdminHistoryPageState();
}

class _AdminHistoryPageState extends State<AdminHistoryPage> {
  var _kind = WeComHistoryKind.fields;
  List<WeComHistoryEntry> _entries = [];
  var _busy = false;
  var _more = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows =
          await widget.history.list(_kind, offset: more ? _entries.length : 0);
      if (!mounted) return;
      setState(() {
        _entries = more ? [..._entries, ...rows] : rows;
        _more = rows.length == WeComOverlayHistoryService.pageSize;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取历史，请确认管理会话和活动场景');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.adminAccess,
      builder: (context, _) => Scaffold(
            appBar: AppBar(title: const Text('修订历史'), actions: [
              IconButton(
                  tooltip: '刷新历史',
                  icon: const Icon(Icons.refresh),
                  onPressed:
                      _busy || !widget.adminAccess.isAdmin ? null : _load),
            ]),
            body: !widget.adminAccess.isAdmin
                ? const Center(child: Text('管理会话已失效'))
                : Column(children: [
                    Padding(
                        padding: const EdgeInsets.all(12),
                        child: SegmentedButton<WeComHistoryKind>(
                          expandedInsets: EdgeInsets.zero,
                          segments: const [
                            ButtonSegment(
                                value: WeComHistoryKind.fields,
                                label: Text('字段')),
                            ButtonSegment(
                                value: WeComHistoryKind.messages,
                                label: Text('消息')),
                            ButtonSegment(
                                value: WeComHistoryKind.simulations,
                                label: Text('模拟')),
                          ],
                          selected: {_kind},
                          onSelectionChanged: _busy
                              ? null
                              : (values) {
                                  setState(() {
                                    _kind = values.single;
                                    _entries = [];
                                  });
                                  _load();
                                },
                        )),
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_error!)),
                    Expanded(
                        child: _entries.isEmpty && !_busy && _error == null
                            ? const Center(child: Text('暂无修订记录'))
                            : ListView.separated(
                                itemCount: _entries.length + (_more ? 1 : 0),
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  if (index == _entries.length) {
                                    return TextButton.icon(
                                        icon: const Icon(Icons.expand_more),
                                        label: const Text('加载更多'),
                                        onPressed: _busy
                                            ? null
                                            : () => _load(more: true));
                                  }
                                  final entry = _entries[index];
                                  return ListTile(
                                    key: Key(
                                        'history-${entry.kind.name}-${entry.id}'),
                                    onTap: _busy ? null : () => _open(entry),
                                    leading: Icon(entry.revertsId == null
                                        ? Icons.edit_note
                                        : Icons.undo),
                                    title:
                                        Text('${_action(entry)} #${entry.id}'),
                                    subtitle: Text(
                                        '${entry.target}\n${_date(entry.createdAt)}',
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis),
                                    trailing: const Icon(Icons.chevron_right),
                                  );
                                })),
                  ]),
          ));

  Future<void> _open(WeComHistoryEntry entry) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => _HistoryDetailPage(
            history: widget.history,
            entry: entry,
            adminAccess: widget.adminAccess)));
    if (changed == true) {
      try {
        await widget.onChanged();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('撤销已保存，显示刷新失败，请重试刷新')));
        }
      }
    }
    if (mounted) await _load();
  }
}

class _HistoryDetailPage extends StatefulWidget {
  const _HistoryDetailPage(
      {required this.history, required this.entry, required this.adminAccess});
  final WeComOverlayHistoryService history;
  final WeComHistoryEntry entry;
  final AdminAccessController adminAccess;
  @override
  State<_HistoryDetailPage> createState() => _HistoryDetailPageState();
}

class _HistoryDetailPageState extends State<_HistoryDetailPage> {
  WeComHistoryDetail? _detail;
  var _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value =
          await widget.history.detail(widget.entry.kind, widget.entry.id);
      if (mounted) setState(() => _detail = value);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取修订详情');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.adminAccess,
      builder: (context, _) {
        final detail = _detail;
        return Scaffold(
          appBar: AppBar(
              title: Text('${_action(widget.entry)} #${widget.entry.id}')),
          body: !widget.adminAccess.isAdmin
              ? const Center(child: Text('管理会话已失效'))
              : detail == null
                  ? Center(
                      child: _error == null
                          ? const CircularProgressIndicator()
                          : Text(_error!))
                  : ListView(padding: const EdgeInsets.all(16), children: [
                      SelectableText(widget.entry.target),
                      Text(_date(widget.entry.createdAt)),
                      if (widget.entry.revertsId != null)
                        Text('撤销引用 #${widget.entry.revertsId}'),
                      if (widget.entry.row['dataset_id']
                          case final String dataset)
                        SelectableText('数据集 $dataset'),
                      const SizedBox(height: 16),
                      for (final key in {
                        ...detail.before.keys,
                        ...detail.after.keys
                      }) ...[
                        Text(key,
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8),
                        const Text('修改前'),
                        SelectableText(_value(detail.before, key)),
                        const SizedBox(height: 8),
                        const Text('修改后'),
                        SelectableText(_value(detail.after, key)),
                        const Divider(height: 24),
                      ],
                      if (detail.undoReason != null) Text(detail.undoReason!),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          key: const Key('undo-history'),
                          onPressed:
                              _busy || detail.undoReason != null ? null : _undo,
                          icon: const Icon(Icons.undo),
                          label: const Text('撤销此修订')),
                      if (_busy) const LinearProgressIndicator(),
                    ]),
        );
      });

  Future<void> _undo() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('撤销此修订？'),
                content: Text('${_action(widget.entry)} #${widget.entry.id}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton.icon(
                      key: const Key('confirm-history-undo'),
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(Icons.undo),
                      label: const Text('确认撤销')),
                ]));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.history.undo(widget.entry.kind, widget.entry.id);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未撤销，请确认后续修订、管理会话和活动场景')));
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

String _action(WeComHistoryEntry entry) => entry.revertsId != null
    ? '反向修订'
    : switch (entry.action) {
        'upsert' => '字段覆盖',
        'tombstone' => '隐藏记录',
        'add' => '新增消息',
        'replace' => '覆盖消息',
        'hide' => '隐藏消息',
        'textExchange' => '文本模拟',
        'scheduledCall' => '预约来电',
        _ => entry.action,
      };
String _value(Map<String, Object?> values, String key) =>
    !values.containsKey(key)
        ? '无记录'
        : values[key] is String
            ? values[key]! as String
            : jsonEncode(values[key]);
String _date(DateTime instant) => instant.toLocal().toString().split('.').first;
