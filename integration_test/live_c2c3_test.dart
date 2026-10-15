// Phase 17.10.2 — LIVE Flutter verification of C2/C3 against the local
// sandbox backend (http://localhost:3000, busskit_new). Runs the real PosApp
// with the real HTTP client on a simulator; nothing here is mocked.
//
// Credentials come from the git-ignored lib/core/config/test.local (read at
// run time, never printed) — or, if the simulator cannot read the host file,
// from --dart-define POS_LIVE_* values. Writes are limited to toggling the
// labelled SEC-TEST store's register off and back on.
//
//   flutter test integration_test/live_c2c3_test.dart -d <simulator-id>
import 'dart:io';

import 'package:buskit_pos/app.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/products/state/product_list_controller.dart';
import 'package:buskit_pos/features/products/ui/products_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

const baseUrl = 'http://localhost:3000';
const credPath = '/Users/aneesh/buskit-pos/lib/core/config/test.local';

class LiveCreds {
  LiveCreds(this.deviceId, this.deviceSecret, this.pins);
  final String deviceId;
  final String deviceSecret;
  final Map<String, String> pins;

  static LiveCreds load() {
    String text;
    try {
      text = File(credPath).readAsStringSync();
    } catch (_) {
      text = const String.fromEnvironment('POS_LIVE_CREDS');
    }
    final dev = RegExp(r'Identifier\s+(TEST-TAB-5),\s*secret\s+(\S+)')
        .firstMatch(text);
    if (dev == null) throw StateError('TEST-TAB-5 credentials not found');
    final pins = {
      for (final m in RegExp(
        r'Staff ID\s+(\S+),\s*PIN\s+(\S+)',
      ).allMatches(text))
        m.group(1)!: m.group(2)!,
    };
    return LiveCreds(dev.group(1)!, dev.group(2)!, pins);
  }
}

/// Pumps real frames until [finder] matches (real network latency), failing
/// clearly instead of hanging if it never does.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 150));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visible = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .where((t) => t.trim().isNotEmpty)
      .take(25)
      .join(' | ');
  var session = 'n/a';
  final anyText = find.byType(Text);
  if (anyText.evaluate().isNotEmpty) {
    try {
      final sc = Provider.of<SessionController>(
        tester.element(anyText.first),
        listen: false,
      );
      session =
          'phase=${sc.phase} error=${sc.error?.kind}/${sc.error?.statusCode}/${sc.error?.message}';
    } catch (_) {}
  }
  fail(
    'Timed out waiting for ${reason ?? finder.toString()}. Session: $session. Visible text: $visible',
  );
}

/// Waits for any loading indicator to disappear (proves no stuck spinner).
Future<void> settleNetwork(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  await tester.pump(const Duration(milliseconds: 300));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 150));
    final busy =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
    if (!busy) return;
  }
  fail('Still loading after ${timeout.inSeconds}s (stuck spinner)');
}

/// Real devices show an on-screen keyboard that can cover buttons: dismiss
/// it and scroll the target into view before tapping.
Future<void> tapButton(WidgetTester tester, Finder f) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
}

/// Debug builds autofill the login fields from the simulator keychain (the
/// app's TESTING-ONLY dev helper) asynchronously after the page appears. Let
/// that finish before typing so the test's input always wins.
Future<void> letAutofillFinish(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> signIn(WidgetTester tester, LiveCreds c, String staffId) async {
  await tester.pumpWidget(
    PosApp(key: UniqueKey(), tokenStore: MemoryTokenStore(), baseUrl: baseUrl),
  );
  await pumpUntil(
    tester,
    find.widgetWithText(TextField, 'Device identifier'),
    reason: 'device login page',
  );
  await letAutofillFinish(tester);
  await tester.enterText(
    find.widgetWithText(TextField, 'Device identifier'),
    c.deviceId,
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Device secret'),
    c.deviceSecret,
  );
  await tapButton(tester, find.widgetWithText(FilledButton, 'Continue'));
  await pumpUntil(
    tester,
    find.widgetWithText(TextField, 'Staff ID'),
    reason: 'staff login page',
  );
  await letAutofillFinish(tester);
  await tester.enterText(find.widgetWithText(TextField, 'Staff ID'), staffId);
  await tester.enterText(
    find.widgetWithText(TextField, 'PIN'),
    c.pins[staffId]!,
  );
  await tapButton(tester, find.widgetWithText(FilledButton, 'Sign in'));
  // The app always shows the open-shift step after staff login; register 191
  // already has shift 79 open, so the backend answers 409 and the app
  // continues with that shift (no new shift is created).
  await pumpUntil(
    tester,
    find.widgetWithText(TextField, 'Opening cash amount'),
    reason: '$staffId open-shift step',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Opening cash amount'),
    '0',
  );
  await tapButton(tester, find.widgetWithText(FilledButton, 'Open shift'));
  await pumpUntil(
    tester,
    find.byType(ProductsPage),
    reason: '$staffId reaching the POS (existing shift 79)',
  );
  await settleNetwork(tester);
}

/// Taps a sidebar entry in whichever layout the simulator uses: full
/// sidebar (text), collapsed rail (tooltip) or compact drawer.
Future<void> openNav(WidgetTester tester, String label) async {
  // A SnackBar (e.g. "continuing with the open shift") floats over the bottom
  // of the sidebar, where Settings sits — let it go first.
  final end = DateTime.now().add(const Duration(seconds: 12));
  while (find.byType(SnackBar).evaluate().isNotEmpty &&
      DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pumpAndSettle();
  final closeBefore = find.byTooltip('Close').evaluate().length;
  Finder target = find.byTooltip(label).hitTestable();
  if (target.evaluate().isEmpty) target = find.text(label).hitTestable();
  if (target.evaluate().isEmpty) {
    final menu = find.byTooltip('Open navigation menu').hitTestable();
    expect(menu, findsOneWidget, reason: 'navigation for "$label"');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    target = find.text(label).hitTestable();
  }
  bool opened() => find.byTooltip('Close').evaluate().length > closeBefore;
  for (var attempt = 1; attempt <= 2 && !opened(); attempt++) {
    await tester.tap(target.first);
    await tester.pumpAndSettle();
  }
  expect(opened(), isTrue, reason: '"$label" opened its sheet');
  await settleNetwork(tester);
}

Future<void> closeSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Close').hitTestable().first);
  await tester.pumpAndSettle();
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    300,
    scrollable: find.byType(Scrollable).last,
  );
}

