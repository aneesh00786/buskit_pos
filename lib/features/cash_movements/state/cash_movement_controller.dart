import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/uuid.dart';
import '../data/cash_movement_service.dart';
import '../models/cash_movement.dart';

enum CashMovementListStatus { idle, loading, loaded, error }

enum WithdrawStatus { idle, withdrawing }

/// Current-shift cash withdrawals: the list (`GET /shifts/current/cash-movements`)
/// plus the withdraw action (`POST /shifts/cash-withdrawal`). Mirrors
/// SalesHistoryController.refundSale's idempotency-key-per-attempt rule.
class CashMovementController extends ChangeNotifier {
  CashMovementController(this._service);

  final CashMovementService _service;

  CashMovementListStatus _status = CashMovementListStatus.idle;
  CurrentShiftSummary? _shift;
  List<CashMovement> _movements = const [];
  ApiException? _error;
  bool _disposed = false;

  WithdrawStatus _withdrawStatus = WithdrawStatus.idle;
  ApiException? _withdrawError;
  CashMovement? _lastWithdrawal;
  // Same "same attempt keeps its key across a retry" rule as
  // CartController.completeSale/SalesHistoryController.refundSale — a
  // withdrawal's amount/reason CAN vary between attempts (unlike a refund),
  // so the fingerprint is the amount+reason pair, not a fixed id. Retrying
  // with the SAME amount+reason (e.g. after a timeout) reuses the key;
  // changing either always gets a fresh one.
  String? _withdrawAttemptFingerprint;
  String? _withdrawAttemptKey;

  CashMovementListStatus get status => _status;
  CurrentShiftSummary? get shift => _shift;
  List<CashMovement> get movements => _movements;
  ApiException? get error => _error;

  bool get isWithdrawing => _withdrawStatus == WithdrawStatus.withdrawing;
  ApiException? get withdrawError => _withdrawError;
  CashMovement? get lastWithdrawal => _lastWithdrawal;

  Future<void> load() async {
    _status = CashMovementListStatus.loading;
    _error = null;
    _notify();
    try {
      final result = await _service.listCurrentShift();
      _shift = result.shift;
      _movements = result.movements;
      _status = CashMovementListStatus.loaded;
    } on ApiException catch (e) {
      _error = e;
      _status = CashMovementListStatus.error;
    }
    _notify();
  }

  Future<void> retry() => load();

  /// Returns true on success. The created movement is available via
  /// [lastWithdrawal] and is prepended to [movements] so the list reflects
  /// it immediately without a full reload.
  Future<bool> withdraw({required String amount, String? reason}) async {
    if (_withdrawStatus == WithdrawStatus.withdrawing) return false;
    final fingerprint = '$amount|${reason ?? ''}';
    if (_withdrawAttemptFingerprint != fingerprint) {
      _withdrawAttemptFingerprint = fingerprint;
      _withdrawAttemptKey = generateUuidV4();
    }
    final key = _withdrawAttemptKey!;

    _withdrawStatus = WithdrawStatus.withdrawing;
    _withdrawError = null;
    _notify();
    try {
      final result = await _service.withdraw(
        amount: amount,
        reason: reason,
        idempotencyKey: key,
      );
      _withdrawStatus = WithdrawStatus.idle;
      _lastWithdrawal = result;
      if (result != null) {
        _movements = [result, ..._movements];
      }
      // A successful withdrawal closes this attempt — a later withdrawal
      // with the same amount/reason is a NEW request and must get its own key.
      _withdrawAttemptFingerprint = null;
      _withdrawAttemptKey = null;
      _notify();
      return true;
    } on ApiException catch (e) {
      _withdrawStatus = WithdrawStatus.idle;
      _withdrawError = e;
      _notify();
      return false;
    }
  }

  void clearWithdrawError() {
    if (_withdrawError == null) return;
    _withdrawError = null;
    _notify();
  }

  void clearLastWithdrawal() {
    _lastWithdrawal = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
