// Phase C5: UI follows the backend's permissions. Controls hide/disable only
// when the loaded permission context positively lacks the permission (the
// backend's 403 still decides); missing data never hides anything.
import 'dart:convert';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/ui/pay_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

const cashierLike = [
  'sales.view', 'sales.create', 'sales.edit_current', 'sales.hold', 'sales.resume',
  'payments.accept_cash', 'payments.accept_card', 'payments.accept_other', 'promotions.view', 'promotions.apply',
  'customers.view', 'customers.create', 'loyalty.view', 'loyalty.redeem_points', 'loyalty.redeem_wallet',
];

CartSale withItems() => CartSale.fromJson(
  saleJson(id: 7, version: 2, status: 'draft', items: [lineJson(id: 1, quantity: 2, name: 'Tea')], total: 20),
)!;

PosAuthContext ctx(List<String> permissions) => PosAuthContext(
  staff: const StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Role')),
  permissions: permissions,
);

Future<PageHarness> page(WidgetTester tester, List<String> permissions, {PosApiClient? client, double width = 1400}) async {
  final h = PageHarness(client: client);
  h.fakeAuth.onAuthContext = (t) async => ctx(permissions);
  h.carts.onAdd = (_) async => withItems();
  h.carts.onGet = (_) async => withItems();
  await h.signIn();
  await pumpProductsPage(tester, h, width: width, height: 1000);
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
  return h;
}

Finder tenderChips() => find.descendant(of: find.byType(PayModal), matching: find.byType(ChoiceChip));

ApiException forbidden(String permission, {List<String>? anyOf}) => ApiException(
  kind: ApiErrorKind.forbidden,
  message: 'Forbidden',
  errorCode: PosErrorCodes.permissionDenied,
  data: {'permission': permission, 'any_of': ?anyOf},
);

