import 'dart:async';

import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import '../data/wecom_local_simulation_repository.dart';
import '../state/offline_demo_store.dart';
import 'admin_console_page.dart';
import 'contacts_page.dart';
import 'conversations_page.dart';
import 'offline_theme.dart';
import 'profile_page.dart';
import 'workbench_page.dart';

class OfflineHome extends StatefulWidget {
  const OfflineHome({
    required this.environment,
    required this.onEnvironmentReload,
    super.key,
  });

  final OfflineEnvironment environment;
  final Future<void> Function() onEnvironmentReload;

  @override
  State<OfflineHome> createState() => _OfflineHomeState();
}

class _OfflineHomeState extends State<OfflineHome> with WidgetsBindingObserver {
  var _sectionIndex = 0;
  late final Listenable _changes;
  Timer? _callTimer;
  Timer? _ringTimer;
  final _presentedCalls = <String>{};
  bool _callDialogOpen = false;
  bool _inForeground = true;
  int _callScheduleRevision = 0;

  static const _userSections = <_NavigationSection>[
    _NavigationSection('消息', Icons.chat_bubble_outline_rounded),
    _NavigationSection('通讯录', Icons.people_outline_rounded),
    _NavigationSection('工作台', Icons.grid_view_rounded),
    _NavigationSection('我的', Icons.person_outline_rounded),
  ];
  static const _adminSection =
      _NavigationSection('管理', Icons.admin_panel_settings_outlined);

