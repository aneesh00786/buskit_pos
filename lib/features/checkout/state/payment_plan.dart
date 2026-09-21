import '../models/payment.dart';

enum PayMode { cash, card, other, split }

/// Turns what the cashier typed into the `payments[]` the backend expects, and
/// previews change/shortfall. Pure and integer-only (milli-units).
///
/// The sale total is the SERVER's figure; the change shown here is a preview —
/// the recorded change comes back from the server. The backend requires the
/// payments to sum to its total exactly, so this never produces a partial
/// payment: a "split" is cash for part and Card/Other for the remainder.
class PaymentPlan {
  const PaymentPlan({
    required this.totalMilli,
    required this.mode,
    this.cashReceivedMilli,
    this.cashAppliedMilli,
    this.secondary = TenderMethod.card,
    this.reference,
  });

  final int totalMilli;
  final PayMode mode;

  /// Cash handed over (cash mode; split mode's cash line). Null = not entered.
  final int? cashReceivedMilli;

  /// Split only: the part of the sale paid in cash.
  final int? cashAppliedMilli;

  /// Split only: the method that pays the remainder (never cash).
  final TenderMethod secondary;
  final String? reference;

  static const maxReferenceLength = 255;

  bool get _refTooLong => (reference?.trim().length ?? 0) > maxReferenceLength;

  /// The cash actually applied to the sale.
  int? get _cashApplied => switch (mode) {
    PayMode.cash => totalMilli,
    PayMode.split => cashAppliedMilli,
    _ => null,
  };

  /// Split only: what is left for the secondary method.
  int get remainderMilli =>
      mode == PayMode.split ? totalMilli - (cashAppliedMilli ?? 0) : 0;

  /// Cash received minus the cash applied (>= 0 when valid).
  int get changeDueMilli {
    final applied = _cashApplied;
    final received =
        cashReceivedMilli ?? (mode == PayMode.split ? applied : null);
    if (applied == null || received == null) return 0;
    final d = received - applied;
    return d > 0 ? d : 0;
  }

  /// How far the cash received is from covering the cash applied.
  int get shortByMilli {
    final applied = _cashApplied;
    if (applied == null) return 0;
    final received =
        cashReceivedMilli ?? (mode == PayMode.split ? applied : null);
    if (received == null) return applied;
    final d = applied - received;
    return d > 0 ? d : 0;
  }

  /// First reason the plan cannot be submitted, or null when it can.
  String? get problem {
    if (totalMilli <= 0) return 'There is nothing to pay.';
    if (_refTooLong) {
      return 'Reference must be at most $maxReferenceLength characters.';
    }
    switch (mode) {
      case PayMode.cash:
        if (cashReceivedMilli == null) return 'Enter the amount tendered.';
        if (cashReceivedMilli! < totalMilli) {
          return 'Amount tendered is less than the total.';
        }
        return null;
      case PayMode.card:
      case PayMode.other:
        return null;
      case PayMode.split:
        final a = cashAppliedMilli;
        if (a == null) return 'Enter the cash amount.';
        if (a <= 0) return 'The cash amount must be more than zero.';
        if (a >= totalMilli) {
          return 'For a split, the cash amount must be less than the total.';
        }
        final r = cashReceivedMilli ?? a;
        if (r < a) return 'Cash received is less than the cash amount.';
        return null;
    }
  }

  bool get isValid => problem == null;

  /// The request lines (empty when invalid).
  List<PaymentLine> get payments {
    if (!isValid) return const [];
    final ref = (reference == null || reference!.trim().isEmpty)
        ? null
        : reference!.trim();
    switch (mode) {
      case PayMode.cash:
        return [
          PaymentLine(
            method: TenderMethod.cash,
            amountMilli: totalMilli,
            tenderedMilli: cashReceivedMilli,
          ),
        ];
      case PayMode.card:
        return [
          PaymentLine(
            method: TenderMethod.card,
            amountMilli: totalMilli,
            reference: ref,
          ),
        ];
      case PayMode.other:
        return [
          PaymentLine(
            method: TenderMethod.other,
            amountMilli: totalMilli,
            reference: ref,
          ),
        ];
      case PayMode.split:
        final a = cashAppliedMilli!;
        return [
          PaymentLine(
            method: TenderMethod.cash,
            amountMilli: a,
            tenderedMilli: cashReceivedMilli ?? a,
          ),
          PaymentLine(
            method: secondary,
            amountMilli: totalMilli - a,
            reference: ref,
          ),
        ];
    }
  }

  /// Quick-cash denominations worth offering: those that cover [dueMilli].
  static List<int> quickCash(
    int dueMilli, {
    List<int> denominations = const [10, 20, 50, 100],
  }) => [
    for (final d in denominations)
      if (d * 1000 >= dueMilli) d * 1000,
  ];
}
