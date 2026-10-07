// Offline POS Phase 2 — offline checkout, end to end against REAL JSON files
// in a temporary directory: CartController (the real checkout controller)
// -> OfflineCheckoutService -> OfflineSale -> sales/<id>.json + queue/<id>.json.
// Only the server (CartService) is faked; local storage is never mocked.
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_payment_policy.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_customer_service.dart';
import '../../support/fakes.dart';

late Directory root;
late OfflineStorageService storage;
late FakeCartService server;
late CartController cart;
bool offline = true;
PosTokenScope? scope;
final List<CartSale> serverSales = [];

const soap = OfflineProduct(
  productVariationId: 1,
  productName: 'Soap',
  sellingMode: 'PIECE',
  sellPriceMilli: 100000,
  taxPercent: 12,
  taxMode: 'exclusive',
);
const oil = OfflineProduct(
  productVariationId: 2,
  productName: 'Oil',
  sellingMode: 'PIECE',
  sellPriceMilli: 236000,
  taxPercent: 18,
  taxMode: 'inclusive',
);
const apples = OfflineProduct(
  productVariationId: 3,
  productName: 'Apples',
  sellingMode: 'WEIGHT',
  sellPriceMilli: 150000,
  taxPercent: 0,
  taxMode: 'none',
);

const theScope = PosTokenScope(
  companyId: 1,
  storeId: 213,
  registerId: 5,
  deviceId: 9,
  salesmanId: 'TEST-SALES-A1',
);

OfflineShiftContext shift({
  String status = 'open',
  int store = 213,
  int register = 5,
  int device = 9,
}) => OfflineShiftContext(
  companyId: 1,
  storeId: store,
  registerId: register,
  deviceId: device,
  shiftId: 79,
  salesmanId: 'TEST-SALES-A1',
  openedAt: DateTime.utc(2026, 10, 6, 8),
  status: status,
  currency: 'INR',
);

List<String> files(String dir) {
  final d = Directory('${root.path}/$dir');
  if (!d.existsSync()) return const [];
  return d
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.json'))
      .toList();
}

Map<String, dynamic> readJson(String rel) =>
    jsonDecode(File('${root.path}/$rel').readAsStringSync())
        as Map<String, dynamic>;

CartController newCart() => CartController(
  server,
  offline: OfflineCartSupport(
    checkout: OfflineCheckoutService(storage),
    isOffline: () => offline,
    scope: () => scope,
    staffName: () => 'Asha',
    onServerSale: serverSales.add,
  ),
);

PaymentLine cash(int amount, {int? tendered}) => PaymentLine(
  method: TenderMethod.cash,
  amountMilli: amount,
  tenderedMilli: tendered ?? amount,
);

Future<void> seed({double soapStock = 10, double oilStock = 5}) async {
  await storage.saveCatalogue(
    OfflineCatalogue(
      companyId: 1,
      storeId: 213,
      // Phase 14G: refreshed just now (fresh for the real-clock checkout).
      cachedAt: DateTime.now().toUtc(),
      products: const [soap, oil, apples],
    ),
  );
  await storage.saveInventory(
    InventorySnapshot(
      syncedAt: DateTime.utc(2026, 10, 6, 8),
      entries: [
        InventorySnapshotEntry(
          productVariationId: 1,
          serverQuantity: soapStock,
        ),
        InventorySnapshotEntry(productVariationId: 2, serverQuantity: oilStock),
        const InventorySnapshotEntry(productVariationId: 3, serverQuantity: 5),
      ],
    ),
  );
  await storage.saveCurrentShift(shift());
  await storage.saveCustomers(const [
    OfflineCustomer(
      id: 11,
      customerId: 'CUST-11',
      fullname: 'Meera K',
      mobileno: '9000000011',
    ),
  ]);
}

/// Soap x2 = 200.000 + 12% tax 24.000 = 224.000 (server figures).
Future<OfflineSale> sellSoap(int qty) async {
  expect(await cart.addItem(1, qty), isTrue, reason: '${cart.error?.message}');
  final total = cart.sale!.totals.grandTotal!;
  expect(
    await cart.completeSale([cash((total * 1000).round())]),
    isTrue,
    reason: '${cart.error?.message}',
  );
  final s = cart.completedOfflineSale!;
  cart.acknowledgeOfflineCompletion();
  return s;
}

