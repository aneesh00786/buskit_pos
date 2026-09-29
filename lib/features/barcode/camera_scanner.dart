import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'camera_scan_page.dart';

/// Opens the device camera and returns the first barcode it reads, or null if
/// the cashier closed it. Behind an interface so tests need no camera.
abstract class CameraScanner {
  /// False where there is no camera scanning (desktop, web).
  bool get supported;
  Future<String?> scan(BuildContext context);
}

class MobileCameraScanner implements CameraScanner {
  const MobileCameraScanner();

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<String?> scan(BuildContext context) => Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => const CameraScanPage()));
}
