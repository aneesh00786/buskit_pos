import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/layout/responsive.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/core/theme/pos_tokens.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_panel.dart';
import 'package:buskit_pos/features/shell/ui/pos_header.dart';
import 'package:buskit_pos/features/shell/ui/pos_sidebar.dart';
import 'package:buskit_pos/features/shell/ui/summary_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

PosSidebar sidebar(WidgetTester t) =>
    t.widget<PosSidebar>(find.byType(PosSidebar));

void main() {
  group('width classes', () {
    test('boundaries', () {
      expect(PosLayoutClass.forWidth(320), PosLayoutClass.compact);
      expect(PosLayoutClass.forWidth(899.9), PosLayoutClass.compact);
      expect(PosLayoutClass.forWidth(900), PosLayoutClass.medium);
      expect(PosLayoutClass.forWidth(1279), PosLayoutClass.medium);
      expect(PosLayoutClass.forWidth(1280), PosLayoutClass.expanded);
      expect(PosLayoutClass.forWidth(1599), PosLayoutClass.expanded);
      expect(PosLayoutClass.forWidth(1600), PosLayoutClass.wide);
    });

    test('which pieces each class shows', () {
      expect(PosLayoutClass.compact.hasSideCart, isFalse);
      expect(PosLayoutClass.medium.hasSideCart, isTrue);
      expect(PosLayoutClass.medium.hasFullSidebar, isFalse);
      expect(PosLayoutClass.expanded.hasFullSidebar, isTrue);
      expect(PosLayoutClass.expanded.hasSummary, isFalse);
      expect(PosLayoutClass.wide.hasSummary, isTrue);
    });
  });

  group('compact (phone / small tablet)', () {
    testWidgets(
      'app bar + catalog + bottom cart bar; no permanent sidebar or header; search sits in the body',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 400, height: 800);
        expect(find.byType(AppBar), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Products'),
          ),
          findsOneWidget,
        );
        expect(find.byType(PosSidebar), findsNothing);
        expect(find.byType(PosHeader), findsNothing);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.text('Cart'), findsOneWidget);
        expect(
          find.byType(CartPanel),
          findsNothing,
          reason: 'the cart is behind the bottom bar / sheet',
        );
      },
    );

    testWidgets(
      'the menu button opens the navigation drawer with every section',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        expect(sidebar(tester).collapsed, isFalse);
        for (final label in [
          'Sales',
          'Orders',
          'Sales history',
          'Customers',
          'Inventory',
          'Promotions',
          'Analytics',
          'Settings',
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
      },
    );

    testWidgets(
      'Sales history in the drawer closes it and opens the history sheet',
      (tester) async {
        final client = PosApiClient(
          baseUrl: 'http://test',
          httpClient: MockClient(
            (_) async => http.Response('{"status":true,"data":[]}', 200),
          ),
        );
        final h = PageHarness(client: client);
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sales history'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('Sales history'), findsWidgets);
        expect(find.text('No completed sales'), findsOneWidget);
        expect(
          find.byType(PosSidebar),
          findsNothing,
          reason: 'the drawer closed',
        );
      },
    );

    testWidgets(
      'Customers in the drawer closes it and opens customer management',
      (tester) async {
        final client = PosApiClient(
          baseUrl: 'http://test',
          httpClient: MockClient(
            (_) async => http.Response(
              '{"status":true,"data":{"items":[],"pagination":{"page":1,"limit":20,"total":0,"total_pages":1}}}',
              200,
            ),
          ),
        );
        final h = PageHarness(client: client);
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Customers'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('Customers'), findsWidgets);
        expect(find.text('No customers yet'), findsOneWidget);
        expect(
          find.byType(PosSidebar),
          findsNothing,
          reason: 'the drawer closed',
        );
      },
    );

    testWidgets(
      'Promotions in the drawer closes it and opens the promotions browser',
      (tester) async {
        final client = PosApiClient(
          baseUrl: 'http://test',
          httpClient: MockClient(
            (_) async => http.Response(
              '{"status":true,"data":{"items":[],"pagination":{"page":1,"limit":20,"total":0,"total_pages":1}}}',
              200,
            ),
          ),
        );
        final h = PageHarness(client: client);
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Promotions'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('Promotions'), findsWidgets);
        expect(find.text('No promotions available'), findsOneWidget);
        expect(
          find.byType(PosSidebar),
          findsNothing,
          reason: 'the drawer closed',
        );
      },
    );

    testWidgets(
      'Orders in the drawer closes it and opens the held sales sheet',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Orders'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('Held sales'), findsOneWidget);
        expect(
          find.byType(PosSidebar),
          findsNothing,
          reason: 'the drawer closed',
        );
      },
    );

    testWidgets(
      'the bottom bar shows the item count and the server total once there are items',
      (tester) async {
        final h = PageHarness();
        h.carts.onAdd = (_) async => CartSaleFactory.sale(
          items: [lineJson(id: 1, quantity: 2, lineTotal: 21.2)],
          total: 21.2,
        );
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(find.text('Cart · 2 items'), findsOneWidget);
        expect(find.text('21.20'), findsOneWidget);
      },
    );

    testWidgets(
      'the cart opens as a bottom sheet with the full Current Sale panel',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.text('Cart'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('Current Sale'), findsOneWidget);
      },
    );
  });

  group('medium (tablet portrait)', () {
    testWidgets('icon rail + header + catalog + side cart; no summary', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h, width: 1000, height: 800);
      expect(sidebar(tester).collapsed, isTrue);
      expect(find.byType(PosHeader), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PosHeader),
          matching: find.byType(TextField),
        ),
        findsOneWidget,
      );
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Current Sale'), findsOneWidget);
      expect(find.byType(SalesSummaryPanel), findsNothing);
      expect(find.text('Products'), findsOneWidget, reason: 'page heading');
    });

    testWidgets('the rail keeps tooltips for every icon-only item', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h, width: 1000, height: 800);
      for (final tip in [
        'Sales',
        'Held sales',
        'Customers',
        'Inventory',
        'Promotions',
        'Analytics',
        'Settings',
        'Sign out',
      ]) {
        expect(find.byTooltip(tip), findsWidgets, reason: tip);
      }
    });
  });

  group('expanded (tablet landscape)', () {
    testWidgets('full sidebar with labels, header, catalog, side cart', (
      tester,
    ) async {
      final h = PageHarness();
      await h.signIn();
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      expect(sidebar(tester).collapsed, isFalse);
      expect(sidebar(tester).active, PosSection.sales);
      for (final label in [
        'Sales',
        'Orders',
        'Customers',
        'Inventory',
        'Promotions',
        'Analytics',
        'Settings',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('ThriveWoo POS'), findsOneWidget);
      expect(
        find.text('Device REG-1'),
        findsOneWidget,
        reason: 'the device identifier is shown in the sidebar footer',
      );
      expect(find.text('Current Sale'), findsOneWidget);
      expect(find.byType(SalesSummaryPanel), findsNothing);
    });

    testWidgets(
      'no sidebar section is a placeholder any more — Inventory (Phase 17.5) was the last one',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        expect(find.text('Soon'), findsNothing);
        await tester.tap(find.text('Inventory'));
        await tester.pump();
        expect(find.text('Inventory is coming soon'), findsNothing);
      },
    );

    testWidgets('Sales is the active section and tapping it does nothing', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      await tester.tap(find.text('Sales'));
      await tester.pump();
      expect(find.textContaining('coming soon'), findsNothing);
    });

    testWidgets('Sign out in the sidebar returns to PIN sign-in', (
      tester,
    ) async {
      final h = PageHarness();
      await h.signIn();
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      expect(h.session.phase, SessionPhase.shiftOpen);
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pump();
      expect(h.session.phase, SessionPhase.staffLogin);
    });

    testWidgets(
      'Orders opens the held sales; the count badge follows the list',
      (tester) async {
        final h = PageHarness();
        h.heldService.onList = () async => [];
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        expect(find.byTooltip('Held sales'), findsOneWidget);
        h.heldService.onList = () async => [];
        await tester.tap(find.byTooltip('Held sales'));
        await tester.pumpAndSettle();
        expect(
          find.byType(Dialog),
          findsOneWidget,
          reason: 'a dialog on tablets',
        );
        expect(find.text('No held sales'), findsOneWidget);
      },
    );

    testWidgets('without held-sales support Orders is a plain placeholder', (
      tester,
    ) async {
      final h = PageHarness(withHeld: false);
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      await tester.tap(find.text('Orders'));
      await tester.pump();
      expect(find.text('Orders is coming soon'), findsOneWidget);
    });
  });

  group('wide (summary column)', () {
    testWidgets(
      'shows the summary cards: three backed by real (zero) data, two honest placeholders',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1800, height: 900);
        expect(find.byType(SalesSummaryPanel), findsOneWidget);
        for (final title in [
          "Today's sales",
          'Top items',
          'Staff performance',
          'Sales trend',
          'Inventory alerts',
        ]) {
          expect(find.text(title), findsOneWidget, reason: title);
        }
        // Only the two cards with no backing data at all keep the pill.
        expect(find.text('Coming soon'), findsNWidgets(2));
        expect(find.text('Not available yet.'), findsNWidgets(2));
        expect(find.text('0 transactions today'), findsOneWidget);
        expect(find.text('No sales in the last 7 days yet.'), findsOneWidget);
        expect(find.text('No sales today yet.'), findsOneWidget);
      },
    );

    testWidgets(
      'the real cards show the server\'s own figures; the remaining placeholders show none',
      (tester) async {
        final client = PosApiClient(
          baseUrl: 'http://test',
          httpClient: MockClient((r) async {
            if (r.method == 'GET' &&
                r.url.path.endsWith('/analytics/summary')) {
              return http.Response(
                jsonEncode({
                  'status': true,
                  'data': {
                    'today': {'transaction_count': 3, 'sales_total': 450.5},
                    'payment_breakdown': [],
                    'top_products': [
                      {
                        'product_variation_id': 1,
                        'product_name': 'Tea',
                        'quantity_sold': 7,
                        'revenue': 350,
                      },
                    ],
                    'staff_performance': [
                      {
                        'salesman_id': 'S1',
                        'fullname': 'Jane',
                        'transaction_count': 3,
                        'sales_total': 450.5,
                      },
                    ],
                  },
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({'status': false, 'message': 'no route'}),
              404,
            );
          }),
        );
        final h = PageHarness(client: client);
        await pumpProductsPage(tester, h, width: 1800, height: 900);

        // The three real cards show exactly what the server sent — nothing
        // invented on the client. Scoped to the panel: "Tea" is also a
        // fixture product name shown elsewhere on the page.
        final panel = find.byType(SalesSummaryPanel);
        expect(
          find.descendant(of: panel, matching: find.text('450.50')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: panel,
            matching: find.text('3 transactions today'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: panel, matching: find.textContaining('Tea')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: panel, matching: find.textContaining('Jane')),
          findsOneWidget,
        );

        // The two cards with genuinely no backing data never show a number.
        for (final title in ['Sales trend', 'Inventory alerts']) {
          final texts = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.ancestor(
                    of: find.text(title),
                    matching: find.byType(SummaryCard),
                  ),
                  matching: find.byType(Text),
                ),
              )
              .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');
          for (final s in texts) {
            expect(
              RegExp(r'\d').hasMatch(s),
              isFalse,
              reason: 'unexpected number in "$s" ($title)',
            );
          }
        }
      },
    );

    testWidgets(
      'the gradient hero card and the plain cards render without overflow',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1800, height: 700);
        expect(tester.takeException(), isNull);
        expect(find.byType(SummaryCard), findsNWidgets(5));
      },
    );
  });

  group('header', () {
    testWidgets(
      'inline on wide screens: search, camera-scan button, quick actions, staff, status, clock',
      (tester) async {
        final h = PageHarness();
        await h.signIn(staff: 'SALES1');
        await pumpProductsPage(tester, h, width: 1920, height: 900);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.qr_code_scanner),
              )
              .onPressed,
          isNotNull,
        );
        expect(find.byTooltip('Scan barcode with camera'), findsOneWidget);
        for (final tip in ['Alerts', 'Reports', 'Quick settings']) {
          expect(find.byTooltip(tip), findsOneWidget, reason: tip);
        }
        expect(find.byTooltip('More actions'), findsNothing);
        await tester.tap(find.byTooltip('Reports'));
        await tester.pump();
        expect(find.text('Reports is coming soon'), findsOneWidget);
        expect(find.text('Staff SALES1'), findsWidgets);
        expect(find.text('POS staff'), findsOneWidget);
        expect(find.byType(ClockText), findsOneWidget);
      },
    );

    testWidgets(
      'on a typical tablet the quick actions live in a More menu (still reachable)',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        expect(find.byTooltip('Alerts'), findsNothing);
        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();
        expect(find.text('Alerts'), findsOneWidget);
        expect(find.text('Reports'), findsOneWidget);
        expect(find.text('Quick settings'), findsOneWidget);
        await tester.tap(find.text('Alerts'));
        await tester.pumpAndSettle();
        expect(find.text('Alerts is coming soon'), findsOneWidget);
      },
    );

    testWidgets(
      'the header sheds secondary items as it narrows and always keeps the search field',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(
          tester,
          h,
          width: 900,
          height: 800,
        ); // header ~ 464 dp wide
        expect(
          find.descendant(
            of: find.byType(PosHeader),
            matching: find.byType(TextField),
          ),
          findsOneWidget,
        );
        expect(find.byTooltip('Alerts'), findsNothing);
        expect(find.byTooltip('Scan barcode with camera'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the clock formats the injected time', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClockText(now: () => DateTime(2026, 9, 21, 9, 5)),
          ),
        ),
      );
      expect(find.text('Mon, 21 Sep · 09:05'), findsOneWidget);
    });
  });

  group('network status', () {
    testWidgets(
      'Connecting -> Online after a response -> Offline after a connection failure',
      (tester) async {
        var fail = false;
        final client = PosApiClient(
          baseUrl: 'http://h',
          httpClient: MockClient((r) async {
            if (fail) throw const SocketException('down');
            return http.Response('{"status":true,"data":{}}', 200);
          }),
        );
        final h = PageHarness(client: client);
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        expect(find.text('Connecting'), findsOneWidget);

        await client.get('/x');
        await tester.pump();
        expect(find.text('Online'), findsOneWidget);

        fail = true;
        await expectLater(client.get('/x'), throwsA(anything));
        await tester.pump();
        expect(find.text('Offline'), findsOneWidget);
      },
    );

    testWidgets('an error status still means the server is reachable', (
      tester,
    ) async {
      final client = PosApiClient(
        baseUrl: 'http://h',
        httpClient: MockClient(
          (r) async => http.Response('{"status":false,"message":"no"}', 500),
        ),
      );
      final h = PageHarness(client: client);
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      await expectLater(client.get('/x'), throwsA(anything));
      await tester.pump();
      expect(find.text('Online'), findsOneWidget);
    });

    testWidgets('the phone app bar shows only an accessible status dot', (
      tester,
    ) async {
      final client = PosApiClient(
        baseUrl: 'http://h',
        httpClient: MockClient(
          (r) async => http.Response('{"status":true,"data":{}}', 200),
        ),
      );
      final h = PageHarness(client: client);
      await pumpProductsPage(tester, h, width: 400, height: 800);
      await client.get('/x');
      await tester.pump();
      expect(find.text('Online'), findsNothing);
      expect(find.bySemanticsLabel('Server status: Online'), findsOneWidget);
    });
  });

  group('theme', () {
    test('light and dark share the token set but differ in color', () {
      final l = AppTheme.light().extension<PosTokens>()!;
      final d = AppTheme.dark().extension<PosTokens>()!;
      expect(l.canvas, isNot(d.canvas));
      expect(l.surface, isNot(d.surface));
      expect(AppTheme.dark().brightness, Brightness.dark);
    });

    testWidgets('the page renders in dark mode with the dark tokens', (
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
      expect(tester.takeException(), isNull);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor ??
            Theme.of(tester.element(find.byType(Scaffold).first))
                .scaffoldBackgroundColor,
        PosTokens.dark.canvas,
      );
    });
  });

  group('no overflow', () {
    for (final size in const [
      Size(320, 568),
      Size(360, 640),
      Size(600, 960),
      Size(800, 1280),
      Size(900, 600),
      Size(1024, 768),
      Size(1280, 800),
      Size(1366, 1024),
      Size(1600, 900),
      Size(1920, 1080),
    ]) {
      testWidgets(
        '${size.width.toInt()}x${size.height.toInt()} with a product and a filled cart',
        (tester) async {
          final h = PageHarness();
          h.products.onSearch = (_) async => page([
            for (var i = 1; i <= 8; i++)
              productJson(
                id: i,
                name: 'A rather long product name number $i',
                variation: 'Large economy size',
                unit: 'carton',
              ),
          ]);
          h.carts.onAdd = (_) async => CartSaleFactory.sale(
            items: [
              for (var i = 1; i <= 4; i++)
                lineJson(
                  id: i,
                  name: 'A long cart line name $i',
                  unitPrice: 12345.678,
                ),
            ],
            total: 5000,
          );
          await pumpProductsPage(
            tester,
            h,
            width: size.width,
            height: size.height,
          );
          await tester.tap(find.text('Add').first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final size in const [
      Size(400, 800),
      Size(1366, 1024),
      Size(1800, 900),
    ]) {
      testWidgets(
        'at 130% text scale: ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          final h = PageHarness();
          await h.signIn();
          await pumpProductsPage(
            tester,
            h,
            width: size.width,
            height: size.height,
            textScale: 1.3,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
