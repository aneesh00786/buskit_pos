import 'package:buskit_pos/features/analytics/data/analytics_service.dart';
import 'package:buskit_pos/features/analytics/models/analytics_summary.dart';

Map<String, dynamic> analyticsSummaryJson({
  int transactionCount = 0,
  num salesTotal = 0,
  List<Map<String, dynamic>> paymentBreakdown = const [],
  List<Map<String, dynamic>> topProducts = const [],
  List<Map<String, dynamic>> staffPerformance = const [],
}) => {
  'today': {'transaction_count': transactionCount, 'sales_total': salesTotal},
  'payment_breakdown': paymentBreakdown,
  'top_products': topProducts,
  'staff_performance': staffPerformance,
};

final zeroAnalyticsSummary = AnalyticsSummary.fromJson(analyticsSummaryJson())!;

class FakeAnalyticsService implements AnalyticsService {
  int callCount = 0;
  String? lastFrom;
  String? lastTo;
  Future<AnalyticsSummary> Function() onGetSummary = () async =>
      zeroAnalyticsSummary;

  @override
  Future<AnalyticsSummary> getSummary({String? from, String? to}) {
    callCount++;
    lastFrom = from;
    lastTo = to;
    return onGetSummary();
  }
}
