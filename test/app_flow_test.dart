import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/app.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

/// Drives the whole app through a mock backend that enforces the verified
/// contract: which token is required where, and the exact request bodies.
class MockBackend {
  final List<http.Request> requests = [];
  bool productsUnauthorized = false;
  bool shiftAlreadyOpen = false;
  Map<String, dynamic>? weightRejection;

  // --- stateful sale (the "server" owns version, quantities and every number) ---
  int version = 1;
  String status = 'draft';
  int qty = 0;
  bool lineExists = false;
  bool expireStaff = false;

  // --- checkout: enforces the verified backend rules ---
  String? customerId;
  Map<String, dynamic>? lastCreateBody;
  final List<Map<String, dynamic>> completeBodies = [];
  final List<Map<String, dynamic>> cancelBodies = [];
  Map<String, dynamic>? _completedView;
  String? _completedKey;
  int completionCount = 0;

  /// The next completion is recorded by the server, but the RESPONSE is lost
  /// (a connection drop): the client sees a network error and cannot know.
  bool dropNextCompleteResponse = false;

  /// If set, the next PATCH/DELETE answers 409 (someone else changed the cart):
  /// the server moves to this version with this quantity.
  int? conflictAtVersion;
  int conflictQty = 0;

  static double _r(double v) => (v * 100).round() / 100;

  // Like the real server, every sale view carries the sale's customer_id.
  Map<String, dynamic> saleView() => _baseView()..['customer_id'] = customerId;

  Map<String, dynamic> _baseView() => saleJson(
    id: 7,
    version: version,
    status: status,
    items: lineExists
        ? [
            {
              'id': 1,
              'product_variation_id': 42,
              'quantity': qty,
              'product_name': 'Tea',
              'availability_status': 'available',
              'unit_price': 119,
              'tax_percent': 12,
              'tax_amount': _r(qty * 14.28),
              'tax_included': false,
              'line_total': _r(qty * 133.28),
            },
          ]
        : [],
    subtotal: _r(qty * 119.0),
    tax: _r(qty * 14.28),
    total: _r(qty * 133.28),
  );

  http.Response _ok(Object data) => http.Response(
    jsonEncode({
      'status_code': 200,
      'status': true,
      'message': 'OK',
      'data': data,
    }),
    200,
  );
  http.Response _err(int code, String msg, {String? errorCode}) =>
      http.Response(
        jsonEncode({
          'status_code': code,
          'status': false,
          'message': msg,
          'error_code': ?errorCode,
        }),
        code,
      );

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final path = r.url.path.replaceFirst('/api/v1/pos', '');
    final auth = r.headers['Authorization'];
    if (expireStaff && auth == 'Bearer staff-tok') {
      return _err(401, 'Token expired');
    }
    Map<String, dynamic> body() =>
        r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