void expectProductsBrowsable(WidgetTester tester) {
  final products = Provider.of<ProductListController>(
    tester.element(find.byType(ProductsPage)),
    listen: false,
  );
  expect(
    products.status,
    ListStatus.loaded,
    reason: 'device-level product browsing',
  );
  expect(products.items, isNotEmpty);
}

Future<void> openSalesHistoryAll(WidgetTester tester) async {
  await openNav(tester, 'Sales history');
  await pumpUntil(tester, find.text('Sales history'));
  final all = find.text('All').hitTestable();
  if (all.evaluate().isNotEmpty) {
    await tester.tap(all.first);
    await tester.pumpAndSettle();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final creds = LiveCreds.load();

  testWidgets('L0. revoked device credentials are rejected at device login', (
    tester,
  ) async {
    await tester.pumpWidget(
      PosApp(
        key: UniqueKey(),
        tokenStore: MemoryTokenStore(),
        baseUrl: baseUrl,
      ),
    );
    await pumpUntil(
      tester,
      find.widgetWithText(TextField, 'Device identifier'),
    );
    await letAutofillFinish(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Device identifier'),
      'TEST-TAB-4',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Device secret'),
      'not-the-secret',
    );
    await tapButton(tester, find.widgetWithText(FilledButton, 'Continue'));
    await settleNetwork(tester);
    expect(
      find.widgetWithText(TextField, 'Staff ID'),
      findsNothing,
      reason: 'must stay on device login',
    );
    expect(find.widgetWithText(TextField, 'Device identifier'), findsOneWidget);
  });

  testWidgets(
    'L1. SEC-ADMIN: products, settings with management controls, a permitted operation, sales history, held sales',
    (tester) async {
      await signIn(tester, creds, 'SEC-ADMIN');
      expectProductsBrowsable(tester);

      await openNav(tester, 'Settings');
      await pumpUntil(
        tester,
        find.text('Edit Store'),
        reason: 'store section with management controls',
      );
      expect(find.textContaining('do not have permission'), findsNothing);
      // Two stores exist (MAIN + the SEC-TEST store); pick Main Store explicitly.
      final storeSwitcher = find.byType(DropdownButtonFormField<int>);
      expect(
        storeSwitcher,
        findsOneWidget,
        reason: 'two stores -> store switcher',
      );
      if (find.text('Main Store').evaluate().length < 2) {
        await tester.tap(storeSwitcher);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Main Store').last);
        await settleNetwork(tester);
      }
      await pumpUntil(
        tester,
        find.text('REG1'),
        reason: 'Main Store registers',
      );
      expect(find.text('Edit Store'), findsOneWidget);
      expect(find.text('REG1'), findsOneWidget);
      expect(
        tester.widget<Switch>(find.byType(Switch).first).onChanged,
        isNotNull,
        reason: 'register toggle enabled',
      );
      // Device rows: name as title, "<identifier> · <status>" as subtitle.
      await scrollTo(tester, find.textContaining('TEST-TAB-5 · active'));
      expect(find.textContaining('TEST-TAB-5 · active'), findsOneWidget);
      expect(
        find.textContaining('TEST-TAB-4 · revoked'),
        findsOneWidget,
        reason: 'the revoked device is listed as revoked',
      );
      expect(
        find.widgetWithText(TextButton, 'Revoke'),
        findsWidgets,
        reason: 'device revoke available',
      );
      await tester.scrollUntilVisible(
        find.byType(DropdownButtonFormField<int>),
        -300,
        scrollable: find.byType(Scrollable).last,
      );

      // Permitted management operation, on the labelled SEC-TEST store only:
      // switch store, toggle its register off and back on.
      final switcher = find.byType(DropdownButtonFormField<int>);
      await tester.tap(switcher);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Security Test Store').last);
      await settleNetwork(tester);
      await pumpUntil(
        tester,
        find.text('SEC-REG'),
        reason: 'SEC-TEST register',
      );
      final regSwitch = find.ancestor(
        of: find.text('SEC-REG'),
        matching: find.byType(ListTile),
      );
      final sw = find.descendant(of: regSwitch, matching: find.byType(Switch));
      expect(tester.widget<Switch>(sw).value, isTrue);
      await tester.tap(sw);
      await settleNetwork(tester);
      expect(
        tester.widget<Switch>(sw).value,
        isFalse,
        reason: 'register deactivated via the live API',
      );
      await tester.tap(sw);
      await settleNetwork(tester);
      expect(
        tester.widget<Switch>(sw).value,
        isTrue,
        reason: 'register restored',
      );
      expect(find.byType(SnackBar), findsNothing, reason: 'no error reported');

      await scrollTo(tester, find.text('App version'));
      expect(find.text('Printer setup'), findsOneWidget);
      expect(
        find.text('Cash Management'),
        findsOneWidget,
        reason: 'Administrator holds cash permissions',
      );
      await closeSheet(tester);

      await openSalesHistoryAll(tester);
      expect(find.textContaining('do not have permission'), findsNothing);
      await pumpUntil(
        tester,
        find.textContaining('POS-'),
        reason: 'completed sales listed',
      );
      await closeSheet(tester);

      await openNav(tester, 'Orders');
      await pumpUntil(tester, find.text('Held sales'));
      expect(find.textContaining('do not have permission'), findsNothing);
      expect(
        find.text('No held sales'),
        findsNothing,
        reason: 'store 213 has one held sale',
      );
      await closeSheet(tester);
    },
  );

  testWidgets(
    'L2. SALES1 (Cashier): products, sales history and held sales work; Settings shows the notice',
    (tester) async {
      await signIn(tester, creds, 'SALES1');
      expectProductsBrowsable(tester);

      await openSalesHistoryAll(tester);
      expect(find.textContaining('do not have permission'), findsNothing);
      await pumpUntil(
        tester,
        find.textContaining('POS-'),
        reason: 'completed sales listed',
      );
      await closeSheet(tester);

      await openNav(tester, 'Orders');
      await pumpUntil(tester, find.text('Held sales'));
      expect(find.textContaining('do not have permission'), findsNothing);
      await closeSheet(tester);

      await openNav(tester, 'Settings');
      await pumpUntil(
        tester,
        find.textContaining('do not have permission to view store settings'),
      );
      expect(find.text('Main Store'), findsNothing);
      expect(find.text('Edit Store'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Revoke'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Printer setup'), findsOneWidget);
      await scrollTo(tester, find.text('App version'));
      expect(find.text('App version'), findsOneWidget);
      expect(
        find.text('Cash Management'),
        findsNothing,
        reason: 'Cashier has neither cash permission -> section hidden',
      );
      await closeSheet(tester);
    },
  );

  testWidgets(
    'L3. SEC-NOROLE: 403s handled on sales history, held sales and settings; no crash, no stuck loading',
    (tester) async {
      await signIn(tester, creds, 'SEC-NOROLE');
      expectProductsBrowsable(tester);

      await openNav(tester, 'Sales history');
      await pumpUntil(
        tester,
        find.textContaining('You do not have permission to view sales'),
        reason: 'sales history 403 message',
      );
      expect(
        find.text('Retry'),
        findsNothing,
        reason: 'a permission denial is not offered as a retry',
      );
      await closeSheet(tester);

      await openNav(tester, 'Orders');
      await pumpUntil(
        tester,
        find.textContaining('You do not have permission to view sales'),
        reason: 'held sales 403 message',
      );
      expect(find.text('Retry'), findsNothing);
      await closeSheet(tester);

      await openNav(tester, 'Settings');
      await pumpUntil(
        tester,
        find.textContaining('do not have permission to view store settings'),
      );
      expect(find.text('Printer setup'), findsOneWidget);
      await scrollTo(tester, find.text('App version'));
      expect(find.text('App version'), findsOneWidget);
      await closeSheet(tester);

      // Still fully usable after the denials: back on the products page.
      expect(find.byType(ProductsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
