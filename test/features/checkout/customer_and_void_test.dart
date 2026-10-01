import 'dart:async';
import 'dart:convert';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/held_sales/models/held_sale_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

/// A [PosApiClient] whose customer search always returns [customers] — used
/// by the "Change customer" dialog's search/select picker.
PosApiClient customersApiClient(List<Map<String, dynamic>> customers) =>
    PosApiClient(
      baseUrl: 'http://test',
      httpClient: MockClient((r) async {
        if (r.method == 'GET' && r.url.path.endsWith('/customers')) {
          return http.Response(
            jsonEncode({'status': true, 'data': pageJson(customers)}),
            200,
          );
        }
        return http.Response(
          jsonEncode({'status': false, 'message': 'no route'}),
          404,
        );
      }),
    );

CartSale withItems({
  int version = 2,
  String? customer,
  String status = 'draft',
}) {
  final j = saleJson(
    id: 7,
    version: version,
    status: status,
    items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
    total: 20,
  );
  j['customer_id'] = customer;
  return CartSale.fromJson(j)!;
}

Future<PageHarness> pumpPage(
  WidgetTester tester, {
  double width = 1400,
  double height = 900,
  PosApiClient? client,
}) async {
  final h = PageHarness(client: client);
  h.carts.onAdd = (_) async => withItems();
  h.carts.onGet = (_) async => withItems();
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
  group('customer row', () {
    testWidgets(
      'default is Guest checkout with an enabled Change before any sale exists',
      (tester) async {
        await pumpPage(tester);
        expect(find.text('Guest checkout'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Change'))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets(
      'search and select a customer: shown by name, then used when the sale is created',
      (tester) async {
        final client = customersApiClient([
          {
            'id': 1,
            'customer_id': 'C-42',
            'fullname': 'Jane Doe',
            'mobileno': '0400000000',
            'email': null,
            'status': 2,
          },
        ]);
        final h = await pumpPage(tester, client: client);
        await tester.tap(find.text('Change'));
        await tester.pumpAndSettle();
        expect(find.text('Customer'), findsOneWidget);

        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
              .onPressed,
          isNull,
          reason: 'nothing picked yet',
        );
        expect(find.text('Jane Doe'), findsOneWidget);
        await tester.tap(find.text('Jane Doe'));
        await tester.pumpAndSettle();
        expect(find.text('Selected: Jane Doe'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(
          find.text('Jane Doe'),
          findsOneWidget,
          reason: 'shown by name before the sale exists',
        );
        expect(h.cart.pendingCustomerId, 'C-42');

        h.carts.onAdd = (_) async => withItems(customer: 'C-42');
        await addItem(tester);
        expect(h.carts.createCustomerIds, ['C-42']);
        expect(
          find.text('Customer C-42'),
          findsOneWidget,
          reason: 'now read from the server sale (no name returned there)',
        );
      },
    );

    testWidgets('+ New Customer creates and auto-selects a customer', (
      tester,
    ) async {
      final client = PosApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((r) async {
          if (r.method == 'GET' && r.url.path.endsWith('/customers')) {
            return http.Response(
              jsonEncode({'status': true, 'data': pageJson(const [])}),
              200,
            );
          }
          if (r.method == 'POST' && r.url.path.endsWith('/customers')) {
            return http.Response(
              jsonEncode({
                'status': true,
                'data': {
                  'id': 9,
                  'customer_id': 'C-99',
                  'fullname': 'New Guy',
                  'mobileno': '0400999999',
                  'email': null,
                  'status': 2,
                },
              }),
              201,
            );
          }
          return http.Response(
            jsonEncode({'status': false, 'message': 'no route'}),
            404,
          );
        }),
      );
      final h = await pumpPage(tester, client: client);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ New Customer'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name *'),
        'New Guy',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone *'),
        '0400999999',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save Customer'));
      await tester.pumpAndSettle();
      expect(find.text('Selected: New Guy'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('New Guy'), findsOneWidget);
      expect(h.cart.pendingCustomerId, 'C-99');
    });

    testWidgets(
      'once the sale exists the choice is locked with an explanation',
      (tester) async {
        await pumpPage(tester);
        await addItem(tester);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Change'))
              .onPressed,
          isNull,
        );
        expect(
          find.byTooltip(
            'The customer is set when the sale starts. Void the sale to change it.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Cancel keeps the current choice; picking Guest again clears a chosen customer',
      (tester) async {
        final h = await pumpPage(tester);
        h.cart.setPendingCustomer('C-1');
        await tester.pump();
        await tester.tap(find.text('Change'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(h.cart.pendingCustomerId, 'C-1');

        await tester.tap(find.text('Change'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Guest checkout').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(h.cart.pendingCustomerId, isNull);
        expect(find.text('Guest checkout'), findsOneWidget);
      },
    );

    testWidgets(
      'an unknown customer ID: the server error is shown, nothing is created, and the choice can be corrected',
      (tester) async {
        final h = await pumpPage(tester);
        h.cart.setPendingCustomer('NOPE');
        h.carts.onCreate = () async =>
            throw apiError(404, message: 'Customer not found');
        await tester.pump();
        await addItem(tester);
        expect(find.text('Customer not found'), findsOneWidget);
        expect(h.cart.sale, isNull);
        expect(find.text('Customer NOPE'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Change'))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets(
      'a customer already on the server sale (e.g. a resumed sale) is shown read-only',
      (tester) async {
        final h = await pumpPage(tester);
        h.carts.onAdd = (_) async => withItems(customer: 'C-9');
        await addItem(tester);
        expect(find.text('Customer C-9'), findsOneWidget);
      },
    );

    testWidgets('the customer appears on the receipt', (tester) async {
      final h = await pumpPage(tester);
      h.cart.setPendingCustomer('C-42');
      h.carts.onAdd = (_) async => withItems(customer: 'C-42');
      h.carts.onComplete = (c) async => CompletedSale.fromJson(
        completedJson(customerId: 'C-42', payments: c.payments),
      )!;
      await tester.pump();
      await addItem(tester);
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exact'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text('C-42')),
        findsOneWidget,
      );
    });

    testWidgets(
      'no overflow in the customer dialog on a small phone at large text',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(
          tester,
          h,
          width: 360,
          height: 640,
          textScale: 1.5,
        );
        await tester.tap(find.text('Cart'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Change'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Void sale (active cart)', () {
    testWidgets(
      'visible for an open draft with items, hidden for an empty cart',
      (tester) async {
        await pumpPage(tester);
        expect(find.text('Void sale'), findsNothing);
        await addItem(tester);
        expect(find.text('Void sale'), findsOneWidget);
      },
    );

    testWidgets('asks for confirmation; Keep sale sends nothing', (
      tester,
    ) async {
      final h = await pumpPage(tester);
      await addItem(tester);
      await tester.tap(find.text('Void sale'));
      await tester.pumpAndSettle();
      expect(find.text('Void this sale?'), findsOneWidget);
      expect(find.textContaining('It cannot be undone'), findsOneWidget);
      await tester.tap(find.text('Keep sale'));
      await tester.pumpAndSettle();
      expect(h.carts.cancelCalls, isEmpty);
      expect(h.cart.sale, isNotNull);
    });

    testWidgets(
      'confirming cancels with the id and version, clears the cart and confirms',
      (tester) async {
        final h = await pumpPage(tester);
        await addItem(tester);
        await tester.tap(find.text('Void sale'));
        await tester.pumpAndSettle();
        await tester.tap(inAlert(find.text('Void sale')));
        await tester.pumpAndSettle();
        final c = h.carts.cancelCalls.single;
        expect((c.saleId, c.expectedVersion), (7, 2));
        expect(h.cart.sale, isNull);
        expect(find.text('Sale #7 voided'), findsOneWidget);
        expect(find.text('The cart is empty'), findsOneWidget);
      },
    );

    testWidgets(
      'a version conflict shows the review message in the cart and refreshes it',
      (tester) async {
        final h = await pumpPage(tester);
        await addItem(tester);
        h.carts.onCancel = (_) async => throw apiError(
          409,
          message: 'Sale has been modified since you last read it',
          data: {'current_version': 6},
        );
        h.carts.onGet = (_) async => withItems(version: 6);
        await tester.tap(find.text('Void sale'));
        await tester.pumpAndSettle();
        await tester.tap(inAlert(find.text('Void sale')));
        await tester.pumpAndSettle();
        expect(find.text(CartController.conflictMessage), findsOneWidget);
        expect(h.cart.sale!.version, 6);
        expect(h.carts.cancelCalls, hasLength(1));
        expect(find.text('Sale #7 voided'), findsNothing);
      },
    );

    testWidgets(
      'a sale that can no longer be voided is explained, and the cart becomes read-only',
      (tester) async {
        final h = await pumpPage(tester);
        await addItem(tester);
        h.carts.onCancel = (_) async => throw apiError(
          409,
          message: 'Sale cannot be canceled from its current status: completed',
        );
        h.carts.onGet = (_) async => withItems(version: 9, status: 'completed');
        await tester.tap(find.text('Void sale'));
        await tester.pumpAndSettle();
        await tester.tap(inAlert(find.text('Void sale')));
        await tester.pumpAndSettle();
        expect(
          find.text(CartController.cancelNotAllowedMessage),
          findsOneWidget,
        );
        expect(
          find.textContaining('no longer open (completed)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a network error while voiding leaves the sale open and says so',
      (tester) async {
        final h = await pumpPage(tester);
        await addItem(tester);
        h.carts.onCancel = (_) async => throw const ApiException(
          kind: ApiErrorKind.network,
          message:
              'Cannot reach the server. Check your connection and try again.',
        );
        await tester.tap(find.text('Void sale'));
        await tester.pumpAndSettle();
        await tester.tap(inAlert(find.text('Void sale')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Cannot reach the server'), findsOneWidget);
        expect(h.cart.sale, isNotNull);
      },
    );

    testWidgets(
      'the button is disabled while a request is running (no double void)',
      (tester) async {
        final h = await pumpPage(tester);
        await addItem(tester);
        final gate = Completer<CartSale>();
        h.carts.onCancel = (_) => gate.future;
        unawaited(h.cart.cancelCurrent());
        await tester.pump();
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Void sale'))
              .onPressed,
          isNull,
        );
        gate.complete(withItems(version: 3, status: 'canceled'));
        await tester.pumpAndSettle();
      },
    );
  });

  group('Void sale — permission-aware (Phase 17.2)', () {
    testWidgets(
      'hidden when the loaded auth context does NOT grant sales.cancel',
      (tester) async {
        final h = PageHarness();
        h.fakeAuth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Cashier')),
          permissions: ['sales.view'],
        );
        h.carts.onAdd = (_) async => withItems();
        h.carts.onGet = (_) async => withItems();
        await h.signIn();
        await pumpProductsPage(tester, h);
        await addItem(tester);
        expect(
          find.text('Void sale'),
          findsNothing,
          reason: 'a positively-known missing permission must hide the button',
        );
      },
    );

    testWidgets(
      'stays visible when the loaded auth context grants sales.cancel',
      (tester) async {
        final h = PageHarness();
        h.fakeAuth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Manager')),
          permissions: ['sales.cancel'],
        );
        h.carts.onAdd = (_) async => withItems();
        h.carts.onGet = (_) async => withItems();
        await h.signIn();
        await pumpProductsPage(tester, h);
        await addItem(tester);
        expect(find.text('Void sale'), findsOneWidget);
      },
    );
  });

  group('Void a held sale (held-sales list)', () {
    Future<PageHarness> openHeldDetail(WidgetTester tester) async {
      final h = PageHarness();
      h.heldService.onList = () async => [
        HeldSaleSummary.fromJson(heldRowJson(id: 12, version: 3))!,
      ];
      h.carts.onGet = (id) async => CartSale.fromJson(
        saleJson(
          id: id,
          version: 5,
          status: 'held',
          items: [lineJson(id: 1, name: 'Tea')],
          total: 20,
        ),
      )!;
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      await tester.tap(find.byTooltip('Held sales'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sale #12'));
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets(
      'detail shows Void sale beside Resume; confirming sends the FRESH version and removes the sale from the list',
      (tester) async {
        final h = await openHeldDetail(tester);
        expect(find.text('Void sale'), findsOneWidget);
        h.heldService.onList = () async => [];
        await tester.tap(find.text('Void sale'));
        await tester.pumpAndSettle();
        expect(find.text('Void this sale?'), findsOneWidget);
        expect(find.textContaining('held sale #12'), findsOneWidget);
        await tester.tap(inAlert(find.text('Void sale')));
        await tester.pumpAndSettle();
        final c = h.carts.cancelCalls.single;
        expect(
          (c.saleId, c.expectedVersion),
          (12, 5),
          reason: 'the detail version, not the list-time version',
        );
        expect(h.held!.sales, isEmpty);
        expect(find.text('Sale #12 voided'), findsOneWidget);
      },
    );

    testWidgets('Keep sale sends nothing', (tester) async {
      final h = await openHeldDetail(tester);
      await tester.tap(find.text('Void sale'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep sale'));
      await tester.pumpAndSettle();
      expect(h.carts.cancelCalls, isEmpty);
    });

    testWidgets(
      'a conflict shows the review message, reloads the sale, refreshes the list, and is not retried',
      (tester) async {
        final h = await openHeldDetail(tester);
        h.carts.onCancel = (_) async => throw apiError(
          409,
          message: 'Sale has been modified since you last read it',
          data: {'current_version': 8},
        );
        final listCalls = h.heldService.calls;
        await tester.tap(find.text('Void sale'));
        await tester.pumpAndSettle();
        await tester.tap(inAlert(find.text('Void sale')));
        await tester.pumpAndSettle();
        expect(find.text(CartController.conflictMessage), findsOneWidget);
        expect(h.carts.cancelCalls, hasLength(1));
        expect(
          h.heldService.calls,
          greaterThan(listCalls),
          reason: 'the list was refreshed',
        );
        expect(h.cart.error!.currentVersion, 8);
      },
    );

    testWidgets(
      'an already-resumed or finished sale cannot be voided from here (read-only detail disables Void)',
      (tester) async {
        final h = PageHarness();
        h.heldService.onList = () async => [
          HeldSaleSummary.fromJson(heldRowJson(id: 12))!,
        ];
        h.carts.onGet = (id) async => CartSale.fromJson(
          saleJson(
            id: id,
            version: 6,
            status: 'draft',
            items: [lineJson(id: 1)],
          ),
        )!;
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        await tester.tap(find.byTooltip('Held sales'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sale #12'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Void sale'))
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets('voiding a held sale never touches the open cart', (
      tester,
    ) async {
      final h = await openHeldDetail(tester);
      expect(h.cart.sale, isNull);
      await tester.tap(find.text('Void sale'));
      await tester.pumpAndSettle();
      await tester.tap(inAlert(find.text('Void sale')));
      await tester.pumpAndSettle();
      expect(h.cart.sale, isNull);
      expect(h.carts.createCalls, 0);
    });
  });

  group('Void a held sale — permission-aware (Phase 17.2)', () {
    testWidgets(
      'hidden when the loaded auth context does NOT grant sales.cancel',
      (tester) async {
        final h = PageHarness();
        h.fakeAuth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Cashier')),
          permissions: ['sales.view'],
        );
        h.heldService.onList = () async => [
          HeldSaleSummary.fromJson(heldRowJson(id: 12, version: 3))!,
        ];
        h.carts.onGet = (id) async => CartSale.fromJson(
          saleJson(
            id: id,
            version: 5,
            status: 'held',
            items: [lineJson(id: 1, name: 'Tea')],
            total: 20,
          ),
        )!;
        await h.signIn();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        await tester.tap(find.byTooltip('Held sales'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sale #12'));
        await tester.pumpAndSettle();
        expect(
          find.text('Void sale'),
          findsNothing,
          reason: 'a positively-known missing permission must hide the button',
        );
      },
    );

    testWidgets(
      'stays visible when the loaded auth context grants sales.cancel',
      (tester) async {
        final h = PageHarness();
        h.fakeAuth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Manager')),
          permissions: ['sales.cancel'],
        );
        h.heldService.onList = () async => [
          HeldSaleSummary.fromJson(heldRowJson(id: 12, version: 3))!,
        ];
        h.carts.onGet = (id) async => CartSale.fromJson(
          saleJson(
            id: id,
            version: 5,
            status: 'held',
            items: [lineJson(id: 1, name: 'Tea')],
            total: 20,
          ),
        )!;
        await h.signIn();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        await tester.tap(find.byTooltip('Held sales'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sale #12'));
        await tester.pumpAndSettle();
        expect(find.text('Void sale'), findsOneWidget);
      },
    );
  });
}