/// A server draft as the live sale view returns it: soap x2, server-priced.
CartSale serverDraft({Map<String, dynamic>? promotion, int shiftId = 79}) =>
    CartSale.fromJson({
      ...saleJson(
        id: 7,
        version: 3,
        items: [
          lineJson(
            id: 501,
            variationId: 1,
            quantity: 2,
            name: 'Soap',
            unitPrice: 100,
            tax: 24,
            taxPercent: 12,
            lineTotal: 224,
          ),
        ],
        subtotal: 200,
        tax: 24,
        total: 224,
        promotion: promotion,
      ),
      'shift_id': shiftId,
      'store_id': 213,
      'register_id': 5,
    })!;

void main() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pos_offline_checkout_');
    storage = OfflineStorageService(root);
    await storage.initialize();
    server = FakeCartService();
    offline = true;
    scope = theScope;
    serverSales.clear();
    await seed();
    cart = newCart();
  });

  tearDown(() async {
    await Process.run('chmod', ['-R', 'u+w', root.path]);
    await root.delete(recursive: true);
  });

  group('offline checkout', () {
    test('cash sale: UUID, no server id, QUEUED, queue entry, cash tendered and change stored; the server is never called', () async {
      expect(await cart.addItem(1, 2), isTrue);
      expect(cart.isLocalSale, isTrue);
      expect(cart.sale!.isLocal, isTrue);
      expect(cart.sale!.totals.grandTotal, 224);
      expect(cart.willCompleteOffline, isTrue);

      final ok = await cart.completeSale([cash(224000, tendered: 300000)]);
      expect(ok, isTrue, reason: '${cart.error?.message}');
      final sale = cart.completedOfflineSale!;
      expect(OfflineSale.idPattern.hasMatch(sale.localSaleId), isTrue);
      expect(sale.serverSaleId, isNull);
      expect(sale.status, OfflineSaleStatus.queued);
      expect(sale.displayReference, startsWith('LOCAL-'));
      expect(sale.displayReference.length, 'LOCAL-'.length + 8);

      expect(files('sales'), ['${sale.localSaleId}.json']);
      expect(files('queue'), ['${sale.localSaleId}.json']);
      final onDisk = readJson('sales/${sale.localSaleId}.json')['data'];
      expect(onDisk['status'], 'QUEUED');
      expect(onDisk['server_sale_id'], isNull);
      expect(onDisk['company_id'], 1);
      expect(onDisk['store_id'], 213);
      expect(onDisk['register_id'], 5);
      expect(onDisk['device_id'], 9);
      expect(onDisk['shift_id'], 79);
      expect(onDisk['salesman_id'], 'TEST-SALES-A1');
      expect(onDisk['salesman_name'], 'Asha');
      expect(onDisk['currency'], 'INR');
      expect(onDisk['source_draft_sale_id'], isNull);
      final pay = (onDisk['payments'] as List).single as Map;
      expect(pay['method'], 'cash');
      expect(pay['provider'], 'NONE');
      expect(pay['amount_milli'], 224000);
      expect(pay['tendered_milli'], 300000);
      expect(pay['change_milli'], 76000);
      final queue = readJson('queue/${sale.localSaleId}.json')['data'];
      expect(queue['status'], 'PENDING');
      expect(queue['entity_type'], 'sale');

      // Cart cleared only after the save; nothing went to the server.
      expect(cart.sale, isNull);
      expect(server.createCalls, 0);
      expect(server.addCalls, isEmpty);
      expect(server.completeCalls, isEmpty);
    });

    test(
      'the sale survives an app restart and is listed as a pending local sale',
      () async {
        final sale = await sellSoap(2);
        final reopened = OfflineStorageService(root);
        await reopened.initialize();
        final again = await reopened.getSale(sale.localSaleId);
        expect(again!.status, OfflineSaleStatus.queued);
        expect(again.lines.single.quantity, 2);
        expect((await reopened.getQueueEntry(sale.localSaleId)), isNotNull);
        expect((await reopened.getPendingSales()).map((s) => s.localSaleId), [
          sale.localSaleId,
        ]);
        expect(again.status.label, 'Saved on this device — not yet synced');
      },
    );

    test('every sale gets a different UUID', () async {
      final a = await sellSoap(1);
      final b = await sellSoap(1);
      expect(a.localSaleId, isNot(b.localSaleId));
      expect(files('queue').toSet(), {
        '${a.localSaleId}.json',
        '${b.localSaleId}.json',
      });
    });
  });

  group('payments', () {
    Future<bool> payWith(PaymentLine p) async {
      await cart.addItem(1, 2);
      return cart.completeSale([p]);
    }

    test(
      'manual CARD is refused by default and allowed once enabled in settings',
      () async {
        final card = PaymentLine(
          method: TenderMethod.card,
          amountMilli: 224000,
        );
        expect(await payWith(card), isFalse);
        expect(cart.error!.message, OfflinePaymentPolicy.onlineRequiredMessage);
        expect(files('sales'), isEmpty);
        expect(cart.sale!.items, isNotEmpty, reason: 'cart kept');

        await storage.saveSettings(
          const OfflineSettings(offlineManualTenders: {'card'}),
        );
        expect(await cart.completeSale([card]), isTrue);
        expect(cart.completedOfflineSale!.payments.single.method, 'card');
      },
    );

    test(
      'manual OTHER is refused by default and allowed once enabled in settings',
      () async {
        final other = PaymentLine(
          method: TenderMethod.other,
          amountMilli: 224000,
          reference: 'UPI-SLIP-1',
        );
        expect(await payWith(other), isFalse);
        expect(files('sales'), isEmpty);
        await storage.saveSettings(
          const OfflineSettings(offlineManualTenders: {'other'}),
        );
        expect(await cart.completeSale([other]), isTrue);
        expect(
          cart.completedOfflineSale!.payments.single.reference,
          'UPI-SLIP-1',
        );
      },
    );

    test('Razorpay (QR, provider payment attempt) is refused offline — nothing saved', () async {
      await storage.saveSettings(
        const OfflineSettings(offlineManualTenders: {'other', 'card'}),
      );
      final razorpay = PaymentLine(
        method: TenderMethod.other,
        amountMilli: 224000,
        paymentAttemptId: 31,
      );
      expect(await payWith(razorpay), isFalse);
      expect(
        cart.error!.message,
        'Internet connection is required for this payment method.',
      );
      expect(files('sales'), isEmpty);
      expect(files('queue'), isEmpty);
    });

    test(
      'Pine Labs (card terminal attempt) is refused offline — nothing saved',
      () async {
        await storage.saveSettings(
          const OfflineSettings(offlineManualTenders: {'card'}),
        );
        final pine = PaymentLine(
          method: TenderMethod.card,
          amountMilli: 224000,
          paymentAttemptId: 32,
        );
        expect(await payWith(pine), isFalse);
        expect(
          cart.error!.message,
          'Internet connection is required for this payment method.',
        );
        expect(files('sales'), isEmpty);
      },
    );

    test('any future provider (provider != NONE) is refused offline, even for cash', () {
      const policy = OfflinePaymentPolicy(
        OfflineSettings(offlineManualTenders: {'card', 'other'}),
      );
      for (final provider in ['STRIPE', 'PHONEPE', 'ANY_FUTURE']) {
        for (final method in ['cash', 'card', 'other']) {
          expect(
            policy.check(method: method, provider: provider),
            OfflinePaymentPolicy.onlineRequiredMessage,
          );
        }
      }
    });

    test('payment total must equal the sale total (short and over-paid are refused)', () async {
      await cart.addItem(1, 2);
      expect(await cart.completeSale([cash(200000)]), isFalse);
      expect(cart.error!.message, OfflineCheckoutService.paymentTotalMessage);
      expect(await cart.completeSale([cash(230000)]), isFalse);
      expect(files('sales'), isEmpty);
    });
  });

  group('stock', () {
    test('sale succeeds within local stock; insufficient stock is refused with the server and offline figures', () async {
      await sellSoap(3); // server 10, 3 sold offline -> 7 available
      expect(await cart.addItem(1, 8), isFalse);
      expect(
        cart.error!.message,
        'Insufficient offline stock for "Soap". Last server stock: 10. Available offline stock: 7.',
      );
      expect(await cart.addItem(1, 7), isTrue);
      expect(await cart.completeSale([cash(784000)]), isTrue);
    });

    test('multiple offline sales reduce the available stock; unsynced sales count, the server figure is untouched', () async {
      await sellSoap(2);
      await sellSoap(3);
      final level = (await storage.getStockLevels())[1]!;
      expect(level.serverQuantity, 10);
      expect(level.offlineConsumedQuantity, 5);
      expect(level.availableQuantity, 5);
      final inv = readJson('inventory.json')['data'];
      expect(
        (inv['entries'] as List).first['server_quantity'],
        10,
        reason: 'snapshot never rewritten',
      );
    });

    test(
      'the final check at payment also refuses when stock ran out meanwhile',
      () async {
        await cart.addItem(1, 4);
        // Another sale on this device took 7 of the 10 in the meantime.
        final other = newCart();
        expect(await other.addItem(1, 7), isTrue);
        expect(await other.completeSale([cash(784000)]), isTrue);
        expect(await cart.completeSale([cash(448000)]), isFalse);
        expect(cart.error!.message, contains('Available offline stock: 3'));
        expect(files('sales').length, 1);
      },
    );

    test(
      'a product without offline stock information cannot be sold',
      () async {
        await storage.saveInventory(
          InventorySnapshot(syncedAt: DateTime.utc(2026), entries: const []),
        );
        expect(await cart.addItem(1, 1), isFalse);
        expect(
          cart.error!.message,
          OfflineCheckoutService.noStockInfoMessage('Soap'),
        );
      },
    );
  });

  group('price snapshot', () {
    test('the sale keeps the price, tax and totals the cashier saw', () async {
      final sale = await sellSoap(2);
      final line = sale.lines.single;
      expect(line.unitPriceMilli, 100000);
      expect(line.quantity, 2);
      expect(line.taxPercent, 12);
      expect(line.taxMode, 'exclusive');
      expect(line.taxAmountMilli, 24000);
      expect(line.discountAmountMilli, 0);
      expect(line.lineTotalMilli, 224000);
      expect(sale.subtotalMilli, 200000);
      expect(sale.taxTotalMilli, 24000);
      expect(sale.grandTotalMilli, 224000);
    });

    test('changing the cached product price later never changes an existing offline sale (or a line already in the cart)', () async {
      final sale = await sellSoap(2);
      expect(await cart.addItem(2, 1), isTrue); // oil at 236.000
      await storage.saveCatalogue(
        OfflineCatalogue(
          companyId: 1,
          storeId: 213,
          cachedAt: DateTime.now().toUtc(),
          products: const [
            OfflineProduct(
              productVariationId: 1,
              productName: 'Soap',
              sellingMode: 'PIECE',
              sellPriceMilli: 150000,
              taxPercent: 12,
              taxMode: 'exclusive',
            ),
            OfflineProduct(
              productVariationId: 2,
              productName: 'Oil',
              sellingMode: 'PIECE',
              sellPriceMilli: 999000,
              taxPercent: 18,
              taxMode: 'inclusive',
            ),
          ],
        ),
      );
      final stored = (await storage.getSale(sale.localSaleId))!;
      expect(stored.lines.single.unitPriceMilli, 100000);
      expect(stored.grandTotalMilli, 224000);
      expect(cart.sale!.items.single.unitPrice, 236);
      expect(await cart.updateQuantity(2, 2), isTrue);
      expect(cart.sale!.totals.grandTotal, 472, reason: 'snapshot price kept');
    });
  });

  group('shift and scope', () {
    Future<void> expectRefused(String message) async {
      await cart.addItem(1, 1);
      expect(await cart.completeSale([cash(112000)]), isFalse);
      expect(cart.error!.message, message);
      expect(files('sales'), isEmpty);
      expect(files('queue'), isEmpty);
    }

    test(
      'no stored shift -> "Open a shift before making an offline sale."',
      () async {
        await storage.clearCurrentShift();
        await expectRefused('Open a shift before making an offline sale.');
      },
    );

    test('closed shift -> refused', () async {
      await storage.saveCurrentShift(shift(status: 'closed'));
      await expectRefused(OfflineCheckoutService.shiftClosedMessage);
    });

    test('wrong store, register or device -> refused', () async {
      for (final s in [
        shift(store: 999),
        shift(register: 6),
        shift(device: 10),
      ]) {
        await storage.saveCurrentShift(s);
        cart = newCart();
        await expectRefused(OfflineCheckoutService.scopeMismatchMessage);
      }
    });

    test('no signed-in staff session -> refused', () async {
      scope = null;
      await expectRefused(OfflineCheckoutService.noSessionMessage);
    });
  });

  group('customer', () {
    test(
      'a cached customer can be used: the sale stores the customer',
      () async {
        expect(cart.setPendingCustomer('CUST-11', label: 'Meera K'), isTrue);
        final sale = await sellSoap(1);
        expect(sale.customerId, 'CUST-11');
        expect(sale.customerName, 'Meera K');
      },
    );

    test('an uncached customer cannot be found offline and a sale for one is refused', () async {
      final customers = OfflineCustomerService(
        FakeCustomerService(),
        storage,
        isOffline: () => true,
      );
      expect(
        (await customers.search(query: 'Meera')).items.single.customerId,
        'CUST-11',
      );
      expect((await customers.search(query: 'Nobody')).items, isEmpty);
      expect(await customers.findByCustomerId('CUST-99'), isNull);
      expect(
        () => customers.create(fullname: 'New', mobileno: '9'),
        throwsA(isA<ApiException>()),
      );

      cart.setPendingCustomer('CUST-99', label: 'Unknown');
      await cart.addItem(1, 1);
      expect(await cart.completeSale([cash(112000)]), isFalse);
      expect(
        cart.error!.message,
        OfflineCheckoutService.customerNotCachedMessage,
      );
      expect(files('sales'), isEmpty);
    });
  });

  group('validation', () {
    test('empty cart is refused', () async {
      expect(await cart.completeSale([cash(1000)]), isFalse);
      expect(cart.error!.message, CartController.emptyCompleteMessage);
      final svc = OfflineCheckoutService(storage);
      await expectLater(
        svc.complete(
          OfflineCheckoutRequest(
            localSaleId: '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c',
            scope: theScope,
            lines: const [],
            payments: [cash(1000)],
          ),
        ),
        throwsA(
          isA<OfflineCheckoutRejected>().having(
            (e) => e.message,
            'message',
            OfflineCheckoutService.emptyCartMessage,
          ),
        ),
      );
      expect(files('sales'), isEmpty);
    });

    test('invalid quantities are refused (cart and service)', () async {
      expect(await cart.addItem(1, 0), isFalse);
      expect(await cart.addItem(1, -2), isFalse);
      final svc = OfflineCheckoutService(storage);
      final zero = OfflineCheckoutLine.fromProduct(soap, 1);
      await expectLater(
        svc.complete(
          OfflineCheckoutRequest(
            localSaleId: '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c',
            scope: theScope,
            lines: [
              OfflineCheckoutLine(
                productVariationId: 1,
                productName: 'Soap',
                quantity: 0,
                unitPriceMilli: zero.unitPriceMilli,
                taxPercent: 12,
                taxMode: 'exclusive',
                taxAmountMilli: 0,
                lineTotalMilli: 0,
              ),
            ],
            payments: [cash(1000)],
          ),
        ),
        throwsA(
          isA<OfflineCheckoutRejected>().having(
            (e) => e.message,
            'message',
            OfflineCheckoutService.invalidQuantityMessage,
          ),
        ),
      );
      expect(files('sales'), isEmpty);
    });

    test('a tampered line/sale total (not what the server tax rule gives) is refused', () async {
      final svc = OfflineCheckoutService(storage);
      for (final bad in [
        const OfflineCheckoutLine(
          productVariationId: 1,
          productName: 'Soap',
          quantity: 2,
          unitPriceMilli: 100000,
          taxPercent: 12,
          taxMode: 'exclusive',
          taxAmountMilli: 20000,
          lineTotalMilli: 220000,
        ),
        const OfflineCheckoutLine(
          productVariationId: 1,
          productName: 'Soap',
          quantity: 2,
          unitPriceMilli: 100000,
          taxPercent: 12,
          taxMode: 'exclusive',
          taxAmountMilli: 24000,
          lineTotalMilli: 200000,
        ),
      ]) {
        await expectLater(
          svc.complete(
            OfflineCheckoutRequest(
              localSaleId: '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c',
              scope: theScope,
              lines: [bad],
              payments: [cash(bad.lineTotalMilli)],
            ),
          ),
          throwsA(
            isA<OfflineCheckoutRejected>().having(
              (e) => e.message,
              'message',
              OfflineCheckoutService.totalsMessage,
            ),
          ),
        );
      }
      expect(files('sales'), isEmpty);
      // The model's own check refuses inconsistent stored totals too.
      final s = OfflineSale(
        localSaleId: '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c',
        status: OfflineSaleStatus.completedLocal,
        companyId: 1,
        storeId: 213,
        registerId: 5,
        shiftId: 79,
        salesmanId: 'S',
        installationId: 'i',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        lines: const [
          OfflineSaleLine(
            productVariationId: 1,
            productName: 'Soap',
            quantity: 1,
            unitPriceMilli: 100000,
            taxPercent: 12,
            taxMode: 'exclusive',
            taxAmountMilli: 12000,
            lineTotalMilli: 100000,
          ),
        ],
        payments: const [OfflinePayment(method: 'cash', amountMilli: 100000)],
        subtotalMilli: 100000,
        taxTotalMilli: 12000,
        discountTotalMilli: 0,
        grandTotalMilli: 100000,
      );
      expect(s.validateCompleted(), contains('line total'));
    });

    test(
      'WEIGHT/REVIEW products and uncached products cannot be sold offline',
      () async {
        expect(await cart.addItem(3, 1), isFalse);
        expect(cart.error!.message, contains('only items sold by the piece'));
        expect(await cart.addItem(404, 1, label: 'Ghost'), isFalse);
        expect(
          cart.error!.message,
          OfflineCheckoutService.notInCatalogueMessage('Ghost'),
        );
      },
    );
  });

  group('failure and recovery', () {
    test('a failed JSON write is never reported as completed: cart kept; retry finishes the SAME sale with one queue entry', () async {
      await cart.addItem(1, 2);
      final queueDir = '${root.path}/queue';
      await Process.run('chmod', ['555', queueDir]);
      expect(await cart.completeSale([cash(224000)]), isFalse);
      expect(
        cart.error!.message,
        'Unable to save the sale on this device. Please do not leave this screen and contact support.',
      );
      expect(cart.completedOfflineSale, isNull);
      expect(cart.sale!.items.single.quantity, 2, reason: 'cart not cleared');
      final written = files('sales');
      expect(
        written.length,
        1,
        reason: 'the sale file was written before the queue failed',
      );
      expect(files('queue'), isEmpty);

      await Process.run('chmod', ['755', queueDir]);
      expect(await cart.completeSale([cash(224000)]), isTrue);
      final sale = cart.completedOfflineSale!;
      expect(
        '${sale.localSaleId}.json',
        written.single,
        reason: 'same sale, not a second one',
      );
      expect(sale.status, OfflineSaleStatus.queued);
      expect(files('sales').length, 1);
      expect(files('queue'), ['${sale.localSaleId}.json']);
    });

    test('restart after a partial save: recovery rebuilds the queue entry, marks the sale QUEUED, and never duplicates it', () async {
      await cart.addItem(1, 2);
      await Process.run('chmod', ['555', '${root.path}/queue']);
      expect(await cart.completeSale([cash(224000)]), isFalse);
      await Process.run('chmod', ['755', '${root.path}/queue']);
      final id = files('sales').single.replaceAll('.json', '');
      expect(readJson('sales/$id.json')['data']['status'], 'COMPLETED_LOCAL');

      final restarted = OfflineStorageService(root);
      final report = await restarted.initialize();
      expect(report.recreatedQueueEntries, [id]);
      expect(report.promotedToQueued, [id]);
      expect((await restarted.getSale(id))!.status, OfflineSaleStatus.queued);
      expect(files('queue'), ['$id.json']);

      final second = await OfflineStorageService(root).initialize();
      expect(second.recreatedQueueEntries, isEmpty);
      expect(second.promotedToQueued, isEmpty);
      expect(files('queue'), ['$id.json']);
    });

    test(
      'nothing was saved when the sales folder itself cannot be written',
      () async {
        await cart.addItem(1, 1);
        await Process.run('chmod', ['555', '${root.path}/sales']);
        expect(await cart.completeSale([cash(112000)]), isFalse);
        expect(
          cart.error!.message,
          OfflineCheckoutService.storageFailureMessage,
        );
        await Process.run('chmod', ['755', '${root.path}/sales']);
        expect(files('sales'), isEmpty);
        expect(files('queue'), isEmpty);
        expect(cart.sale!.items, isNotEmpty);
      },
    );
  });

  group('online / offline transitions', () {
    test('ONLINE (reachable true or unknown): the existing server checkout runs, nothing is stored locally', () async {
      offline = false;
      server.onAdd = (_) async => serverDraft();
      expect(await cart.addItem(1, 2), isTrue);
      expect(cart.isLocalSale, isFalse);
      expect(server.addCalls, hasLength(1));
      expect(cart.willCompleteOffline, isFalse);
      expect(await cart.completeSale([cash(224000)]), isTrue);
      expect(server.completeCalls, hasLength(1));
      expect(cart.completedSale, isNotNull);
      expect(cart.completedOfflineSale, isNull);
      expect(files('sales'), isEmpty);
      expect(files('queue'), isEmpty);
    });

    test('CASE 1: cart opened online, connection lost, sale completed -> stored locally with the server draft id; the draft is never completed', () async {
      offline = false;
      server.onAdd = (_) async => serverDraft();
      await cart.addItem(1, 2);
      offline = true;
      expect(cart.willCompleteOffline, isTrue);
      expect(
        await cart.completeSale([cash(224000, tendered: 250000)]),
        isTrue,
        reason: '${cart.error?.message}',
      );
      final sale = cart.completedOfflineSale!;
      expect(sale.sourceDraftSaleId, 7);
      expect(sale.lines.single.lineTotalMilli, 224000);
      expect(sale.payments.single.changeMilli, 26000);
      expect(server.completeCalls, isEmpty);
      expect(cart.sale, isNull);
    });

    test(
      'CASE 1 with a promotion (server-only discount) is refused offline',
      () async {
        offline = false;
        server.onAdd = (_) async => serverDraft(
          promotion: {
            'id': 1,
            'title': 'Diwali',
            'eligible': true,
            'discount_amount': 10,
          },
        );
        await cart.addItem(1, 2);
        offline = true;
        expect(await cart.completeSale([cash(224000)]), isFalse);
        expect(
          cart.error!.message,
          OfflineCheckoutService.serverDiscountsMessage,
        );
        expect(files('sales'), isEmpty);
      },
    );

    test('CASE 1 after an online completion whose outcome is unknown is refused (no possible double sale)', () async {
      offline = false;
      server.onAdd = (_) async => serverDraft();
      server.onComplete = (_) async =>
          throw const ApiException(kind: ApiErrorKind.network, message: 'down');
      await cart.addItem(1, 2);
      expect(await cart.completeSale([cash(224000)]), isFalse);
      offline = true;
      expect(await cart.completeSale([cash(224000)]), isFalse);
      expect(
        cart.error!.message,
        CartController.completionMayHaveReachedServerMessage,
      );
      expect(files('sales'), isEmpty);
    });

    test('CASE 2/3: a cart opened offline stays local even if the connection returns — completed once, locally, no server call', () async {
      await cart.addItem(1, 1);
      offline = false; // connection back
      expect(await cart.addItem(2, 1), isTrue);
      expect(cart.isLocalSale, isTrue);
      expect(await cart.completeSale([cash(348000)]), isTrue);
      expect(server.createCalls, 0);
      expect(server.completeCalls, isEmpty);
      expect(files('sales').length, 1);
    });

    test('CASE 4: after an offline sale the connection returns — nothing is synced, the sale stays QUEUED', () async {
      final sale = await sellSoap(1);
      offline = false;
      expect(cart.isLocalSale, isFalse);
      final stored = (await storage.getSale(sale.localSaleId))!;
      expect(stored.status, OfflineSaleStatus.queued);
      expect((await storage.getQueueEntry(sale.localSaleId))!.attemptCount, 0);
      expect(server.callLog, isEmpty);
    });

    test('a local cart cannot be held, and void discards it without saving anything', () async {
      await cart.addItem(1, 1);
      expect(await cart.holdCurrent(), isFalse);
      expect(cart.error!.message, CartController.holdOfflineMessage);
      expect(server.holdCalls, isEmpty);
      expect(await cart.cancelCurrent(), isTrue);
      expect(cart.sale, isNull);
      expect(files('sales'), isEmpty);
    });
  });

  group('offline readiness (filled while online)', () {
    test('every server sale view is reported so the shift id can be stored; the cache keeps it', () async {
      offline = false;
      await storage.clearCurrentShift();
      server.onAdd = (_) async => serverDraft(shiftId: 81);
      await cart.addItem(1, 2);
      expect(serverSales.single.shiftId, 81);
      final cache = OfflineCacheService(storage);
      await cache.recordShiftFromSale(serverSales.single, theScope);
      final s = (await storage.getCurrentShift())!;
      expect(s.shiftId, 81);
      expect(s.isOpen, isTrue);
      expect(s.storeId, 213);
      expect(s.deviceId, 9);
      await cache.markShiftClosed(81);
      expect((await storage.getCurrentShift())!.isOpen, isFalse);
    });

    test('catalogue refresh reads every page and stores products + server stock together', () async {
      final api = FakeProductService();
      ProductItem item(int id, double price, double stock) =>
          ProductItem.fromJson({
            'id': id,
            'product_name': 'P$id',
            'selling_mode': 'PIECE',
            'stock': {'current_stock': stock},
            'pricing': {
              'sell_price': price,
              'tax_percent': 5,
              'tax_mode': 'exclusive',
            },
          })!;
      api.onSearch = (c) async => ProductPage(
        items: c.page == 1
            ? [item(10, 20, 4), item(11, 30, 0)]
            : [item(12, 40, 9)],
        pagination: Pagination(
          page: c.page,
          limit: c.limit,
          total: 3,
          totalPages: 2,
        ),
      );
      expect(
        await OfflineCacheService(storage).refreshCatalogue(api, theScope),
        isTrue,
      );
      expect(api.calls.map((c) => c.page), [1, 2]);
      expect((await storage.getProducts()).map((p) => p.productVariationId), [
        10,
        11,
        12,
      ]);
      expect((await storage.getProduct(12))!.sellPriceMilli, 40000);
      final stock = await storage.getStockLevels();
      expect(stock[10]!.serverQuantity, 4);
      expect(stock[12]!.serverQuantity, 9);
    });

    test('a failed page leaves the previous catalogue untouched', () async {
      final api = FakeProductService();
      api.onSearch = (c) async => c.page == 1
          ? ProductPage(
              items: const [],
              pagination: const Pagination(
                page: 1,
                limit: 100,
                total: 200,
                totalPages: 2,
              ),
            )
          : throw const ApiException(
              kind: ApiErrorKind.network,
              message: 'down',
            );
      expect(
        await OfflineCacheService(storage).refreshCatalogue(api, theScope),
        isFalse,
      );
      expect((await storage.getProducts()).length, 3);
    });

    test(
      'offline product browsing serves the cache with OFFLINE stock',
      () async {
        await sellSoap(4);
        final products = OfflineProductService(
          FakeProductService(),
          storage,
          isOffline: () => true,
        );
        final page = await products.search(query: 'soa');
        expect(page.items.single.id, 1);
        expect(page.items.single.currentStock, 6);
        expect((await products.findById(2))!.pricing.sellPrice, 236);
      },
    );

    test('the staff token scope is read from the server-issued claims only', () {
      String token(Map<String, dynamic> claims) =>
          'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';
      final s = PosTokenScope.fromToken(
        token({
          'company_id': 1,
          'store_id': 213,
          'register_id': 5,
          'device_id': 9,
          'salesman_id': 'TEST-SALES-A1',
          'authType': 'staff',
        }),
      )!;
      expect(
        [s.companyId, s.storeId, s.registerId, s.deviceId, s.salesmanId],
        [1, 213, 5, 9, 'TEST-SALES-A1'],
      );
      expect(
        PosTokenScope.fromToken(
          token({
            'company_id': 1,
            'store_id': 2,
            'register_id': 3,
            'device_id': 4,
            'authType': 'device',
          }),
        ),
        isNull,
      );
      expect(PosTokenScope.fromToken('not-a-jwt'), isNull);
      expect(PosTokenScope.fromToken(null), isNull);
    });
  });
}
