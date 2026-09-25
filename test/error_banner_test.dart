import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/widgets/common.dart';

void main() {
  testWidgets('ErrorBanner shows the failure text and dismisses', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ErrorBanner(
          message: 'GET /api/v1/cron failed (404) — Not Found',
          log: const [
            'GET /api/v1/cron failed (404) — Not Found',
            'load sessions: could not reach http://192.168.1.146:9130',
          ],
          onDismiss: () => dismissed = true,
        ),
      ),
    ));

    expect(find.textContaining('failed (404)'), findsOneWidget);
    expect(find.text('Log (2)'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, isTrue);
  });

  testWidgets('ErrorBanner opens the recent-failure log', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ErrorBanner(
          message: 'boom',
          log: const ['boom', 'older boom'],
          onDismiss: () {},
        ),
      ),
    ));

    await tester.tap(find.text('Log (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Recent failures'), findsOneWidget);
    expect(find.text('older boom'), findsOneWidget);
  });

  testWidgets('a single failure shows no Log button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ErrorBanner(message: 'boom', log: const ['boom'], onDismiss: () {}),
      ),
    ));
    expect(find.textContaining('Log ('), findsNothing);
  });
}
