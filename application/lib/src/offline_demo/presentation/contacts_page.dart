import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({
    required this.contactsAvailable,
    required this.organizationUnits,
    required this.contacts,
    required this.onRefresh,
    required this.loadOrganizationContacts,
    super.key,
  });

  final bool contactsAvailable;
  final List<OrgUnit> organizationUnits;
  final List<DirectoryContact> contacts;
  final Future<void> Function() onRefresh;
  final Future<List<DirectoryContact>> Function(String organizationUnitId)
      loadOrganizationContacts;

  @override
  Widget build(BuildContext context) {
    if (!contactsAvailable) {
      return _ContactsState(
        onRefresh: onRefresh,
        icon: Icons.storage_outlined,
        label: '未选择联系人数据',
      );
    }
    if (contacts.isEmpty && organizationUnits.isEmpty) {
      return _ContactsState(
        onRefresh: onRefresh,
        icon: Icons.people_outline_rounded,
        label: '暂无联系人',
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: contacts.length + (organizationUnits.isEmpty ? 0 : 1),
        separatorBuilder: (context, index) => const Divider(indent: 76),
        itemBuilder: (context, index) {
          if (organizationUnits.isNotEmpty && index == 0) {
            return Material(
              color: Colors.white,
              child: ListTile(
                key: const Key('organization-directory'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => OrganizationDirectoryPage(
                      organizationUnits: organizationUnits,
                      loadContacts: loadOrganizationContacts,
                    ),
                  ),
                ),
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE8F5EE),
                  child: Icon(
                    Icons.account_tree_outlined,
                    color: OfflineTheme.primary,
                  ),
                ),
                title: const Text(
                  '组织架构',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('${organizationUnits.length} 个部门'),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            );
          }
          final contactIndex = index - (organizationUnits.isEmpty ? 0 : 1);
          return _contactTile(context, contacts[contactIndex]);
        },
      ),
    );
  }
}

class ContactDetailPage extends StatelessWidget {
  const ContactDetailPage({required this.contact, super.key});

  final DirectoryContact contact;

  @override
  Widget build(BuildContext context) {
    final summary = _contactSummary(contact, includeAccount: false);
    return Scaffold(
      appBar: AppBar(title: const Text('联系人详情')),
      body: ListView(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                OfflineAvatar(
                  id: contact.id,
                  label: _contactLabel(contact),
                  size: 72,
                ),
                const SizedBox(height: 14),
                Text(
                  _contactLabel(contact),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                if (summary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    style: const TextStyle(color: Color(0xFF64727A)),
                  ),
                ],
              ],
            ),
          ),
          if (contact.account != null ||
              contact.organizationName != null ||
              contact.departmentName != null ||
              contact.jobTitle != null)
            const SizedBox(height: 12),
          if (contact.account case final account?)
            OfflineInfoTile(
              icon: Icons.alternate_email_rounded,
              label: '账号',
              value: account,
            ),
          if (contact.organizationName case final organization?)
            OfflineInfoTile(
              icon: Icons.apartment_rounded,
              label: '企业',
              value: organization,
            ),
          if (contact.departmentName case final department?)
            OfflineInfoTile(
              icon: Icons.account_tree_outlined,
              label: '部门',
              value: department,
            ),
          if (contact.jobTitle case final jobTitle?)
            OfflineInfoTile(
              icon: Icons.badge_outlined,
              label: '职位',
              value: jobTitle,
            ),
        ],
      ),
    );
  }
}

class OrganizationDirectoryPage extends StatelessWidget {
  const OrganizationDirectoryPage({
    required this.organizationUnits,
    required this.loadContacts,
    super.key,
  });

  final List<OrgUnit> organizationUnits;
  final Future<List<DirectoryContact>> Function(String organizationUnitId)
      loadContacts;

  @override
  Widget build(BuildContext context) {
    final unitIds = organizationUnits.map((unit) => unit.id).toSet();
    final roots = organizationUnits
        .where(
          (unit) => unit.parentId == null || !unitIds.contains(unit.parentId),
        )
        .toList(growable: false);
    final visibleRoots = roots.isEmpty ? organizationUnits : roots;
    return Scaffold(
      appBar: AppBar(title: const Text('组织架构')),
      body: ListView.separated(
        itemCount: visibleRoots.length,
        separatorBuilder: (context, index) => const Divider(indent: 64),
        itemBuilder: (context, index) => _departmentTile(
          context,
          visibleRoots[index],
          organizationUnits,
          loadContacts,
        ),
      ),
    );
  }
}

