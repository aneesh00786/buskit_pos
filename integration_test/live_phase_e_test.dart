// Phase E-E — LIVE Flutter run against the local Phase E backend
// (http://localhost:3000 -> disposable busskit_phase_e_test). Completes the
// eight E-E sales through the real UI and prints, per sale, what the cart,
// the completed sale and the receipt (text / thermal / PDF) showed, as
// `PE|<json>` lines for the host-side comparison. Nothing is mocked.
//
// Test-only credentials come from --dart-define=PE_CREDS=<json> (never
// printed). Never point this at a shared or production backend.
//
//   flutter test integration_test/live_phase_e_test.dart -d macos --dart-define=PE_CREDS=...
import 'dart:convert';

import 'package:buskit_pos/app.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/products/ui/product_card.dart';
import 'package:buskit_pos/features/products/ui/products_page.dart';
import 'package:buskit_pos/features/receipt/data/receipt_pdf.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:buskit_pos/features/receipt/printing/escpos_receipt_renderer.dart';
import 'package:buskit_pos/features/receipt/printing/printer_adapter.dart';
import 'package:buskit_pos/features/receipt/ui/receipt_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

// The E-G run points the till at the local fault-injection proxy instead.
const baseUrl = String.fromEnvironment('PE_BASE_URL', defaultValue: 'http://localhost:3000');
final creds = jsonDecode(const String.fromEnvironment('PE_CREDS', defaultValue: '{}')) as Map<String, dynamic>;

Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20), String? reason}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 150));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visible = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().where((t) => t.trim().isNotEmpty).take(30).join(' | ');
  fail('Timed out waiting for ${reason ?? finder.toString()}. Visible text: $visible');
}

Future<void> settle(WidgetTester tester) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  await tester.pump(const Duration(milliseconds: 300));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 150));
    final busy = find.byType(CircularProgressIndicator).evaluate().isNotEmpty || find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
    if (!busy) return;
  }
  final ind = [...find.byType(CircularProgressIndicator).evaluate(), ...find.byType(LinearProgressIndicator).evaluate()];
  final owners = ind.map((e) {
    final chain = <String>[];
    e.visitAncestorElements((a) {
      final n = a.widget.runtimeType.toString();
      if (!n.startsWith('_') && chain.length < 12 && !['Padding', 'SizedBox', 'Center', 'Align', 'Builder', 'Semantics', 'KeyedSubtree', 'Expanded', 'Flexible', 'Column', 'Row', 'DefaultTextStyle', 'MediaQuery', 'Container'].contains(n)) chain.add(n);
      return chain.length < 12;
    });
    return chain.join('<');
  }).join(' || ');
  final visible = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().where((t) => t.trim().isNotEmpty).take(60).join(' | ');
  fail('Still loading after 20s. Indicators: $owners. Visible: $visible');
}

Future<void> tapIt(WidgetTester tester, Finder f) async {
  // ignore: avoid_print
  print('PESTEP|tap ${f.describeMatch(Plurality.one)}');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.ensureVisible(f.first);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(f.first);
  await tester.pump(const Duration(milliseconds: 300));
}

CartController cartOf(WidgetTester tester) => Provider.of<CartController>(tester.element(find.byType(ProductsPage)), listen: false);

Future<void> signIn(WidgetTester tester, String till, String staff) async {
  final dev = creds['devices'][till] as Map<String, dynamic>;
  await tester.pumpWidget(PosApp(key: UniqueKey(), tokenStore: MemoryTokenStore(), baseUrl: baseUrl));
  await pumpUntil(tester, find.widgetWithText(TextField, 'Device identifier'), reason: 'device login');
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
  await tester.enterText(find.widgetWithText(TextField, 'Device identifier'), dev['identifier'] as String);
  await tester.enterText(find.widgetWithText(TextField, 'Device secret'), dev['secret'] as String);
  await tapIt(tester, find.widgetWithText(FilledButton, 'Continue'));
  await pumpUntil(tester, find.widgetWithText(TextField, 'Staff ID'), reason: 'staff login');
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
  await tester.enterText(find.widgetWithText(TextField, 'Staff ID'), staff);
  await tester.enterText(find.widgetWithText(TextField, 'PIN'), creds['pins'][staff] as String);
  await tapIt(tester, find.widgetWithText(FilledButton, 'Sign in'));
  await pumpUntil(tester, find.widgetWithText(TextField, 'Opening cash amount'), reason: 'open shift');
  await tester.enterText(find.widgetWithText(TextField, 'Opening cash amount'), '0');
  await tapIt(tester, find.widgetWithText(FilledButton, 'Open shift'));
  await pumpUntil(tester, find.byType(ProductsPage), reason: '$staff at the till');
  await settle(tester);
}

