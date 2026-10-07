import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Phase 14F-C — hands an exported file to the platform's own share / save
/// sheet (Files, Drive, email, …). The app keeps nothing and sends nothing.
abstract class ReportFileSharer {
  /// Throws when the file could not be handed over. A sheet the user
  /// dismisses is not an error.
  Future<void> share({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  });
}

class PlatformReportFileSharer implements ReportFileSharer {
  const PlatformReportFileSharer();

  @override
  Future<void> share({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  }) async {
    // A real file with the chosen name (the share sheet shows that name).
    final dir = Directory('${(await getTemporaryDirectory()).path}/reports');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType, name: filename)],
        subject: filename,
        // Required on iPad: where the share popover points.
        sharePositionOrigin: origin,
      ),
    );
    if (result.status == ShareResultStatus.unavailable) {
      throw const ReportShareUnavailable();
    }
  }
}

class ReportShareUnavailable implements Exception {
  const ReportShareUnavailable();
  @override
  String toString() => 'Sharing is not available on this device.';
}