  @override
  void initState() {
    super.initState();
    _changes = Listenable.merge([
      widget.environment.store,
      widget.environment.adminAccess,
    ]);
    WidgetsBinding.instance.addObserver(this);
    widget.environment.store.addListener(_scheduleCalls);
    widget.environment.adminAccess.addListener(_scheduleCalls);
    _scheduleCalls();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _callScheduleRevision += 1;
    widget.environment.store.removeListener(_scheduleCalls);
    widget.environment.adminAccess.removeListener(_scheduleCalls);
    _callTimer?.cancel();
    _ringTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _inForeground = true;
        widget.environment.adminAccess.resumeFromBackground();
        _scheduleCalls();
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _inForeground = false;
        widget.environment.adminAccess.recordBackgrounded();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _scheduleCalls() async {
    _callTimer?.cancel();
    final revision = ++_callScheduleRevision;
    final simulation = widget.environment.wecomSimulation;
    if (simulation == null || !mounted) return;
    List<WeComSimulatedCall> calls;
    try {
      calls = await simulation.listCalls();
    } catch (_) {
      if (!mounted || revision != _callScheduleRevision) return;
      rethrow;
    }
    if (!mounted || revision != _callScheduleRevision) return;
    final instant = simulation.now;
    DateTime? next;
    for (final call in calls) {
      final status = call.statusAt(instant);
      if (status == 'scheduled') {
        if (next == null || call.scheduledAt.isBefore(next)) {
          next = call.scheduledAt;
        }
      } else if (status == 'ringing') {
        if (next == null || call.ringEndsAt.isBefore(next)) {
          next = call.ringEndsAt;
        }
        if (_inForeground &&
            !widget.environment.adminAccess.isAdmin &&
            !_callDialogOpen &&
            !_presentedCalls.contains(call.eventKey)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showCall(call);
          });
        }
      }
    }
    if (next != null) {
      _callTimer = Timer(next.difference(instant), () async {
        await widget.environment.store.refreshCallRecords();
        _scheduleCalls();
      });
    }
  }

  Future<void> _showCall(WeComSimulatedCall call) async {
    final simulation = widget.environment.wecomSimulation;
    if (simulation == null ||
        !_inForeground ||
        _callDialogOpen ||
        widget.environment.adminAccess.isAdmin ||
        _presentedCalls.contains(call.eventKey) ||
        call.statusAt(simulation.now) != 'ringing') {
      return;
    }
    _presentedCalls.add(call.eventKey);
    _callDialogOpen = true;
    final peerName = widget.environment.store.contacts
            .where((contact) => contact.id == call.peerProfileId)
            .map((contact) => contact.displayName)
            .firstOrNull ??
        call.peerProfileId;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _ringTimer = Timer(call.ringEndsAt.difference(simulation.now), () {
          if (dialogContext.mounted) Navigator.of(dialogContext).pop();
        });
        return AlertDialog(
          title: const Text('语音来电'),
          content: Text(peerName),
          actions: [
            FilledButton.tonalIcon(
              key: const Key('reject-simulated-call'),
              onPressed: () async {
                await simulation.rejectCall(call.eventKey);
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
              icon: const Icon(Icons.call_end_rounded),
              label: const Text('拒绝'),
            ),
          ],
        );
      },
    );
    _ringTimer?.cancel();
    _callDialogOpen = false;
    if (mounted) {
      await widget.environment.store.refreshCallRecords();
      _scheduleCalls();
    }
  }

  @override
  Widget build(BuildContext context) {
    final environment = widget.environment;
    final store = environment.store;
    return AnimatedBuilder(
      animation: _changes,
      builder: (context, _) {
        final isAdmin = environment.adminAccess.isAdmin;
        final sections = [
          ..._userSections,
          if (isAdmin) _adminSection,
        ];
        final selectedIndex =
            _sectionIndex < sections.length ? _sectionIndex : 0;
        final pages = <Widget>[
          ConversationsPage(
            store: store,
            conversationEditor:
                isAdmin ? environment.wecomConversationEditor : null,
            messageEditor: isAdmin ? environment.wecomMessageEditor : null,
            adminAccess: environment.adminAccess,
          ),
          ContactsPage(
            contactsAvailable: store.contactsAvailable,
            directoryEditor: isAdmin ? environment.wecomDirectoryEditor : null,
            organizationUnits: store.organizationUnits,
            groups: store.conversations
                .where((conversation) => conversation.type == 'group')
                .toList(growable: false),
            contacts: store.contacts,
            onRefresh: store.refreshContacts,
            loadOrganizationContacts: store.contactsForOrganizationUnit,
            loadGroupMembers: store.membersFor,
          ),
          WorkbenchPage(environment: widget.environment),
          ProfilePage(environment: widget.environment),
          if (isAdmin)
            AdminConsolePage(
              environment: environment,
              onEnvironmentReload: widget.onEnvironmentReload,
            ),
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final content = wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: selectedIndex,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: _selectSection,
                        destinations: List.generate(
                          sections.length,
                          (index) => NavigationRailDestination(
                            icon: _navigationIcon(
                              index,
                              store,
                              sections: sections,
                              selected: false,
                            ),
                            selectedIcon: _navigationIcon(
                              index,
                              store,
                              sections: sections,
                              selected: true,
                            ),
                            label: Text(sections[index].label),
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child:
                            IndexedStack(index: selectedIndex, children: pages),
                      ),
                    ],
                  )
                : IndexedStack(index: selectedIndex, children: pages);
            return Scaffold(
              appBar: AppBar(
                title: Text(sections[selectedIndex].label),
                actions: const [
                  Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: _LocalStatus(),
                  ),
                ],
              ),
              body: isAdmin
                  ? Column(
                      children: [
                        _AdminModeBanner(
                          onExit: environment.adminAccess.exitAdminMode,
                        ),
                        Expanded(child: content),
                      ],
                    )
                  : content,
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      selectedIndex: selectedIndex,
                      onDestinationSelected: _selectSection,
                      destinations: List.generate(
                        sections.length,
                        (index) => NavigationDestination(
                          icon: _navigationIcon(
                            index,
                            store,
                            sections: sections,
                            selected: false,
                          ),
                          selectedIcon: _navigationIcon(
                            index,
                            store,
                            sections: sections,
                            selected: true,
                          ),
                          label: sections[index].label,
                        ),
                      ),
                    ),
            );
          },
        );
      },
    );
  }

  Widget _navigationIcon(
    int index,
    OfflineDemoStore store, {
    required List<_NavigationSection> sections,
    required bool selected,
  }) {
    final icon = Icon(
      sections[index].icon,
      color: selected ? OfflineTheme.primary : null,
    );
    final count = index == 0 ? store.unreadConversationCount : 0;
    return count == 0 ? icon : Badge.count(count: count, child: icon);
  }

  void _selectSection(int index) {
    setState(() {
      _sectionIndex = index;
    });
  }
}

class _AdminModeBanner extends StatelessWidget {
  const _AdminModeBanner({required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      color: const Color(0xFFF59E0B),
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          const Icon(Icons.admin_panel_settings_outlined, size: 17),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '管理模式',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: null,
            tooltip: '暂无可撤销操作',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 40, height: 28),
            iconSize: 17,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            key: const Key('admin-banner-exit'),
            onPressed: onExit,
            tooltip: '退出管理模式',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 40, height: 28),
            iconSize: 17,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _LocalStatus extends StatelessWidget {
  const _LocalStatus();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '当前为离线运行状态',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: OfflineTheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '本地',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _NavigationSection {
  const _NavigationSection(this.label, this.icon);

  final String label;
  final IconData icon;
}