Future<void> addProduct(WidgetTester tester, String name, int pv) async {
  final before = cartOf(tester).sale?.items.fold<double>(0, (a, l) => a + l.quantity) ?? 0;
  final search = find.byKey(const Key('product-search'));
  await tester.tap(search.hitTestable().first);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.enterText(search.hitTestable().first, '');
  await tester.pump(const Duration(milliseconds: 400));
  await tester.enterText(search.hitTestable().first, name);
  await pumpUntil(tester, find.text(name), reason: 'search result $name');
  await settle(tester);
  // Only the card for this product (the unfiltered list may still be showing).
  final card = find.ancestor(of: find.text(name), matching: find.byWidgetPredicate((w) => w is ProductCard || w is ProductListTile)).first;
  await tapIt(tester, find.descendant(of: card, matching: find.widgetWithText(FilledButton, 'Add')));
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 150));
    final now = cartOf(tester).sale?.items.fold<double>(0, (a, l) => a + l.quantity) ?? 0;
    if (now > before && !cartOf(tester).isMutating) break;
  }
  await settle(tester);
  expect(cartOf(tester).sale!.items.any((l) => l.productVariationId == pv), isTrue, reason: '$name added');
}

int lineId(WidgetTester tester, int pv) => cartOf(tester).sale!.items.firstWhere((l) => l.productVariationId == pv).id;

Future<void> openLine(WidgetTester tester, int pv) async {
  await tapIt(tester, find.byKey(Key('line-pricing-${lineId(tester, pv)}')));
  await pumpUntil(tester, find.byKey(const Key('line-pricing-dialog')), reason: 'line pricing dialog');
  await settle(tester);
}

Future<void> lineDiscount(WidgetTester tester, int pv, {required bool percent, required String value, required String reason}) async {
  await openLine(tester, pv);
  await pumpUntil(tester, find.byKey(const Key('line-discount-value')), reason: 'discount fields (policy loaded)');
  if (!percent) await tapIt(tester, find.descendant(of: find.byKey(const Key('line-discount-type')), matching: find.text('Fixed amount')));
  await tester.enterText(find.byKey(const Key('line-discount-value')), value);
  await tester.enterText(find.byKey(const Key('line-discount-reason')), reason);
  await tapIt(tester, find.byKey(const Key('line-discount-apply')));
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(end) && find.byKey(const Key('line-pricing-dialog')).evaluate().isNotEmpty) {
    await tester.pump(const Duration(milliseconds: 150));
  }
  expect(find.byKey(const Key('line-pricing-dialog')), findsNothing, reason: 'dialog closes after the server accepted the discount');
  await settle(tester);
}

Future<void> priceOverride(WidgetTester tester, int pv, {required String price, required String reason}) async {
  await openLine(tester, pv);
  await pumpUntil(tester, find.byKey(const Key('line-price-value')), reason: 'price fields (policy loaded)');
  await tester.enterText(find.byKey(const Key('line-price-value')), price);
  await tester.enterText(find.byKey(const Key('line-price-reason')), reason);
  await tapIt(tester, find.byKey(const Key('line-price-apply')));
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(end) && find.byKey(const Key('line-pricing-dialog')).evaluate().isNotEmpty) {
    await tester.pump(const Duration(milliseconds: 150));
  }
  expect(find.byKey(const Key('line-pricing-dialog')), findsNothing, reason: 'dialog closes after the server accepted the price');
  await settle(tester);
}

