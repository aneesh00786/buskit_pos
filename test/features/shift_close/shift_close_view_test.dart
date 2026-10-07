import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/shell/ui/pos_sidebar.dart';
import 'package:buskit_pos/features/shift_close/data/shift_close_service.dart';
import 'package:buskit_pos/features/shift_close/models/shift_summary.dart';
import 'package:buskit_pos/features/shift_close/ui/shift_close_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

/// Server-shaped summary JSON (the same keys GET /shifts/current/summary sends).
Map<String, dynamic> summaryJson({
  String status = 'open',
  bool closable = true,
  double expected = 375,
  Map<String, dynamic>? cashExtra,
}) => {
  'shift': {
    'id': 123,
    'status': status,
    'register_code': 'R-01',
    'register_name': 'Front counter',
    'opened_by': 'S1',
    'opened_at': '2026-10-05 09:15:00',
    'closed_at': status == 'closed' ? '2026-10-05 18:00:00' : null,
    'opening_amount': 50,
  },
  'sales': {
    'count': 5,
    'total': 800,
    'refunds_count': 3,
    'refunds_total': 300,
    'voids_count': 1,
    'voids_total': 100,
  },
  'payments': [
    {'method': 'card', 'count': 2, 'amount': 250},
    {'method': 'cash', 'count': 4, 'amount': 520},
    {'method': 'wallet', 'count': 1, 'amount': 30},
  ],
  'cash': {
    'opening': 50,
    'cash_sales': 520,
    'cash_refunds': 200,
    'deposits': 20,
    'withdrawals': 15,
    'expected': expected,
    ...?cashExtra,
  },
  'closable_by_current_staff': closable,
};

ShiftSummary summary({bool closable = true}) =>
    ShiftSummary.fromJson(summaryJson(closable: closable))!;

ShiftSummary closedResult({double counted = 380, double variance = 5}) =>
    ShiftSummary.fromJson(
      summaryJson(
        status: 'closed',
        closable: false,
        cashExtra: {'counted': counted, 'variance': variance},
      ),
    )!;

class FakeShiftCloseService implements ShiftCloseService {
  Future<ShiftSummary> Function() onSummary = () async => summary();
  Future<ShiftSummary> Function(int shiftId, double amount) onClose = (
    id,
    amount,
  ) async => closedResult(counted: amount, variance: amount - 375);
  final List<String> closeCalls = [];
  int summaryCalls = 0;

  @override
  Future<ShiftSummary> currentSummary() {
    summaryCalls++;
    return onSummary();
  }

  @override
  Future<ShiftSummary> close({
    required int shiftId,
    required double closingAmount,
    List<DenominationCount>? denominations,
  }) {
    closeCalls.add('$shiftId:$closingAmount');
    denominationCalls.add(denominations);
    return onClose(shiftId, closingAmount);
  }

  /// Phase 14C-B2: the denominations sent with each close (null = none).
  final List<List<DenominationCount>?> denominationCalls = [];
}

Future<SessionController> signedInSession({List<String>? permissions}) async {
  final auth = FakeAuthService();
  if (permissions != null) {
    auth.onAuthContext = (t) async => PosAuthContext(
      staff: const StaffInfo(
        salesmanId: 'S1',
        role: StaffRole(id: 1, name: 'Cashier'),
      ),
      permissions: permissions,
    );
  }
  final session = SessionController(auth, MemoryTokenStore());
  await session.loginDevice('REG-1', 'secret');
  await session.loginStaff('S1', '1234');
  await session.openShift(0);
  return session;
}

