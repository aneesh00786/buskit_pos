import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/utils/money.dart';
import '../data/shift_close_service.dart';
import '../models/cash_denominations.dart';
import '../models/shift_summary.dart';

enum ShiftCloseStatus { loading, ready, noOpenShift, error, closing, closed }

/// Shift Close: loads the server's summary for the shift open on this
/// register, takes the counted cash, and closes the shift once. Every
/// financial figure comes from the server; the only client-side arithmetic
/// is the variance PREVIEW while typing (counted - server expected). The
/// final variance shown after closing is the server's.
class ShiftCloseController extends ChangeNotifier {
  ShiftCloseController(this._service, {List<int>? denominationsMilli})
    : denominationsMilli = List.unmodifiable(
        denominationsMilli ?? cashDenominationsFor(null),
      );

  final ShiftCloseService _service;

  /// Phase 14C-B2: the notes / coins offered for the cash count (thousandths).
  final List<int> denominationsMilli;
  final Map<int, String> _quantityText = {};

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

  // ---- Phase 14C-B2: cash count by denomination ----

  static final _wholeNumber = RegExp(r'^\d{1,6}$');

  String quantityText(int valueMilli) => _quantityText[valueMilli] ?? '';

  /// The entered quantity: empty = 0; null when it is not a whole number
  /// (negative, fractional or not a number).
  int? quantityOf(int valueMilli) {
    final t = quantityText(valueMilli).trim();
    if (t.isEmpty) return 0;
    return _wholeNumber.hasMatch(t) ? int.parse(t) : null;
  }

  bool quantityIsValid(int valueMilli) => quantityOf(valueMilli) != null;

  bool get denominationsValid =>
      denominationsMilli.every((v) => quantityOf(v) != null);

  /// value x quantity, in exact thousandths (0 while invalid).
  int lineTotalMilli(int valueMilli) =>
      valueMilli * (quantityOf(valueMilli) ?? 0);

  int get denominationTotalMilli =>
      denominationsMilli.fold(0, (sum, v) => sum + lineTotalMilli(v));

  /// The cash is being counted by notes / coins (any quantity entered).
  bool get countingByDenomination => denominationsMilli.any(
    (v) => quantityText(v).trim().isNotEmpty && quantityOf(v) != 0,
  );

  /// The non-zero entries sent with the close.
  List<DenominationCount> get denominationCounts => [
    for (final v in denominationsMilli)
      if ((quantityOf(v) ?? 0) > 0)
        DenominationCount(valueMilli: v, quantity: quantityOf(v)!),
  ];

  void setQuantity(int valueMilli, String text) {
    _quantityText[valueMilli] = text;
    _closeError = null;
    _notify();
  }

  /// Counted cash in milli, or null while the input is empty/invalid. With a
  /// denomination count it is that count's exact total (the server computes
  /// and stores the authoritative figure).
  int? get countedMilli {
    if (countingByDenomination) {
      return denominationsValid ? denominationTotalMilli : null;
    }
    return parseMilli(_countedText);
  }

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
        denominations: countingByDenomination ? denominationCounts : null,
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
