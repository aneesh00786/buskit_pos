import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/utils/uuid.dart';
import '../../receipt/state/cash_drawer_service.dart';
import '../data/no_sale_service.dart';

enum NoSaleOutcome {
  /// Recorded and the drawer opened.
  opened,

  /// Recorded, but the drawer could not be opened.
  recordedNotOpened,

  /// No drawer set up: nothing recorded, nothing sent.
  notConfigured,

  /// Refused by the server (permission, session) or not reachable: nothing
  /// was opened.
  refused,
}

class NoSaleResult {
  const NoSaleResult(this.outcome, this.message);
  final NoSaleOutcome outcome;
  final String message;
}

/// Phase 14A — manual "open drawer / no sale": (1) a drawer must be set up,
/// (2) the server records it (and checks `payments.cash_drawer`) BEFORE
/// (3) the drawer is pulsed — so the drawer never opens unrecorded. One
/// idempotency key per call: a retried request is a replay on the server.
class NoSaleAction {
  NoSaleAction({
    required this.service,
    required this.drawer,
    String Function()? newKey,
  }) : _newKey = newKey ?? generateUuidV4;

  final NoSaleService service;
  final CashDrawerService drawer;
  final String Function() _newKey;

  Future<NoSaleResult> run({String? reason}) async {
    if (!await drawer.isConfigured()) {
      return const NoSaleResult(
        NoSaleOutcome.notConfigured,
        CashDrawerService.notConfiguredMessage,
      );
    }
    try {
      await service.recordNoSale(idempotencyKey: _newKey(), reason: reason);
    } on ApiException catch (e) {
      return NoSaleResult(NoSaleOutcome.refused, describeApiError(e));
    } catch (_) {
      return const NoSaleResult(
        NoSaleOutcome.refused,
        'The no-sale could not be recorded. The drawer was not opened.',
      );
    }
    final r = await drawer.open();
    if (r.opened) {
      return const NoSaleResult(
        NoSaleOutcome.opened,
        'Cash drawer opened. Recorded as a no-sale.',
      );
    }
    return NoSaleResult(
      NoSaleOutcome.recordedNotOpened,
      'The no-sale was recorded, but the drawer did not open. '
      '${r.message ?? CashDrawerService.failedMessage}',
    );
  }
}