    switch ('${r.method} $path') {
      case 'POST /auth/device-login':
        if (auth != null) {
          return _err(400, 'device-login must be unauthenticated');
        }
        return body()['device_secret'] == 'good-secret'
            ? _ok({'token': 'device-tok', 'expires_in_hours': 12})
            : _err(401, 'Invalid device credentials');
      case 'POST /auth/staff-login':
        if (auth != 'Bearer device-tok') {
          return _err(
            401,
            'A valid device token is required before staff login',
          );
        }
        return body()['pin'] == '1234'
            ? _ok({'token': 'staff-tok', 'expires_in_hours': 10})
            : _err(
                401,
                'Invalid staff credentials or account unavailable',
                errorCode: 'POS_INVALID_STAFF_CREDENTIALS',
              );
      case 'POST /shifts/open':
        if (auth != 'Bearer staff-tok') {
          return _err(401, 'Staff authentication required');
        }
        return shiftAlreadyOpen
            ? _err(409, 'This register already has an open shift')
            : _ok({'id': 1, 'status': 'open'});
      case 'GET /categories':
        return _ok([
          {'cid': 1, 'category': 'Dairy'},
        ]);
      case 'GET /products':
        if (productsUnauthorized) return _err(401, 'Token expired');
        return _ok(
          pageJson([
            productJson(
              id: 42,
              variationId: 'VARIATION42',
              name: 'Tea',
              price: 119,
            ),
          ]),
        );
      case 'POST /sales':
        version = 1;
        status = 'draft';
        qty = 0;
        lineExists = false;
        lastCreateBody = body();
        customerId = lastCreateBody!['customer_id'] as String?;
        _completedView = null;
        _completedKey = null;
        return _ok(saleView()..['customer_id'] = customerId);
      case 'POST /sales/7/cancel':
        if (auth != 'Bearer staff-tok') {
          return _err(401, 'Staff authentication required');
        }
        cancelBodies.add(body());
        if (status != 'draft' && status != 'held') {
          return _err(
            409,
            'Sale cannot be canceled from its current status: $status',
          );
        }
        if (body()['expected_version'] != version) {
          return http.Response(
            jsonEncode({
              'status': false,
              'message': 'Sale has been modified since you last read it',
              'data': {'current_version': version, 'current_status': status},
            }),
            409,
          );
        }
        status = 'canceled';
        version += 1;
        return _ok(saleView());
      case 'POST /sales/7/complete':
        if (auth != 'Bearer staff-tok') {
          return _err(401, 'Staff authentication required');
        }
        final b = body();
        completeBodies.add(b);
        final key = b['idempotency_key'];
        if (key is! String || key.length < 8 || key.length > 64) {
          return _err(
            422,
            'idempotency_key is required (string, 8-64 characters)',
          );
        }
        if (status == 'completed') {
          // Same key + same request = replay; anything else is a conflict.
          if (key == _completedKey) return _ok(_completedView!);
          return _err(409, 'Sale already completed');
        }
        if (status != 'draft') {
          return _err(
            409,
            'Only a draft sale can be completed (current status: $status)',
          );
        }
        if (b['expected_version'] != version) {
          return http.Response(
            jsonEncode({
              'status': false,
              'message': 'Sale has been modified since you last read it',
              'data': {'current_version': version, 'current_status': status},
            }),
            409,
          );
        }
        final total = _r(qty * 133.28);
        final payments = (b['payments'] as List).cast<Map<String, dynamic>>();
        final paid = payments.fold<double>(
          0,
          (a, p) => a + (p['amount'] as num),
        );
        if ((paid - total).abs() > 0.0005) {
          return _err(
            422,
            'Payment total ($paid) must equal the sale total ($total)',
          );
        }
        for (final p in payments) {
          if (p['method'] == 'cash' &&
              (p['tendered_amount'] == null ||
                  p['tendered_amount'] < p['amount'])) {
            return _err(
              422,
              'payments[0].tendered_amount must be greater than or equal to amount',
            );
          }
        }
        status = 'completed';
        version += 1;
        completionCount += 1;
        _completedKey = key;
        _completedView = {
          'id': 7,
          'status': 'completed',
          'sale_number': 'POS-00000007',
          'customer_id': customerId,
          'version': version,
          'items': [
            {
              'id': 1,
              'product_variation_id': 42,
              'quantity': qty,
              'unit_price': 119,
              'tax_percent': 12,
              'tax_included': false,
              'tax_amount': _r(qty * 14.28),
              'discount_amount': 0,
              'line_total': total,
            },
          ],
          'totals': {
            'subtotal': _r(qty * 119.0),
            'tax_total': _r(qty * 14.28),
            'discount_total': 0,
            'grand_total': total,
          },
          'payments': [
            for (final p in payments)
              {
                'method': p['method'],
                'amount': p['amount'],
                'tendered_amount': p['tendered_amount'],
                'change_due': p['method'] == 'cash'
                    ? _r(
                        ((p['tendered_amount'] as num) - (p['amount'] as num))
                            .toDouble(),
                      )
                    : null,
                'status': 'completed',
              },
          ],
          'completed_at': '2026-09-21 15:23:52',
        };
        if (dropNextCompleteResponse) {
          dropNextCompleteResponse = false;
          throw const SocketException('connection reset');
        }
        return _ok(_completedView!);
      case 'GET /sales':
        // Raw pos_sales rows, exactly like the real endpoint (null totals).
        return _ok(
          (r.url.queryParameters['status'] == 'held' && status == 'held')
              ? [
                  {
                    ...heldRowJson(id: 7, version: version, salesman: 'S1'),
                    'status': 'held',
                  },
                ]
              : [],
        );
      case 'POST /sales/7/hold':
      case 'POST /sales/7/resume':
        if (auth != 'Bearer staff-tok') {
          return _err(401, 'Staff authentication required');
        }
        final isHold = path.endsWith('/hold');
        if (isHold && status != 'draft') {
          return _err(409, 'Sale is not a draft (current status: $status)');
        }
        if (!isHold && status != 'held') {
          return _err(409, 'Sale is not held (current status: $status)');
        }
        if (body()['expected_version'] != version) {
          return http.Response(
            jsonEncode({
              'status': false,
              'message': 'Sale has been modified since you last read it',
              'data': {'current_version': version, 'current_status': status},
            }),
            409,
          );
        }
        status = isHold ? 'held' : 'draft';
        version += 1;
        return _ok(saleView());
      case 'GET /sales/7':
        return _ok(saleView());
      case 'POST /sales/7/items':
        if (auth != 'Bearer staff-tok') {
          return _err(401, 'Staff authentication required');
        }
        if (weightRejection != null) {
          return _err(
            422,
            'Weight-based products cannot be sold through POS stock-enabled sales yet',
            errorCode: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
          );
        }
        qty = (body()['quantity'] as int) + (lineExists ? qty : 0);
        lineExists = true;
        version += 1;
        return _ok(saleView());
      case 'PATCH /sales/7/items/1':
      case 'DELETE /sales/7/items/1':
        if (auth != 'Bearer staff-tok') {
          return _err(401, 'Staff authentication required');
        }
        final sent = r.method == 'DELETE'
            ? int.tryParse(r.url.queryParameters['expected_version'] ?? '')
            : body()['expected_version'];
        if (conflictAtVersion != null) {
          version = conflictAtVersion!;
          qty = conflictQty;
          conflictAtVersion = null;
          return http.Response(
            jsonEncode({
              'status_code': 409,
              'status': false,
              'message': 'Sale has been modified since you last read it',
              'data': {'current_version': version, 'current_status': 'draft'},
            }),
            409,
          );
        }
        if (sent != version) {
          return http.Response(
            jsonEncode({
              'status': false,
              'message': 'Sale has been modified since you last read it',
              'data': {'current_version': version, 'current_status': 'draft'},
            }),
            409,
          );
        }
        if (!lineExists) return _err(404, 'Line item not found');
        if (r.method == 'DELETE') {
          lineExists = false;
          qty = 0;
        } else {
          qty = body()['quantity'] as int;
        }
        version += 1;
        return _ok(saleView());
    }
    return _err(404, 'no route $path');
  }
}

