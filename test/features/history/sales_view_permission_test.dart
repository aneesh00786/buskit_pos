// Phase 17.10 (C3): GET /sales and GET /sales/:id now need a staff session +
// sales.view. A 403 is shown with a clear message; nothing is assumed.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/features/history/state/sales_history_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import 'sales_history_controller_test.dart' show FakeHistoryService, completed, entry;

const forbiddenSalesView = ApiException(
  kind: ApiErrorKind.forbidden,
  message: 'Forbidden',
  errorCode: PosErrorCodes.permissionDenied,
  data: {'permission': 'sales.view'},
);

void main() {
  test('listing without sales.view surfaces the 403 with a clear message', () async {
    final svc = FakeHistoryService()..onList = () async => throw forbiddenSalesView;
    final c = SalesHistoryController(svc, FakeProductService());
    await c.refresh();
    expect(c.status, HistoryListStatus.error);
    expect(c.error, forbiddenSalesView);
    expect(describeApiError(c.error!), 'You do not have permission to view sales. Ask a manager or administrator.');
    expect(c.error!.isRetryable, isFalse, reason: 'a permission denial is not offered as a retry');
  });

  test('opening a sale without sales.view surfaces the 403 on the detail', () async {
    final svc = FakeHistoryService()
      ..rows = [entry(id: 1)]
      ..onDetail = (id) async => throw forbiddenSalesView;
    final c = SalesHistoryController(svc, FakeProductService());
    await c.selectSale(1);
    expect(c.detail, isNull);
    expect(c.detailError, forbiddenSalesView);
  });

  test('with access, history and detail load as before', () async {
    final svc = FakeHistoryService()
      ..rows = [entry(id: 1)]
      ..details = {1: completed(id: 1)};
    final c = SalesHistoryController(svc, FakeProductService());
    await c.refresh();
    expect(c.status, HistoryListStatus.loaded);
    await c.selectSale(1);
    expect(c.detail!.id, 1);
  });
}
