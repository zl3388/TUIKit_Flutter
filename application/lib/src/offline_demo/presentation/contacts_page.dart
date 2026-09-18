import 'package:flutter/material.dart';

import '../data/wecom_directory_editor.dart';
import '../domain/models.dart';
import 'group_directory_page.dart';
import 'offline_theme.dart';
import 'offline_widgets.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({
    required this.contactsAvailable,
    required this.directoryEditor,
    required this.organizationUnits,
    required this.groups,
    required this.contacts,
    required this.onRefresh,
    required this.loadOrganizationContacts,
    required this.loadGroupMembers,
    super.key,
  });

  final bool contactsAvailable;
  final WeComDirectoryEditor? directoryEditor;
  final List<OrgUnit> organizationUnits;
  final List<OfflineConversation> groups;
  final List<DirectoryContact> contacts;
  final Future<void> Function() onRefresh;
  final Future<List<DirectoryContact>> Function(String organizationUnitId)
      loadOrganizationContacts;
  final Future<List<OfflineConversationMember>> Function(String groupId)
      loadGroupMembers;

  @override
  Widget build(BuildContext context) {
    if (!contactsAvailable) {
      return _ContactsState(
        onRefresh: onRefresh,
        icon: Icons.storage_outlined,
        label: '未选择联系人数据',
      );
    }
    if (contacts.isEmpty && organizationUnits.isEmpty && groups.isEmpty) {
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
        itemCount: contacts.length +
            (organizationUnits.isEmpty ? 0 : 1) +
            (groups.isEmpty ? 0 : 1),
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
                      directoryEditor: directoryEditor,
                      onChanged: onRefresh,
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
          final groupIndex = organizationUnits.isEmpty ? 0 : 1;
          if (groups.isNotEmpty && index == groupIndex) {
            return Material(
              color: Colors.white,
              child: ListTile(
                key: const Key('group-directory'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => GroupDirectoryPage(
                      groups: groups,
                      loadMembers: loadGroupMembers,
                    ),
                  ),
                ),
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFEAF1F8),
                  child: Icon(
                    Icons.groups_outlined,
                    color: Color(0xFF356A98),
                  ),
                ),
                title: const Text(
                  '群聊',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('${groups.length} 个群聊'),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            );
          }
          final contactIndex = index -
              (organizationUnits.isEmpty ? 0 : 1) -
              (groups.isEmpty ? 0 : 1);
          return _contactTile(
            context,
            contacts[contactIndex],
            directoryEditor: directoryEditor,
            onChanged: onRefresh,
          );
        },
      ),
    );
  }
}

class ContactDetailPage extends StatefulWidget {
  const ContactDetailPage({
    required this.contact,
    required this.directoryEditor,
    required this.onChanged,
    super.key,
  });

  final DirectoryContact contact;
  final WeComDirectoryEditor? directoryEditor;
  final Future<void> Function() onChanged;

  @override
  State<ContactDetailPage> createState() => _ContactDetailPageState();
}

class _ContactDetailPageState extends State<ContactDetailPage> {
  late DirectoryContact _contact;

  @override
  void initState() {
    super.initState();
    _contact = widget.contact;
  }

