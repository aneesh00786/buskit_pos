import 'dart:typed_data';

import '../data/escpos_encoder.dart';

/// Phase 11A — what an ESC/POS printer can do beyond the basics. Not every
/// ESC/POS printer has a cutter, a drawer kick-out port or double-size text,
/// so these are opt-in per printer (an adapter fills them in later); the
/// renderer never emits a command the printer did not declare.
class EscPosCapabilities {
  const EscPosCapabilities({
    this.cutter = true,
    this.cashDrawer = false,
    this.doubleSize = true,
  });

  /// `GS V` paper cut.
  final bool cutter;

  /// `ESC p` drawer kick pulse (Phase 11D uses it; never sent automatically).
  final bool cashDrawer;

  /// `GS !` character size (used only for the title).
  final bool doubleSize;

  /// The commands every ESC/POS printer understands (no optional extras).
  static const basic = EscPosCapabilities(
    cutter: false,
    cashDrawer: false,
    doubleSize: false,
  );
}

enum EscPosAlign { left, center, right }

/// Phase 11A — printer-neutral ESC/POS TEXT-mode command builder. Only the
/// common receipt commands: initialise, text, alignment, bold, (optional)
/// size, line feed, separator, (optional) cut and the (optional) cash-drawer
/// pulse definition. Text is reduced to printable ASCII, which every printer
/// code page shares (no code-page switching). Connection-agnostic: it only
/// builds bytes.
///
/// The existing raster path ([EscPosEncoder], used by the LAN printer) is
/// unchanged; init / feed / cut bytes are shared with it.
class EscPosCommands {
  EscPosCommands();

  static const int esc = EscPosEncoder.esc;
  static const int gs = EscPosEncoder.gs;
  static const int lf = 0x0A;
  static const _encoder = EscPosEncoder();

  final BytesBuilder _out = BytesBuilder(copy: false);
  final List<String> _log = [];

  /// The commands issued, in order (for tests / diagnostics; no text).
  List<String> get log => List.unmodifiable(_log);

  /// `ESC @` — reset the printer to its defaults.
  EscPosCommands initialize() {
    _log.add('initialize');
    _out.add(_encoder.initialize());
    return this;
  }

  /// `ESC a n`.
  EscPosCommands align(EscPosAlign a) {
    _log.add('align:${a.name}');
    _out.add([esc, 0x61, a.index]);
    return this;
  }

  /// `ESC E n`.
  EscPosCommands bold(bool on) {
    _log.add('bold:$on');
    _out.add([esc, 0x45, on ? 1 : 0]);
    return this;
  }

  /// `GS ! n` — width/height multipliers 1–2 (only when the printer declares
  /// [EscPosCapabilities.doubleSize]; the caller checks).
  EscPosCommands size({int width = 1, int height = 1}) {
    final w = width.clamp(1, 2) - 1;
    final h = height.clamp(1, 2) - 1;
    _log.add('size:${w + 1}x${h + 1}');
    _out.add([gs, 0x21, (w << 4) | h]);
    return this;
  }

  /// Printable-ASCII text (no line feed).
  EscPosCommands text(String s) {
    _out.add(asciiBytes(s));
    return this;
  }

  /// Text followed by a line feed.
  EscPosCommands line(String s) => text(s).feedLine();

  /// `LF`.
  EscPosCommands feedLine() {
    _out.addByte(lf);
    return this;
  }

  /// `ESC d n` — feed [lines] lines.
  EscPosCommands feed(int lines) {
    _log.add('feed:$lines');
    _out.add(_encoder.feed(lines));
    return this;
  }

  /// A full-width rule of [columns] characters.
  EscPosCommands separator(int columns, {String char = '-'}) {
    _log.add('separator');
    return line(char * columns);
  }

  /// `GS V 66 0` — partial cut (same bytes as the raster path).
  EscPosCommands cut() {
    _log.add('cut');
    _out.add(_encoder.cut());
    return this;
  }

  /// `ESC p m t1 t2` — drawer kick pulse on connector pin 2 (m = 0) or 5
  /// (m = 1), on-time t1 × 2 ms, off-time t2 × 2 ms. DEFINED ONLY in Phase
  /// 11A: nothing sends it unless explicitly asked, and no hardware is used.
  EscPosCommands openCashDrawer({
    int pin = 0,
    int onMs = 100,
    int offMs = 100,
  }) {
    _log.add('drawer:$pin');
    _out.add(drawerPulse(pin: pin, onMs: onMs, offMs: offMs));
    return this;
  }

  static Uint8List drawerPulse({
    int pin = 0,
    int onMs = 100,
    int offMs = 100,
  }) => Uint8List.fromList([
    esc,
    0x70,
    pin == 1 ? 1 : 0,
    (onMs ~/ 2).clamp(0, 255),
    (offMs ~/ 2).clamp(0, 255),
  ]);

  Uint8List bytes() => _out.toBytes();

  /// Printable ASCII only (shared by every ESC/POS code page): common
  /// typographic characters are mapped, anything else becomes `?`.
  static Uint8List asciiBytes(String s) {
    final t = s
        .replaceAll('×', 'x')
        .replaceAll('·', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('₹', 'Rs');
    return Uint8List.fromList([
      for (final c in t.runes) (c >= 0x20 && c <= 0x7E) ? c : 0x3F,
    ]);
  }
}
