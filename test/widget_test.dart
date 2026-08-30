import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/widgets/common.dart';

void main() {
  testWidgets('StatusMessage renders its title', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: StatusMessage(title: 'Hello', icon: Icons.check)),
    ));
    expect(find.text('Hello'), findsOneWidget);
  });
}
