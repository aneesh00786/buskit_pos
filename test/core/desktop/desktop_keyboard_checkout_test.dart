// Phase 6ZC — keyboard checkout on desktop tills (macOS / Windows, Dart level;
// Windows NATIVE behaviour still needs a real Windows machine). Found by
// inspection: the payment screen opened with nothing focused, and Enter in
// "Amount tendered" did nothing, so a keyboard-only cashier had to reach for
// the mouse. Now (desktop only): F4 opens payment with the amount focused,
// Enter does exactly what Complete Sale does (same guards). Android / iOS are
// unchanged (no autofocus, no Enter action). Also: no overflow at the
// configured desktop minimum window sizes.
import 'dart:async';

import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

CartSale sale112() => CartSaleFactory.sale(items: [lineJson(id: 1, quantity: 2, name: 'Tea'), lineJson(id: 2, variationId: 43, name: 'Salt')], total: 112);

Future<PageHarness> withCart(WidgetTester t, {double width = 1366, double height = 768}) async {
  final h = PageHarness();
  h.carts.onAdd = (_) async => sale112();
  h.carts.onGet = (_) async => sale112();
  await pumpProductsPage(t, h, width: width, height: height);
  await t.tap(find.text('Add').first);
  await t.pumpAndSettle();
  return h;
}

Finder get amountField => find.widgetWithText(TextField, 'Amount tendered');
bool amountFocused(WidgetTester t) {
  final focus = FocusManager.instance.primaryFocus;
  final editable = t.widget<EditableText>(find.descendant(of: amountField, matching: find.byType(EditableText)));
  return focus != null && identical(focus, editable.focusNode);
}

/// Types into the FOCUSED field through the text-input connection, as a
/// keyboard does, then presses Enter (TextInputAction.done).
Future<void> typeAndEnter(WidgetTester t, String text) async {
  t.testTextInput.updateEditingValue(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)));
  await t.pump();
  await t.testTextInput.receiveAction(TextInputAction.done);
  await t.pumpAndSettle();
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('$platform: F4 opens payment with the amount focused; typing then Enter completes once with that tender', (t) async {
      debugDefaultTargetPlatformOverride = platform;
      final h = await withCart(t);
      await t.sendKeyEvent(LogicalKeyboardKey.f4);
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(amountFocused(t), isTrue, reason: 'the cashier can type the amount straight away');
      await typeAndEnter(t, '120');
      expect(h.carts.completeCalls, hasLength(1));
      final p = h.carts.completeCalls.single.payments.single;
      expect([p.method, p.amountMilli, p.tenderedMilli], [TenderMethod.cash, 112000, 120000]);
      expect(find.text('Sale complete'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('desktop: Enter with an empty or short amount does nothing (same as the disabled Complete Sale button)', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final h = await withCart(t);
    await t.sendKeyEvent(LogicalKeyboardKey.f4);
    await t.pumpAndSettle();
    await typeAndEnter(t, '');
    await typeAndEnter(t, '50');
    expect(h.carts.completeCalls, isEmpty);
    expect(find.byType(Dialog), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop: Enter pressed again while completing never sends a second completion', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final h = await withCart(t);
    final gate = Completer<CompletedSale>();
    h.carts.onComplete = (_) => gate.future;
    await t.sendKeyEvent(LogicalKeyboardKey.f4);
    await t.pumpAndSettle();
    t.testTextInput.updateEditingValue(const TextEditingValue(text: '112', selection: TextSelection.collapsed(offset: 3)));
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(h.carts.completeCalls, hasLength(1));
    gate.complete(CompletedSale.fromJson(completedJson())!);
    await t.pumpAndSettle();
    expect(h.carts.completeCalls, hasLength(1));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop: a draft already recorded offline (Phase 6S) is never completed by Enter', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final h = await withCart(t);
    h.carts.onComplete = (_) async => throw apiError(409, message: 'recorded offline', code: PosErrorCodes.draftSyncedOffline);
    await t.sendKeyEvent(LogicalKeyboardKey.f4);
    await t.pumpAndSettle();
    await typeAndEnter(t, '112');
    expect(h.carts.completeCalls, hasLength(1));
    expect(h.cart.draftSyncedOffline, isTrue);
    await t.tap(amountField);
    await t.pump();
    await typeAndEnter(t, '112');
    expect(h.carts.completeCalls, hasLength(1), reason: 'blocked like the hidden Complete Sale button');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android (unchanged): no autofocus, and Enter in the amount field does not complete the sale', (t) async {
    final h = await withCart(t);
    await t.tap(find.text('Pay'));
    await t.pumpAndSettle();
    expect(amountFocused(t), isFalse);
    await t.tap(amountField);
    await t.pump();
    await typeAndEnter(t, '120');
    expect(h.carts.completeCalls, isEmpty);
    expect(find.text('Complete Sale'), findsOneWidget);
  });

  for (final size in [const Size(1024, 640), const Size(1024, 700)]) {
    testWidgets('desktop minimum ${size.width.toInt()} x ${size.height.toInt()}: the sales screen and payment dialog lay out without overflow', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final h = await withCart(t, width: size.width, height: size.height);
      expect(t.takeException(), isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.f4);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Complete Sale'), findsOneWidget);
      expect(amountField, findsOneWidget);
      expect(h.cart.sale, isNotNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