Future<void> chooseCustomer(WidgetTester tester, String search, String name) async {
  await tapIt(tester, find.text('Change'));
  await pumpUntil(tester, find.text('Customer'), reason: 'customer dialog');
  await tapIt(tester, find.text('Search'));
  await tester.enterText(find.widgetWithText(TextField, 'Search customers by name or phone'), search);
  await pumpUntil(tester, find.text(name), reason: 'customer result');
  await tapIt(tester, find.text(name).last);
  await tester.pump(const Duration(milliseconds: 500));
  final save = find.widgetWithText(FilledButton, 'Save');
  if (save.evaluate().isNotEmpty) await tapIt(tester, save);
  await settle(tester);
  expect(cartOf(tester).pendingCustomerId, isNotNull, reason: 'customer chosen');
}

Future<void> applyPromotion(WidgetTester tester, String title) async {
  await tapIt(tester, find.text('Add Promotion'));
  await pumpUntil(tester, find.text(title), reason: 'promotion listed');
  await tapIt(tester, find.text(title));
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(end) && cartOf(tester).sale?.promotion == null) {
    await tester.pump(const Duration(milliseconds: 150));
  }
  await settle(tester);
}

Future<void> redeemPoints(WidgetTester tester, String points) async {
  // With a tier discount already on the sale the loyalty row shows a summary
  // and "Change" (the last "Change": the customer row's comes first).
  final redeem = find.text('Redeem Loyalty');
  await tapIt(tester, redeem.evaluate().isNotEmpty ? redeem : find.widgetWithText(TextButton, 'Change').last);
  await pumpUntil(tester, find.widgetWithText(TextField, 'Points to redeem'), reason: 'loyalty picker');
  await tester.enterText(find.widgetWithText(TextField, 'Points to redeem'), points);
  await tapIt(tester, find.widgetWithText(FilledButton, 'Apply')); // first = Redeem Points
  await settle(tester);
  final close = find.byTooltip('Close');
  if (close.evaluate().isNotEmpty) await tapIt(tester, close);
  await settle(tester);
}

Future<void> wholeSaleDiscount(WidgetTester tester, {required String amount, required String reason}) async {
  await tapIt(tester, find.text('Add Discount'));
  await pumpUntil(tester, find.text('Amount'), reason: 'discount dialog');
  await tapIt(tester, find.text('Amount'));
  await tester.enterText(find.widgetWithText(TextField, 'Amount *'), amount);
  await tester.enterText(find.widgetWithText(TextField, 'Reason'), reason);
  await tapIt(tester, find.widgetWithText(FilledButton, 'Continue'));
  await pumpUntil(tester, find.text('Confirm discount'));
  await tapIt(tester, find.widgetWithText(FilledButton, 'Apply'));
  await settle(tester);
}

Map<String, dynamic> cartSnapshot(WidgetTester tester) {
  final s = cartOf(tester).sale!;
  return {
    'sale_id': s.id,
    'lines': [
      for (final l in s.items) {'pv': l.productVariationId, 'qty': l.quantity, 'unit': l.unitPrice, 'disc': l.discountAmount, 'total': l.lineTotal},
    ],
    'totals': {'subtotal': s.totals.subtotal, 'tax': s.totals.taxTotal, 'discount': s.totals.discountTotal, 'grand': s.totals.grandTotal},
  };
}

