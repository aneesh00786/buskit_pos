/// Phase 14C-B2 — the notes and coins offered on the Shift Close cash count.
/// A small UI-level default per currency (values in exact thousandths); it is
/// NOT a currency master: the server validates every count against the
/// shift's store currency, and any positive value is accepted there.
const Map<String, List<int>> defaultCashDenominationsMilli = {
  // Notes 100 / 50 / 20 / 10 / 5; coins 2 / 1 / 0.50 / 0.20 / 0.10 / 0.05.
  'AUD': [100000, 50000, 20000, 10000, 5000, 2000, 1000, 500, 200, 100, 50],
  // Notes 500 / 200 / 100 / 50 / 20 / 10; coins 5 / 2 / 1.
  'INR': [500000, 200000, 100000, 50000, 20000, 10000, 5000, 2000, 1000],
};

/// The device does not know the store currency before the close (the
/// server applies it), so the default is the backend's default store
/// currency (AUD).
const defaultCashCurrency = 'AUD';

List<int> cashDenominationsFor(String? currency) =>
    defaultCashDenominationsMilli[currency?.toUpperCase()] ??
    defaultCashDenominationsMilli[defaultCashCurrency]!;

/// Exact decimal text for a milli amount ("0.050", "100.000") — sent to
/// the server instead of a floating-point number.
String milliToDecimalText(int milli) =>
    '${milli ~/ 1000}.${(milli % 1000).toString().padLeft(3, '0')}';
