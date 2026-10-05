import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/customers/data/customer_service.dart';
import 'package:buskit_pos/features/customers/models/customer.dart';
import 'package:buskit_pos/features/customers/models/customer_purchase.dart';
import 'package:buskit_pos/features/customers/state/customer_list_controller.dart';
import 'package:buskit_pos/features/customers/ui/customers_view.dart';
import 'package:buskit_pos/features/loyalty/models/loyalty_profile.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_customer_service.dart';
import '../../support/fake_loyalty_service.dart';
import '../../support/fakes.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'Cannot reach the server. Check your connection and try again.',
);

CustomerPage page(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int total = -1,
  int limit = 20,
}) {
  final items = rows.map(Customer.fromJson).whereType<Customer>().toList();
  final effectiveTotal = total < 0 ? items.length : total;
  return CustomerPage(
    items: items,
    pagination: Pagination(
      page: page,
      limit: limit,
      total: effectiveTotal,
      totalPages: total < 0
          ? 1
          : (effectiveTotal / limit).ceil().clamp(1, 1 << 30),
    ),
  );
}

Future<CustomerListController> pumpCustomers(
  WidgetTester tester, {
  FakeCustomerService? service,
  FakeLoyaltyService? loyaltyService,
  double width = 1000,
  double height = 700,
  /// Null = no permission context loaded (nothing hidden — the backend
  /// decides), as for every pre-C5 test here.
  List<String>? permissions,
}) async {
  final auth = FakeAuthService();
  if (permissions != null) {
    auth.onAuthContext = (t) async => PosAuthContext(
      staff: const StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Role')),
      permissions: permissions,
    );
  }
  final session = SessionController(auth, MemoryTokenStore());
  addTearDown(session.dispose);
  if (permissions != null) {
    await session.loginDevice('REG-1', 'secret');
    await session.loginStaff('S1', '1234');
  }
  final svc = service ?? FakeCustomerService();
  final controller = CustomerListController(
    svc,
    loyaltyService: loyaltyService,
  );
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<CustomerListController>.value(value: controller),
        ChangeNotifierProvider<SessionController>.value(value: session),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SizedBox.expand(child: CustomersView())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('list states', () {
    testWidgets('loading, then the list, with the search box visible', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(id: 1, fullname: 'Jane Doe')]);
      await pumpCustomers(tester, service: svc);
      expect(find.text('Jane Doe'), findsOneWidget);
      expect(find.text('Search customers by name or phone'), findsOneWidget);
    });

    testWidgets(
      'an empty store shows the empty state with a New Customer button',
      (tester) async {
        await pumpCustomers(tester);
        expect(find.text('No customers yet'), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, 'New Customer'),
          findsOneWidget,
        );
      },
    );

    testWidgets('an error with retry, then a successful retry shows the list', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async => throw netDown;
      await pumpCustomers(tester, service: svc);
      expect(find.textContaining('Cannot reach'), findsOneWidget);
      svc.onSearch = (_) async => page([customerJson(fullname: 'Recovered')]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Recovered'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('typing narrows the list (debounced)', (tester) async {
      final svc = FakeCustomerService();
      svc.onSearch = (call) async {
        final rows = (call.query == null || call.query!.isEmpty)
            ? [
                customerJson(id: 1, fullname: 'Alice'),
                customerJson(id: 2, fullname: 'Bob'),
              ]
            : [customerJson(id: 2, fullname: 'Bob')];
        return page(rows);
      };
      await pumpCustomers(tester, service: svc);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Bob'), findsWidgets);
    });
  });

  group('detail', () {
    testWidgets(
      'tapping a customer shows phone/email/code, purchase summary and history',
      (tester) async {
        final svc = FakeCustomerService();
        svc.onSearch = (_) async => page([
          customerJson(
            customerId: 'CUSTO1',
            fullname: 'Jane Doe',
            mobileno: '0400111222',
            email: 'jane@example.com',
          ),
        ]);
        svc.onFindByCustomerId = (id) async => Customer.fromJson(
          customerJson(
            customerId: id,
            fullname: 'Jane Doe',
            mobileno: '0400111222',
            email: 'jane@example.com',
          ),
        );
        svc.onPurchaseHistory = (_, _) async => CustomerPurchasePage(
          summary: const CustomerPurchaseSummary(
            transactionCount: 3,
            totalPurchases: 45.5,
          ),
          items: const [
            CustomerPurchase(id: 1, saleNumber: 'POS-1', grandTotal: 45.5),
          ],
          pagination: const Pagination(
            page: 1,
            limit: 20,
            total: 1,
            totalPages: 1,
          ),
        );
        await pumpCustomers(tester, service: svc, width: 400);
        await tester.tap(find.text('Jane Doe'));
        await tester.pumpAndSettle();
        expect(find.text('Customer details'), findsOneWidget);
        expect(find.text('CUSTO1'), findsOneWidget);
        expect(find.text('0400111222'), findsOneWidget);
        expect(find.text('jane@example.com'), findsOneWidget);
        expect(find.text('Transactions'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        expect(find.text('POS-1'), findsOneWidget);
      },
    );

    testWidgets('no purchases yet shows the empty purchase-history message', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
      svc.onFindByCustomerId = (id) async =>
          Customer.fromJson(customerJson(customerId: id, fullname: 'Jane Doe'));
      await pumpCustomers(tester, service: svc, width: 400);
      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.text('No completed sales yet.'), findsOneWidget);
    });

    testWidgets(
      'a purchase-history failure shows one inline error with retry, not a blank section',
      (tester) async {
        final svc = FakeCustomerService();
        svc.onSearch = (_) async =>
            page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
        svc.onFindByCustomerId = (id) async => Customer.fromJson(
          customerJson(customerId: id, fullname: 'Jane Doe'),
        );
        svc.onPurchaseHistory = (_, _) async => throw netDown;
        await pumpCustomers(tester, service: svc, width: 400);
        await tester.tap(find.text('Jane Doe'));
        await tester.pumpAndSettle();
        expect(find.text('Customer details'), findsOneWidget);
        expect(find.textContaining('Cannot reach'), findsOneWidget);
        expect(find.text('No completed sales yet.'), findsNothing);
        svc.onPurchaseHistory = (_, _) async => CustomerPurchasePage(
          summary: const CustomerPurchaseSummary(
            transactionCount: 1,
            totalPurchases: 10,
          ),
          items: const [],
          pagination: const Pagination(
            page: 1,
            limit: 20,
            total: 0,
            totalPages: 1,
          ),
        );
        await tester.tap(find.widgetWithText(TextButton, 'Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Transactions'), findsOneWidget);
      },
    );

    testWidgets(
      'a known status code is shown as a readable badge, not a raw number',
      (tester) async {
        final svc = FakeCustomerService();
        svc.onSearch = (_) async => page([
          customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe', status: 2),
        ]);
        svc.onFindByCustomerId = (id) async => Customer.fromJson(
          customerJson(customerId: id, fullname: 'Jane Doe', status: 2),
        );
        await pumpCustomers(tester, service: svc, width: 400);
        await tester.tap(find.text('Jane Doe'));
        await tester.pumpAndSettle();
        expect(find.text('Active customer'), findsOneWidget);
        expect(find.text('2'), findsNothing);
      },
    );

    testWidgets('a phone-width back arrow returns to the list', (tester) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
      svc.onFindByCustomerId = (id) async =>
          Customer.fromJson(customerJson(customerId: id, fullname: 'Jane Doe'));
      await pumpCustomers(tester, service: svc, width: 400);
      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back to customers'));
      await tester.pumpAndSettle();
      expect(find.text('Customers'), findsOneWidget);
      expect(find.text('Jane Doe'), findsOneWidget);
    });

    testWidgets(
      'wide: list and detail side by side; selecting keeps the list visible',
      (tester) async {
        final svc = FakeCustomerService();
        svc.onSearch = (_) async =>
            page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
        svc.onFindByCustomerId = (id) async => Customer.fromJson(
          customerJson(customerId: id, fullname: 'Jane Doe'),
        );
        await pumpCustomers(tester, service: svc, width: 900, height: 700);
        expect(find.text('Select a customer'), findsOneWidget);
        await tester.tap(find.text('Jane Doe'));
        await tester.pumpAndSettle();
        expect(
          find.text('Jane Doe'),
          findsWidgets,
          reason: 'still visible in the list pane',
        );
        expect(
          find.byTooltip('Back to customers'),
          findsNothing,
          reason: 'no back arrow needed side-by-side',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a detail load failure shows an error with retry', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
      svc.onFindByCustomerId = (_) async => throw netDown;
      await pumpCustomers(tester, service: svc, width: 400);
      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cannot reach'), findsOneWidget);
      svc.onFindByCustomerId = (id) async =>
          Customer.fromJson(customerJson(customerId: id, fullname: 'Jane Doe'));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Customer details'), findsOneWidget);
    });
  });

  group('loyalty', () {
    testWidgets(
      'an enabled program shows tier/points/wallet; no section at all when disabled',
      (tester) async {
        final svc = FakeCustomerService();
        svc.onSearch = (_) async =>
            page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
        svc.onFindByCustomerId = (id) async => Customer.fromJson(
          customerJson(customerId: id, fullname: 'Jane Doe'),
        );
        final loyaltySvc = FakeLoyaltyService();
        loyaltySvc.onGetProfile = (_) async => LoyaltyProfile.fromJson(
          loyaltyProfileJson(
            tier: {'id': 2, 'name': 'Gold', 'discount_percentage': 5},
            pointsBalance: 1280,
            walletBalance: 245.5,
          ),
        );
        await pumpCustomers(
          tester,
          service: svc,
          loyaltyService: loyaltySvc,
          width: 400,
        );
        await tester.tap(find.text('Jane Doe'));
        await tester.pumpAndSettle();
        expect(find.text('Gold member'), findsOneWidget);
        expect(find.text('1280'), findsOneWidget);
        expect(find.text('245.50'), findsOneWidget);
        expect(loyaltySvc.getProfileCalls, ['CUSTO1']);
      },
    );

    testWidgets('no active program means no loyalty section is shown at all', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
      svc.onFindByCustomerId = (id) async =>
          Customer.fromJson(customerJson(customerId: id, fullname: 'Jane Doe'));
      final loyaltySvc = FakeLoyaltyService();
      loyaltySvc.onGetProfile = (_) async =>
          LoyaltyProfile.fromJson(loyaltyProfileJson(enabled: false));
      await pumpCustomers(
        tester,
        service: svc,
        loyaltyService: loyaltySvc,
        width: 400,
      );
      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.text('Loyalty'), findsNothing);
    });

    testWidgets('a loyalty load failure shows an inline error with retry', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(customerId: 'CUSTO1', fullname: 'Jane Doe')]);
      svc.onFindByCustomerId = (id) async =>
          Customer.fromJson(customerJson(customerId: id, fullname: 'Jane Doe'));
      final loyaltySvc = FakeLoyaltyService();
      loyaltySvc.onGetProfile = (_) async => throw netDown;
      await pumpCustomers(
        tester,
        service: svc,
        loyaltyService: loyaltySvc,
        width: 400,
      );
      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.text('Loyalty'), findsOneWidget);
      expect(find.textContaining('Cannot reach'), findsOneWidget);
      loyaltySvc.onGetProfile = (_) async =>
          LoyaltyProfile.fromJson(loyaltyProfileJson(pointsBalance: 10));
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(find.text('10'), findsOneWidget);
    });
  });

  group('create', () {
    testWidgets('validation blocks empty name/phone', (tester) async {
      await pumpCustomers(tester);
      await tester.tap(find.byTooltip('New customer'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save Customer'));
      await tester.pumpAndSettle();
      expect(find.text('Name is required.'), findsOneWidget);
      expect(find.text('Phone is required.'), findsOneWidget);
    });

    testWidgets('an invalid email is rejected before submitting', (
      tester,
    ) async {
      await pumpCustomers(tester);
      await tester.tap(find.byTooltip('New customer'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name *'),
        'New Guy',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone *'),
        '0400000000',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'not-an-email',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save Customer'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
    });

    testWidgets(
      'a successful create closes the dialog and adds the customer to the list',
      (tester) async {
        final svc = FakeCustomerService();
        svc.onCreate = (call) async => Customer.fromJson(
          customerJson(fullname: call.fullname, mobileno: call.mobileno),
        )!;
        await pumpCustomers(tester, service: svc);
        await tester.tap(find.byTooltip('New customer'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Name *'),
          'New Guy',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Phone *'),
          '0400000000',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save Customer'));
        await tester.pumpAndSettle();
        expect(
          find.text('New customer'),
          findsNothing,
          reason: 'dialog closed',
        );
        expect(find.text('New Guy'), findsOneWidget);
        expect(svc.createCalls.single.mobileno, '0400000000');
      },
    );

    testWidgets(
      'a duplicate mobile offers to use the existing customer instead',
      (tester) async {
        final svc = FakeCustomerService();
        svc.onCreate = (_) async =>
            throw duplicateMobileError('CUSTO-EXISTING');
        svc.onFindByCustomerId = (id) async => Customer.fromJson(
          customerJson(customerId: id, fullname: 'Existing Guy'),
        );
        await pumpCustomers(tester, service: svc);
        await tester.tap(find.byTooltip('New customer'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Name *'),
          'New Guy',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Phone *'),
          '0400000000',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save Customer'));
        await tester.pumpAndSettle();
        expect(
          find.text('A customer with this mobile number already exists'),
          findsOneWidget,
        );
        await tester.tap(find.text('Use this existing customer'));
        await tester.pumpAndSettle();
        expect(find.text('Existing Guy'), findsOneWidget);
      },
    );
  });

  group('edit', () {
    testWidgets('Phase C5: Edit Customer is hidden without customers.edit; New customer stays with customers.create', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async => page([customerJson(customerId: 'CUSTO1', fullname: 'Cashier View')]);
      svc.onFindByCustomerId = (id) async => Customer.fromJson(customerJson(customerId: id, fullname: 'Cashier View'));
      await pumpCustomers(tester, service: svc, width: 400, permissions: const ['customers.view', 'customers.create']);
      expect(find.byTooltip('New customer'), findsOneWidget);
      await tester.tap(find.text('Cashier View'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Edit Customer'), findsNothing);
    });

    testWidgets('Phase C5: New customer is hidden without customers.create', (tester) async {
      await pumpCustomers(tester, permissions: const ['customers.view']);
      expect(find.byTooltip('New customer'), findsNothing);
      expect(find.text('New Customer'), findsNothing, reason: 'empty-state button too');
    });

    testWidgets('editing a customer updates the detail and the list', (
      tester,
    ) async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(customerId: 'CUSTO1', fullname: 'Old Name')]);
      svc.onFindByCustomerId = (id) async =>
          Customer.fromJson(customerJson(customerId: id, fullname: 'Old Name'));
      svc.onUpdate = (call) async => Customer.fromJson(
        customerJson(customerId: call.customerId, fullname: call.fullname!),
      )!;
      await pumpCustomers(tester, service: svc, width: 400);
      await tester.tap(find.text('Old Name'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Edit Customer'));
      await tester.pumpAndSettle();
      expect(find.text('Edit customer'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name *'),
        'New Name',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('New Name'), findsWidgets);
      expect(find.text('Old Name'), findsNothing);
    });
  });
}
