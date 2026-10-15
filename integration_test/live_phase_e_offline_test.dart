// Phase E-G — LIVE offline / network-recovery run. The till talks to the
// local fault-injection proxy (scratchpad pe_proxy.js, 127.0.0.1:3001 ->
// :3000, disposable busskit_phase_e_test); the test switches the proxy
// between online / offline / "drop the next pricing response" and uses the
// backend directly (:3000) for the other actor in the 409 and 403 cases.
// Prints `PEG|<json>` facts for the host-side checks. Nothing is mocked.
//
//   flutter test integration_test/live_phase_e_offline_test.dart -d macos \
//     --dart-define=PE_BASE_URL=http://127.0.0.1:3001 --dart-define=PE_CREDS=...
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/features/products/ui/products_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'live_phase_e_test.dart' as e;

const backend = 'http://127.0.0.1:3000/api/v1';
const proxy = 'http://127.0.0.1:3001';

Future<Map<String, dynamic>> http(String method, String url, {String? token, Object? body}) async {
  final c = HttpClient();
  try {
    final r = await c.openUrl(method, Uri.parse(url));
    r.headers.contentType = ContentType.json;
    if (token != null) r.headers.set('Authorization', 'Bearer $token');
    if (body != null) r.write(jsonEncode(body));
    final res = await r.close();
    final text = await res.transform(utf8.decoder).join();
    return {'status': res.statusCode, 'body': text.isEmpty ? null : jsonDecode(text)};
  } finally {
    c.close();
  }
}

Future<Map<String, dynamic>> proxyMode(String mode) async => (await http('GET', '$proxy/__pe/mode/$mode'))['body'] as Map<String, dynamic>;

Future<String> adminToken() async {
  final r = await http('POST', '$backend/admin/auth/login', body: {'email': e.creds['admins']['sa'], 'password': e.creds['password']});
  return r['body']['data']['token'] as String;
}

Future<String> posToken(String till, String staff) async {
  final dev = e.creds['devices'][till] as Map<String, dynamic>;
  final d = await http('POST', '$backend/pos/auth/device-login', body: {'device_identifier': dev['identifier'], 'device_secret': dev['secret']});
  final s = await http('POST', '$backend/pos/auth/staff-login', token: d['body']['data']['token'] as String, body: {'salesman_id': staff, 'pin': e.creds['pins'][staff]});
  return s['body']['data']['token'] as String;
}

Future<void> setRoleLimit(String admin, int? pct) async {
  final roleId = e.creds['roles']['senior'];
  final list = await http('GET', '$backend/admin/discount-limits', token: admin);
  final role = (list['body']['data']['roles'] as List).firstWhere((r) => r['role_id'] == roleId);
  final v = role['limit'] == null ? 0 : role['limit']['version'];
  if (pct == null) {
    if (role['limit'] != null) await http('DELETE', '$backend/admin/discount-limits/roles/$roleId', token: admin, body: {'expected_version': v});
  } else {
    await http('PUT', '$backend/admin/discount-limits/roles/$roleId', token: admin, body: {'max_percent': pct, 'expected_version': v});
  }
}

void fact(String name, Object? value) {
  // ignore: avoid_print
  print('PEG|${jsonEncode({'fact': name, 'value': value})}');
  // Also to the proxy log: flutter test only shows prints at the end.
  unawaited(http('GET', '$proxy/__pe/fact/${Uri.encodeComponent(jsonEncode({name: value}))}').catchError((_) => <String, dynamic>{}));
}

String dialogText(WidgetTester tester) => find
    .descendant(of: find.byKey(const Key('line-pricing-dialog')), matching: find.byType(Text))
    .evaluate()
    .map((x) => (x.widget as Text).data)
    .whereType<String>()
    .join(' | ');

Future<void> closeDialog(WidgetTester tester) async {
  await e.tapIt(tester, find.byKey(const Key('line-pricing-close')));
  await e.settle(tester);
}

