import 'package:buskit_pos/features/products/models/category.dart';
import 'package:buskit_pos/features/products/models/product_group.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  group('ProductItem.fromJson', () {
    test('parses a full backend row', () {
      final p = ProductItem.fromJson(
        productJson(
          id: 42,
          productId: 'P9',
          name: 'Tea',
          variation: '250g',
          variationId: 'VAR42',
          price: 12.5,
          stock: 8,
          unit: 'pack',
          taxMode: 'inclusive',
          taxPercent: 5,
          image: 'https://img.example/t.png',
        ),
      )!;
      expect(p.id, 42);
      expect(p.variationId, 'VAR42');
      expect(p.productId, 'P9');
      expect(p.productName, 'Tea');
      expect(p.variationName, '250g');
      expect(p.unitType, 'pack');
      expect(p.imageUrl, 'https://img.example/t.png');
      expect(p.category!.id, 1);
      expect(p.currentStock, 8);
      expect(p.pricing.sellPrice, 12.5);
      expect(p.pricing.taxMode, 'inclusive');
      expect(p.pricing.taxIncluded, isTrue);
      expect(p.pricing.taxPercent, 5);
      expect(p.pricing.pricingStatus, 'base_price_only');
    });

    test('the cart id is the numeric id, not the string variation_id', () {
      final p = ProductItem.fromJson(
        productJson(id: 7, variationId: 'VARIATION1264'),
      )!;
      expect(p.id, 7);
      expect(p.variationId, 'VARIATION1264');
    });

    test('tolerates missing, null and wrongly typed fields', () {
      final p = ProductItem.fromJson({
        'id': '15',
        'product_name': null,
        'image_url': 'not a url',
        'stock': 'lots',
        'pricing': 'oops',
        'category': {'id': 'x'},
        'unit_type': 5,
      })!;
      expect(p.id, 15, reason: 'numeric string id is accepted');
      expect(p.productName, 'Unnamed product');
      expect(p.imageUrl, isNull, reason: 'non-http(s) URLs are dropped');
      expect(p.currentStock, isNull);
      expect(p.pricing.sellPrice, isNull);
      expect(p.category, isNull);
      expect(p.unitType, '5');
    });

    test('prices sent as strings (DECIMAL) still parse', () {
      final p = ProductItem.fromJson({
        'id': 1,
        'pricing': {'sell_price': '119.000', 'tax_percent': '12'},
      })!;
      expect(p.pricing.sellPrice, 119.0);
      expect(p.pricing.taxPercent, 12.0);
    });

    test('rows that are not objects or lack an id are rejected', () {
      expect(ProductItem.fromJson(null), isNull);
      expect(ProductItem.fromJson('x'), isNull);
      expect(ProductItem.fromJson({'product_name': 'No id'}), isNull);
    });

    test('javascript:/file: image URLs are not accepted', () {
      expect(
        ProductItem.fromJson({'id': 1, 'image_url': 'javascript:alert(1)'})!
            .imageUrl,
        isNull,
      );
      expect(
        ProductItem.fromJson({'id': 1, 'image_url': 'file:///etc/passwd'})!
            .imageUrl,
        isNull,
      );
    });
  });

  group('ProductPage.fromJson', () {
    test('parses items and pagination', () {
      final p = ProductPage.fromJson(
        pageJson(
          [productJson(id: 1), productJson(id: 2)],
          page: 2,
          total: 45,
          totalPages: 3,
          limit: 20,
        ),
      );
      expect(p.items.map((i) => i.id), [1, 2]);
      expect(p.pagination.page, 2);
      expect(p.pagination.total, 45);
      expect(p.pagination.totalPages, 3);
      expect(p.hasMore, isTrue);
    });

    test('last page has no more', () {
      expect(
        ProductPage.fromJson(pageJson([], page: 3, totalPages: 3)).hasMore,
        isFalse,
      );
    });

    test('garbage and empty payloads produce an empty page, never a crash', () {
      for (final bad in [
        null,
        'x',
        5,
        <String, dynamic>{},
        {'items': 'nope'},
      ]) {
        final p = ProductPage.fromJson(bad);
        expect(p.items, isEmpty);
        expect(p.pagination.page, 1);
        expect(p.pagination.totalPages, 1);
      }
    });

    test('unusable rows are skipped and counted', () {
      final p = ProductPage.fromJson({
        'items': [
          productJson(id: 1),
          {'nope': true},
          3,
        ],
      });
      expect(p.items, hasLength(1));
      expect(p.skipped, 2);
    });
  });

  group('ProductCategory.fromJson', () {
    test('reads the backend {cid, category} rows', () {
      final c = ProductCategory.fromJson({'cid': 4, 'category': ' Dairy '})!;
      expect((c.id, c.name), (4, 'Dairy'));
    });
    test('falls back to a generic name; rejects rows without an id', () {
      expect(
        ProductCategory.fromJson({'cid': 4, 'category': ''})!.name,
        'Category 4',
      );
      expect(ProductCategory.fromJson({'category': 'x'}), isNull);
    });
  });

  group('ProductGroup', () {
    test('groups flat variation rows by product_id, preserving order', () {
      final items = [
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
        productJson(id: 3, productId: 'B', name: 'Salt', price: 3),
      ].map(ProductItem.fromJson).whereType<ProductItem>();
      final groups = ProductGroup.group(items);
      expect(groups.map((g) => g.name), ['Rice', 'Salt']);
      expect(groups[0].variations.map((v) => v.id), [1, 2]);
      expect(groups[0].hasMultipleVariations, isTrue);
      expect(groups[1].hasMultipleVariations, isFalse);
      expect((groups[0].minPrice, groups[0].maxPrice), (10, 45));
    });

    test('a product whose variations straddle two pages is merged, without duplicates', () {
      final page1 = [productJson(id: 1, productId: 'A')]
          .map(ProductItem.fromJson)
          .whereType<ProductItem>()
          .toList();
      final page2 = [
        productJson(id: 1, productId: 'A'),
        productJson(id: 2, productId: 'A'),
      ].map(ProductItem.fromJson).whereType<ProductItem>();
      final g = ProductGroup.group([...page1, ...page2]);
      expect(g, hasLength(1));
      expect(g.single.variations.map((v) => v.id), [1, 2]);
    });

    test('rows without a product_id are never merged together', () {
      final a = ProductItem.fromJson({'id': 1, 'product_name': 'X'})!;
      final b = ProductItem.fromJson({'id': 2, 'product_name': 'X'})!;
      expect(ProductGroup.group([a, b]), hasLength(2));
    });
  });
}