Future<void> payAndRecord(WidgetTester tester, String label) async {
  final cart = cartSnapshot(tester);
  // What the cart panel shows (rendered text, not just the model).
  final shown = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().where((t) => t.contains('₹') || t.startsWith('Price changed') || t.startsWith('Line discount')).toList();
  ScaffoldMessenger.of(tester.element(find.byType(ProductsPage))).clearSnackBars();
  await tester.pump(const Duration(milliseconds: 600));
  await tapIt(tester, find.widgetWithText(FilledButton, 'Pay'));
  await pumpUntil(tester, find.text('Exact'), reason: 'pay modal');
  final payShown = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().where((t) => t.contains('₹')).toList();
  await tapIt(tester, find.text('Exact'));
  await tapIt(tester, find.widgetWithText(FilledButton, 'Complete Sale'));
  await pumpUntil(tester, find.text('Sale complete'), reason: '$label completed', timeout: const Duration(seconds: 30));
  await settle(tester);
  final done = cartOf(tester).completedSale!;
  final receipt = tester.widget<ReceiptActions>(find.byType(ReceiptActions)).receipt;
  final text = receipt.toLines();
  final job = const EscPosReceiptRenderer().render(receipt, const ReceiptPrinterConfig());
  final pdf = await buildReceiptPdf(receipt);
  final completeShown = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().where((t) => t.trim().isNotEmpty).toList();
  // ignore: avoid_print
  print('PE|${jsonEncode({
    'label': label,
    'cart': cart,
    'cart_text': shown,
    'pay_text': payShown,
    'completed': {
      'id': done.id,
      'number': done.displayNumber,
      'lines': [for (final l in done.items) {'pv': l.productVariationId, 'qty': l.quantity, 'unit': l.unitPrice, 'disc': l.discountAmount, 'total': l.lineTotal}],
      'totals': {'subtotal': done.totals.subtotal, 'tax': done.totals.taxTotal, 'discount': done.totals.discountTotal, 'grand': done.totals.grandTotal},
    },
    'complete_text': completeShown,
    'receipt_text': text,
    'thermal_lines': job.lines,
    'thermal_bytes': job.bytes.length,
    'pdf_bytes': pdf.length,
    'pdf_header': String.fromCharCodes(pdf.take(5)),
  })}');
  await tapIt(tester, find.widgetWithText(FilledButton, 'New Sale'));
  await settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const tea = 9901, coffee = 9902, water = 9903;

  testWidgets(timeout: const Timeout(Duration(minutes: 8)), 'E-E: eight sales through the real till UI', (tester) async {
    expect(creds['pins'], isNotNull, reason: 'PE_CREDS not provided');
    // ignore: avoid_print
    print('PESTEP|view ${tester.view.physicalSize} dpr ${tester.view.devicePixelRatio}');

    // Senior cashier (role limit 10%).
    await signIn(tester, 'till1', 'E2E-SEN');
    await addProduct(tester, 'E2E No-Tax Water', water);
    await payAndRecord(tester, 'S1 ordinary');

    await addProduct(tester, 'E2E Exclusive Tea', tea);
    await lineDiscount(tester, tea, percent: true, value: '10', reason: 'E2E S2 dented tin');
    await payAndRecord(tester, 'S2 percentage line discount');

    await addProduct(tester, 'E2E Inclusive Coffee', coffee);
    await lineDiscount(tester, coffee, percent: false, value: '10', reason: 'E2E S3 near expiry');
    await payAndRecord(tester, 'S3 fixed line discount');

    await addProduct(tester, 'E2E Exclusive Tea', tea);
    await addProduct(tester, 'E2E Inclusive Coffee', coffee);
    await addProduct(tester, 'E2E No-Tax Water', water);
    await lineDiscount(tester, tea, percent: true, value: '5', reason: 'E2E S8 tea');
    await lineDiscount(tester, coffee, percent: false, value: '5', reason: 'E2E S8 coffee');
    await payAndRecord(tester, 'S8 several discounted lines');

    // Manager (override authority, price override).
    await signIn(tester, 'till1', 'E2E-MGR');
    await addProduct(tester, 'E2E Exclusive Tea', tea);
    await priceOverride(tester, tea, price: '150', reason: 'E2E S4 price match');
    await payAndRecord(tester, 'S4 price override');

    await addProduct(tester, 'E2E Exclusive Tea', tea);
    await priceOverride(tester, tea, price: '180', reason: 'E2E S5 price match');
    await lineDiscount(tester, tea, percent: true, value: '10', reason: 'E2E S5 damaged');
    await payAndRecord(tester, 'S5 override and line discount');

    await chooseCustomer(tester, 'E2E Gold', 'E2E Gold Customer');
    await addProduct(tester, 'E2E Exclusive Tea', tea);
    await addProduct(tester, 'E2E Exclusive Tea', tea);
    await lineDiscount(tester, tea, percent: true, value: '10', reason: 'E2E S6 bulk');
    await applyPromotion(tester, 'E2E 5% over 300');
    await redeemPoints(tester, '100');
    await payAndRecord(tester, 'S6 promotion and loyalty');

    await addProduct(tester, 'E2E No-Tax Water', water);
    await addProduct(tester, 'E2E No-Tax Water', water);
    await wholeSaleDiscount(tester, amount: '10', reason: 'E2E S7 regular');
    await payAndRecord(tester, 'S7 whole-sale discount');
  });
}