Future<void> pumpApp(
  WidgetTester tester,
  MockBackend backend, {
  TokenStore? store,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    PosApp(
      baseUrl: 'http://backend',
      tokenStore: store ?? MemoryTokenStore(),
      httpClient: MockClient(backend.handle),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> signIn(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Device identifier'),
    'REG-1',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Device secret'),
    'good-secret',
  );
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Staff ID'), 'S1');
  await tester.enterText(find.widgetWithText(TextField, 'PIN'), '1234');
  await tester.pump();
  await tester.tap(find.text('Sign in'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Open shift'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'first launch shows device registration; the button is disabled until both fields are filled',
    (tester) async {
      await pumpApp(tester, MockBackend());
      expect(find.text('Register this device'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
            .onPressed,
        isNull,
      );
      final secret = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Device secret'),
      );
      expect(secret.obscureText, isTrue);
    },
  );

  testWidgets(
    'bad device credentials show the backend message and stay on the screen',
    (tester) async {
      await pumpApp(tester, MockBackend());
      await tester.enterText(
        find.widgetWithText(TextField, 'Device identifier'),
        'REG-1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Device secret'),
        'wrong',
      );
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Invalid device credentials'), findsOneWidget);
      expect(find.text('Register this device'), findsOneWidget);
    },
  );

  testWidgets(
    'full flow: device -> staff -> shift -> browse -> add to cart, with the right tokens and body',
    (tester) async {
      final backend = MockBackend();
      final store = MemoryTokenStore();
      await pumpApp(tester, backend, store: store);
      await signIn(tester);

      expect(find.text('Tea'), findsOneWidget);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final add = backend.requests.lastWhere(
        (r) => r.url.path.endsWith('/sales/7/items'),
      );
      expect(jsonDecode(add.body), {
        'product_variation_id': 42,
        'quantity': 1,
        'expected_version': 1,
      });
      expect(add.headers['Authorization'], 'Bearer staff-tok');
      final products = backend.requests.firstWhere(
        (r) => r.url.path.endsWith('/products'),
      );
      expect(products.headers['Authorization'], 'Bearer staff-tok');
      expect(
        find.text('133.28'),
        findsNWidgets(2),
        reason: 'server-computed line total and grand total, shown as received',
      );
      expect(await store.read(TokenKeys.deviceToken), 'device-tok');
    },
  );

  testWidgets('wrong PIN: message shown, cashier stays on the PIN screen', (
    tester,
  ) async {
    await pumpApp(tester, MockBackend());
    await tester.enterText(
      find.widgetWithText(TextField, 'Device identifier'),
      'REG-1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Device secret'),
      'good-secret',
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Staff ID'), 'S1');
    await tester.enterText(find.widgetWithText(TextField, 'PIN'), '0000');
    await tester.pump();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Invalid staff credentials or account unavailable'),
      findsOneWidget,
    );
    expect(find.text('Cashier sign-in'), findsOneWidget);
  });

  testWidgets(
    'a register with an open shift (409) still reaches the products screen',
    (tester) async {
      await pumpApp(tester, MockBackend()..shiftAlreadyOpen = true);
      await signIn(tester);
      expect(find.text('Tea'), findsOneWidget);
    },
  );

  testWidgets(
    'the weight-unit rejection reaches the cashier as a friendly message',
    (tester) async {
      await pumpApp(tester, MockBackend()..weightRejection = {'x': 1});
      await signIn(tester);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.textContaining('sold by weight'), findsOneWidget);
      expect(
        find.textContaining('POS_WEIGHT_UNIT_NOT_SUPPORTED'),
        findsNothing,
        reason: 'the raw code is not shown to the cashier',
      );
    },
  );

  testWidgets(
    'an expired token mid-session returns the cashier to PIN sign-in',
    (tester) async {
      final backend = MockBackend();
      await pumpApp(tester, backend);
      backend.productsUnauthorized = true;
      await signIn(tester);
      expect(find.text('Cashier sign-in'), findsOneWidget);
      expect(
        find.text('Your session has expired. Please sign in again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a saved device token skips registration on the next launch', (
    tester,
  ) async {
    final store = MemoryTokenStore();
    await store.write(TokenKeys.deviceToken, 'device-tok');
    await store.write(TokenKeys.deviceIdentifier, 'REG-1');
    await pumpApp(tester, MockBackend(), store: store);
    expect(find.text('Cashier sign-in'), findsOneWidget);
    expect(find.text('Device REG-1'), findsOneWidget);
  });

  group('cart update and remove through the app', () {
    Future<MockBackend> addTea(
      WidgetTester tester, {
      MemoryTokenStore? store,
    }) async {
      final backend = MockBackend();
      await pumpApp(tester, backend, store: store);
      await signIn(tester);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets(
      '+ updates the quantity with the right line id, body and version; totals are the server\'s',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.byTooltip('Increase quantity'));
        await tester.pumpAndSettle();

        final patch = backend.requests.lastWhere((r) => r.method == 'PATCH');
        expect(patch.url.path, '/api/v1/pos/sales/7/items/1');
        expect(jsonDecode(patch.body), {'quantity': 2, 'expected_version': 2});
        expect(patch.headers['Authorization'], 'Bearer staff-tok');
        expect(find.text('266.56'), findsNWidgets(2));
        expect(find.text('2 × 119.00'), findsOneWidget);
      },
    );

    testWidgets('consecutive updates chain the version token', (tester) async {
      final backend = await addTea(tester);
      await tester.tap(find.byTooltip('Increase quantity'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Increase quantity'));
      await tester.pumpAndSettle();
      final versions = backend.requests
          .where((r) => r.method == 'PATCH')
          .map((r) => jsonDecode(r.body)['expected_version'])
          .toList();
      expect(versions, [2, 3]);
    });

    testWidgets(
      'remove: confirm, DELETE with ?expected_version, cart becomes empty',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.byTooltip('Remove Tea'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();

        final del = backend.requests.lastWhere((r) => r.method == 'DELETE');
        expect(del.url.path, '/api/v1/pos/sales/7/items/1');
        expect(del.url.queryParameters, {'expected_version': '2'});
        expect(find.text('The cart is empty'), findsOneWidget);
        expect(
          find.text('Tea'),
          findsOneWidget,
          reason: 'the product is still browsable in the list',
        );
      },
    );

    testWidgets(
      'a version conflict refreshes to the server state, warns the cashier, and does not retry',
      (tester) async {
        final backend = await addTea(tester);
        backend
          ..conflictAtVersion = 9
          ..conflictQty = 5;
        await tester.tap(find.byTooltip('Increase quantity'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('changed elsewhere and has been refreshed'),
          findsOneWidget,
        );
        expect(
          find.text('5 × 119.00'),
          findsOneWidget,
          reason: 'server state after the refresh',
        );
        expect(
          backend.requests.where((r) => r.method == 'PATCH'),
          hasLength(1),
        );
        expect(
          backend.requests.where(
            (r) => r.method == 'GET' && r.url.path.endsWith('/sales/7'),
          ),
          isNotEmpty,
        );

        // The next tap uses the refreshed version (9).
        await tester.tap(find.byTooltip('Increase quantity'));
        await tester.pumpAndSettle();
        expect(
          jsonDecode(
            backend.requests.lastWhere((r) => r.method == 'PATCH').body,
          )['expected_version'],
          9,
        );
        expect(find.textContaining('changed elsewhere'), findsNothing);
      },
    );

    testWidgets(
      'removing a line that is already gone: friendly message and refreshed cart',
      (tester) async {
        final backend = await addTea(tester);
        // Another device removed the line and the cart moved on; this device still has version 2.
        backend
          ..lineExists = false
          ..qty = 0
          ..version = 2;
        await tester.tap(find.byTooltip('Remove Tea'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        expect(find.textContaining('no longer in the cart'), findsOneWidget);
        expect(
          find.text('The cart is empty'),
          findsOneWidget,
          reason: 'the refreshed cart is empty, with the notice shown above it',
        );
      },
    );

    testWidgets(
      'an expired staff token during an update returns to PIN sign-in, once, keeping the device',
      (tester) async {
        final store = MemoryTokenStore();
        final backend = await addTea(tester, store: store);
        backend.expireStaff = true;
        await tester.tap(find.byTooltip('Increase quantity'));
        await tester.pumpAndSettle();

        expect(find.text('Cashier sign-in'), findsOneWidget);
        expect(
          find.text('Your session has expired. Please sign in again.'),
          findsOneWidget,
        );
        expect(
          await store.read(TokenKeys.deviceToken),
          'device-tok',
          reason: 'one 401 must not also forget the device',
        );
      },
    );
  });

  group('hold and resume through the app', () {
    Future<MockBackend> addTea(
      WidgetTester tester, {
      MemoryTokenStore? store,
    }) async {
      final backend = MockBackend();
      await pumpApp(tester, backend, store: store);
      await signIn(tester);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets(
      'Hold sale: request body and version, cart cleared, held count and list refreshed',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.text('Hold sale'));
        await tester.pumpAndSettle();

        final hold = backend.requests.lastWhere(
          (r) => r.url.path.endsWith('/hold'),
        );
        expect(hold.method, 'POST');
        expect(hold.url.path, '/api/v1/pos/sales/7/hold');
        expect(jsonDecode(hold.body), {'expected_version': 2});
        expect(hold.headers['Authorization'], 'Bearer staff-tok');
        expect(find.text('The cart is empty'), findsOneWidget);
        expect(find.textContaining('Sale #7 is on hold'), findsOneWidget);
        expect(
          find.byTooltip('Held sales (1)'),
          findsOneWidget,
          reason: 'the list was reloaded after the hold',
        );
        final list = backend.requests.lastWhere(
          (r) => r.method == 'GET' && r.url.path == '/api/v1/pos/sales',
        );
        expect(list.url.queryParameters, {'status': 'held'});
      },
    );

    testWidgets(
      'held list -> detail -> Resume: exact requests, cart restored, list emptied',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.text('Hold sale'));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Held sales (1)'));
        await tester.pumpAndSettle();
        expect(find.text('Held sales'), findsOneWidget);
        expect(find.text('Sale #7'), findsOneWidget);
        expect(find.text('Staff: S1'), findsOneWidget);

        await tester.tap(find.text('Sale #7'));
        await tester.pumpAndSettle();
        expect(find.text('Tea'), findsWidgets);
        await tester.tap(find.text('Resume sale'));
        await tester.pumpAndSettle();

        final resume = backend.requests.lastWhere(
          (r) => r.url.path.endsWith('/resume'),
        );
        expect(resume.url.path, '/api/v1/pos/sales/7/resume');
        expect(jsonDecode(resume.body), {'expected_version': 3});
        expect(resume.headers['Authorization'], 'Bearer staff-tok');
        expect(find.text('Sale #7 resumed'), findsOneWidget);
        expect(
          find.byTooltip('Held sales'),
          findsOneWidget,
          reason: 'no held sales remain, so no count badge',
        );
        expect(
          find.text('Hold sale'),
          findsOneWidget,
          reason: 'the resumed draft is editable again',
        );
        expect(find.text('133.28'), findsNWidgets(2));
      },
    );

    testWidgets(
      'resume lost the race (someone else resumed it): message, list refreshed, nothing broken',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.text('Hold sale'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Held sales (1)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sale #7'));
        await tester.pumpAndSettle();

        // Another register resumes it first.
        backend
          ..status = 'draft'
          ..version = 4;
        await tester.tap(find.text('Resume sale'));
        await tester.pumpAndSettle();

        expect(
          find.text(CartController.resumeUnavailableMessage),
          findsOneWidget,
        );
        expect(
          backend.requests.where((r) => r.url.path.endsWith('/resume')),
          hasLength(1),
          reason: 'not retried',
        );
        expect(find.textContaining('already been resumed'), findsOneWidget);
      },
    );

    testWidgets(
      'an expired staff token while holding returns to PIN sign-in once, keeping the device',
      (tester) async {
        final store = MemoryTokenStore();
        final backend = await addTea(tester, store: store);
        backend.expireStaff = true;
        await tester.tap(find.text('Hold sale'));
        await tester.pumpAndSettle();
        expect(find.text('Cashier sign-in'), findsOneWidget);
        expect(await store.read(TokenKeys.deviceToken), 'device-tok');
      },
    );

    testWidgets(
      'the held-sales action is on the app bar with no count when nothing is held',
      (tester) async {
        await addTea(tester);
        expect(find.byTooltip('Held sales'), findsOneWidget);
      },
    );
  });

  group('checkout through the app', () {
    final uuidV4 = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    Finder inModal(Finder f) =>
        find.descendant(of: find.byType(Dialog), matching: f);

    Future<MockBackend> addTea(WidgetTester tester) async {
      final backend = MockBackend();
      await pumpApp(tester, backend);
      await signIn(tester);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      return backend;
    }

    Future<void> payExact(WidgetTester tester) async {
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exact'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'cash sale: exact request contract, receipt from server values, New Sale returns to the catalog',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.text('Pay'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Amount tendered'),
          '150',
        );
        await tester.pump();
        expect(
          inModal(find.text('16.72')),
          findsOneWidget,
          reason: 'change preview: 150 - 133.28',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
        await tester.pumpAndSettle();

        final req = backend.requests.lastWhere(
          (r) => r.url.path.endsWith('/complete'),
        );
        expect(req.url.path, '/api/v1/pos/sales/7/complete');
        expect(req.headers['Authorization'], 'Bearer staff-tok');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {
          'expected_version',
          'idempotency_key',
          'payments',
        });
        expect(body['expected_version'], 2);
        expect(body['idempotency_key'], matches(uuidV4));
        expect(body['payments'], [
          {'method': 'cash', 'amount': 133.28, 'tendered_amount': 150},
        ]);

        expect(find.text('Sale complete'), findsOneWidget);
        expect(inModal(find.text('POS-00000007')), findsOneWidget);
        expect(inModal(find.text('Tea')), findsOneWidget);
        expect(inModal(find.text('133.28')), findsWidgets);
        expect(
          inModal(find.text('16.72')),
          findsWidgets,
          reason: 'the server change, not a client calculation',
        );

        await tester.tap(find.text('New Sale'));
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsNothing);
        expect(find.text('The cart is empty'), findsOneWidget);
        expect(
          find.text('Tea'),
          findsOneWidget,
          reason: 'the catalog is usable again',
        );
      },
    );

    testWidgets('split tender: two payments summing to the total', (
      tester,
    ) async {
      final backend = await addTea(tester);
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Split'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Cash amount'),
        '100',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
      await tester.pumpAndSettle();
      final payments =
          (jsonDecode(
                backend.requests
                    .lastWhere((r) => r.url.path.endsWith('/complete'))
                    .body,
              )['payments']
              as List);
      expect(payments, [
        {'method': 'cash', 'amount': 100, 'tendered_amount': 100},
        {'method': 'card', 'amount': 33.28},
      ]);
      expect(backend.completionCount, 1);
      expect(find.text('Sale complete'), findsOneWidget);
    });

    testWidgets(
      'the response is LOST after the server recorded the sale: retry sends the SAME key and the server replays — one sale, no double charge',
      (tester) async {
        final backend = await addTea(tester);
        backend.dropNextCompleteResponse = true;
        await payExact(tester);

        expect(backend.completionCount, 1, reason: 'the server did record it');
        expect(
          find.text('Sale complete'),
          findsNothing,
          reason: 'the client cannot know yet',
        );
        expect(find.textContaining('Cannot reach the server'), findsOneWidget);
        expect(find.text('Retry payment'), findsOneWidget);

        await tester.tap(find.text('Retry payment'));
        await tester.pumpAndSettle();

        expect(backend.completeBodies, hasLength(2));
        expect(
          backend.completeBodies.first['idempotency_key'],
          backend.completeBodies.last['idempotency_key'],
        );
        expect(
          backend.completeBodies.first['expected_version'],
          backend.completeBodies.last['expected_version'],
        );
        expect(
          backend.completionCount,
          1,
          reason: 'still exactly one completed sale',
        );
        expect(find.text('Sale complete'), findsOneWidget);
        expect(inModal(find.text('POS-00000007')), findsOneWidget);
      },
    );

    testWidgets(
      'changing the payment after a lost response cannot double-charge: the server refuses a second completion',
      (tester) async {
        final backend = await addTea(tester);
        backend.dropNextCompleteResponse = true;
        await payExact(tester);
        // A different tender means a different request (and a new key)...
        await tester.tap(find.widgetWithText(ChoiceChip, 'Card'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Retry payment'));
        await tester.pumpAndSettle();
        expect(
          backend.completeBodies.map((b) => b['idempotency_key']).toSet(),
          hasLength(2),
        );
        // ...but the sale is already completed on the server, so nothing is charged twice.
        expect(backend.completionCount, 1);
        expect(find.textContaining('Sale already completed'), findsOneWidget);
        expect(find.text('Sale complete'), findsNothing);
      },
    );

    testWidgets(
      'a payment that does not cover the total is refused by the server and shown',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.text('Pay'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Split'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Cash amount'),
          '100',
        );
        await tester.pump();
        // Tamper with what the server thinks is due (another device changed the quantity).
        backend.qty = 5;
        await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('must equal the sale total'),
          findsOneWidget,
        );
        expect(backend.completionCount, 0);
      },
    );

    testWidgets(
      'an expired staff token while paying returns to PIN sign-in once',
      (tester) async {
        final backend = await addTea(tester);
        backend.expireStaff = true;
        await payExact(tester);
        await tester.pumpAndSettle();
        expect(find.text('Cashier sign-in'), findsOneWidget);
      },
    );

    testWidgets(
      'Void sale: confirmation, cancel request with the version, cart cleared',
      (tester) async {
        final backend = await addTea(tester);
        await tester.tap(find.text('Void sale'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Void sale'),
          ),
        );
        await tester.pumpAndSettle();
        expect(backend.cancelBodies, [
          {'expected_version': 2},
        ]);
        expect(find.text('The cart is empty'), findsOneWidget);
        expect(find.text('Sale #7 voided'), findsOneWidget);
      },
    );

    testWidgets('a chosen customer ID is sent when the sale is created', (
      tester,
    ) async {
      final backend = MockBackend();
      await pumpApp(tester, backend);
      await signIn(tester);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Customer ID').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Customer ID'),
        'C-42',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(backend.lastCreateBody, {'customer_id': 'C-42'});
      expect(find.text('Customer C-42'), findsOneWidget);
    });

    testWidgets('guest checkout sends no customer', (tester) async {
      final backend = await addTea(tester);
      expect(backend.lastCreateBody, <String, dynamic>{});
    });
  });
}
