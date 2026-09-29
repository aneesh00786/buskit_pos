import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'barcode_key_buffer.dart';

/// Listens to raw key events for the whole app shell and reports a barcode when
/// a scanner-speed burst of characters ends with Enter. It never consumes the
/// keys, so text fields keep working; it is silent while a dialog, sheet or
/// other route covers the shell (so a scan cannot land in a payment form).
class BarcodeKeyListener extends StatefulWidget {
  const BarcodeKeyListener({
    super.key,
    required this.onBarcode,
    required this.child,
    this.now = DateTime.now,
    this.buffer,
  });

  final ValueChanged<String> onBarcode;
  final Widget child;

  /// Injectable clock for tests.
  final DateTime Function() now;
  final BarcodeKeyBuffer? buffer;

  @override
  State<BarcodeKeyListener> createState() => _BarcodeKeyListenerState();
}

class _BarcodeKeyListenerState extends State<BarcodeKeyListener> {
  late final BarcodeKeyBuffer _buffer = widget.buffer ?? BarcodeKeyBuffer();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _buffer.clear();
      return false;
    }
    final key = event.logicalKey;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed) {
      return false;
    }
    final now = widget.now();
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.complete(now);
      if (code != null) widget.onBarcode(code);
      return false;
    }
    final ch = event.character;
    if (ch != null && ch.length == 1 && ch.codeUnitAt(0) >= 0x20) {
      _buffer.addChar(ch, now);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
