import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

CartSale draft({
  int version = 2,
  Map<String, dynamic>? discountOverride,
  Map<String, dynamic>? promotion,
  Map<String, dynamic>? loyalty,
  String? customerId,
}) => CartSale.fromJson(
  saleJson(
    id: 7,
    version: version,
    items: [lineJson(id: 1, quantity: 1, name: 'Tea')],
    subtotal: 5000,
    tax: 540,
    discount: discountOverride != null ? 500 : 0,
    total: discountOverride != null ? 5040 : 5600,
    discountOverride: discountOverride,
    promotion: promotion,
    loyalty: loyalty,
    customerId: customerId,
  ),
)!;

Future<PageHarness> pumpPage(
  WidgetTester tester, {
  CartSale? sale,
  double width = 1400,
  double height = 900,
}) async {
  final h = PageHarness();
  final s = sale ?? draft();
  h.carts.onAdd = (_) async => s;
  h.carts.onGet = (_) async => s;
  await pumpProductsPage(tester, h, width: width, height: height);
  return h;
}

Future<void> addItem(WidgetTester tester) async {
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
}

Finder inAlert(Finder f) =>
    find.descendant(of: find.byType(AlertDialog), matching: f);

void main() {
  group('visibility (Phase 17.4)', () {
    testWidgets(
      'hidden when the loaded auth context does NOT grant discounts.override, and no override is applied',
      (tester) async {
        final h = PageHarness();
        h.fakeAuth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Cashier')),
          permissions: ['sales.view'],
        );
        h.carts.onAdd = (_) async => draft();
        h.carts.onGet = (_) async => draft();
        await h.signIn();
        await pumpProductsPage(tester, h);
        await addItem(tester);
        expect(find.text('Add Discount'), findsNothing);
      },
    );

    testWidgets(
      'visible when the loaded auth context grants discounts.override',
      (tester) async {
        final h = PageHarness();
        h.fakeAuth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Manager')),
          permissions: ['discounts.override'],
        );
        h.carts.onAdd = (_) async => draft();
        h.carts.onGet = (_) async => draft();
        await h.signIn();
        await pumpProductsPage(tester, h);
        await addItem(tester);
        expect(find.text('Add Discount'), findsOneWidget);
      },
    );

    testWidgets(
      'visible when no auth context has loaded at all (defers to the backend)',
      (tester) async {
        await pumpPage(tester);
        await addItem(tester);
        expect(find.text('Add Discount'), findsOneWidget);
      },
    );

    testWidgets(
      'an already-applied discount stays visible to everyone, but Change/Remove are hidden without the permission',
      (tester) async {
        final h = PageHarness();
        h.fakeAuth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Cashier')),
          permissions: ['sales.view'],
        );
        final withDiscount = draft(
          discountOverride: discountOverrideJson(discountType: 'percentage', discountValue: 10),
        );
        h.carts.onAdd = (_) async => withDiscount;
        h.carts.onGet = (_) async => withDiscount;
        await h.signIn();
        await pumpProductsPage(tester, h);
        await addItem(tester);
        expect(find.textContaining('10'), findsWidgets);
        // "Change" also labels the (unrelated, always-present) customer row's
        // button — exactly one such match (the customer row's) must survive,
        // never a second one from the discount row itself.
        expect(find.text('Change'), findsOneWidget);
        expect(find.text('Remove'), findsNothing);
      },
    );
  });

  group('the discount form', () {
    testWidgets('an empty or invalid percentage is rejected before any request is sent', (
      tester,
    ) async {
      final h = await pumpPage(tester);
      await addItem(tester);
      await tester.tap(find.text('Add Discount'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter a percentage'), findsOneWidget);
      expect(h.carts.applyDiscountCalls, isEmpty);

      await tester.enterText(inAlert(find.byType(TextField)).at(0), '150');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('at most 100'), findsOneWidget);
      expect(h.carts.applyDiscountCalls, isEmpty);
    });

    testWidgets('a valid amount switches to flat mode and proceeds to confirmation', (
      tester,
    ) async {
      final h = await pumpPage(tester);
      await addItem(tester);
      await tester.tap(find.text('Add Discount'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amount'));
      await tester.pumpAndSettle();
      await tester.enterText(inAlert(find.byType(TextField)).at(0), '500');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm discount'), findsOneWidget);
      expect(h.carts.applyDiscountCalls, isEmpty, reason: 'not sent until confirmed');
    });
  });

  group('confirmation flow', () {
    testWidgets('shows the discount and reason, and Cancel sends nothing', (
      tester,
    ) async {
      final h = await pumpPage(tester);
      await addItem(tester);
      await tester.tap(find.text('Add Discount'));
      await tester.pumpAndSettle();
      await tester.enterText(inAlert(find.byType(TextField)).at(0), '15');
      await tester.enterText(inAlert(find.byType(TextField)).at(1), 'Manager approved');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm discount'), findsOneWidget);
      expect(find.textContaining('15%'), findsOneWidget);
      expect(find.text('Manager approved'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.carts.applyDiscountCalls, isEmpty);
    });
  });

  group('submitting a discount', () {
    Future<void> fillAndConfirm(
      WidgetTester tester, {
      String value = '10',
      String? reason,
    }) async {
      await tester.tap(find.text('Add Discount'));
      await tester.pumpAndSettle();
      await tester.enterText(inAlert(find.byType(TextField)).at(0), value);
      if (reason != null) {
        await tester.enterText(inAlert(find.byType(TextField)).at(1), reason);
      }
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
    }

    testWidgets('a successful discount updates the sale from the server response', (
      tester,
    ) async {
      final h = await pumpPage(tester);
      await addItem(tester);
      h.carts.onApplyDiscount = (c) async => draft(
        version: c.expectedVersion + 1,
        discountOverride: discountOverrideJson(
          discountType: c.discountType,
          discountValue: double.parse(c.discountValue),
        ),
      );
      await fillAndConfirm(tester, value: '10');
      expect(h.carts.applyDiscountCalls, hasLength(1));
      expect(h.carts.applyDiscountCalls.single.discountType, 'percentage');
      expect(find.textContaining('10'), findsWidgets);
      // "Remove" is unique to the discount row (the customer row only ever
      // offers "Change"), so this alone confirms the row re-rendered editable.
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('a stale version conflict shows the existing review message', (
      tester,
    ) async {
      final h = await pumpPage(tester);
      await addItem(tester);
      h.carts.onApplyDiscount = (c) async => throw const ApiException(
        kind: ApiErrorKind.conflict,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 9},
      );
      await fillAndConfirm(tester, value: '10');
      expect(
        find.textContaining('refreshed'),
        findsWidgets,
        reason: 'the same stale-version message every other cart mutation uses',
      );
    });

    testWidgets('a 403 permission error shows the existing permission-denied message', (
      tester,
    ) async {
      final h = await pumpPage(tester);
      await addItem(tester);
      h.carts.onApplyDiscount = (c) async => throw ApiException(
        kind: ApiErrorKind.forbidden,
        message: 'Forbidden',
        errorCode: PosErrorCodes.permissionDenied,
        data: const {'permission': 'discounts.override'},
      );
      await fillAndConfirm(tester, value: '10');
      expect(
        find.textContaining('do not have permission to apply a discount'),
        findsOneWidget,
      );
    });
  });

  group('interaction with existing promotion/loyalty display', () {
    testWidgets('an existing promotion keeps rendering correctly alongside a discount override', (
      tester,
    ) async {
      await pumpPage(
        tester,
        sale: draft(
          promotion: {
            'id': 1,
            'title': '10% Off',
            'discount_type': 'percentage',
            'discount_value': 10,
            'eligible': true,
            'discount_amount': 500,
          },
          discountOverride: discountOverrideJson(discountType: 'flat', discountValue: 200),
        ),
      );
      await addItem(tester);
      expect(find.text('10% Off'), findsOneWidget);
      expect(find.textContaining('200'), findsWidgets);
    });

    testWidgets('existing loyalty display keeps rendering correctly alongside a discount override', (
      tester,
    ) async {
      await pumpPage(
        tester,
        sale: draft(
          customerId: 'CUST-1',
          loyalty: loyaltySaleInfoJson(
            tier: {'id': 2, 'name': 'Gold'},
            tierDiscountAmount: 50,
          ),
          discountOverride: discountOverrideJson(discountType: 'flat', discountValue: 200),
        ),
      );
      await addItem(tester);
      expect(find.textContaining('tier'), findsWidgets);
      expect(find.textContaining('200'), findsWidgets);
    });

    testWidgets('the existing checkout flow (Pay) remains reachable with a discount override applied', (
      tester,
    ) async {
      await pumpPage(
        tester,
        sale: draft(discountOverride: discountOverrideJson(discountType: 'flat', discountValue: 200)),
      );
      await addItem(tester);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Pay')).onPressed,
        isNotNull,
      );
    });
  });
}
