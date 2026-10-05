// Phase 17.10 (C2): Settings hides/disables store, register and device
// management per settings.* permission (UI convenience only — the backend
// enforces), keeps cash/printer/about available, and reports 403s.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cash_movements/state/cash_movement_controller.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';
import 'package:buskit_pos/features/settings/state/settings_controller.dart';
import 'package:buskit_pos/features/settings/ui/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_settings_service.dart';
import '../../support/fakes.dart';

const allSettings = [
  'settings.view',
  'settings.edit',
  'settings.store',
  'settings.register',
  'settings.device',
];

ApiException forbidden(String permission) => ApiException(
  kind: ApiErrorKind.forbidden,
  message: 'Forbidden',
  errorCode: PosErrorCodes.permissionDenied,
  data: {'permission': permission},
);

Future<SessionController> sessionWith(List<String>? permissions) async {
  final auth = FakeAuthService();
  if (permissions != null) {
    auth.onAuthContext = (t) async => PosAuthContext(
      staff: const StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Role')),
      permissions: permissions,
    );
  }
  final session = SessionController(auth, MemoryTokenStore());
  await session.loginDevice('REG-1', 'secret');
  await session.loginStaff('S1', '1234');
  return session;
}

Future<FakeSettingsService> pump(WidgetTester tester, {List<String>? permissions, FakeSettingsService? service}) async {
  final svc = service ?? FakeSettingsService();
  final controller = SettingsController(svc);
  final cash = CashMovementController(FakeCashMovementService());
  final session = await sessionWith(permissions);
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  addTearDown(cash.dispose);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: controller),
        ChangeNotifierProvider<CashMovementController>.value(value: cash),
        ChangeNotifierProvider<SessionController>.value(value: session),
        Provider<ReceiptServices>.value(value: FakeReceipts().services),
      ],
      child: const MaterialApp(home: Scaffold(body: SizedBox.expand(child: SettingsView()))),
    ),
  );
  await tester.pumpAndSettle();
  return svc;
}

void main() {
  testWidgets('without settings.view: no store calls, a notice, and cash/printer/about still shown', (tester) async {
    var listCalls = 0;
    final svc = FakeSettingsService();
    final original = svc.onListStores;
    svc.onListStores = () {
      listCalls++;
      return original();
    };
    await pump(tester, permissions: ['payments.cash_withdrawal'], service: svc);
    expect(listCalls, 0, reason: 'never calls the store endpoints when positively denied');
    expect(find.textContaining('do not have permission to view store settings'), findsOneWidget);
    expect(find.text('Main Store'), findsNothing);
    expect(find.text('Cash Management'), findsOneWidget);
    expect(find.text('Printer setup'), findsOneWidget);
    expect(find.text('App version'), findsOneWidget);
  });

  testWidgets('a backend 403 on load (context not yet known) shows the notice, not a dead-end error', (tester) async {
    final svc = FakeSettingsService()..onListStores = () async => throw forbidden('settings.view');
    await pump(tester, service: svc);
    expect(find.textContaining('do not have permission to view store settings'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Printer setup'), findsOneWidget);
  });

  testWidgets('full settings permissions: every management control is available', (tester) async {
    await pump(tester, permissions: allSettings);
    expect(find.text('Edit Store'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).onChanged, isNotNull);
    expect(find.widgetWithText(TextButton, 'Revoke'), findsWidgets);
  });

  testWidgets('settings.view only: details visible, but no edit, no register toggle, no revoke', (tester) async {
    await pump(tester, permissions: ['settings.view']);
    expect(find.text('Main Store'), findsOneWidget);
    expect(find.text('Edit Store'), findsNothing);
    for (final sw in tester.widgetList<Switch>(find.byType(Switch))) {
      expect(sw.onChanged, isNull);
    }
    expect(find.widgetWithText(TextButton, 'Revoke'), findsNothing);
  });

  testWidgets('Edit Store needs BOTH settings.store and settings.edit', (tester) async {
    await pump(tester, permissions: ['settings.view', 'settings.store']);
    expect(find.text('Edit Store'), findsNothing);
  });

  testWidgets('no permission context loaded: controls stay visible (backend decides)', (tester) async {
    await pump(tester);
    expect(find.text('Edit Store'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Revoke'), findsWidgets);
  });

  testWidgets('a 403 when toggling a register is reported, not swallowed', (tester) async {
    final svc = FakeSettingsService()..onSetRegisterStatus = (c) async => throw forbidden('settings.register');
    await pump(tester, service: svc);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('You do not have permission to manage registers. Ask a manager or administrator.'), findsOneWidget);
  });

  testWidgets('a 403 when revoking a device is reported', (tester) async {
    final svc = FakeSettingsService()..onSetDeviceStatus = (c) async => throw forbidden('settings.device');
    await pump(tester, service: svc);
    await tester.tap(find.widgetWithText(TextButton, 'Revoke').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('You do not have permission to manage devices. Ask a manager or administrator.'), findsOneWidget);
  });

  test('403 messages for the new sale/shift/settings permissions', () {
    expect(describeApiError(forbidden('sales.view')), contains('permission to view sales'));
    expect(describeApiError(forbidden('shifts.view')), contains('permission to view shifts'));
    expect(describeApiError(forbidden('settings.edit')), contains('permission to edit the store'));
  });
}
