/// Recognises a hardware (HID "keyboard wedge") barcode scanner among ordinary
/// typing: scanners send the code as a rapid burst of characters followed by
/// Enter, far faster than a person types.
///
/// Pure logic — no Flutter types — so timing rules are easy to test.
class BarcodeKeyBuffer {
  BarcodeKeyBuffer({
    this.maxGap = const Duration(milliseconds: 80),
    this.minLength = 4,
    this.maxLength = 50,
  });

  /// Longest pause between two characters that still counts as scanner speed.
  final Duration maxGap;

  /// Shorter bursts are treated as typing (or noise), not a barcode.
  final int minLength;

  /// The backend accepts 1–50 characters.
  final int maxLength;

  final StringBuffer _chars = StringBuffer();
  DateTime? _last;

  bool get isEmpty => _chars.isEmpty;

  void clear() {
    _chars.clear();
    _last = null;
  }

  /// Feeds one printable character. A pause longer than [maxGap] means the
  /// earlier characters were not part of a burst, so they are dropped.
  void addChar(String char, DateTime now) {
    if (_last != null && now.difference(_last!) > maxGap) _chars.clear();
    _chars.write(char);
    _last = now;
  }

  /// Enter pressed: returns the scanned code if the buffered characters arrived
  /// as one fast burst, otherwise null. Always resets.
  String? complete(DateTime now) {
    final fast = _last != null && now.difference(_last!) <= maxGap;
    final code = _chars.toString();
    clear();
    if (!fast || code.length < minLength || code.length > maxLength) {
      return null;
    }
    return code;
  }
}
