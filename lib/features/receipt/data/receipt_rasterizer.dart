import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'escpos_encoder.dart';

/// Draws receipt text lines in a monospace face onto a white canvas and
/// thresholds it to a [MonoBitmap] for a thermal printer.
class ReceiptRasterizer {
  const ReceiptRasterizer();

  /// Dots per line width for common paper: 58 mm ≈ 384, 80 mm ≈ 576.
  static const int width58mm = 384;
  static const int width80mm = 576;

  /// Text columns that fit [widthDots] with the chosen font size.
  static int columnsFor(int widthDots, {double fontSize = 20}) =>
      (widthDots / (fontSize * 0.6)).floor();

  Future<MonoBitmap> render(
    List<String> lines, {
    int widthDots = width80mm,
    double fontSize = 20,
  }) async {
    final w = (widthDots ~/ 8) * 8;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const [
        'Courier',
        'Courier New',
        'Menlo',
        'Roboto Mono',
      ],
      fontSize: fontSize,
      color: const ui.Color(0xFF000000),
      height: 1.15,
    );
    final painters = [
      for (final l in lines)
        TextPainter(
          text: TextSpan(text: l.isEmpty ? ' ' : l, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: w.toDouble()),
    ];
    final lineHeight = painters.isEmpty
        ? fontSize
        : painters.map((p) => p.height).reduce((a, b) => a > b ? a : b);
    final h = ((painters.length * lineHeight) + 8).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    var y = 4.0;
    for (final p in painters) {
      p.paint(canvas, ui.Offset(0, y));
      y += lineHeight;
    }
    final image = await recorder.endRecording().toImage(w, h);
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
    return thresholdRgba(rgba.buffer.asUint8List(), w, h);
  }

  /// RGBA pixels -> 1-bit bitmap (dark pixels become black dots).
  static MonoBitmap thresholdRgba(
    Uint8List rgba,
    int width,
    int height, {
    int threshold = 140,
  }) {
    final bytesPerRow = width ~/ 8;
    final out = Uint8List(bytesPerRow * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final a = rgba[i + 3];
        // Composite over white, then luminance.
        final r = (rgba[i] * a + 255 * (255 - a)) ~/ 255;
        final g = (rgba[i + 1] * a + 255 * (255 - a)) ~/ 255;
        final b = (rgba[i + 2] * a + 255 * (255 - a)) ~/ 255;
        final lum = (r * 299 + g * 587 + b * 114) ~/ 1000;
        if (lum < threshold) out[y * bytesPerRow + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
    return MonoBitmap(width: width, height: height, data: out);
  }
}
