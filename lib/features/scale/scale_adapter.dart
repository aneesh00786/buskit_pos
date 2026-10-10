/// Phase 18A — the contract every weighing-scale driver implements.
///
/// Hardware-neutral: no transport (USB, Bluetooth, serial, network) and no
/// vendor protocol is assumed. A real driver is added as another
/// implementation once the scale model and its protocol are known; nothing
/// outside lib/features/scale depends on how a scale talks.
library;

import 'dart:async';

import 'scale_reading.dart';

enum ScaleConnectionState { disconnected, connecting, connected, error }

/// What a scale can do besides weighing. Zero / tare are offered only when
/// the driver says the device supports them.
class ScaleCapabilities {
  const ScaleCapabilities({this.canZero = false, this.canTare = false});
  final bool canZero;
  final bool canTare;
}

/// A scale problem with a cashier-safe message (never a raw device error).
class ScaleException implements Exception {
  const ScaleException(this.code, this.message);

  /// timeout | not_connected | unsupported | connection_failed | device_error
  final String code;
  final String message;

  @override
  String toString() => 'ScaleException($code): $message';
}

abstract class ScaleAdapter {
  /// Shown to the cashier, e.g. "Simulated scale".
  String get name;

  /// True for the mock / simulator: its readings are NOT from a real scale
  /// and are always labelled as simulated.
  bool get isSimulated;

  ScaleCapabilities get capabilities;

  ScaleConnectionState get connectionState;

  /// Connection changes (also reflected by [connectionState]).
  Stream<ScaleConnectionState> get connectionChanges;

  /// Every reading the scale reports, stable or not.
  Stream<ScaleReading> get readings;

  /// Opens the connection. Throws [ScaleException] on failure.
  Future<void> connect();

  /// Closes the connection; safe to call when already disconnected.
  Future<void> disconnect();

  /// Zero the scale. Throws [ScaleException] ('unsupported') when
  /// [capabilities] says it cannot.
  Future<void> zero();

  /// Tare the scale. Throws [ScaleException] ('unsupported') when
  /// [capabilities] says it cannot.
  Future<void> tare();

  /// Releases everything; the adapter is not used afterwards.
  Future<void> dispose();
}
