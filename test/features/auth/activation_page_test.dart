// The device activation screen no longer offers "Dev: generate a new test
// device" (it created devices through a POS API that has been removed —
// devices are registered in the admin portal). The debug-only autofill of a
// saved test device is unchanged and makes no network call.
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/auth/ui/auth_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

Future<FakeAuthService> pumpActivation(
  WidgetTester t,
  Map<String, String> saved,
) async {
  FlutterSecureStorage.setMockInitialValues(saved);
  t.view.physicalSize = const Size(1366, 768);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final auth = FakeAuthService();
  final session = SessionController(auth, MemoryTokenStore());
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: session,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const DeviceLoginPage(),
      ),
    ),
  );
  await t.pumpAndSettle();
  return auth;
}

void main() {
  testWidgets(
    'no "generate a new test device" link or bolt button, with or without a saved test device',
    (t) async {
      for (final saved in [
        <String, String>{},
        {
          'dev_test_device_identifier': 'TEST-TAB-5',
          'dev_test_device_secret': 'abcd1234',
        },
      ]) {
        await pumpActivation(t, saved);
        expect(find.textContaining('generate a new test device'), findsNothing);
        expect(find.textContaining('Dev:'), findsNothing);
        expect(find.byIcon(Icons.bolt_outlined), findsNothing);
        expect(find.text('Continue'), findsOneWidget);
      }
    },
  );

  testWidgets(
    'debug autofill of the saved test device still works, with no network call',
    (t) async {
      final auth = await pumpActivation(t, {
        'dev_test_device_identifier': 'TEST-TAB-5',
        'dev_test_device_secret': 'abcd1234',
        'dev_test_staff_id': 'S1',
        'dev_test_staff_pin': '1234',
      });
      expect(find.widgetWithText(TextField, 'TEST-TAB-5'), findsOneWidget);
      expect(
        find.text('Autofilled from the saved test device.'),
        findsOneWidget,
      );
      expect(auth.log, isEmpty);
    },
  );
}