void main() {
  group('SessionController.isDeniedAll', () {
    test('false with no permission context; true only when every one is missing', () async {
      final auth = FakeAuthService();
      final s = SessionController(auth, MemoryTokenStore());
      addTearDown(s.dispose);
      expect(s.isDeniedAll(const ['reports.sales', 'reports.cashier']), isFalse, reason: 'missing data never denies');
      auth.onAuthContext = (t) async => ctx(const ['reports.cashier']);
      await s.loginDevice('REG-1', 'secret');
      await s.loginStaff('S1', '1234');
      expect(s.isDeniedAll(const ['reports.sales', 'reports.cashier']), isFalse);
      expect(s.isDeniedAll(const ['reports.sales', 'reports.payment']), isTrue);
    });
  });

  group('403 messages', () {
    test('each newly enforced permission has clear wording', () {
      expect(describeApiError(forbidden('shifts.open')), contains('Ask a manager to open the shift'));
      expect(describeApiError(forbidden('customers.edit')), contains('edit customers'));
      expect(describeApiError(forbidden('sales.create')), contains('start or complete sales'));
      expect(describeApiError(forbidden('payments.accept_card')), contains('card payments'));
      expect(describeApiError(forbidden('payments.accept_other')), contains('this payment method'));
      expect(describeApiError(forbidden('reports.sales', anyOf: const ['reports.sales', 'reports.cashier', 'reports.payment', 'reports.product'])), contains('sales reports'));
      expect(describeApiError(forbidden('loyalty.redeem_points', anyOf: const ['loyalty.redeem_points', 'loyalty.redeem_wallet'])), contains('loyalty redemptions'));
    });
  });

  group('cart controls', () {
    testWidgets('Hold is disabled without sales.hold, enabled with it', (tester) async {
      await page(tester, cashierLike.where((p) => p != 'sales.hold').toList());
      final hold = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Hold sale'));
      expect(hold.onPressed, isNull);
    });

    testWidgets('Hold stays enabled for a role that has sales.hold', (tester) async {
      await page(tester, cashierLike);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Hold sale')).onPressed, isNotNull);
    });

    testWidgets('Add Promotion is hidden without promotions.apply', (tester) async {
      await page(tester, cashierLike.where((p) => p != 'promotions.apply').toList());
      expect(find.text('Add Promotion'), findsNothing);
    });

    testWidgets('Add Promotion is shown with promotions.apply', (tester) async {
      await page(tester, cashierLike);
      expect(find.text('Add Promotion'), findsOneWidget);
    });
  });

  group('tender options', () {
    testWidgets('without payments.accept_card the Card tender is not offered (cash, other, split remain)', (tester) async {
      await page(tester, cashierLike.where((p) => p != 'payments.accept_card').toList());
      await tester.tap(find.widgetWithText(FilledButton, 'Pay'));
      await tester.pumpAndSettle();
      final chips = tester.widgetList<ChoiceChip>(tenderChips()).map((c) => (c.label as Text).data).toList();
      expect(chips, ['Cash', 'Other', 'Split']);
    });

    testWidgets('without payments.accept_cash the pay screen opens on an allowed tender and offers no Cash/Split', (tester) async {
      await page(tester, cashierLike.where((p) => p != 'payments.accept_cash').toList());
      await tester.tap(find.widgetWithText(FilledButton, 'Pay'));
      await tester.pumpAndSettle();
      final chips = tester.widgetList<ChoiceChip>(tenderChips());
      expect(chips.map((c) => (c.label as Text).data).toList(), ['Card', 'Other']);
      expect(chips.firstWhere((c) => c.selected).label, isA<Text>().having((t) => t.data, 'label', 'Card'));
    });

    testWidgets('without payments.accept_other the Other tender is not offered', (tester) async {
      await page(tester, cashierLike.where((p) => p != 'payments.accept_other').toList());
      await tester.tap(find.widgetWithText(FilledButton, 'Pay'));
      await tester.pumpAndSettle();
      expect(tester.widgetList<ChoiceChip>(tenderChips()).map((c) => (c.label as Text).data).toList(), ['Cash', 'Card', 'Split']);
    });

    testWidgets('a full role sees every tender', (tester) async {
      await page(tester, cashierLike);
      await tester.tap(find.widgetWithText(FilledButton, 'Pay'));
      await tester.pumpAndSettle();
      expect(tester.widgetList<ChoiceChip>(tenderChips()).map((c) => (c.label as Text).data).toList(), ['Cash', 'Card', 'Other', 'Split']);
    });
  });

  group('sales summary panel', () {
    PosApiClient countingClient(List<int> analyticsCalls, {int status = 200}) => PosApiClient(
      baseUrl: 'http://test',
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/analytics/summary')) {
          analyticsCalls.add(1);
          if (status == 403) {
            return http.Response(jsonEncode({'status': false, 'message': 'Forbidden', 'error_code': 'POS_PERMISSION_DENIED', 'data': {'permission': 'reports.sales', 'any_of': ['reports.sales', 'reports.cashier', 'reports.payment', 'reports.product']}}), 403);
          }
          return http.Response(jsonEncode({'status': true, 'data': {'today': {'transaction_count': 0, 'sales_total': 0}, 'payment_breakdown': [], 'top_products': [], 'staff_performance': []}}), 200);
        }
        return http.Response(jsonEncode({'status': true, 'data': {'items': [], 'pagination': {'page': 1, 'limit': 20, 'total': 0, 'total_pages': 1}}}), 200);
      }),
    );

    testWidgets('no reporting permission: no call, a permission message, no stuck loading', (tester) async {
      final calls = <int>[];
      await page(tester, cashierLike, client: countingClient(calls), width: 1700);
      expect(calls, isEmpty, reason: 'the panel never calls analytics without a reports.* permission');
      expect(find.text('Sales figures need a reporting permission.'), findsOneWidget);
      expect(find.text('Loading…'), findsNothing);
    });

    testWidgets('a backend 403 is shown as a permission message, not an outage', (tester) async {
      final calls = <int>[];
      final h = PageHarness(client: countingClient(calls, status: 403));
      h.carts.onAdd = (_) async => withItems();
      h.carts.onGet = (_) async => withItems();
      await pumpProductsPage(tester, h, width: 1700, height: 1000); // no permission context loaded
      expect(calls, isNotEmpty);
      expect(find.text('Sales figures need a reporting permission.'), findsOneWidget);
      expect(find.text('Sales reporting is temporarily unavailable.'), findsNothing);
    });

    testWidgets('with any one reports.* permission the panel loads figures', (tester) async {
      final calls = <int>[];
      await page(tester, [...cashierLike, 'reports.cashier'], client: countingClient(calls), width: 1700);
      expect(calls, isNotEmpty);
      expect(find.text('Sales figures need a reporting permission.'), findsNothing);
    });
  });
}
