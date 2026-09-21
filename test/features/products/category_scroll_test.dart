import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/products/models/category.dart';
import 'package:buskit_pos/features/products/ui/product_filter_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

Finder get left => find.byTooltip('Scroll categories left');
Finder get right => find.byTooltip('Scroll categories right');

/// The IconButtons behind the chevrons.
IconButton leftBtn(WidgetTester t) =>
    t.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_left));
IconButton rightBtn(WidgetTester t) =>
    t.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right));
ScrollController scrollOf(WidgetTester t) => t
    .widget<ListView>(
      find.descendant(
        of: find.byType(ProductFilterBar),
        matching: find.byType(ListView),
      ),
    )
    .controller!;

Future<PageHarness> pump(
  WidgetTester tester, {
  required int categories,
  double width = 400,
  double height = 800,
  ThemeData? theme,
  double textScale = 1,
}) async {
  final h = PageHarness();
  h.products.onCategories = () async => [
    for (var i = 1; i <= categories; i++)
      ProductCategory(id: i, name: 'Category number $i'),
  ];
  await pumpProductsPage(
    tester,
    h,
    width: width,
    height: height,
    theme: theme,
    textScale: textScale,
  );
  return h;
}

void main() {
  group('category scroll arrows', () {
    testWidgets(
      'shown when the chips overflow: < is dimmed at the start, > is active',
      (tester) async {
        await pump(tester, categories: 12);
        expect(left, findsOneWidget);
        expect(right, findsOneWidget);
        expect(
          leftBtn(tester).onPressed,
          isNull,
          reason: 'already at the start',
        );
        expect(rightBtn(tester).onPressed, isNotNull);
      },
    );

    testWidgets('hidden when every category fits, so no space is wasted', (
      tester,
    ) async {
      await pump(tester, categories: 1, width: 1400, height: 900);
      expect(left, findsNothing);
      expect(right, findsNothing);
    });

    testWidgets(
      '> scrolls the row forward and enables <; the row really moved',
      (tester) async {
        await pump(tester, categories: 12);
        final before = scrollOf(tester).offset;
        await tester.tap(right);
        await tester.pumpAndSettle();
        expect(scrollOf(tester).offset, greaterThan(before));
        expect(leftBtn(tester).onPressed, isNotNull);
      },
    );

    testWidgets(
      'scrolling to the end dims > and keeps < active; < scrolls back',
      (tester) async {
        await pump(tester, categories: 12);
        for (var i = 0; i < 60 && rightBtn(tester).onPressed != null; i++) {
          await tester.tap(right);
          await tester.pumpAndSettle();
        }
        expect(
          rightBtn(tester).onPressed,
          isNull,
          reason: 'nothing further to the right',
        );
        expect(leftBtn(tester).onPressed, isNotNull);
        final end = scrollOf(tester).offset;
        await tester.tap(left);
        await tester.pumpAndSettle();
        expect(scrollOf(tester).offset, lessThan(end));
        expect(rightBtn(tester).onPressed, isNotNull);
      },
    );

    testWidgets('dragging the chips updates the arrows too', (tester) async {
      await pump(tester, categories: 12);
      // The strip is several thousand dp long and lays chips out lazily, so drag
      // (with a fresh finder each time) until the end is reached.
      for (var i = 0; i < 12 && rightBtn(tester).onPressed != null; i++) {
        await tester.drag(
          find.descendant(
            of: find.byType(ProductFilterBar),
            matching: find.byType(ListView),
          ),
          const Offset(-2500, 0),
        );
        await tester.pumpAndSettle();
      }
      expect(leftBtn(tester).onPressed, isNotNull);
      expect(rightBtn(tester).onPressed, isNull);
    });

    testWidgets('arrows have accessible labels and 48dp-tall touch targets', (
      tester,
    ) async {
      await pump(tester, categories: 12);
      expect(tester.getSize(left).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(right).height, greaterThanOrEqualTo(48));
      expect(rightBtn(tester).tooltip, 'Scroll categories right');
      expect(leftBtn(tester).tooltip, 'Scroll categories left');
    });

    testWidgets('selecting a chip still works with the arrows present', (
      tester,
    ) async {
      final h = await pump(tester, categories: 12);
      h.products.calls.clear();
      await tester.tap(right);
      await tester.pumpAndSettle();
      // Chips are built lazily; scroll the strip until the target exists.
      // A cashier taps > until the chip they want comes into view.
      for (
        var i = 0;
        i < 20 && find.text('Category number 4').evaluate().isEmpty;
        i++
      ) {
        await tester.tap(right);
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('Category number 4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Category number 4'));
      await tester.pumpAndSettle();
      expect(h.products.calls.last.categoryId, 4);
    });

    testWidgets(
      'narrow phone: arrows at the ends of the chips, dropdown above (not squeezing the row)',
      (tester) async {
        await pump(tester, categories: 12);
        final l = tester.getRect(left);
        final r = tester.getRect(right);
        final chips = tester.getRect(
          find.descendant(
            of: find.byType(ProductFilterBar),
            matching: find.byType(ListView),
          ),
        );
        final sort = tester.getRect(find.byType(SortDropdown));
        expect(l.right, lessThanOrEqualTo(chips.left));
        expect(chips.right, lessThanOrEqualTo(r.left));
        expect(sort.bottom, lessThanOrEqualTo(chips.top));
      },
    );

    testWidgets(
      'narrow phone: the chip strip keeps real room and the first chip is fully visible',
      (tester) async {
        await pump(tester, categories: 12, width: 400);
        final chips = tester.getRect(
          find.descendant(
            of: find.byType(ProductFilterBar),
            matching: find.byType(ListView),
          ),
        );
        expect(
          chips.width,
          greaterThanOrEqualTo(240),
          reason: 'not squeezed to ~110dp by the dropdown',
        );
        final all = tester.getRect(
          find.widgetWithText(ChoiceChip, 'All categories'),
        );
        expect(all.left, greaterThanOrEqualTo(chips.left));
        expect(all.right, lessThanOrEqualTo(chips.right));
      },
    );

    testWidgets(
      'wider compact screens keep the dropdown beside the chips, with the arrows between',
      (tester) async {
        await pump(tester, categories: 12, width: 700, height: 900);
        final l = tester.getRect(left);
        final r = tester.getRect(right);
        final chips = tester.getRect(
          find.descendant(
            of: find.byType(ProductFilterBar),
            matching: find.byType(ListView),
          ),
        );
        final sort = tester.getRect(find.byType(SortDropdown));
        expect(l.right, lessThanOrEqualTo(chips.left));
        expect(chips.right, lessThanOrEqualTo(r.left));
        expect(r.right, lessThanOrEqualTo(sort.left));
      },
    );

    for (final size in const [
      Size(320, 568),
      Size(360, 700),
      Size(400, 800),
      Size(800, 1280),
      Size(1000, 800),
      Size(1400, 900),
      Size(1920, 1080),
    ]) {
      testWidgets(
        'no overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await pump(
            tester,
            categories: 12,
            width: size.width,
            height: size.height,
          );
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byType(SortDropdown)).right,
            lessThanOrEqualTo(size.width),
          );
        },
      );
    }

    testWidgets('no overflow at 150% text scale on a small phone', (
      tester,
    ) async {
      await pump(
        tester,
        categories: 12,
        width: 360,
        height: 700,
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      expect(left, findsOneWidget);
      expect(right, findsOneWidget);
    });

    testWidgets('dark mode', (tester) async {
      await pump(tester, categories: 12, theme: AppTheme.dark());
      expect(tester.takeException(), isNull);
      expect(right, findsOneWidget);
    });

    testWidgets(
      'categories that fail to load show the retry message, not arrows',
      (tester) async {
        final h = PageHarness();
        h.products.onCategories = () async => throw apiError(500);
        await pumpProductsPage(tester, h, width: 400, height: 800);
        expect(find.text('Categories could not be loaded'), findsOneWidget);
        expect(left, findsNothing);
        expect(right, findsNothing);
      },
    );
  });
}
