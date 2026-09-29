import 'package:buskit_pos/features/promotions/ui/promotions_unavailable_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'states plainly that promotions are unavailable, with no Apply-style action',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showPromotionsUnavailable(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Promotions are not available from POS yet. Every sale total is calculated by the server with no discount applied.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Apply'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not available'), findsNothing);
    },
  );

  testWidgets('fits at 200% text scale without overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showPromotionsUnavailable(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
