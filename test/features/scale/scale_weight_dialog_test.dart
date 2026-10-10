// Phase 18A — the scale inside the existing weight dialog. A reading only
// fills the field when the cashier taps "Use"; it never submits, never picks
// a product, never touches another cart line. Without a scale (or with a
// disconnected one) the dialog is the manual one and checkout is unaffected.
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_item_tile.dart';
import 'package:buskit_pos/features/cart/ui/quantity_dialog.dart';
import 'package:buskit_pos/features/scale/mock_scale_adapter.dart';
import 'package:buskit_pos/features/scale/scale_controller.dart';
import 'package:buskit_pos/features/scale/scale_reading.dart';
import 'package:buskit_pos/features/scale/ui/scale_weight_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

class _Rig {
  _Rig() : mock = MockScaleAdapter() {
    scale = ScaleController(mock, staleAfter: const Duration(minutes: 5));
  }
  final MockScaleAdapter mock;
  late final ScaleController scale;

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    scale.dispose();
    await mock.dispose();
  }
}

/// Opens the weight dialog from a button; [result] receives what it returns.
Future<void> pumpOpener(
  WidgetTester tester, {
  required void Function(num?) onResult,
  ScaleController? scale,
  bool weight = true,
  bool useScale = true,
}) async {
  final app = MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => FilledButton(
          onPressed: () async => onResult(
            await showQuantityDialog(
              context,
              initial: 1,
              itemName: 'Loose Rice',
              weight: weight,
              useScale: useScale,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    scale == null ? app : ScaleScope(controller: scale, child: app),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Readings arrive on a stream (a microtask) and repaint on the next frame.
Future<void> flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets(
    'no scale configured: the weight dialog is the manual one, unchanged',
    (tester) async {
      num? result = -1;
      await pumpOpener(tester, onResult: (v) => result = v);
      expect(find.byKey(const Key('scale-panel')), findsNothing);
      await tester.enterText(find.byType(TextField), '0.750');
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(result, 0.75);
    },
  );

  testWidgets(
    'a stable reading fills the field only on "Use"; nothing is submitted until Update',
    (tester) async {
      final rig = _Rig();
      num? result = -1;
      var returned = false;
      await pumpOpener(
        tester,
        scale: rig.scale,
        onResult: (v) {
          result = v;
          returned = true;
        },
      );
      await flush(tester); // post-frame connect
      expect(rig.scale.isConnected, isTrue);
      expect(find.text('Simulated scale (not a real scale)'), findsOneWidget);

      // Readings arrive: the field and the dialog are untouched.
      rig.mock.emitWeight(1310, stable: false);
      await flush(tester);
      expect(find.textContaining('(settling)'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('scale-use')))
            .onPressed,
        isNull,
      );
      rig.mock.emitWeight(1250);
      await flush(tester);
      expect(fieldText(tester), '1.000');
      expect(returned, isFalse);
      expect(find.text('Set weight'), findsOneWidget);

      await tester.tap(find.byKey(const Key('scale-use')));
      await flush(tester);
      expect(fieldText(tester), '1.250');
      expect(returned, isFalse, reason: 'using the reading never submits');

      // A later reading does not overwrite what the cashier took.
      rig.mock.emitWeight(2000);
      await flush(tester);
      expect(fieldText(tester), '1.250');

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(result, 1.25);
      await rig.close(tester);
    },
  );

  testWidgets('cancel after using a reading applies nothing', (tester) async {
    final rig = _Rig();
    num? result = -1;
    await pumpOpener(tester, scale: rig.scale, onResult: (v) => result = v);
    await flush(tester);
    rig.mock.emitWeight(480, unit: ScaleUnit.kilogram);
    await flush(tester);
    await tester.tap(find.byKey(const Key('scale-use')));
    await flush(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await rig.close(tester);
  });

  testWidgets(
    'zero, invalid and unsupported-unit readings cannot be used; manual entry still works',
    (tester) async {
      final rig = _Rig();
      num? result = -1;
      await pumpOpener(tester, scale: rig.scale, onResult: (v) => result = v);
      await flush(tester);
      Future<void> expectBlocked(String why) async {
        await flush(tester);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('scale-use')))
              .onPressed,
          isNull,
          reason: why,
        );
        expect(find.textContaining(why), findsOneWidget);
      }

      rig.mock.emitWeight(0);
      await expectBlocked('weight is zero');
      rig.mock.emitStatus(ScaleReadingStatus.invalid);
      await expectBlocked('invalid reading');
      rig.mock.emitWeight(2000, unit: ScaleUnit.pound);
      await expectBlocked('only g and kg');
      rig.mock.emitWeight(250500, unit: ScaleUnit.gram);
      await expectBlocked('more than 3 decimal places');

      await tester.enterText(find.byType(TextField), '0.333');
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(result, 0.333);
      await rig.close(tester);
    },
  );

  testWidgets('a disconnected or failing scale never blocks manual entry', (
    tester,
  ) async {
    final rig = _Rig();
    rig.mock.failConnect = true;
    num? result = -1;
    await pumpOpener(tester, scale: rig.scale, onResult: (v) => result = v);
    await flush(tester);
    await flush(tester);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Could not connect to the scale.'), findsOneWidget);
    expect(find.byKey(const Key('scale-connect')), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('scale-use'))).onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '1.5');
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(result, 1.5);

    // Connected, then unplugged mid-dialog: the reading disappears.
    rig.mock.failConnect = false;
    await pumpOpener(tester, scale: rig.scale, onResult: (v) => result = v);
    await flush(tester); // reopening the dialog reconnects by itself
    expect(rig.scale.isConnected, isTrue);
    expect(find.byKey(const Key('scale-connect')), findsNothing);
    rig.mock.emitWeight(1250);
    await flush(tester);
    expect(find.text('Use 1.250 kg'), findsOneWidget);
    rig.mock.simulateDisconnect();
    await flush(tester);
    expect(find.text('Use 1.250 kg'), findsNothing);
    expect(find.text('The scale is disconnected.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await rig.close(tester);
  });

  testWidgets(
    'wrong product type or a non-sale weight dialog: no scale offered',
    (tester) async {
      final rig = _Rig();
      await pumpOpener(
        tester,
        scale: rig.scale,
        weight: false,
        onResult: (_) {},
      );
      expect(find.text('Set quantity'), findsOneWidget);
      expect(find.byKey(const Key('scale-panel')), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // e.g. the partial-refund weight dialog does not opt in.
      await pumpOpener(
        tester,
        scale: rig.scale,
        useScale: false,
        onResult: (_) {},
      );
      expect(find.text('Set weight'), findsOneWidget);
      expect(find.byKey(const Key('scale-panel')), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await rig.close(tester);
    },
  );

  testWidgets(
    'cart: the reading goes only to the line being edited; readings alone change nothing',
    (tester) async {
      final rig = _Rig();
      final server = FakeCartService();
      Map<String, dynamic> rice(num q) => lineJson(
        id: 1,
        variationId: 9801,
        quantity: q,
        name: 'Loose Rice',
        unitPrice: 80,
        tax: 0,
        taxPercent: 0,
        lineTotal: 80.0 * q,
        sellingMode: 'WEIGHT',
      );
      Map<String, dynamic> dal() => lineJson(
        id: 2,
        variationId: 9802,
        quantity: 0.5,
        name: 'Loose Dal',
        unitPrice: 120,
        tax: 0,
        taxPercent: 0,
        lineTotal: 60,
        sellingMode: 'WEIGHT',
      );
      server.onAdd = (c) async => CartSale.fromJson(
        saleJson(id: 7, version: 2, items: [rice(1.25), dal()]),
      )!;
      server.onUpdate = (c) async => CartSale.fromJson(
        saleJson(id: 7, version: 3, items: [rice(c.quantity), dal()]),
      )!;
      final cart = CartController(server);
      expect(await cart.addItem(9801, 1.25, sellingMode: 'WEIGHT'), isTrue);
      final addsBefore = server.addCalls.length;

      await tester.pumpWidget(
        ScaleScope(
          controller: rig.scale,
          child: ChangeNotifierProvider<CartController>.value(
            value: cart,
            child: MaterialApp(
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: cart,
                  builder: (context, _) => Column(
                    children: [
                      for (final l in cart.sale!.items)
                        CartItemTile(
                          line: l,
                          label: null,
                          imageUrl: null,
                          enabled: true,
                          inFlight: false,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await rig.scale.connect();

      // Readings with no dialog open: no cart call of any kind.
      rig.mock.emitWeight(3000);
      await flush(tester);
      expect(server.updateCalls, isEmpty);
      expect(server.addCalls.length, addsBefore);

      // Edit line 1 (rice) with the scale.
      await tester.tap(find.byKey(const Key('weight-1')));
      await tester.pumpAndSettle();
      expect(find.text('Loose Rice'), findsWidgets);
      rig.mock.emitWeight(2480);
      await flush(tester);
      await tester.tap(find.byKey(const Key('scale-use')));
      await flush(tester);
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(server.updateCalls, hasLength(1));
      expect(server.updateCalls.single.itemId, 1);
      expect(server.updateCalls.single.quantity, 2.48);
      expect(
        server.addCalls.length,
        addsBefore,
        reason: 'no product added or selected',
      );
      final dalLine = cart.sale!.items.firstWhere((l) => l.id == 2);
      expect(
        dalLine.quantityText,
        '0.500',
        reason: 'the other line is untouched',
      );
      await rig.close(tester);
    },
  );
}
