// Phase 6 — recovery wiring on the real POS page: the check runs at start-up
// and when the connection returns with an empty cart (never over a sale being
// rung up), and the pay screen leaves a local reminder (sale id only) BEFORE a
// provider payment starts.
import 'dart:io';

import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';
import 'payment_recovery_test.dart'
    show FakeRecoveryService, recoverableJson, attemptJson;
import 'terminal_payment_test.dart' show FakeTerminalService, pineLabsJson;

void main() {
  testWidgets(
    'start-up: an unfinished captured payment of this device opens Payment Recovery automatically',
    (tester) async {
      final recovery = FakeRecoveryService()
        ..current = FakeRecoveryService.result([recoverableJson()]);
      final h = PageHarness()..recovery = recovery;
      await pumpProductsPage(tester, h);
      expect(find.text('Payment Recovery'), findsOneWidget);
      expect(find.byKey(const Key('recovery-resume')), findsOneWidget);
      expect(recovery.fetchCalls.length, 1);
    },
  );

  testWidgets(
    'start-up with nothing to recover: no screen; the connection coming back (empty cart) checks again; never while a sale is in the cart',
    (tester) async {
      final recovery = FakeRecoveryService();
      final h = PageHarness()..recovery = recovery;
      await pumpProductsPage(tester, h);
      expect(find.text('Payment Recovery'), findsNothing);
      expect(recovery.fetchCalls.length, 1);

      h.client.reachable.value = false;
      await tester.pump();
      recovery.current = FakeRecoveryService.result([
        recoverableJson(
          state: 'PAYMENT_PENDING',
          canComplete: false,
          nextAction: 'CHECK_PAYMENT',
          attempts: [attemptJson(status: 'PENDING')],
        ),
      ]);
      h.client.reachable.value = true;
      await tester.pumpAndSettle();
      expect(recovery.fetchCalls.length, 2);
      expect(find.text('Payment pending'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recovery-later')));
      await tester.pumpAndSettle();

      // A sale is being rung up: a reconnect does not interrupt it.
      CartSale sale() => CartSaleFactory.sale(
        items: [lineJson(id: 1, quantity: 1, name: 'Tea')],
        total: 10,
      );
      h.carts.onAdd = (_) async => sale();
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      h.client.reachable.value = false;
      await tester.pump();
      h.client.reachable.value = true;
      await tester.pumpAndSettle();
      expect(
        recovery.fetchCalls.length,
        2,
        reason: 'not checked over an open sale',
      );
      expect(find.text('Payment Recovery'), findsNothing);
    },
  );

  testWidgets(
    'the pay screen saves the recovery reminder (sale id) BEFORE the terminal payment starts',
    (tester) async {
      late Directory root;
      late OfflineStorageService storage;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('pos_rec_page_');
        storage = OfflineStorageService(root);
        await storage.initialize();
      });
      addTearDown(() => root.delete(recursive: true));
      final terminal = FakeTerminalService()
        ..providers = [PaymentProviderInfo.fromJson(pineLabsJson)!];
      List<int>? markersAtStart;
      terminal.onStart = (_) async {
        markersAtStart = await storage.getPaymentRecoveryMarkers();
        return PaymentAttempt.fromJson({
          'id': 1,
          'status': 'PENDING',
          'amount': 112,
        })!;
      };
      final h = PageHarness(offline: OfflineServices(storage))
        ..terminal = terminal;
      CartSale sale() => CartSaleFactory.sale(
        items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
        total: 112,
      );
      h.carts.onAdd = (_) async => sale();
      h.carts.onGet = (_) async => sale();
      await pumpProductsPage(tester, h);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Card').last);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.textContaining('Pay on terminal'));
        for (var i = 0; i < 50 && markersAtStart == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(markersAtStart, [7], reason: 'reminder written first');
      // Leave the terminal dialog (pending) cleanly.
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
