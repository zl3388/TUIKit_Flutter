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
}

Widget _testApp({
  bool contactsAvailable = true,
  required List<DirectoryContact> contacts,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ContactsPage(
        contactsAvailable: contactsAvailable,
        contacts: contacts,
        onRefresh: _refresh,
      ),
    ),
  );
}

Future<void> _refresh() async {}