class _DepartmentDirectoryPage extends StatefulWidget {
  const _DepartmentDirectoryPage({
    required this.department,
    required this.organizationUnits,
    required this.loadContacts,
  });

  final OrgUnit department;
  final List<OrgUnit> organizationUnits;
  final Future<List<DirectoryContact>> Function(String organizationUnitId)
      loadContacts;

  @override
  State<_DepartmentDirectoryPage> createState() =>
      _DepartmentDirectoryPageState();
}

class _DepartmentDirectoryPageState extends State<_DepartmentDirectoryPage> {
  late Future<List<DirectoryContact>> _contacts;

  @override
  void initState() {
    super.initState();
    _contacts = widget.loadContacts(widget.department.id);
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.organizationUnits
        .where((unit) => unit.parentId == widget.department.id)
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.department.name.isEmpty ? '未命名部门' : widget.department.name,
        ),
      ),
      body: FutureBuilder<List<DirectoryContact>>(
        future: _contacts,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ContactsState(
              onRefresh: _reload,
              icon: Icons.error_outline_rounded,
              label: '部门数据读取失败',
            );
          }
          final contacts = snapshot.data ?? const [];
          if (children.isEmpty && contacts.isEmpty) {
            return _ContactsState(
              onRefresh: _reload,
              icon: Icons.people_outline_rounded,
              label: '该部门暂无成员',
            );
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (children.isNotEmpty)
                  const _DirectorySectionHeader(label: '下级部门'),
                for (final child in children)
                  _departmentTile(
                    context,
                    child,
                    widget.organizationUnits,
                    widget.loadContacts,
                  ),
                if (contacts.isNotEmpty)
                  const _DirectorySectionHeader(label: '成员'),
                for (final contact in contacts) _contactTile(context, contact),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _reload() async {
    setState(() {
      _contacts = widget.loadContacts(widget.department.id);
    });
    await _contacts;
  }
}

class _DirectorySectionHeader extends StatelessWidget {
  const _DirectorySectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF64727A),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

Widget _departmentTile(
  BuildContext context,
  OrgUnit unit,
  List<OrgUnit> organizationUnits,
  Future<List<DirectoryContact>> Function(String organizationUnitId)
      loadContacts,
) {
  return Material(
    color: Colors.white,
    child: ListTile(
      key: Key('department-${unit.id}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => _DepartmentDirectoryPage(
            department: unit,
            organizationUnits: organizationUnits,
            loadContacts: loadContacts,
          ),
        ),
      ),
      leading: const Icon(Icons.apartment_rounded),
      title: Text(
        unit.name.isEmpty ? '未命名部门' : unit.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
    ),
  );
}

class _ContactsState extends StatelessWidget {
  const _ContactsState({
    required this.onRefresh,
    required this.icon,
    required this.label,
  });

  final Future<void> Function() onRefresh;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 42, color: OfflineTheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _contactLabel(DirectoryContact contact) {
  return contact.displayName.isEmpty ? '未命名联系人' : contact.displayName;
}

String? _contactSummary(
  DirectoryContact contact, {
  bool includeAccount = true,
}) {
  final parts = [
    contact.departmentName,
    contact.organizationName,
    contact.jobTitle,
    if (includeAccount) contact.account,
  ].whereType<String>().toList(growable: false);
  return parts.isEmpty ? null : parts.join(' · ');
}

Widget _contactTile(BuildContext context, DirectoryContact contact) {
  final summary = _contactSummary(contact);
  return Material(
    color: Colors.white,
    child: ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ContactDetailPage(contact: contact),
        ),
      ),
      leading: OfflineAvatar(
        id: contact.id,
        label: _contactLabel(contact),
        size: 44,
      ),
      title: Text(
        _contactLabel(contact),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: summary == null
          ? null
          : Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: const Icon(Icons.chevron_right_rounded),
    ),
  );
}
