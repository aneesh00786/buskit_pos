import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/utils/money.dart';
import '../data/shift_close_service.dart';
import '../models/shift_summary.dart';

enum ShiftCloseStatus { loading, ready, noOpenShift, error, closing, closed }

/// Shift Close: loads the server's summary for the shift open on this
/// register, takes the counted cash, and closes the shift once. Every
/// financial figure comes from the server; the only client-side arithmetic
/// is the variance PREVIEW while typing (counted - server expected). The
/// final variance shown after closing is the server's.
class ShiftCloseController extends ChangeNotifier {
  ShiftCloseController(this._service);

  final ShiftCloseService _service;

  ShiftCloseStatus _status = ShiftCloseStatus.loading;
  ShiftSummary? _summary;
  ShiftSummary? _result;
  ApiException? _error;
  ApiException? _closeError;
  String _countedText = '';
  bool _disposed = false;

  ShiftCloseStatus get status => _status;
  ShiftSummary? get summary => _summary;

  /// The server's final figures after a successful close.
  ShiftSummary? get result => _result;
  ApiException? get error => _error;
  ApiException? get closeError => _closeError;
  String get countedText => _countedText;

  /// Counted cash in milli, or null while the input is empty/invalid.
  int? get countedMilli => parseMilli(_countedText);
  bool get countedIsValid => countedMilli != null;

  /// Preview only: counted - the server's expected cash.
  int? get varianceMilli {
    final counted = countedMilli;
    final s = _summary;
    if (counted == null || s == null) return null;
    return counted - milliFromDouble(s.cash.expected);
  }

  bool get isClosing => _status == ShiftCloseStatus.closing;

  /// Close is offered only for an open shift the server says this staff
  /// member may close, with a valid count, and never twice.
  bool get canSubmit =>
      _status == ShiftCloseStatus.ready &&
      (_summary?.closableByCurrentStaff ?? false) &&
      countedIsValid;

  Future<void> load() async {
    _status = ShiftCloseStatus.loading;
    _error = null;
    _notify();
    try {
      _summary = await _service.currentSummary();
      _status = ShiftCloseStatus.ready;
    } on ApiException catch (e) {
      _summary = null;
      if (e.errorCode == PosErrorCodes.noOpenShift) {
        _status = ShiftCloseStatus.noOpenShift;
      } else {
        _error = e.withMessage(describeApiError(e));
        _status = ShiftCloseStatus.error;
      }
    }
    _notify();
  }

  void setCounted(String text) {
    _countedText = text;
    _closeError = null;
    _notify();
  }

  /// Sends the close exactly once; a second call while closing (or after a
  /// successful close) does nothing.
  Future<bool> close() async {
    final s = _summary;
    final counted = countedMilli;
    if (!canSubmit || s == null || counted == null) return false;
    _status = ShiftCloseStatus.closing;
    _closeError = null;
    _notify();
    try {
      _result = await _service.close(
        shiftId: s.shiftId,
        closingAmount: milliToJson(counted),
      );
      _status = ShiftCloseStatus.closed;
      _notify();
      return true;
    } on ApiException catch (e) {
      _closeError = e.withMessage(describeApiError(e));
      // Already closed elsewhere (409) or no longer this cashier's: the
      // shift is not open for this screen any more — stop offering Close.
      _status = e.kind == ApiErrorKind.conflict
          ? ShiftCloseStatus.error
          : ShiftCloseStatus.ready;
      if (e.kind == ApiErrorKind.conflict) _error = _closeError;
      _notify();
      return false;
    }
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