  @override
  Widget build(BuildContext context) {
    final contact = _contact;
    final summary = _contactSummary(contact, includeAccount: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('联系人详情'),
        actions: [
          if (widget.directoryEditor != null)
            IconButton(
              key: const Key('edit-contact'),
              tooltip: '编辑联系人',
              onPressed: _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
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

  Future<void> _edit() async {
    final nameController = TextEditingController(text: _contact.displayName);
    final jobController = TextEditingController(text: _contact.jobTitle ?? '');
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑联系人'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('contact-display-name'),
              controller: nameController,
              decoration: const InputDecoration(labelText: '显示名'),
            ),
            TextField(
              key: const Key('contact-job-title'),
              controller: jobController,
              decoration: const InputDecoration(labelText: '职位'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('save-contact'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (submitted != true || !mounted) {
      nameController.dispose();
      jobController.dispose();
      return;
    }
    final displayName = nameController.text.trim();
    final jobTitle = jobController.text.trim();
    nameController.dispose();
    jobController.dispose();
    if (displayName.isEmpty) {
      _showMessage('显示名不能为空');
      return;
    }
    final previous = _contact;
    try {
      final edit = await widget.directoryEditor!.updateContact(
        contactId: int.parse(previous.id),
        displayName: displayName,
        jobTitle: jobTitle,
        departmentId: int.tryParse(previous.organizationUnitId ?? ''),
      );
      await widget.onChanged();
      if (!mounted) {
        return;
      }
      setState(() {
        _contact = DirectoryContact(
          id: previous.id,
          displayName: displayName,
          account: previous.account,
          organizationName: previous.organizationName,
          organizationUnitId: previous.organizationUnitId,
          departmentName: previous.departmentName,
          jobTitle: jobTitle.isEmpty ? null : jobTitle,
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('联系人已保存'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undo(edit, previous),
          ),
        ),
      );
    } on WeComDirectoryNoChangesException {
      _showMessage('没有需要保存的更改');
    } catch (_) {
      _showMessage('联系人保存失败');
    }
  }

  Future<void> _undo(
    WeComDirectoryEdit edit,
    DirectoryContact previous,
  ) async {
    try {
      await widget.directoryEditor!.undo(edit);
      await widget.onChanged();
      if (mounted) {
        setState(() => _contact = previous);
        _showMessage('已撤销联系人修改');
      }
    } catch (_) {
      if (mounted) {
        _showMessage('撤销失败');
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class OrganizationDirectoryPage extends StatefulWidget {
  const OrganizationDirectoryPage({
    required this.organizationUnits,
    required this.loadContacts,
    required this.directoryEditor,
    required this.onChanged,
    super.key,
  });

  final List<OrgUnit> organizationUnits;
  final Future<List<DirectoryContact>> Function(String organizationUnitId)
      loadContacts;
  final WeComDirectoryEditor? directoryEditor;
  final Future<void> Function() onChanged;

  @override
  State<OrganizationDirectoryPage> createState() =>
      _OrganizationDirectoryPageState();
}

class _OrganizationDirectoryPageState extends State<OrganizationDirectoryPage> {
  late List<OrgUnit> _units;

  @override
  void initState() {
    super.initState();
    _units = widget.organizationUnits;
  }

  @override
  Widget build(BuildContext context) {
    final unitIds = _units.map((unit) => unit.id).toSet();
    final roots = _units
        .where(
          (unit) => unit.parentId == null || !unitIds.contains(unit.parentId),
        )
        .toList(growable: false);
    final visibleRoots = roots.isEmpty ? _units : roots;
    return Scaffold(
      appBar: AppBar(title: const Text('组织架构')),
      body: ListView.separated(
        itemCount: visibleRoots.length,
        separatorBuilder: (context, index) => const Divider(indent: 64),
        itemBuilder: (context, index) => _departmentTile(
          context,
          visibleRoots[index],
          _units,
          widget.loadContacts,
          directoryEditor: widget.directoryEditor,
          onChanged: widget.onChanged,
          onDepartmentChanged: _replaceDepartment,
        ),
      ),
    );
  }

  void _replaceDepartment(OrgUnit updated) {
    setState(() {
      _units = [
        for (final unit in _units)
          if (unit.id == updated.id) updated else unit,
      ];
    });
  }
}

class _DepartmentDirectoryPage extends StatefulWidget {
  const _DepartmentDirectoryPage({
    required this.department,
    required this.organizationUnits,
    required this.loadContacts,
    required this.directoryEditor,
    required this.onChanged,
    required this.onDepartmentChanged,
  });

  final OrgUnit department;
  final List<OrgUnit> organizationUnits;
  final Future<List<DirectoryContact>> Function(String organizationUnitId)
      loadContacts;
  final WeComDirectoryEditor? directoryEditor;
  final Future<void> Function() onChanged;
  final ValueChanged<OrgUnit> onDepartmentChanged;

  @override
  State<_DepartmentDirectoryPage> createState() =>
      _DepartmentDirectoryPageState();
}

class _DepartmentDirectoryPageState extends State<_DepartmentDirectoryPage> {
  late Future<List<DirectoryContact>> _contacts;
  late OrgUnit _department;
  late List<OrgUnit> _units;

  @override
  void initState() {
    super.initState();
    _department = widget.department;
    _units = widget.organizationUnits;
    _contacts = widget.loadContacts(_department.id);
  }

  @override
  Widget build(BuildContext context) {
    final children = _units
        .where((unit) => unit.parentId == _department.id)
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _department.name.isEmpty ? '未命名部门' : _department.name,
        ),
        actions: [
          if (widget.directoryEditor != null)
            IconButton(
              key: const Key('edit-department'),
              tooltip: '编辑部门',
              onPressed: _renameDepartment,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
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
                    _units,
                    widget.loadContacts,
                    directoryEditor: widget.directoryEditor,
                    onChanged: widget.onChanged,
                    onDepartmentChanged: _replaceDepartment,
                  ),
                if (contacts.isNotEmpty)
                  const _DirectorySectionHeader(label: '成员'),
                for (final contact in contacts)
                  _contactTile(
                    context,
                    contact,
                    directoryEditor: widget.directoryEditor,
                    onChanged: _reload,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _reload() async {
    setState(() {
      _contacts = widget.loadContacts(_department.id);
    });
    await _contacts;
  }

  Future<void> _renameDepartment() async {
    final controller = TextEditingController(text: _department.name);
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑部门'),
        content: TextField(
          key: const Key('department-name'),
          controller: controller,
          decoration: const InputDecoration(labelText: '部门名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('save-department'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (submitted != true || !mounted) {
      controller.dispose();
      return;
    }
    final name = controller.text.trim();
    controller.dispose();
    if (name.isEmpty) {
      _showMessage('部门名称不能为空');
      return;
    }
    final previous = _department;
    try {
      final edit = await widget.directoryEditor!.renameDepartment(
        departmentId: int.parse(previous.id),
        name: name,
      );
      await widget.onChanged();
      if (!mounted) {
        return;
      }
      final updated = OrgUnit(
        id: previous.id,
        name: name,
        parentId: previous.parentId,
        sortOrder: previous.sortOrder,
      );
      _replaceDepartment(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('部门已保存'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undoDepartment(edit, previous),
          ),
        ),
      );
    } on WeComDirectoryNoChangesException {
      _showMessage('没有需要保存的更改');
    } catch (_) {
      _showMessage('部门保存失败');
    }
  }

  Future<void> _undoDepartment(
    WeComDirectoryEdit edit,
    OrgUnit previous,
  ) async {
    try {
      await widget.directoryEditor!.undo(edit);
      await widget.onChanged();
      if (mounted) {
        _replaceDepartment(previous);
        _showMessage('已撤销部门修改');
      }
    } catch (_) {
      if (mounted) {
        _showMessage('撤销失败');
      }
    }
  }

  void _replaceDepartment(OrgUnit updated) {
    setState(() {
      _units = [
        for (final unit in _units)
          if (unit.id == updated.id) updated else unit,
      ];
      if (_department.id == updated.id) {
        _department = updated;
      }
    });
    widget.onDepartmentChanged(updated);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
      loadContacts, {
  required WeComDirectoryEditor? directoryEditor,
  required Future<void> Function() onChanged,
  required ValueChanged<OrgUnit> onDepartmentChanged,
}) {
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
            directoryEditor: directoryEditor,
            onChanged: onChanged,
            onDepartmentChanged: onDepartmentChanged,
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

Widget _contactTile(
  BuildContext context,
  DirectoryContact contact, {
  required WeComDirectoryEditor? directoryEditor,
  required Future<void> Function() onChanged,
}) {
  final summary = _contactSummary(contact);
  return Material(
    color: Colors.white,
    child: ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ContactDetailPage(
            contact: contact,
            directoryEditor: directoryEditor,
            onChanged: onChanged,
          ),
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
