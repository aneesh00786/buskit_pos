import 'package:buskit_pos/core/config/app_config.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/core/theme/pos_tokens.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_panel.dart';
import 'package:buskit_pos/features/products/ui/product_card.dart';
import 'package:buskit_pos/features/shell/ui/pos_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

Color? sidebarColor(WidgetTester t) => t
    .widget<Container>(
      find
          .descendant(
            of: find.byType(PosSidebar),
            matching: find.byType(Container),
          )
          .first,
    )
    .color;

Color? tileColor(WidgetTester t, String label) => t
    .widget<Material>(
      find
          .ancestor(of: find.text(label), matching: find.byType(Material))
          .first,
    )
    .color;

void main() {
  group('sidebar design', () {
    testWidgets(
      'dark navy background with a green highlight on the active Sales item only',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        expect(sidebarColor(tester), PosTokens.light.sidebar);
        expect(
          PosTokens.light.sidebar.computeLuminance(),
          lessThan(0.05),
          reason: 'a dark navy/teal',
        );
        expect(tileColor(tester, 'Sales'), PosTokens.light.success);
        expect(tileColor(tester, 'Customers'), Colors.transparent);
        expect(tileColor(tester, 'Orders'), Colors.transparent);
      },
    );

    testWidgets(
      'lists Sales, Orders, Customers, Inventory, Promotions, Analytics and Settings',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        for (final l in [
          'Sales',
          'Orders',
          'Customers',
          'Inventory',
          'Promotions',
          'Analytics',
          'Settings',
        ]) {
          expect(find.text(l), findsOneWidget, reason: l);
        }
      },
    );

    testWidgets('footer: Help, Sign out, device ID and app version', (
      tester,
    ) async {
      final h = PageHarness();
      await h.signIn(device: 'TEST-TAB-1');
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      expect(find.text('Help'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.text('Device TEST-TAB-1'), findsOneWidget);
      expect(find.text('Version ${AppConfig.appVersion}'), findsOneWidget);
    });

    testWidgets(
      'Help explains the version and device and offers no invented contact details',
      (tester) async {
        final h = PageHarness();
        await h.signIn(device: 'TEST-TAB-1');
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        await tester.tap(find.text('Help'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.textContaining('version ${AppConfig.appVersion}'),
          findsOneWidget,
        );
        expect(find.textContaining('Device TEST-TAB-1'), findsWidgets);
        expect(find.textContaining('store administrator'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets(
      'the icon rail keeps Help and Sign out as tooltipped icons and hides the text block',
      (tester) async {
        final h = PageHarness();
        await h.signIn();
        await pumpProductsPage(tester, h, width: 1000, height: 800);
        expect(find.byTooltip('Help'), findsOneWidget);
        expect(find.byTooltip('Sign out'), findsOneWidget);
        expect(find.textContaining('Version'), findsNothing);
        expect(find.textContaining('Device '), findsNothing);
      },
    );

    testWidgets(
      'the phone drawer carries the same footer, and Help closes it first',
      (tester) async {
        final h = PageHarness();
        await h.signIn(device: 'REG-9');
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        expect(find.text('Device REG-9'), findsOneWidget);
        expect(find.text('Sign out'), findsOneWidget);
        await tester.tap(find.text('Help'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.byType(PosSidebar),
          findsNothing,
          reason: 'the drawer closed',
        );
      },
    );

    testWidgets('dark theme keeps the sidebar dark and the active item green', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(
        tester,
        h,
        width: 1400,
        height: 900,
        theme: AppTheme.dark(),
      );
      expect(sidebarColor(tester), PosTokens.dark.sidebar);
      expect(tileColor(tester, 'Sales'), PosTokens.dark.success);
      expect(tester.takeException(), isNull);
    });
  });

  group('green primary', () {
    test('the theme primary is the token green in light and dark', () {
      expect(AppTheme.light().colorScheme.primary, PosTokens.light.success);
      expect(AppTheme.dark().colorScheme.primary, PosTokens.dark.success);
    });
  });

  group('product card', () {
    testWidgets(
      'the Add button shows a plus icon and stays a green FilledButton',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        final add = find.widgetWithText(FilledButton, 'Add');
        expect(
          find.descendant(of: add, matching: find.byIcon(Icons.add)),
          findsOneWidget,
        );
        expect(
          tester.widget<FilledButton>(add).style!.backgroundColor!.resolve({}),
          PosTokens.light.success,
        );
        expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
      },
    );

    testWidgets('variations show Select with a tune icon instead', (
      tester,
    ) async {
      final h = PageHarness();
      h.products.onSearch = (_) async => page([
        productJson(id: 1, productId: 'A', variation: '1kg'),
        productJson(id: 2, productId: 'A', variation: '5kg'),
      ]);
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      expect(find.byType(ProductCard), findsOneWidget);
      expect(
        find.descendant(
          of: find.widgetWithText(FilledButton, 'Select'),
          matching: find.byIcon(Icons.tune),
        ),
        findsOneWidget,
      );
    });
  });

  group('current sale panel design', () {
    late FakeCartService service;
    late CartController cart;
    setUp(() {
      service = FakeCartService();
      cart = CartController(service);
    });
    tearDown(() => cart.dispose());

    Future<void> pumpPanel(
      WidgetTester tester, {
      double height = 800,
      ThemeData? theme,
    }) async {
      final s = CartSale.fromJson(
        saleJson(
          id: 7,
          version: 2,
          items: [lineJson(id: 1, quantity: 2)],
          subtotal: 20,
          tax: 2.4,
          total: 22.4,
        ),
      )!;
      service.onAdd = (_) async => s;
      service.onGet = (_) async => s;
      await cart.addItem(1, 2);
      final session = SessionController(FakeAuthService(), MemoryTokenStore());
      addTearDown(session.dispose);
      tester.view.physicalSize = Size(380, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CartController>.value(value: cart),
            ChangeNotifierProvider<SessionController>.value(value: session),
          ],
          child: MaterialApp(
            theme: theme ?? AppTheme.light(),
            home: const Scaffold(body: CartPanel()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Hold is red and Pay is green (both enabled)', (tester) async {
      await pumpPanel(tester);
      final hold = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Hold sale'),
      );
      expect(hold.style!.backgroundColor!.resolve({}), PosTokens.light.danger);
      expect(
        hold.style!.foregroundColor!.resolve({}),
        PosTokens.light.onDanger,
      );
      expect(hold.onPressed, isNotNull);
      final pay = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Pay'),
      );
      expect(pay.onPressed, isNotNull);
      expect(pay.style!.backgroundColor!.resolve({}), PosTokens.light.success);
      expect(
        pay.style!.backgroundColor!.resolve({WidgetState.disabled}),
        PosTokens.light.success.withValues(alpha: 0.35),
      );
    });

    testWidgets(
      'Add Promotion is enabled for a draft sale; no discount row when there is no discount',
      (tester) async {
        await pumpPanel(tester);
        final add = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Add Promotion'),
        );
        expect(add.onPressed, isNotNull);
        expect(
          find.text('Discount'),
          findsNothing,
          reason: 'discount_total is 0 — nothing to show',
        );
      },
    );

    testWidgets(
      'on short panels the promotion row is dropped to keep the list visible',
      (tester) async {
        await pumpPanel(tester, height: 560);
        expect(find.text('Add Promotion'), findsNothing);
        expect(find.text('Hold sale'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('server subtotal, tax and total are shown as sent', (
      tester,
    ) async {
      await pumpPanel(tester);
      expect(find.text('20.00'), findsOneWidget);
      expect(find.text('2.40'), findsOneWidget);
      expect(find.text('22.40'), findsWidgets);
    });

    testWidgets('dark mode renders the red Hold and green Pay', (tester) async {
      await pumpPanel(tester, theme: AppTheme.dark());
      expect(tester.takeException(), isNull);
      final hold = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Hold sale'),
      );
      expect(hold.style!.backgroundColor!.resolve({}), PosTokens.dark.danger);
    });
  });
}
