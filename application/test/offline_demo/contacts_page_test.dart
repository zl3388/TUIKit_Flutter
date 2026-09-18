import 'package:application/src/offline_demo/domain/models.dart';
import 'package:application/src/offline_demo/presentation/contacts_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows an explicit unavailable state without legacy fallback',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        contactsAvailable: false,
        contacts: const [],
      ),
    );

    expect(find.text('未选择联系人数据'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('shows only confirmed WeCom contact fields', (tester) async {
    await tester.pumpWidget(
      _testApp(
        contacts: const [
          DirectoryContact(
            id: '1688001',
            displayName: 'Directory contact',
            account: 'directory.account',
            organizationName: 'Example Corp',
            jobTitle: 'Engineer',
          ),
        ],
      ),
    );

    expect(find.text('Directory contact'), findsOneWidget);
    expect(
      find.text('Example Corp · Engineer · directory.account'),
      findsOneWidget,
    );

    await tester.tap(find.text('Directory contact'));
    await tester.pumpAndSettle();

    expect(find.text('联系人详情'), findsOneWidget);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('directory.account'), findsOneWidget);
    expect(find.text('企业'), findsOneWidget);
    expect(find.text('Example Corp'), findsWidgets);
    expect(find.text('职位'), findsOneWidget);
    expect(find.text('Engineer'), findsWidgets);
    expect(find.byKey(const Key('edit-contact')), findsNothing);
    expect(find.byIcon(Icons.phone_outlined), findsNothing);
    expect(find.byIcon(Icons.email_outlined), findsNothing);
  });

  testWidgets('drills into departments and opens a direct member',
      (tester) async {
    const member = DirectoryContact(
      id: '2',
      displayName: 'Department member',
      departmentName: 'Root department',
      jobTitle: 'Lead',
    );
    await tester.pumpWidget(
      _testApp(
        organizationUnits: const [
          OrgUnit(
            id: 'root',
            name: 'Root department',
            sortOrder: 10,
          ),
          OrgUnit(
            id: 'child',
            name: 'Child department',
            parentId: 'root',
            sortOrder: 20,
          ),
        ],
        contacts: const [],
        loadOrganizationContacts: (id) async =>
            id == 'root' ? const [member] : const [],
      ),
    );

    expect(find.text('组织架构'), findsOneWidget);
    expect(find.text('2 个部门'), findsOneWidget);
    await tester.tap(find.byKey(const Key('organization-directory')));
    await tester.pumpAndSettle();

    expect(find.text('Root department'), findsOneWidget);
    expect(find.text('Child department'), findsNothing);
    await tester.tap(find.byKey(const Key('department-root')));
    await tester.pumpAndSettle();

    expect(find.text('下级部门'), findsOneWidget);
    expect(find.text('Child department'), findsOneWidget);
    expect(find.text('成员'), findsOneWidget);
    expect(find.text('Department member'), findsOneWidget);
    await tester.tap(find.text('Department member'));
    await tester.pumpAndSettle();

    expect(find.text('联系人详情'), findsOneWidget);
    expect(find.text('部门'), findsOneWidget);
    expect(find.text('Root department'), findsWidgets);
    expect(find.text('职位'), findsOneWidget);
    expect(find.text('Lead'), findsWidgets);
  });

  testWidgets('lists groups and shows only verified member roles',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        contacts: const [],
        groups: const [
          OfflineConversation(
            id: 'R:100',
            type: 'group',
            title: 'Project group',
            lastMessagePreview: 'Latest message',
            lastMessageAt: null,
            draftText: '',
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
          ),
        ],
        loadGroupMembers: (id) async => const [
          OfflineConversationMember(
            conversationId: 'R:100',
            userId: '1',
            displayName: 'Group admin',
            isAdmin: true,
            gagType: 0,
          ),
          OfflineConversationMember(
            conversationId: 'R:100',
            userId: '2',
            displayName: 'Group member',
            isAdmin: false,
            gagType: 2,
          ),
        ],
      ),
    );

    expect(find.text('群聊'), findsOneWidget);
    expect(find.text('1 个群聊'), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-directory')));
    await tester.pumpAndSettle();

    expect(find.text('Project group'), findsOneWidget);
    expect(find.text('Latest message'), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-R:100')));
    await tester.pumpAndSettle();

    expect(find.text('成员 · 2'), findsOneWidget);
    expect(find.text('Group admin'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('Group member'), findsOneWidget);
    expect(find.text('禁言'), findsNothing);
    expect(find.text('群主'), findsNothing);
  });
}

Widget _testApp({
  bool contactsAvailable = true,
  List<OrgUnit> organizationUnits = const [],
  List<OfflineConversation> groups = const [],
  required List<DirectoryContact> contacts,
  Future<List<DirectoryContact>> Function(String organizationUnitId)?
      loadOrganizationContacts,
  Future<List<OfflineConversationMember>> Function(String groupId)?
      loadGroupMembers,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ContactsPage(
        contactsAvailable: contactsAvailable,
        directoryEditor: null,
        organizationUnits: organizationUnits,
        groups: groups,
        contacts: contacts,
        onRefresh: _refresh,
        loadOrganizationContacts:
            loadOrganizationContacts ?? _loadNoOrganizationContacts,
        loadGroupMembers: loadGroupMembers ?? _loadNoGroupMembers,
      ),
    ),
  );
}

Future<void> _refresh() async {}

Future<List<DirectoryContact>> _loadNoOrganizationContacts(String id) async =>
    const [];

Future<List<OfflineConversationMember>> _loadNoGroupMembers(String id) async =>
    const [];
