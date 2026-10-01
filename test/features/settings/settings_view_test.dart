import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cash_movements/state/cash_movement_controller.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';
import 'package:buskit_pos/features/settings/models/pos_device.dart';
import 'package:buskit_pos/features/settings/models/pos_store.dart';
import 'package:buskit_pos/features/settings/state/settings_controller.dart';
import 'package:buskit_pos/features/settings/ui/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_settings_service.dart';
import '../../support/fakes.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'Cannot reach the server. Check your connection and try again.',
);

Future<SettingsController> pumpSettings(
  WidgetTester tester, {
  FakeSettingsService? service,
  FakeCashMovementService? cashService,
  SessionController? session,
  double width = 800,
  double height = 900,
}) async {
  final controller = SettingsController(service ?? FakeSettingsService());
  final cashController = CashMovementController(
    cashService ?? FakeCashMovementService(),
  );
  final sess = session ?? SessionController(FakeAuthService(), MemoryTokenStore());
  final receipts = FakeReceipts();
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  addTearDown(cashController.dispose);
  if (session == null) addTearDown(sess.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: controller),
        ChangeNotifierProvider<CashMovementController>.value(
          value: cashController,
        ),
        ChangeNotifierProvider<SessionController>.value(value: sess),
        Provider<ReceiptServices>.value(value: receipts.services),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SizedBox.expand(child: SettingsView())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('shows the header, store details, registers and devices', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Main Store'), findsOneWidget);
    expect(find.text('Register 1'), findsOneWidget);
    expect(find.text('Front counter tablet'), findsOneWidget);
  });

  testWidgets('no store set up shows an explicit empty state', (tester) async {
    final svc = FakeSettingsService();
    svc.onListStores = () async => [];
    await pumpSettings(tester, service: svc);
    expect(find.text('No store found'), findsOneWidget);
  });

  testWidgets('a load failure shows an error with retry; retry recovers', (
    tester,
  ) async {
    final svc = FakeSettingsService();
    svc.onListStores = () async => throw netDown;
    await pumpSettings(tester, service: svc);
    expect(find.textContaining('Cannot reach'), findsOneWidget);
    svc.onListStores = () async => [PosStore.fromJson(storeJson())!];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Main Store'), findsOneWidget);
  });

  testWidgets('registers with no name shows the empty message', (tester) async {
    final svc = FakeSettingsService();
    svc.onListRegisters = (_) async => [];
    await pumpSettings(tester, service: svc);
    expect(find.text('No registers set up yet.'), findsOneWidget);
  });

  testWidgets('a single store shows no switcher', (tester) async {
    await pumpSettings(tester);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
  });

  testWidgets('more than one store shows a switcher', (tester) async {
    final svc = FakeSettingsService();
    svc.onListStores = () async => [
      PosStore.fromJson(storeJson(id: 1, storeName: 'Store 1'))!,
      PosStore.fromJson(storeJson(id: 2, storeName: 'Store 2'))!,
    ];
    await pumpSettings(tester, service: svc);
    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
  });

  group('edit store', () {
    testWidgets('a successful edit updates the displayed store details', (
      tester,
    ) async {
      final svc = FakeSettingsService();
      await pumpSettings(tester, service: svc);
      await tester.tap(find.widgetWithText(TextButton, 'Edit Store'));
      await tester.pumpAndSettle();
      expect(find.text('Edit store'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Store name *'),
        'Renamed Store',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Edit store'), findsNothing, reason: 'dialog closed');
      expect(find.text('Renamed Store'), findsOneWidget);
    });

    testWidgets(
      'a failed edit shows the error inline without closing the dialog',
      (tester) async {
        final svc = FakeSettingsService();
        svc.onUpdateStore = (_) async => throw netDown;
        await pumpSettings(tester, service: svc);
        await tester.tap(find.widgetWithText(TextButton, 'Edit Store'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(find.text('Edit store'), findsOneWidget, reason: 'stays open');
        expect(find.textContaining('Cannot reach'), findsOneWidget);
      },
    );
  });

  group('registers', () {
    testWidgets('toggling the switch flips an active register to inactive', (
      tester,
    ) async {
      final svc = FakeSettingsService();
      await pumpSettings(tester, service: svc);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(svc.setRegisterStatusCalls.single.status, 'inactive');
    });
  });

  group('devices', () {
    testWidgets('revoking asks for confirmation before calling the service', (
      tester,
    ) async {
      final svc = FakeSettingsService();
      await pumpSettings(tester, service: svc);
      await tester.tap(find.widgetWithText(TextButton, 'Revoke'));
      await tester.pumpAndSettle();
      expect(find.text('Revoke this device?'), findsOneWidget);
      expect(svc.setDeviceStatusCalls, isEmpty, reason: 'not yet confirmed');
      await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
      await tester.pumpAndSettle();
      expect(svc.setDeviceStatusCalls.single.status, 'revoked');
    });

    testWidgets('cancelling the confirmation leaves the device untouched', (
      tester,
    ) async {
      final svc = FakeSettingsService();
      await pumpSettings(tester, service: svc);
      await tester.tap(find.widgetWithText(TextButton, 'Revoke'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(svc.setDeviceStatusCalls, isEmpty);
    });

    testWidgets('a revoked device no longer offers a Revoke button', (
      tester,
    ) async {
      final svc = FakeSettingsService();
      svc.onListDevices = (storeId) async => [
        PosDevice.fromJson(deviceJson(storeId: storeId, status: 'revoked'))!,
      ];
      await pumpSettings(tester, service: svc);
      expect(find.widgetWithText(TextButton, 'Revoke'), findsNothing);
    });
  });

  testWidgets('the About section shows the app version', (tester) async {
    // Cash Management (Phase 17.3) added a section above About, pushing it
    // below the default viewport's build/cache extent — a taller viewport
    // keeps this test about About, not about scrolling.
    await pumpSettings(tester, height: 1400);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('App version'), findsOneWidget);
  });

  testWidgets(
    'the Printer & Receipt tile opens the existing printer setup dialog',
    (tester) async {
      await pumpSettings(tester, height: 1400);
      await tester.tap(find.text('Printer setup'));
      await tester.pumpAndSettle();
      expect(find.text('Printer setup'), findsWidgets);
    },
  );
}
