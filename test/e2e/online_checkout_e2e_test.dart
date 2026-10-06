// Phase 5 — END-TO-END smoke: the normal ONLINE checkout with the real app
// code (PosApiClient, ApiProductService, CartController) against the REAL
// backend routes on the isolated test database.
//
// Skipped unless OFFLINE_E2E_CONFIG points at the JSON written by
// buskit-web/test/pos/e2e/offlineSyncE2eServer.js (local test DB only).
// Run against a FRESH server.
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/json_read.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/products/data/product_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cfgPath = Platform.environment['OFFLINE_E2E_CONFIG'];
  final skip = cfgPath == null
      ? 'needs OFFLINE_E2E_CONFIG (buskit-web test/pos/e2e/offlineSyncE2eServer.js)'
      : null;

  test(
    'login -> open shift -> find product -> add -> cash checkout -> sale completed -> stock deducted (once)',
    () async {
      final cfg = asMap(jsonDecode(File(cfgPath!).readAsStringSync()))!;
      String? token;
      final client = PosApiClient(
        baseUrl: cfg['base_url'] as String,
        tokenProvider: () => token,
      );
      final login = await client.post(
        '/auth/staff-login',
        body: {'salesman_id': cfg['salesman_id'], 'pin': cfg['pin']},
        token: cfg['device_token'] as String,
        notifyUnauthorized: false,
      );
      token = asString(asMap(login)!['token']);
      final shiftId = asInt(
        asMap(
          await client.post('/shifts/open', body: {'opening_amount': 0}),
        )!['id'],
      )!;

      // Find the product by search, as the catalogue screen does.
      final products = ApiProductService(client);
      final page = await products.search(query: 'TEST');
      final product = page.items.firstWhere((p) => p.id == 2);
      final stockBefore = product.currentStock!;

      final cart = CartController(ApiCartService(client));
      expect(
        await cart.addItem(product.id, 3),
        isTrue,
        reason: '${cart.error?.message}',
      );
      expect(cart.isLocalSale, isFalse);
      final total = (cart.sale!.totals.grandTotal! * 1000).round();
      final payment = PaymentLine(
        method: TenderMethod.cash,
        amountMilli: total,
        tenderedMilli: total + 20000,
      );
      expect(
        await cart.completeSale([payment]),
        isTrue,
        reason: '${cart.error?.message}',
      );
      final done = cart.completedSale!;
      expect(done.status, 'completed');

      final sale = asMap(await client.get('/sales/${done.id}'))!;
      expect(sale['status'], 'completed');
      expect(sale['shift_id'], shiftId);
      final pay = asMap(asList(sale['payments']).single)!;
      expect([pay['method'], pay['change_due']], ['cash', 20]);
      final after = (await products.findById(2))!;
      expect(
        after.currentStock,
        stockBefore - 3,
        reason: 'stock deducted on the server',
      );
      expect(
        asList(
          await client.get(
            '/sales',
            query: {'status': 'completed', 'range': 'today'},
          ),
        ).length,
        1,
      );
      client.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
