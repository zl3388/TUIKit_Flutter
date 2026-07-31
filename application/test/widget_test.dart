import 'package:application/src/offline_demo/presentation/offline_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offline theme renders a compact operational surface',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OfflineTheme.light,
        home: const Scaffold(
          body: ListTile(
            leading: Icon(Icons.chat_bubble_outline_rounded),
            title: Text('消息'),
          ),
        ),
      ),
    );

    expect(find.text('消息'), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
    expect(Theme.of(tester.element(find.text('消息'))).useMaterial3, isTrue);
  });
}
