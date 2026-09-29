import 'dart:typed_data';

/// A 1-bit-per-pixel image (1 = black), rows packed MSB-first, [width] a
/// multiple of 8.
class MonoBitmap {
  MonoBitmap({required this.width, required this.height, required this.data})
    : assert(width % 8 == 0),
      assert(data.length == (width ~/ 8) * height);

  final int width;
  final int height;
  final Uint8List data;

  int get bytesPerRow => width ~/ 8;

  bool pixel(int x, int y) =>
      (data[y * bytesPerRow + (x >> 3)] & (0x80 >> (x & 7))) != 0;

  /// Rows [from, from+count) as their own bitmap.
  MonoBitmap band(int from, int count) => MonoBitmap(
    width: width,
    height: count,
    data: Uint8List.sublistView(
      data,
      from * bytesPerRow,
      (from + count) * bytesPerRow,
    ),
  );
}

/// Minimal ESC/POS command builder: initialise, print a raster bitmap, feed and
/// cut. Raster (`GS v 0`) is used so any text/currency renders identically on
/// every printer regardless of its code pages.
class EscPosEncoder {
  const EscPosEncoder();

  static const int esc = 0x1B;
  static const int gs = 0x1D;

  /// Bitmaps are sent in bands of this many rows, which is within what common
  /// thermal printers accept for one `GS v 0` command.
  static const int maxBandRows = 128;

  Uint8List initialize() => Uint8List.fromList([esc, 0x40]);

  Uint8List feed(int lines) =>
      Uint8List.fromList([esc, 0x64, lines.clamp(0, 255)]);

  /// Partial cut (`GS V 66 0`).
  Uint8List cut() => Uint8List.fromList([gs, 0x56, 0x42, 0x00]);

  /// `GS v 0 m xL xH yL yH d…` for one band (normal density, m = 0).
  Uint8List rasterBand(MonoBitmap band) {
    final xBytes = band.bytesPerRow;
    return Uint8List.fromList([
      gs,
      0x76,
      0x30,
      0x00,
      xBytes & 0xFF,
      (xBytes >> 8) & 0xFF,
      band.height & 0xFF,
      (band.height >> 8) & 0xFF,
      ...band.data,
    ]);
  }

  /// The whole job: init, the bitmap in bands, feed, optional cut.
  Uint8List receiptJob(
    MonoBitmap bitmap, {
    int feedLines = 4,
    bool cutPaper = true,
  }) {
    final out = BytesBuilder(copy: false)..add(initialize());
    for (var y = 0; y < bitmap.height; y += maxBandRows) {
      final rows = (bitmap.height - y) < maxBandRows
          ? bitmap.height - y
          : maxBandRows;
      out.add(rasterBand(bitmap.band(y, rows)));
    }
    out.add(feed(feedLines));
    if (cutPaper) out.add(cut());
    return out.toBytes();
  }
}
