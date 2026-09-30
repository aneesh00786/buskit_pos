import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/analytics/models/analytics_summary.dart';
import 'package:buskit_pos/features/analytics/state/analytics_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_analytics_service.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'No connection to the server.',
);

void main() {
  test('idle -> loading -> loaded', () async {
    final svc = FakeAnalyticsService();
    final c = AnalyticsController(svc);
    expect(c.status, AnalyticsStatus.idle);
    final f = c.load();
    expect(c.status, AnalyticsStatus.loading);
    await f;
    expect(c.status, AnalyticsStatus.loaded);
    expect(c.summary, isNotNull);
    expect(svc.callCount, 1);
  });

  test(
    'a failure with nothing loaded shows the error state; retry can recover',
    () async {
      final svc = FakeAnalyticsService();
      svc.onGetSummary = () async => throw netDown;
      final c = AnalyticsController(svc);
      await c.load();
      expect(c.status, AnalyticsStatus.error);
      expect(c.error, netDown);
      svc.onGetSummary = () async => zeroAnalyticsSummary;
      await c.retry();
      expect(c.status, AnalyticsStatus.loaded);
      expect(c.summary, isNotNull);
    },
  );

  test('a stale response (superseded by a newer load) is discarded', () async {
    final svc = FakeAnalyticsService();
    final first = Completer<AnalyticsSummary>();
    var calls = 0;
    svc.onGetSummary = () {
      calls++;
      return calls == 1
          ? first.future
          : Future.value(
              AnalyticsSummary.fromJson(
                analyticsSummaryJson(transactionCount: 3),
              ),
            );
    };
    final c = AnalyticsController(svc);
    final firstLoad = c.load();
    final secondLoad = c.load();
    first.complete(
      AnalyticsSummary.fromJson(analyticsSummaryJson(transactionCount: 1))!,
    );
    await firstLoad;
    await secondLoad;
    expect(c.summary!.todayTransactionCount, 3);
  });

  test('disposing after load completes does not throw on notify', () async {
    final svc = FakeAnalyticsService();
    final gate = Completer<void>();
    svc.onGetSummary = () => gate.future.then((_) => zeroAnalyticsSummary);
    final c = AnalyticsController(svc);
    final f = c.load();
    c.dispose();
    gate.complete();
    await f;
  });
}
