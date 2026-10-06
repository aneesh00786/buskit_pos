import 'dart:async';

import '../../core/network/pos_api_client.dart';
import '../auth/state/session_controller.dart';
import '../customers/data/customer_service.dart';
import '../products/data/product_service.dart';
import 'offline_services.dart';

/// Keeps this device ready for offline checkout during a signed-in session
/// and sends queued offline sales, using only foreground, app-lifecycle
/// triggers (no background service):
///  * on start (server reachable or unknown): records the shift this session
///    opened, syncs queued sales, then refreshes the catalogue/stock and the
///    customer cache;
///  * when the connection comes back (reachable false -> true): syncs queued
///    sales, then refreshes the catalogue and stock;
///  * when a retry is due (bounded back-off reported by the sync run): one
///    timer for the earliest due retry;
///  * on request ([syncAndRefresh] — the "Sync now" button, or a sale saved
///    locally while the server is reachable).
/// Syncing first means the refreshed stock already includes synced sales.
class OfflineSessionSync {
  OfflineSessionSync({
    required this.offline,
    required this.client,
    required this.session,
    required this.products,
    CustomerService? customers,
  }) : customers = customers ?? ApiCustomerService(client);

  final OfflineServices offline;
  final PosApiClient client;
  final SessionController session;
  final ProductService products;
  final CustomerService customers;

  bool? _last;
  bool _disposed = false;
  Timer? _retryTimer;

  void start() {
    _last = client.reachable.value;
    client.reachable.addListener(_onReachability);
    final scope = session.tokenScope;
    final opened = session.openedShiftId;
    if (scope != null && opened != null) {
      offline.cache.recordShift(
        scope: scope,
        shiftId: opened,
        openedAt: session.openedShiftAt,
      );
    }
    if (client.reachable.value != false) {
      syncAndRefresh(customersToo: true);
    }
  }

  /// Sends queued sales (sharing a run already in progress), then refreshes
  /// the caches. Best-effort: failures keep everything as it was.
  Future<void> syncAndRefresh({
    bool customersToo = false,
    bool force = false,
  }) async {
    if (_disposed || client.reachable.value == false) return;
    final sync = offline.sync;
    if (sync != null) {
      try {
        final report = await sync.syncNow(force: force);
        _scheduleRetry(report.nextRetryAt);
      } catch (_) {}
    }
    await refresh(customersToo: customersToo);
  }

  /// Best-effort refresh of the caches; failures keep the previous cache.
  Future<void> refresh({bool customersToo = false}) async {
    final scope = session.tokenScope;
    if (_disposed || scope == null || client.reachable.value == false) return;
    await offline.cache.refreshCatalogue(products, scope);
    if (customersToo && !_disposed) {
      await offline.cache.refreshCustomers(customers);
    }
  }

  void _scheduleRetry(DateTime? at) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (at == null || _disposed) return;
    var delay = at.difference(DateTime.now());
    if (delay.isNegative) delay = Duration.zero;
    _retryTimer = Timer(delay, () => syncAndRefresh());
  }

  void _onReachability() {
    final now = client.reachable.value;
    final wasOffline = _last == false;
    _last = now;
    if (wasOffline && now == true) syncAndRefresh();
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    client.reachable.removeListener(_onReachability);
  }
}
