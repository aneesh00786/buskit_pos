// Phase 16A — the cart header ("Current Sale", item count, voice-bill mic,
// "Clear all") on small phones and with large accessibility text. The mic
// (Phase 13C-C) plus a 200%-scaled "Clear all" no longer fit beside the
// title on a 320 px phone: the header must wrap instead of overflowing, keep
// the title readable and keep every control tappable — and look exactly as
// before when there is room.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pump_page.dart';
import '../checkout/pay_modal_test.dart' show pumpWithCart;

final mic = find.byKey(const Key('cart-voice-bill'));
final clearAll = find.widgetWithText(TextButton, 'Clear all');
final title = find.text('Current Sale');

/// Opens the (empty) cart sheet from the phone's bottom bar.
Future<void> openEmptyCart(WidgetTester tester, double width, double height, double scale) async {
  final h = PageHarness();
  await pumpProductsPage(tester, h, width: width, height: height, textScale: scale);
  await tester.tap(find.byIcon(Icons.shopping_cart_outlined));
  await tester.pumpAndSettle();
}

void expectOnScreen(WidgetTester tester, Finder f, double width, String what) {
  expect(f.hitTestable(), findsOneWidget, reason: '$what tappable / visible');
  final r = tester.getRect(f);
  expect(r.left, greaterThanOrEqualTo(0), reason: '$what $r');
  expect(r.right, lessThanOrEqualTo(width), reason: '$what $r');
}

void main() {
  for (final (w, hgt, scale) in [(320.0, 640.0, 2.0), (320.0, 640.0, 1.5), (360.0, 640.0, 2.0)]) {
    testWidgets('${w.toInt()}x${hgt.toInt()} at ${(scale * 100).toInt()}% text, EMPTY cart: no overflow; title readable; mic and Clear all on screen', (tester) async {
      await openEmptyCart(tester, w, hgt, scale);
      expect(tester.takeException(), isNull);
      expectOnScreen(tester, mic, w, 'mic');
      expectOnScreen(tester, clearAll, w, 'Clear all');
      expectOnScreen(tester, title, w, 'title');
      // Readable: the title keeps (at least most of) its width — not squeezed to nothing.
      expect(tester.getSize(title).width, greaterThan(w * 0.5), reason: 'title width');
      // Nothing overlaps.
      expect(tester.getRect(mic).overlaps(tester.getRect(clearAll)), isFalse);
      expect(tester.getRect(title).overlaps(tester.getRect(mic)), isFalse);
      // The mic still starts a voice bill.
      await tester.tap(mic);
      await tester.pump();
      expect(find.byKey(const Key('cart-voice-bill')), findsWidgets);
    });

    testWidgets('${w.toInt()}x${hgt.toInt()} at ${(scale * 100).toInt()}% text, cart WITH items: no overflow; Clear all and Pay reachable', (tester) async {
      await pumpWithCart(tester, width: w, height: hgt, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(mic, findsNothing, reason: 'mic only on an empty cart');
      expectOnScreen(tester, clearAll, w, 'Clear all');
      expect(find.text('Pay').hitTestable(), findsOneWidget);
    });
  }

  // Widget tests draw every character as a full-width square, so this needs
  // a wider screen than a real phone does for the same content to fit.
  testWidgets('when there is room (100% text): unchanged single-line header — title left, mic and Clear all right', (tester) async {
    await openEmptyCart(tester, 560, 800, 1.0);
    expect(tester.takeException(), isNull);
    final t = tester.getRect(title), m = tester.getRect(mic), c = tester.getRect(clearAll);
    expect((t.center.dy - c.center.dy).abs(), lessThan(4), reason: 'one line: $t / $c');
    expect((m.center.dy - c.center.dy).abs(), lessThan(4));
    expect(t.right, lessThan(m.left));
    expect(m.right, lessThanOrEqualTo(c.left + 0.01));
    expect(c.right, greaterThan(560 - 60), reason: 'Clear all at the right edge: $c');
  });
}
