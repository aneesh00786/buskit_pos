// Phase 6ZA — the sales screen answers a desktop quit request (Cmd+Q / closing
// the last window): refused, with the reason shown, while a cart operation
// (e.g. a checkout) is in flight; allowed once nothing is running.
import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:buskit_pos/core/desktop/exit_guard.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

void main() {
  testWidgets('quit is refused while a cart operation runs, and allowed afterwards', (tester) async {
    final h = PageHarness();
    final gate = Completer<CartSale>();
    h.carts.onAdd = (_) => gate.future;
    await pumpProductsPage(tester, h);

    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit, reason: 'nothing running');

    await tester.tap(find.text('Add').first);
    await tester.pump();
    expect(h.cart.isMutating, isTrue);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    await tester.pump();
    expect(find.text(exitBlockedMessage), findsOneWidget);

    gate.complete(CartSaleFactory.sale(items: [lineJson(id: 1, name: 'Tea')], total: 112));
    await tester.pumpAndSettle();
    expect(h.cart.isMutating, isFalse);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
  });
}
