// Phase 6S — the payment screen when completion is refused with
// POS_DRAFT_SYNCED_OFFLINE: the cashier is told the sale is already recorded
// through offline sync, Complete Sale / Retry payment are gone (no re-send),
// and the duplicate draft can be cancelled only after confirming — through
// the existing cancel flow. Dismissing keeps the draft; a failed or
// unconfirmed cancel keeps it open and recoverable.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

CartSale sale112({int version = 2, String status = 'draft'}) => CartSale.fromJson(
  saleJson(
    id: 7,
    version: version,
    status: status,
    items: [lineJson(id: 1, quantity: 2, name: 'Tea'), lineJson(id: 2, variationId: 43, name: 'Salt')],
    subtotal: 112,
    total: 112,
  ),
)!;

ApiException syncedOffline() => apiError(
  409,
  message: 'This cart was already recorded as an offline sale. Cancel this draft instead of completing it.',
  code: PosErrorCodes.draftSyncedOffline,
);

Future<PageHarness> pumpWithCart(WidgetTester tester) async {
  final h = PageHarness();
  h.carts.onAdd = (_) async => sale112();
  h.carts.onGet = (_) async => sale112();
  await pumpProductsPage(tester, h, width: 1400, height: 900);
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
  return h;
}

/// Only inside the payment dialog (the cart panel behind it shows cart errors too).
Finder inModal(Finder f) => find.descendant(of: find.byType(Dialog), matching: f);

Finder get completeBtn => find.widgetWithText(FilledButton, 'Complete Sale');
Finder get cancelDraftBtn => find.byKey(const Key('cancel-duplicate-draft'));

/// Opens Pay, pays exact cash and gets the conflict.
Future<PageHarness> refused(WidgetTester tester) async {
  final h = await pumpWithCart(tester);
  h.carts.onComplete = (_) async => throw syncedOffline();
  await tester.tap(find.text('Pay'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Exact'));
  await tester.pump();
  await tester.tap(completeBtn);
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('the cashier is told why, Complete Sale / Retry payment are replaced by "Cancel duplicate draft"; nothing is re-sent', (tester) async {
    final h = await refused(tester);
    expect(find.textContaining('already been recorded through offline sync'), findsOneWidget);
    expect(find.textContaining('cannot be completed again'), findsOneWidget);
    expect(find.textContaining('safe to retry'), findsNothing);
    expect(find.text('Retry payment'), findsNothing);
    expect(completeBtn, findsNothing);
    expect(cancelDraftBtn, findsOneWidget);
    expect(h.carts.completeCalls, hasLength(1));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(h.carts.completeCalls, hasLength(1), reason: 'never retried automatically');
    expect(h.cart.sale?.id, 7);
  });

  testWidgets('cancelling asks for confirmation; "Keep draft" leaves the draft unchanged and sends nothing', (tester) async {
    final h = await refused(tester);
    await tester.tap(cancelDraftBtn);
    await tester.pumpAndSettle();
    expect(find.text('Cancel the duplicate draft?'), findsOneWidget);
    expect(find.textContaining('the offline sale already recorded is kept'), findsOneWidget);
    await tester.tap(find.text('Keep draft'));
    await tester.pumpAndSettle();
    expect(h.carts.cancelCalls, isEmpty);
    expect(h.cart.sale?.id, 7);
    expect(h.cart.sale?.isDraft, isTrue);
    expect(cancelDraftBtn, findsOneWidget, reason: 'still on the payment screen, still blocked');
  });

  testWidgets('confirmed: the existing cancel is called once, the screen closes and says the offline sale is unchanged', (tester) async {
    final h = await refused(tester);
    await tester.tap(cancelDraftBtn);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel draft'));
    await tester.pumpAndSettle();
    expect(h.carts.cancelCalls.map((c) => [c.saleId, c.expectedVersion]).toList(), [
      [7, 2],
    ]);
    expect(h.cart.sale, isNull);
    expect(find.byKey(const Key('cancel-duplicate-draft')), findsNothing);
    expect(find.textContaining('Duplicate draft #7 cancelled. The offline sale already recorded is unchanged.'), findsOneWidget);
    expect(h.carts.completeCalls, hasLength(1));
  });

  testWidgets('a refused cancellation is shown and the draft is NOT shown as cancelled', (tester) async {
    final h = await refused(tester);
    h.carts.onCancel = (_) async => throw apiError(409, message: 'This sale has a provider payment in progress or captured');
    await tester.tap(cancelDraftBtn);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel draft'));
    await tester.pumpAndSettle();
    expect(inModal(find.textContaining('can no longer be voided')), findsOneWidget);
    expect(h.cart.sale?.id, 7);
    expect(h.cart.sale?.isDraft, isTrue);
    expect(cancelDraftBtn, findsOneWidget, reason: 'recoverable: the cashier can try again');
    expect(find.textContaining('cancelled'), findsNothing);
  });

  testWidgets('an unknown cancel outcome is reconciled with the server before anything is shown as cancelled', (tester) async {
    final h = await refused(tester);
    h.carts.onCancel = (_) async => throw const ApiException(kind: ApiErrorKind.timeout, message: 'The server took too long to respond. Please try again.');
    h.carts.onGet = (_) async => sale112(); // the server still has the draft
    await tester.tap(cancelDraftBtn);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel draft'));
    await tester.pumpAndSettle();
    expect(inModal(find.textContaining('Could not confirm that the duplicate draft was cancelled')), findsOneWidget);
    expect(h.cart.sale?.isDraft, isTrue);
    expect(cancelDraftBtn, findsOneWidget);

    h.carts.onGet = (_) async => sale112(version: 3, status: 'canceled'); // the cancel had reached it
    await tester.tap(cancelDraftBtn);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel draft'));
    await tester.pumpAndSettle();
    expect(h.cart.sale, isNull);
    expect(find.textContaining('Duplicate draft #7 cancelled'), findsOneWidget);
    expect(h.carts.completeCalls, hasLength(1));
  });

  testWidgets('a network failure still offers the existing safe "Retry payment" (same key), not the cancel action', (tester) async {
    final h = await pumpWithCart(tester);
    h.carts.onComplete = (_) async => throw const ApiException(kind: ApiErrorKind.network, message: 'Cannot reach the server. Check your connection and try again.');
    await tester.tap(find.text('Pay'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exact'));
    await tester.pump();
    await tester.tap(completeBtn);
    await tester.pumpAndSettle();
    expect(find.text('Retry payment'), findsOneWidget);
    expect(cancelDraftBtn, findsNothing);
    final key = h.carts.completeCalls.single.key;
    h.carts.onComplete = (c) async => CompletedSale.fromJson(completedJson(payments: c.payments))!;
    await tester.tap(find.text('Retry payment'));
    await tester.pumpAndSettle();
    expect(h.carts.completeCalls.map((c) => c.key).toList(), [key, key]);
  });

  testWidgets('another 409 keeps its existing handling: message shown, Complete Sale still available, no cancel action', (tester) async {
    final h = await pumpWithCart(tester);
    h.carts.onComplete = (_) async => throw apiError(409, message: 'Sale has been modified since you last read it', data: {'current_version': 9});
    await tester.tap(find.text('Pay'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exact'));
    await tester.pump();
    await tester.tap(completeBtn);
    await tester.pumpAndSettle();
    expect(find.textContaining('changed elsewhere and has been refreshed'), findsOneWidget);
    expect(completeBtn, findsOneWidget);
    expect(cancelDraftBtn, findsNothing);
    expect(h.carts.completeCalls, hasLength(1));
  });
}
