import 'package:flutter/material.dart';

import '../bootstrap/offline_bootstrap.dart';
import '../state/offline_demo_store.dart';
import 'contacts_page.dart';
import 'conversations_page.dart';
import 'offline_theme.dart';
import 'profile_page.dart';
import 'workbench_page.dart';

class OfflineHome extends StatefulWidget {
  const OfflineHome({required this.environment, super.key});

  final OfflineEnvironment environment;

  @override
  State<OfflineHome> createState() => _OfflineHomeState();
}

class _OfflineHomeState extends State<OfflineHome> {
  var _sectionIndex = 0;

  static const _sections = <_NavigationSection>[
    _NavigationSection('消息', Icons.chat_bubble_outline_rounded),
    _NavigationSection('通讯录', Icons.people_outline_rounded),
    _NavigationSection('工作台', Icons.grid_view_rounded),
    _NavigationSection('我的', Icons.person_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final store = widget.environment.store;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final pages = <Widget>[
          ConversationsPage(store: store),
          ContactsPage(store: store),
          WorkbenchPage(environment: widget.environment),
          ProfilePage(environment: widget.environment),
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            return Scaffold(
              appBar: AppBar(
                title: Text(_sections[_sectionIndex].label),
                actions: const [
                  Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: _LocalStatus(),
                  ),
                ],
              ),
              body: wide
                  ? Row(
                      children: [
                        NavigationRail(
                          selectedIndex: _sectionIndex,
                          labelType: NavigationRailLabelType.all,
                          onDestinationSelected: _selectSection,
                          destinations: List.generate(
                            _sections.length,
                            (index) => NavigationRailDestination(
                              icon: _navigationIcon(index, store,
                                  selected: false),
                              selectedIcon:
                                  _navigationIcon(index, store, selected: true),
                              label: Text(_sections[index].label),
                            ),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: IndexedStack(
                              index: _sectionIndex, children: pages),
                        ),
                      ],
                    )
                  : IndexedStack(index: _sectionIndex, children: pages),
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      selectedIndex: _sectionIndex,
                      onDestinationSelected: _selectSection,
                      destinations: List.generate(
                        _sections.length,
                        (index) => NavigationDestination(
                          icon: _navigationIcon(index, store, selected: false),
                          selectedIcon:
                              _navigationIcon(index, store, selected: true),
                          label: _sections[index].label,
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
    required bool selected,
  }) {
    final icon = Icon(
      _sections[index].icon,
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
