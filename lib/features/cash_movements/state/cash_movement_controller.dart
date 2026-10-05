import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/uuid.dart';
import '../data/cash_movement_service.dart';
import '../models/cash_movement.dart';

enum CashMovementListStatus { idle, loading, loaded, error }

enum WithdrawStatus { idle, withdrawing }

enum DepositStatus { idle, depositing }

/// One idempotency-key attempt slot. Same "same attempt keeps its key across
/// a retry" rule as CartController.completeSale/SalesHistoryController.
/// refundSale — a movement's amount/reason CAN vary between attempts (unlike
/// a refund), so the fingerprint is the amount+reason pair, not a fixed id.
/// Retrying with the SAME amount+reason (e.g. after a timeout) reuses the
/// key; changing either always gets a fresh one.
class _Attempt {
  String? fingerprint;
  String? key;

  String keyFor(String amount, String? reason) {
    final fp = '$amount|${reason ?? ''}';
    if (fingerprint != fp) {
      fingerprint = fp;
      key = generateUuidV4();
    }
    return key!;
  }

  /// A successful request closes the attempt — a later movement with the
  /// same amount/reason is a NEW request and must get its own key.
  void close() {
    fingerprint = null;
    key = null;
  }
}

/// Current-shift cash movements: the list (`GET /shifts/current/cash-movements`,
/// both types) plus the withdraw (`POST /shifts/cash-withdrawal`) and deposit
/// (`POST /shifts/cash-deposit`) actions. Each type keeps its OWN attempt
/// slot, so a deposit in between never discards a pending withdrawal retry's
/// key (and vice versa). Only one movement is ever in flight at a time.
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
  final _withdrawAttempt = _Attempt();

  DepositStatus _depositStatus = DepositStatus.idle;
  ApiException? _depositError;
  CashMovement? _lastDeposit;
  final _depositAttempt = _Attempt();

  CashMovementListStatus get status => _status;
  CurrentShiftSummary? get shift => _shift;
  List<CashMovement> get movements => _movements;
  ApiException? get error => _error;

  bool get isWithdrawing => _withdrawStatus == WithdrawStatus.withdrawing;
  ApiException? get withdrawError => _withdrawError;
  CashMovement? get lastWithdrawal => _lastWithdrawal;

  bool get isDepositing => _depositStatus == DepositStatus.depositing;
  ApiException? get depositError => _depositError;
  CashMovement? get lastDeposit => _lastDeposit;

  /// True while either movement type is in flight.
  bool get isBusy => isWithdrawing || isDepositing;

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

  /// Re-reads the list from the backend after a successful movement without
  /// flipping to the loading state. A failure here is ignored — the
  /// locally-prepended movement stays visible and a manual retry/re-open
  /// will catch up.
  Future<void> _refreshQuietly() async {
    try {
      final result = await _service.listCurrentShift();
      _shift = result.shift;
      _movements = result.movements;
      _notify();
    } on ApiException {
      // keep the optimistic list
    }
  }

  /// Returns true on success. The created movement is available via
  /// [lastWithdrawal], is prepended to [movements] immediately, and the list
  /// is then re-read from the backend.
  Future<bool> withdraw({required String amount, String? reason}) async {
    if (isBusy) return false;
    final key = _withdrawAttempt.keyFor(amount, reason);

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
      if (result != null) _movements = [result, ..._movements];
      _withdrawAttempt.close();
      _notify();
      await _refreshQuietly();
      return true;
    } on ApiException catch (e) {
      _withdrawStatus = WithdrawStatus.idle;
      _withdrawError = e;
      _notify();
      return false;
    }
  }

  /// Cash In — same contract as [withdraw], against the deposit endpoint and
  /// its own attempt slot.
  Future<bool> deposit({required String amount, String? reason}) async {
    if (isBusy) return false;
    final key = _depositAttempt.keyFor(amount, reason);

    _depositStatus = DepositStatus.depositing;
    _depositError = null;
    _notify();
    try {
      final result = await _service.deposit(
        amount: amount,
        reason: reason,
        idempotencyKey: key,
      );
      _depositStatus = DepositStatus.idle;
      _lastDeposit = result;
      if (result != null) _movements = [result, ..._movements];
      _depositAttempt.close();
      _notify();
      await _refreshQuietly();
      return true;
    } on ApiException catch (e) {
      _depositStatus = DepositStatus.idle;
      _depositError = e;
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

  void clearDepositError() {
    if (_depositError == null) return;
    _depositError = null;
    _notify();
  }

  void clearLastDeposit() {
    _lastDeposit = null;
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
