// Offline POS Phase 4 — manager resolution on the device: the sync service's
// resolve() against REAL JSON storage (only the server is faked, by the same
// FakeSyncServer as the sync tests), and the history UI: who sees the action,
// the confirmation screen (reason, OTHER note, acknowledgement), the result.
import 'dart:async';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/offline/models/offline_queue_entry.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/offline/offline_sync_service.dart';
import 'package:buskit_pos/features/offline/ui/offline_sale_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'offline_sync_test.dart' as base;

late OfflineSyncService sync;

/// A cashier's sale whose sync failed because its shift closed.
Future<OfflineSale> shiftClosedFailure() async {
  final sale = await base.recordSale(qty: 2);
  base.server.before = (_) async =>
      throw base.rejection('OFFLINE_SHIFT_INVALID');
  await sync.syncNow();
  base.server.before = null;
  final failed = (await base.storage.getSale(sale.localSaleId))!;
  expect(failed.status, OfflineSaleStatus.syncFailed);
  expect(failed.lastErrorCode, 'OFFLINE_SHIFT_INVALID');
  return failed;
}

void main() {
  setUp(() async {
    base.root = await Directory.systemTemp.createTemp('pos_offline_res_');
    base.now = DateTime.utc(2026, 10, 6, 9);
    base.storage = OfflineStorageService(base.root, clock: () => base.now);
    await base.storage.initialize();
    await base.seed();
    base.server = base.FakeSyncServer();
    base.scope = base.theScope;
    sync = base.newSync();
  });
  tearDown(() => base.root.delete(recursive: true));

  group('service', () {
    test('resolution syncs the SAME sale (same id, unchanged snapshot) -> SYNCED with resolver, queue DONE; original cashier/shift kept', () async {
      final failed = await shiftClosedFailure();
      final out = await sync.resolve(
        failed.localSaleId,
        reason: OfflineResolutionReason.shiftClosed,
      );
      expect(out.ok, isTrue, reason: out.message);
      final call = base.server.resolveCalls.single;
      expect(call['id'], failed.localSaleId);
      expect(call['reason'], 'SHIFT_CLOSED');
      expect(call['previous_status'], 'SYNC_FAILED');
      expect(call['previous_error_code'], 'OFFLINE_SHIFT_INVALID');
      expect(
        call['body'],
        failed.toSyncJson(),
        reason: 'nothing about the sale changes',
      );

      final s = (await base.storage.getSale(failed.localSaleId))!;
      expect(s.status, OfflineSaleStatus.synced);
      expect(s.serverSaleNumber, isNotNull);
      expect(s.resolvedBy, 'MGR-1');
      expect(s.resolutionReason, 'SHIFT_CLOSED');
      expect(s.salesmanId, 'TEST-SALES-A1', reason: 'original cashier kept');
      expect(s.shiftId, 79, reason: 'original shift kept');
      expect(
        (await base.storage.getQueueEntry(failed.localSaleId))!.status,
        OfflineQueueStatus.done,
      );
      expect(await base.storage.getPendingSales(), isEmpty);
      expect(
        (await base.storage.getSyncedSales()).single.localSaleId,
        failed.localSaleId,
        reason: 'kept for history',
      );
    });

    test('a rejected resolution (stock / tax / price) stays SYNC_FAILED with a clear reason; nothing is deleted', () async {
      final cases = {
        'OFFLINE_STOCK_CONFLICT':
            'Cannot synchronize because stock is no longer available.',
        'OFFLINE_TAX_MISMATCH':
            'Cannot synchronize because tax information changed.',
        'OFFLINE_PRICE_MISMATCH':
            'Cannot synchronize because the product price changed.',
      };
      for (final entry in cases.entries) {
        final failed = await shiftClosedFailure();
        base.server.beforeResolve = (_) async =>
            throw base.rejection(entry.key);
        final out = await sync.resolve(
          failed.localSaleId,
          reason: OfflineResolutionReason.shiftClosed,
        );
        expect(out.ok, isFalse);
        expect(out.message, entry.value);
        final s = (await base.storage.getSale(failed.localSaleId))!;
        expect(s.status, OfflineSaleStatus.syncFailed);
        expect(s.lastError, entry.value);
        expect(s.lastErrorCode, entry.key);
        expect(
          (await base.storage.getQueueEntry(failed.localSaleId))!.status,
          OfflineQueueStatus.failed,
        );
        expect(
          offlineNeedsManagerResolution(s, 'TEST-SALES-A1'),
          isFalse,
          reason: 'a manager cannot override this',
        );
        base.server.beforeResolve = null;
      }
      expect(base.server.created, isEmpty);
    });

    test('lost response: the retry reuses the same local_sale_id and records the ORIGINAL server sale; a network error keeps it resolvable', () async {
      final failed = await shiftClosedFailure();
      base.server.dropNextResponse = true;
      final lost = await sync.resolve(
        failed.localSaleId,
        reason: OfflineResolutionReason.shiftClosed,
      );
      expect(lost.ok, isFalse);
      expect(
        lost.message,
        'Could not connect to the server. Try the resolution again.',
      );
      var s = (await base.storage.getSale(failed.localSaleId))!;
      expect(s.status, OfflineSaleStatus.syncFailed);
      expect(
        s.lastErrorCode,
        'OFFLINE_SHIFT_INVALID',
        reason: 'still resolvable',
      );
      expect(base.server.created.length, 1, reason: 'the server did create it');

      final again = await sync.resolve(
        failed.localSaleId,
        reason: OfflineResolutionReason.shiftClosed,
      );
      expect(again.ok, isTrue);
      s = (await base.storage.getSale(failed.localSaleId))!;
      expect(s.status, OfflineSaleStatus.synced);
      expect(s.serverSaleId, base.server.created[failed.localSaleId]);
      expect(base.server.created.length, 1, reason: 'no second sale');
      expect(base.server.resolveCalls.map((c) => c['id']).toSet(), {
        failed.localSaleId,
      });
    });

    test('OTHER needs a note; a sale of another device or a synced sale cannot be resolved', () async {
      final failed = await shiftClosedFailure();
      final noNote = await sync.resolve(
        failed.localSaleId,
        reason: OfflineResolutionReason.other,
        note: ' ok ',
      );
      expect(noNote.ok, isFalse);
      expect(base.server.resolveCalls, isEmpty);
      base.scope = const PosTokenScope(
        companyId: 1,
        storeId: 213,
        registerId: 5,
        deviceId: 10,
        salesmanId: 'MGR-1',
      );
      expect(
        (await sync.resolve(
          failed.localSaleId,
          reason: OfflineResolutionReason.shiftClosed,
        )).ok,
        isFalse,
      );
      expect(base.server.resolveCalls, isEmpty);
      base.scope = base.theScope;
      final ok = await sync.resolve(
        failed.localSaleId,
        reason: OfflineResolutionReason.other,
        note: 'Cashier went home',
      );
      expect(ok.ok, isTrue);
      expect(base.server.resolveCalls.single['note'], 'Cashier went home');
      expect(
        (await sync.resolve(
          failed.localSaleId,
          reason: OfflineResolutionReason.shiftClosed,
        )).ok,
        isFalse,
        reason: 'already synced',
      );
    });

    test('a sale still queued by ANOTHER cashier can be resolved by a manager; the runner never sends it', () async {
      final theirs = await base.recordSale(staff: 'TEST-SALES-A2');
      final report = await sync.syncNow();
      expect(report.skipped, [theirs.localSaleId]);
      expect(offlineNeedsManagerResolution(theirs, 'TEST-SALES-A1'), isTrue);
      expect(
        offlineNeedsManagerResolution(theirs, 'TEST-SALES-A2'),
        isFalse,
        reason: 'its own cashier just syncs it',
      );
      final out = await sync.resolve(
        theirs.localSaleId,
        reason: OfflineResolutionReason.cashierUnavailable,
      );
      expect(out.ok, isTrue);
      expect(base.server.resolveCalls.single['previous_status'], 'SYNCING');
      final s = (await base.storage.getSale(theirs.localSaleId))!;
      expect(
        [s.status, s.salesmanId, s.resolvedBy],
        [OfflineSaleStatus.synced, 'TEST-SALES-A2', 'MGR-1'],
      );
      // The open-shift answer leaves it queued for its cashier.
      final another = await base.recordSale(staff: 'TEST-SALES-A2');
      base.server.beforeResolve = (_) async =>
          throw base.rejection('OFFLINE_RESOLUTION_NOT_REQUIRED');
      final notNeeded = await sync.resolve(
        another.localSaleId,
        reason: OfflineResolutionReason.cashierUnavailable,
      );
      expect(
        notNeeded.message,
        'The original shift is still open — its cashier can sync this sale normally.',
      );
      expect(
        (await base.storage.getSale(another.localSaleId))!.status,
        OfflineSaleStatus.syncFailed,
      );
    });

    test(
      'a resolution and a sync run never send at the same time (one lock)',
      () async {
        final failed = await shiftClosedFailure();
        final own = await base.recordSale();
        final order = <String>[];
        base.server.gate = Completer<void>();
        base.server.before = (id) async => order.add('sync:$id');
        base.server.beforeResolve = (id) async => order.add('resolve:$id');
        final run = sync.syncNow();
        final res = sync.resolve(
          failed.localSaleId,
          reason: OfflineResolutionReason.shiftClosed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(base.server.resolveCalls, isEmpty, reason: 'waits for the run');
        base.server.gate!.complete();
        await run;
        expect((await res).ok, isTrue);
        expect(order, [
          'sync:${own.localSaleId}',
          'resolve:${failed.localSaleId}',
        ]);
      },
    );
  });

  test('a refusal about the RESOLVER (no permission / own sale) leaves the sale resolvable by a proper manager', () async {
    final failed = await shiftClosedFailure();
    for (final code in [
      'POS_PERMISSION_DENIED',
      'OFFLINE_SELF_RESOLUTION_NOT_ALLOWED',
    ]) {
      base.server.beforeResolve = (_) async =>
          throw base.rejection(code, status: 403);
      final out = await sync.resolve(
        failed.localSaleId,
        reason: OfflineResolutionReason.shiftClosed,
      );
      expect(out.ok, isFalse);
      final s = (await base.storage.getSale(failed.localSaleId))!;
      expect(s.status, OfflineSaleStatus.syncFailed);
      expect(s.lastErrorCode, 'OFFLINE_SHIFT_INVALID');
      expect(s.lastError, failed.lastError);
      expect(
        offlineCanResolve(s, hasPermission: true, currentSalesmanId: 'MGR-1'),
        isTrue,
      );
    }
    base.server.beforeResolve = null;
    expect(
      (await sync.resolve(
        failed.localSaleId,
        reason: OfflineResolutionReason.shiftClosed,
      )).ok,
      isTrue,
    );
  });

  test('the sale\'s own cashier never gets the resolution action, even with the permission', () async {
    final failed = await shiftClosedFailure();
    expect(
      offlineCanResolve(
        failed,
        hasPermission: true,
        currentSalesmanId: 'TEST-SALES-A1',
      ),
      isFalse,
    );
    expect(
      offlineCanResolve(
        failed,
        hasPermission: false,
        currentSalesmanId: 'MGR-1',
      ),
      isFalse,
    );
    expect(
      offlineCanResolve(
        failed,
        hasPermission: true,
        currentSalesmanId: 'MGR-1',
      ),
      isTrue,
    );
  });

  group('history UI', () {
    Future<OfflineSale> pumpHistory(
      WidgetTester tester, {
      required bool canResolve,
    }) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late OfflineSale failed;
      await tester.runAsync(() async => failed = await shiftClosedFailure());
      final offline = OfflineServices(
        base.storage,
        syncApi: base.server,
        scope: () => base.scope,
        clock: () => base.now,
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: LocalSalesSection(
                  offline: offline,
                  canResolve: canResolve,
                  currentSalesmanId: 'MGR-1',
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      return failed;
    }

    testWidgets(
      'an ordinary cashier sees the failure and its reason, but no resolution action',
      (tester) async {
        final failed = await pumpHistory(tester, canResolve: false);
        expect(find.textContaining('Sync failed'), findsOneWidget);
        expect(
          find.textContaining('original shift is no longer valid'),
          findsOneWidget,
        );
        expect(
          find.textContaining('A manager must resolve this sale.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Manager resolution required'),
          findsNothing,
        );
        await tester.tap(find.text(offlineSaleTitle(failed)));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('offline-resolve')), findsNothing);
        expect(
          find.byKey(const Key('offline-retry-sync')),
          findsNothing,
          reason: 'a retry cannot fix a closed shift',
        );
      },
    );

    testWidgets(
      'a manager resolves: details shown, reason + acknowledgement required, OTHER needs a note, success -> SYNCED with resolver, original cashier/shift',
      (tester) async {
        final failed = await pumpHistory(tester, canResolve: true);
        expect(
          find.textContaining('Manager resolution required'),
          findsOneWidget,
        );
        await tester.tap(find.text(offlineSaleTitle(failed)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('offline-resolve')));
        await tester.pumpAndSettle();

        // Review screen.
        expect(find.text('Resolve offline sale'), findsOneWidget);
        expect(
          find.text('TEST-SALES-A1'),
          findsOneWidget,
          reason: 'original cashier',
        );
        expect(find.text('#79'), findsOneWidget, reason: 'original shift');
        expect(find.text('#5'), findsOneWidget, reason: 'original register');
        expect(find.text('2 × Soap'), findsOneWidget);
        expect(find.text('Cash'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('original shift is no longer valid'),
          ),
          findsOneWidget,
        );
        FilledButton submit() => tester.widget<FilledButton>(
          find.byKey(const Key('resolution-submit')),
        );
        expect(submit().onPressed, isNull, reason: 'no reason yet');

        await tester.tap(find.byKey(const Key('resolution-confirm')));
        await tester.pump();
        expect(submit().onPressed, isNull, reason: 'reason still required');
        await tester.tap(find.byKey(const Key('resolution-reason')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Other (note required)').last);
        await tester.pumpAndSettle();
        expect(submit().onPressed, isNull, reason: 'OTHER needs a note');
        await tester.enterText(find.byKey(const Key('resolution-note')), 'abc');
        await tester.pump();
        expect(submit().onPressed, isNull);
        await tester.tap(find.byKey(const Key('resolution-reason')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Shift closed before the sale synced').last);
        await tester.pumpAndSettle();
        expect(submit().onPressed, isNotNull);
        await tester.tap(find.byKey(const Key('resolution-confirm')));
        await tester.pump();
        expect(
          submit().onPressed,
          isNull,
          reason: 'acknowledgement is required',
        );
        expect(
          find.textContaining('without reopening that shift'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('resolution-confirm')));
        await tester.pump();

        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('resolution-submit')));
          for (
            var i = 0;
            i < 100 &&
                (await base.storage.getSale(failed.localSaleId))!.status !=
                    OfflineSaleStatus.synced;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(
          find.text('Offline sale synchronized successfully.'),
          findsOneWidget,
        );
        expect(find.text('POS-00000101'), findsOneWidget);
        expect(base.server.resolveCalls.single['reason'], 'SHIFT_CLOSED');

        await tester.runAsync(() async {
          await tester.tap(find.text('Done'));
          // The list reload reads real files: alternate real time and frames.
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(
          find.text('${offlineSaleTitle(failed)} → POS-00000101'),
          findsOneWidget,
        );
        await tester.tap(
          find.text('${offlineSaleTitle(failed)} → POS-00000101'),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('offline-resolved-by')),
            matching: find.text('MGR-1'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('offline-cashier')),
            matching: find.text('TEST-SALES-A1'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('offline-shift')),
            matching: find.text('#79'),
          ),
          findsOneWidget,
        );
        expect(
          (await tester.runAsync(
            () => base.storage.getQueueEntry(failed.localSaleId),
          ))!.status,
          OfflineQueueStatus.done,
        );
      },
    );

    testWidgets(
      'a failed resolution shows the reason and leaves the sale SYNC_FAILED',
      (tester) async {
        final failed = await pumpHistory(tester, canResolve: true);
        base.server.beforeResolve = (_) async =>
            throw base.rejection('OFFLINE_STOCK_CONFLICT');
        await tester.tap(find.text(offlineSaleTitle(failed)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('offline-resolve')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('resolution-reason')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Shift closed before the sale synced').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('resolution-confirm')));
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('resolution-submit')));
          await Future<void>.delayed(const Duration(milliseconds: 400));
        });
        await tester.pumpAndSettle();
        expect(
          find.text('Cannot synchronize because stock is no longer available.'),
          findsWidgets,
        );
        final s = (await tester.runAsync(
          () => base.storage.getSale(failed.localSaleId),
        ))!;
        expect(s.status, OfflineSaleStatus.syncFailed);
        expect(s.lastErrorCode, 'OFFLINE_STOCK_CONFLICT');
      },
    );
  });

  test('ApiException mapping for resolution never leaks internals', () {
    expect(
      OfflineSyncService.resolutionMessageFor(
        ApiException.fromStatus(422, message: 'SQL near SELECT'),
      ),
      'Cannot synchronize this sale. Please contact support.',
    );
    expect(
      OfflineSyncService.resolutionMessageFor(
        ApiException.fromStatus(403, errorCode: 'POS_PERMISSION_DENIED'),
      ),
      'You do not have permission to resolve offline sales.',
    );
  });
}
