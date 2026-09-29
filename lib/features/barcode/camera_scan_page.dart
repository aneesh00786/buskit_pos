import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/pos_tokens.dart';

/// Full-screen camera view. The first code detected closes it and is returned
/// to the caller, which does the product lookup.
class CameraScanPage extends StatefulWidget {
  const CameraScanPage({super.key});

  @override
  State<CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<CameraScanPage> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && v.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  String _errorText(MobileScannerException e) {
    switch (e.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        return 'Camera access is turned off. Allow the camera for this app in '
            'Settings, then try again.';
      case MobileScannerErrorCode.unsupported:
        return 'This device cannot scan barcodes with its camera.';
      default:
        return 'The camera could not be started.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan barcode'),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(PosTokens.s24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.videocam_off_outlined, size: 48),
                      const SizedBox(height: PosTokens.s12),
                      Text(_errorText(error), textAlign: TextAlign.center),
                      const SizedBox(height: PosTokens.s16),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.all(PosTokens.s12),
                child: const Text(
                  'Point the camera at the barcode',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
