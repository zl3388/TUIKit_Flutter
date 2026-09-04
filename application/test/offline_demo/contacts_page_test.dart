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
}

Widget _testApp({
  bool contactsAvailable = true,
  List<OrgUnit> organizationUnits = const [],
  required List<DirectoryContact> contacts,
  Future<List<DirectoryContact>> Function(String organizationUnitId)?
      loadOrganizationContacts,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ContactsPage(
        contactsAvailable: contactsAvailable,
        organizationUnits: organizationUnits,
        contacts: contacts,
        onRefresh: _refresh,
        loadOrganizationContacts:
            loadOrganizationContacts ?? _loadNoOrganizationContacts,
      ),
    ),
  );
}

Future<void> _refresh() async {}

Future<List<DirectoryContact>> _loadNoOrganizationContacts(String id) async =>
    const [];
