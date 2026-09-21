import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/core/theme/pos_tokens.dart';
import 'package:buskit_pos/features/products/models/product_group.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:buskit_pos/features/products/ui/category_chip.dart';
import 'package:buskit_pos/features/products/ui/product_card.dart';
import 'package:buskit_pos/core/ui/product_image.dart';
import 'package:buskit_pos/features/products/models/category.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

ProductGroup groupOf(List<Map<String, dynamic>> rows) =>
    ProductGroup.group(rows.map(ProductItem.fromJson).whereType<ProductItem>())
        .first;

Future<void> pumpCard(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double width = 220,
  double height = 300,
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('ProductCard (grid)', () {
    testWidgets(
      'image placeholder, name, variation · unit, price with the server tax label, availability, green Add',
      (tester) async {
        final g = groupOf([
          productJson(
            id: 1,
            name: 'Croissant',
            variation: 'Butter',
            unit: 'pcs',
            price: 3.5,
            taxMode: 'exclusive',
            taxPercent: 12,
            stock: 8,
          ),
        ]);
        var taps = 0;
        await pumpCard(tester, ProductCard(group: g, onTap: () => taps++));
        expect(find.text('Croissant'), findsOneWidget);
        expect(find.text('Butter · pcs'), findsOneWidget);
        expect(find.textContaining('3.50'), findsOneWidget);
        expect(find.textContaining('+ 12% tax'), findsOneWidget);
        expect(find.text('Stock: 8'), findsOneWidget);
        expect(find.byType(ProductImage), findsOneWidget);
        expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);

        final add = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Add'),
        );
        final bg = add.style!.backgroundColor!.resolve({});
        expect(
          bg,
          PosTokens.light.success,
          reason: 'the Add button is the success green',
        );
        await tester.tap(find.text('Add'));
        expect(taps, 1);
      },
    );

    testWidgets(
      'out of stock is flagged in the warning color but can still be tapped (the server decides)',
      (tester) async {
        final g = groupOf([productJson(id: 1, stock: 0)]);
        var taps = 0;
        await pumpCard(tester, ProductCard(group: g, onTap: () => taps++));
        final label = tester.widget<Text>(find.text('Out of stock'));
        expect(label.style!.color, PosTokens.light.warning);
        await tester.tap(find.text('Add'));
        expect(taps, 1);
      },
    );

    testWidgets('missing stock information shows no availability line', (
      tester,
    ) async {
      final g = groupOf([productJson(id: 1, stock: null)]);
      await pumpCard(tester, ProductCard(group: g, onTap: () {}));
      expect(find.textContaining('Stock'), findsNothing);
      expect(find.text('Out of stock'), findsNothing);
    });

    testWidgets(
      'several variations: count, "from" price, Select, no per-variation stock line',
      (tester) async {
        final g = groupOf([
          productJson(
            id: 1,
            productId: 'A',
            name: 'Rice',
            variation: '1kg',
            price: 10,
          ),
          productJson(
            id: 2,
            productId: 'A',
            name: 'Rice',
            variation: '5kg',
            price: 45,
          ),
        ]);
        await pumpCard(tester, ProductCard(group: g, onTap: () {}));
        expect(find.text('2 variations'), findsOneWidget);
        expect(find.textContaining('from 10.00'), findsOneWidget);
        expect(find.text('Select'), findsOneWidget);
        expect(find.textContaining('Stock'), findsNothing);
      },
    );

    testWidgets('busy: the card and the button are disabled', (tester) async {
      final g = groupOf([productJson(id: 1)]);
      var taps = 0;
      await pumpCard(
        tester,
        ProductCard(group: g, busy: true, onTap: () => taps++),
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Add'), warnIfMissed: false);
      expect(taps, 0);
    });

    testWidgets('a broken or absent image never breaks the card', (
      tester,
    ) async {
      final g = groupOf([
        productJson(id: 1, image: 'https://img.invalid/x.png'),
      ]);
      await pumpCard(tester, ProductCard(group: g, onTap: () {}));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ProductImage), findsOneWidget);
    });

    testWidgets(
      'the whole card announces name, variation, price and tax to screen readers',
      (tester) async {
        final g = groupOf([
          productJson(
            id: 1,
            name: 'Croissant',
            variation: 'Butter',
            price: 3.5,
            taxPercent: 12,
          ),
        ]);
        await pumpCard(tester, ProductCard(group: g, onTap: () {}));
        expect(
          find.bySemanticsLabel(RegExp(r'Croissant, Butter.*price 3\.50')),
          findsOneWidget,
        );
      },
    );

    testWidgets('long names and prices do not overflow the fixed grid cell', (
      tester,
    ) async {
      final g = groupOf([
        productJson(
          id: 1,
          name: 'An exceptionally long product name that keeps going and going',
          variation: 'A very long variation description here',
          unit: 'carton of forty-eight',
          price: 123456.789,
        ),
      ]);
      await pumpCard(tester, ProductCard(group: g, onTap: () {}));
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in dark mode', (tester) async {
      final g = groupOf([productJson(id: 1, stock: 0)]);
      await pumpCard(
        tester,
        ProductCard(group: g, onTap: () {}),
        theme: AppTheme.dark(),
      );
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(find.text('Out of stock'));
      expect(text.style!.color, PosTokens.dark.warning);
    });
  });

  group('ProductListTile', () {
    testWidgets('same information in a row, with a working Add', (
      tester,
    ) async {
      final g = groupOf([
        productJson(
          id: 1,
          name: 'Croissant',
          variation: 'Butter',
          price: 3.5,
          stock: 4,
        ),
      ]);
      var taps = 0;
      await pumpCard(
        tester,
        ProductListTile(group: g, onTap: () => taps++),
        width: 480,
        height: 120,
      );
      expect(find.text('Croissant'), findsOneWidget);
      expect(find.text('Butter · unit'), findsOneWidget);
      expect(find.textContaining('3.50'), findsOneWidget);
      expect(find.text('Stock: 4'), findsOneWidget);
      await tester.tap(find.text('Add'));
      expect(taps, 1);
    });

    testWidgets('does not overflow at phone width with long content', (
      tester,
    ) async {
      final g = groupOf([
        productJson(
          id: 1,
          name: 'An exceptionally long product name that keeps going and going',
          variation: 'Large economy size',
          price: 123456.789,
        ),
      ]);
      await pumpCard(
        tester,
        ProductListTile(group: g, onTap: () {}),
        width: 320,
        height: 260,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('grid / list toggle on the page', () {
    testWidgets('defaults to the grid; the toggle switches to rows and back', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      expect(find.byType(ProductCard), findsOneWidget);
      expect(find.byType(ProductListTile), findsNothing);

      await tester.tap(find.byTooltip('List view'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductListTile), findsOneWidget);
      expect(find.byType(ProductCard), findsNothing);

      await tester.tap(find.byTooltip('Grid view'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductCard), findsOneWidget);
    });

    testWidgets(
      'list mode still adds to the cart with the numeric variation id',
      (tester) async {
        final h = PageHarness();
        h.products.onSearch = (_) async => page([
          productJson(id: 42, variationId: 'VARIATION42', name: 'Tea'),
        ]);
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        await tester.tap(find.byTooltip('List view'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(h.carts.addCalls.single.variationId, 42);
        expect(h.carts.addCalls.single.quantity, 1);
      },
    );

    testWidgets('the toggle exposes its selected state and has 48dp targets', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      final grid = tester.getSize(find.byTooltip('Grid view'));
      expect((grid.width, grid.height), (48, 48));
      expect(find.bySemanticsLabel('Grid view'), findsOneWidget);
    });

    testWidgets(
      'pagination still works in list mode (scroll to the end loads page 2)',
      (tester) async {
        final h = PageHarness();
        h.products.onSearch = (c) async => page(
          [
            for (var i = 0; i < 20; i++)
              productJson(id: c.page * 100 + i, name: 'Item ${c.page}-$i'),
          ],
          page: c.page,
          total: 40,
          totalPages: 2,
        );
        await pumpProductsPage(tester, h, width: 420, height: 800);
        await tester.tap(find.byTooltip('List view'));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -9000),
        );
        await tester.pumpAndSettle();
        expect(h.products.calls.map((c) => c.page), [1, 2]);
      },
    );
  });

  group('CategoryChip', () {
    testWidgets(
      'the active chip is filled with the primary color, others are outlined',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Row(
                children: [
                  CategoryChip(label: 'All', selected: true, onSelected: () {}),
                  CategoryChip(
                    label: 'Dairy',
                    selected: false,
                    onSelected: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        final scheme = Theme.of(tester.element(find.byType(Scaffold)))
            .colorScheme;
        final active = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'All'),
        );
        final rest = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'Dairy'),
        );
        expect(active.selected, isTrue);
        expect(active.selectedColor, scheme.primary);
        expect(rest.selected, isFalse);
        expect(rest.backgroundColor, PosTokens.light.surface);
      },
    );

    testWidgets('tapping reports the selection once', (tester) async {
      var n = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CategoryChip(
              label: 'Dairy',
              selected: false,
              onSelected: () => n++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Dairy'));
      expect(n, 1);
    });

    testWidgets(
      'on the page: selecting a category filters the catalog and resets to page 1; All clears it',
      (tester) async {
        final h = PageHarness();
        h.products.onCategories = () async => [
          const ProductCategory(id: 5, name: 'Dairy'),
          const ProductCategory(id: 6, name: 'Bakery'),
        ];
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        final all = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'All categories'),
        );
        expect(all.selected, isTrue);

        h.products.calls.clear();
        await tester.tap(find.text('Dairy'));
        await tester.pumpAndSettle();
        expect(
          (h.products.calls.single.categoryId, h.products.calls.single.page),
          (5, 1),
        );
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Dairy'))
              .selected,
          isTrue,
        );
        expect(
          tester
              .widget<ChoiceChip>(
                find.widgetWithText(ChoiceChip, 'All categories'),
              )
              .selected,
          isFalse,
        );

        await tester.tap(find.text('All categories'));
        await tester.pumpAndSettle();
        expect(h.products.calls.last.categoryId, isNull);
      },
    );
  });
}