/// Pumps a host page whose button opens Shift Close exactly like the POS
/// sidebar does (closing signs the staff member out with a notice).
Future<void> pumpHost(
  WidgetTester tester, {
  required FakeShiftCloseService service,
  required SessionController session,
  bool cartHasItems = false,
  int unsyncedOfflineSales = 0,
  double width = 1200,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<SessionController>.value(
      value: session,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showShiftClose(
                  context,
                  service: service,
                  cartHasItems: cartHasItems,
                  unsyncedOfflineSales: unsyncedOfflineSales,
                  onClosed: (r) => session.logoutStaff(
                    notice:
                        'Shift #${r.shiftId} closed. Sign in to open the next shift.',
                  ),
                ),
                child: const Text('open shift close'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open shift close'));
  await tester.pumpAndSettle();
}

String valueOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Future<void> enterCounted(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('shift-counted-cash')), text);
  await tester.pump();
}

void main() {
  late SessionController session;
  late FakeShiftCloseService service;

  setUp(() async {
    service = FakeShiftCloseService();
    session = await signedInSession();
  });
  tearDown(() => session.dispose());

  testWidgets(
    '1-4. loads the server summary: shift, sales, payments and expected cash',
    (tester) async {
      await pumpHost(tester, service: service, session: session);
      expect(service.summaryCalls, 1);
      expect(find.text('Shift #123'), findsOneWidget);
      expect(find.text('Front counter'), findsOneWidget);
      expect(find.text('Sales (5)'), findsOneWidget);
      expect(find.text('800.00'), findsOneWidget); // sales total
      expect(find.text('Refunds (3)'), findsOneWidget);
      expect(find.text('Voided (1)'), findsOneWidget);
      expect(find.text('Cash (4)'), findsOneWidget);
      expect(find.text('Card (2)'), findsOneWidget);
      expect(find.text('Loyalty wallet (1)'), findsOneWidget);
      expect(
        find.text('520.00'),
        findsWidgets,
      ); // cash takings, formatted like the rest of the POS
      expect(valueOf(tester, 'shift-expected-cash'), '375.00');
      expect(find.text('−200.00'), findsOneWidget); // cash refunds
      expect(find.text('−15.00'), findsOneWidget); // cash out
      expect(
        find.textContaining('₹'),
        findsNothing,
        reason: 'no hard-coded currency symbol',
      );
    },
  );

  testWidgets(
    '5/6. counted cash input drives the variance preview (over, short, exact, invalid)',
    (tester) async {
      await pumpHost(tester, service: service, session: session);
      expect(valueOf(tester, 'shift-variance'), '—');
      final submit = find.byKey(const Key('shift-close-submit'));
      expect(
        tester.widget<FilledButton>(submit).onPressed,
        isNull,
        reason: 'no count yet',
      );

      await enterCounted(tester, '380');
      expect(valueOf(tester, 'shift-variance'), '+5.00');
      await enterCounted(tester, '367.5');
      expect(valueOf(tester, 'shift-variance'), '−7.50');
      await enterCounted(tester, '375');
      expect(valueOf(tester, 'shift-variance'), '0.00');
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

      await enterCounted(tester, '1.2345');
      expect(
        find.text('Enter an amount with up to 3 decimals.'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    },
  );

  testWidgets(
    'Phase 5: unsynced offline sales on this device are warned about before the shift closes (none -> no warning)',
    (tester) async {
      await pumpHost(
        tester,
        service: service,
        session: session,
        unsyncedOfflineSales: 2,
      );
      await enterCounted(tester, '380');
      await tester.tap(find.byKey(const Key('shift-close-submit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('shift-close-unsynced-warning')),
        findsOneWidget,
      );
      expect(
        find.textContaining('2 offline sales have not synced yet'),
        findsOneWidget,
      );
      expect(
        find.textContaining('a manager will have to resolve them'),
        findsOneWidget,
      );
      expect(
        service.closeCalls,
        isEmpty,
        reason: 'only a warning: nothing sent before confirming',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.closeCalls, isEmpty);
    },
  );

  testWidgets('Phase 5: no offline sales pending -> no offline warning', (
    tester,
  ) async {
    await pumpHost(tester, service: service, session: session);
    await enterCounted(tester, '380');
    await tester.tap(find.byKey(const Key('shift-close-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shift-close-unsynced-warning')), findsNothing);
  });

  testWidgets(
    '7/8. confirm -> close once with the server shift id -> server result -> Done signs out',
    (tester) async {
      await pumpHost(
        tester,
        service: service,
        session: session,
        cartHasItems: true,
      );
      await enterCounted(tester, '380');
      await tester.tap(find.byKey(const Key('shift-close-submit')));
      await tester.pumpAndSettle();

      // Confirmation shows the figures and the warnings.
      expect(find.text('Close this shift?'), findsOneWidget);
      expect(
        find.textContaining('will be closed and you will be signed out'),
        findsOneWidget,
      );
      expect(
        find.textContaining('will be left on this closed shift'),
        findsOneWidget,
      );
      expect(
        service.closeCalls,
        isEmpty,
        reason: 'nothing sent before confirming',
      );

      await tester.tap(find.byKey(const Key('shift-close-confirm')));
      await tester.pumpAndSettle();
      expect(service.closeCalls, ['123:380.0']);
      expect(find.byKey(const Key('shift-closed-title')), findsOneWidget);
      expect(
        valueOf(tester, 'shift-final-variance'),
        '+5.00',
        reason: "the server's variance",
      );
      expect(
        session.phase,
        SessionPhase.ready,
        reason: 'still signed in until Done',
      );

      await tester.tap(find.byKey(const Key('shift-closed-done')));
      await tester.pumpAndSettle();
      expect(find.text('Shift close'), findsNothing);
      expect(
        session.phase,
        SessionPhase.staffLogin,
        reason: 'the app no longer believes the shift is open',
      );
      expect(
        session.notice,
        'Shift #123 closed. Sign in to open the next shift.',
      );
    },
  );

  testWidgets('cancelling the confirmation sends nothing', (tester) async {
    await pumpHost(tester, service: service, session: session);
    await enterCounted(tester, '375');
    await tester.tap(find.byKey(const Key('shift-close-submit')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('will be left on this closed shift'),
      findsNothing,
      reason: 'no cart warning with an empty cart',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.closeCalls, isEmpty);
    expect(session.phase, SessionPhase.ready);
  });

  testWidgets(
    '11. the close cannot be submitted twice while the request is in flight',
    (tester) async {
      final pending = Completer<ShiftSummary>();
      service.onClose = (id, amount) => pending.future;
      await pumpHost(tester, service: service, session: session);
      await enterCounted(tester, '380');
      await tester.tap(find.byKey(const Key('shift-close-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shift-close-confirm')));
      await tester.pump();

      final submit = find.byKey(const Key('shift-close-submit'));
      expect(find.text('Closing…'), findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(submit, warnIfMissed: false);
      await tester.pump();
      expect(service.closeCalls.length, 1);

      pending.complete(closedResult());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shift-closed-title')), findsOneWidget);
      expect(service.closeCalls.length, 1);
    },
  );

  testWidgets(
    '9. already closed (409) on close: the backend message is shown and Close is no longer offered',
    (tester) async {
      service.onClose = (id, amount) async => throw const ApiException(
        kind: ApiErrorKind.conflict,
        statusCode: 409,
        message: 'Shift is not open',
      );
      await pumpHost(tester, service: service, session: session);
      await enterCounted(tester, '380');
      await tester.tap(find.byKey(const Key('shift-close-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shift-close-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Shift is not open'), findsOneWidget);
      expect(find.byKey(const Key('shift-close-submit')), findsNothing);
      expect(
        session.phase,
        SessionPhase.ready,
        reason: 'a failed close never signs out',
      );
    },
  );

  testWidgets(
    'a register with no open shift shows that, with nothing to close',
    (tester) async {
      service.onSummary = () async => throw const ApiException(
        kind: ApiErrorKind.notFound,
        statusCode: 404,
        errorCode: 'POS_NO_OPEN_SHIFT',
        message: 'There is no open shift on this register',
      );
      await pumpHost(tester, service: service, session: session);
      expect(find.text('No open shift'), findsOneWidget);
      expect(find.byKey(const Key('shift-close-submit')), findsNothing);
    },
  );

  testWidgets(
    '10. session expired (401) while loading: the error is shown, not a summary',
    (tester) async {
      service.onSummary = () async => throw const ApiException(
        kind: ApiErrorKind.unauthorized,
        statusCode: 401,
        message: 'Your session has expired. Please sign in again.',
      );
      await pumpHost(tester, service: service, session: session);
      expect(
        find.text('Your session has expired. Please sign in again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('shift-close-submit')), findsNothing);
    },
  );

  testWidgets(
    'permission denied (403) on close shows the permission message and keeps the shift screen',
    (tester) async {
      service.onClose = (id, amount) async => throw const ApiException(
        kind: ApiErrorKind.forbidden,
        statusCode: 403,
        errorCode: 'POS_PERMISSION_DENIED',
        message: 'Forbidden',
        data: {'permission': 'shifts.close'},
      );
      await pumpHost(tester, service: service, session: session);
      await enterCounted(tester, '380');
      await tester.tap(find.byKey(const Key('shift-close-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shift-close-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'You do not have permission to close the shift. Ask a manager.',
        ),
        findsOneWidget,
      );
      expect(session.phase, SessionPhase.ready);
    },
  );

  testWidgets(
    'a shift opened by someone else cannot be closed from this screen',
    (tester) async {
      service.onSummary = () async => summary(closable: false);
      await pumpHost(tester, service: service, session: session);
      await enterCounted(tester, '375');
      expect(find.byKey(const Key('shift-not-closable')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('shift-close-submit')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'loaded permissions without shifts.close disable the button (backend still decides)',
    (tester) async {
      final limited = await signedInSession(permissions: ['shifts.view']);
      addTearDown(limited.dispose);
      await pumpHost(tester, service: service, session: limited);
      await enterCounted(tester, '375');
      expect(
        find.text(
          'You do not have permission to close the shift. Ask a manager.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('shift-close-submit')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('phone width opens as a sheet with the same flow', (
    tester,
  ) async {
    await pumpHost(tester, service: service, session: session, width: 400);
    expect(find.text('Shift #123'), findsOneWidget);
    await enterCounted(tester, '380');
    expect(valueOf(tester, 'shift-variance'), '+5.00');
  });

  testWidgets('sidebar shows "Close shift" only when a callback is wired', (
    tester,
  ) async {
    Future<void> pumpSidebar(VoidCallback? onCloseShift) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              height: 900,
              child: PosSidebar(
                collapsed: false,
                brandTitle: 'POS',
                onSignOut: () {},
                onCloseShift: onCloseShift,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    var tapped = 0;
    await pumpSidebar(() => tapped++);
    expect(find.text('Close shift'), findsOneWidget);
    await tester.tap(find.text('Close shift'));
    expect(tapped, 1);
    await pumpSidebar(null);
    expect(find.text('Close shift'), findsNothing);
    expect(find.text('Sign out'), findsOneWidget);
  });
}
