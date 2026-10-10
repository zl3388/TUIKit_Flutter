import 'package:flutter/material.dart';

import '../data/wecom_local_simulation_repository.dart';
import '../domain/models.dart';
import '../state/admin_access_controller.dart';
import '../state/offline_demo_store.dart';
import 'offline_widgets.dart';

class AdminScheduledCallsPage extends StatefulWidget {
  const AdminScheduledCallsPage({
    required this.store,
    required this.simulation,
    required this.adminAccess,
    super.key,
  });

  final OfflineDemoStore store;
  final WeComLocalSimulationRepository simulation;
  final AdminAccessController adminAccess;

  @override
  State<AdminScheduledCallsPage> createState() =>
      _AdminScheduledCallsPageState();
}

class _AdminScheduledCallsPageState extends State<AdminScheduledCallsPage> {
  List<WeComSimulatedCall> _calls = const [];
  DirectoryContact? _contact;
  DateTime? _scheduledAt;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final calls = await widget.simulation.listCalls();
    if (mounted) setState(() => _calls = calls);
  }

  Future<void> _chooseTime() async {
    final initial = DateTime.now().add(const Duration(minutes: 2));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    setState(() => _scheduledAt = DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ));
  }

  Future<void> _schedule() async {
    if (!widget.adminAccess.isAdmin) {
      _message('管理会话已结束，请重新进入管理模式');
      return;
    }
    final contact = _contact;
    final due = _scheduledAt;
    if (contact == null || due == null || !due.isAfter(DateTime.now())) {
      _message('请选择联系人和未来的来电时间');
      return;
    }
    setState(() => _processing = true);
    try {
      await widget.simulation.scheduleCall(
        peerProfileId: contact.id,
        scheduledAt: due,
      );
      await _reload();
      if (mounted) setState(() => _scheduledAt = null);
      await widget.store.refreshCallRecords();
    } catch (_) {
      if (mounted) _message('预约失败，请重试');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _cancel(WeComSimulatedCall call) async {
    if (!widget.adminAccess.isAdmin) {
      _message('管理会话已结束，请重新进入管理模式');
      return;
    }
    setState(() => _processing = true);
    try {
      await widget.simulation.cancelCall(call.eventKey);
      await _reload();
      await widget.store.refreshCallRecords();
    } catch (_) {
      if (mounted) _message('取消失败，请重试');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  String _callStatus(WeComSimulatedCall call) =>
      switch (call.statusAt(widget.simulation.now)) {
        'scheduled' => '待来电',
        'ringing' => '响铃中',
        'rejected' => '已拒绝',
        _ => '未接',
      };

  @override
  Widget build(BuildContext context) {
    final contactsById = {
      for (final contact in widget.store.contacts)
        contact.id: contact.displayName,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('预约来电')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Autocomplete<DirectoryContact>(
            displayStringForOption: (contact) => contact.displayName,
            optionsBuilder: (value) {
              final query = value.text.trim().toLowerCase();
              if (query.isEmpty) {
                return const Iterable<DirectoryContact>.empty();
              }
              return widget.store.contacts
                  .where((contact) =>
                      contact.displayName.toLowerCase().contains(query) ||
                      contact.id.contains(query))
                  .take(20);
            },
            onSelected: (contact) => setState(() => _contact = contact),
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextField(
                key: const Key('scheduled-call-contact'),
                controller: controller,
                focusNode: focusNode,
                onChanged: (value) {
                  if (_contact?.displayName != value) _contact = null;
                },
                decoration: const InputDecoration(
                  labelText: '来电联系人',
                  prefixIcon: Icon(Icons.person_search_outlined),
                  border: OutlineInputBorder(),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('scheduled-call-time'),
            onPressed: _processing ? null : _chooseTime,
            icon: const Icon(Icons.schedule_rounded),
            label: Text(_scheduledAt == null
                ? '选择来电时间'
                : formatDateTime(_scheduledAt!)),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('schedule-call'),
            onPressed: _processing ? null : _schedule,
            icon: const Icon(Icons.call_outlined),
            label: const Text('预约语音来电'),
          ),
          const SizedBox(height: 24),
          Text('已预约', style: Theme.of(context).textTheme.titleMedium),
          if (_calls.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('暂无预约来电')),
            ),
          for (final call in _calls)
            ListTile(
              key: Key('scheduled-call-${call.eventKey}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call_outlined),
              title:
                  Text(contactsById[call.peerProfileId] ?? call.peerProfileId),
              subtitle: Text(
                  '${formatDateTime(call.scheduledAt)} · ${_callStatus(call)}'),
              trailing: IconButton(
                key: Key('cancel-call-${call.eventKey}'),
                tooltip: '取消来电',
                onPressed: _processing || call.rejectedAt != null
                    ? null
                    : () => _cancel(call),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ),
        ],
      ),
    );
  }
}