Future<void> waitFor(WidgetTester tester, bool Function() cond, {int seconds = 15}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end) && !cond()) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const tea = 9901, coffee = 9902, water = 9903;

  testWidgets(timeout: const Timeout(Duration(minutes: 10)), 'E-G: offline and network recovery through the real till', (tester) async {
    expect(e.creds['pins'], isNotNull, reason: 'PE_CREDS not provided');
    fact('start', true);
    // iPad portrait uses the narrow layout (cart behind a button): lay the
    // till out in landscape, as on a counter-mounted tablet.
    final size = tester.view.physicalSize;
    if (size.width < size.height) {
      tester.view.physicalSize = Size(size.height, size.width);
      addTearDown(tester.view.resetPhysicalSize);
    }
    await proxyMode('online');
    fact('proxy_ok', true);
    await http('GET', '$proxy/__pe/stats/reset');
    final admin = await adminToken();
    await setRoleLimit(admin, null);

    // ---- 1. lost response: applied on the server, outcome unknown on the till ----
    await e.signIn(tester, 'till1', 'E2E-MGR');
    fact('signed_in', true);
    await e.addProduct(tester, 'E2E Exclusive Tea', tea);
    await e.addProduct(tester, 'E2E Inclusive Coffee', coffee);
    await proxyMode('drop-next-pricing');
    await e.openLine(tester, coffee);
    await e.pumpUntil(tester, find.byKey(const Key('line-discount-value')));
    await tester.enterText(find.byKey(const Key('line-discount-value')), '5');
    await tester.enterText(find.byKey(const Key('line-discount-reason')), 'E2E-G lost response');
    await e.tapIt(tester, find.byKey(const Key('line-discount-apply')));
    await waitFor(tester, () => e.cartOf(tester).linePricingOutcomeUnknown, seconds: 40);
    await e.settle(tester);
    final cart = e.cartOf(tester);
    fact('lost.unknown', cart.linePricingOutcomeUnknown);
    fact('lost.dialog_after', dialogText(tester));
    fact('lost.stats', await proxyMode('online'));
    // A further change is refused without a request.
    final before = (await http('GET', '$proxy/__pe/stats'))['body']['pricingForwarded'];
    await closeDialog(tester);
    fact('lost.offline_flag_right_after', cart.offline?.isOffline());
    await e.openLine(tester, tea);
    fact('lost.reopen_shows_unknown', find.byKey(const Key('line-pricing-unknown')).evaluate().isNotEmpty);
    fact('lost.reopen_has_apply', find.byKey(const Key('line-discount-apply')).evaluate().isNotEmpty);
    final ok = await cart.changeLinePricing(e.lineId(tester, tea), (s) async => throw StateError('must not be sent'));
    fact('lost.programmatic_change_refused', !ok);
    fact('lost.no_request_while_unknown', (await http('GET', '$proxy/__pe/stats'))['body']['pricingForwarded'] == before);
    // Reload reconciles: the discount the server applied is shown once.
    await e.tapIt(tester, find.byKey(const Key('line-pricing-reload')));
    await waitFor(tester, () => !cart.linePricingOutcomeUnknown);
    await e.settle(tester);
    fact('lost.after_reload_unknown', cart.linePricingOutcomeUnknown);
    fact('lost.after_reload_reachable', cart.offline?.isOffline() != true);
    final coffeeLine = cart.sale!.items.firstWhere((l) => l.productVariationId == coffee);
    fact('lost.after_reload_discount', coffeeLine.discountAmount);
    fact('lost.sale_id', cart.sale!.id);
    fact('lost.dialog_normal_again', find.byKey(const Key('line-discount-value')).evaluate().isNotEmpty || find.byKey(const Key('line-pricing-dialog')).evaluate().isEmpty);
    if (find.byKey(const Key('line-pricing-dialog')).evaluate().isNotEmpty) await closeDialog(tester);

    // ---- 2. offline: no pricing, not queued, no fallback checkout at catalogue price ----
    await proxyMode('offline');
    await cart.refresh();
    await waitFor(tester, () => cart.offline?.isOffline() == true);
    fact('offline.detected', cart.offline?.isOffline());
    final fwd = (await http('GET', '$proxy/__pe/stats'))['body']['pricingForwarded'];
    await e.openLine(tester, tea);
    fact('offline.dialog_offline_message', find.byKey(const Key('line-pricing-offline')).evaluate().isNotEmpty);
    fact('offline.dialog_has_apply', find.byKey(const Key('line-discount-apply')).evaluate().isNotEmpty);
    await closeDialog(tester);
    final ok2 = await cart.changeLinePricing(e.lineId(tester, tea), (s) async => throw StateError('must not be sent'));
    fact('offline.programmatic_change_refused', !ok2);
    ScaffoldMessenger.of(tester.element(find.byType(ProductsPage))).clearSnackBars();
    await tester.pump(const Duration(milliseconds: 600));
    await e.tapIt(tester, find.widgetWithText(FilledButton, 'Pay'));
    await tester.pump(const Duration(seconds: 2));
    fact('offline.pay_online_required', find.byKey(const Key('online-required')).evaluate().isNotEmpty);
    fact('offline.pay_offline_note', find.byKey(const Key('offline-checkout-note')).evaluate().isNotEmpty);
    final complete = find.widgetWithText(FilledButton, 'Complete Sale');
    fact('offline.complete_enabled', complete.evaluate().isNotEmpty && tester.widget<FilledButton>(complete).onPressed != null);
    fact('offline.will_complete_offline', cart.willCompleteOffline);
    final close = find.byTooltip('Close');
    if (close.evaluate().isNotEmpty) await e.tapIt(tester, close.first);
    await e.settle(tester);
    await proxyMode('online');
    await tester.pump(const Duration(seconds: 3));
    fact('offline.nothing_queued_after_reconnect', (await http('GET', '$proxy/__pe/stats'))['body']['pricingForwarded'] == fwd);
    await cart.refresh();
    await waitFor(tester, () => cart.offline?.isOffline() != true);
    await e.settle(tester);
    fact('offline.recovered', cart.offline?.isOffline() != true);
    await e.payAndRecord(tester, 'G1 after recovery');

    // ---- 3. 409: another actor changed the sale; the till reloads ----
    await e.addProduct(tester, 'E2E Exclusive Tea', tea);
    final saleId = cart.sale!.id;
    final other = await posToken('till1', 'E2E-MGR');
    final cur = await http('GET', '$backend/pos/sales/$saleId', token: other);
    final itemId = e.lineId(tester, tea);
    final ch = await http('PUT', '$backend/pos/sales/$saleId/items/$itemId/price', token: other, body: {'expected_version': cur['body']['data']['version'], 'unit_price': 170, 'reason': 'E2E-G other actor'});
    fact('conflict.other_actor_status', ch['status']);
    await e.openLine(tester, tea);
    await e.pumpUntil(tester, find.byKey(const Key('line-discount-value')));
    await tester.enterText(find.byKey(const Key('line-discount-value')), '5');
    await tester.enterText(find.byKey(const Key('line-discount-reason')), 'E2E-G stale');
    await e.tapIt(tester, find.byKey(const Key('line-discount-apply')));
    await e.settle(tester);
    await tester.pump(const Duration(seconds: 1));
    fact('conflict.dialog_text', dialogText(tester));
    fact('conflict.cart_unit_after', cart.sale!.items.firstWhere((l) => l.productVariationId == tea).unitPrice);
    fact('conflict.cart_discount_after', cart.sale!.items.firstWhere((l) => l.productVariationId == tea).discountAmount);
    fact('conflict.sale_id', saleId);
    if (find.byKey(const Key('line-pricing-dialog')).evaluate().isNotEmpty) await closeDialog(tester);
    await e.payAndRecord(tester, 'G2 after conflict review');

    // ---- 4. 403 refreshes the policy; 5. 422 message ----
    await setRoleLimit(admin, 10);
    await e.signIn(tester, 'till1', 'E2E-SEN');
    await e.addProduct(tester, 'E2E No-Tax Water', water);
    await e.openLine(tester, water);
    await e.pumpUntil(tester, find.byKey(const Key('line-discount-limit')));
    fact('forbidden.limit_before', (tester.widget<Text>(find.byKey(const Key('line-discount-limit')))).data);
    await setRoleLimit(admin, 3);
    await tester.enterText(find.byKey(const Key('line-discount-value')), '5');
    await tester.enterText(find.byKey(const Key('line-discount-reason')), 'E2E-G limit lowered');
    await e.tapIt(tester, find.byKey(const Key('line-discount-apply')));
    await e.settle(tester);
    await e.pumpUntil(tester, find.byKey(const Key('line-discount-limit')));
    await tester.pump(const Duration(seconds: 1));
    fact('forbidden.dialog_text', dialogText(tester));
    fact('forbidden.limit_after', (tester.widget<Text>(find.byKey(const Key('line-discount-limit')))).data);
    fact('forbidden.cart_discount', e.cartOf(tester).sale!.items.first.discountAmount);
    // 422: a value the server rejects (if the dialog lets it through).
    await tester.enterText(find.byKey(const Key('line-discount-value')), '2.555');
    await e.tapIt(tester, find.byKey(const Key('line-discount-apply')));
    await e.settle(tester);
    fact('invalid.dialog_text', dialogText(tester));
    await closeDialog(tester);
    await setRoleLimit(admin, null);
    // ignore: avoid_print
    print('PEG|${jsonEncode({'fact': 'done', 'value': true})}');
  });
}
