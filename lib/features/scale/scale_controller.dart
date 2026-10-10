/// Phase 18A — UI-facing state for one [ScaleAdapter]: connection, latest
/// reading, freshness and a cashier-safe error. It never touches the cart:
/// the weight dialog asks it for the current sale weight and the cashier
/// decides whether to use it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'scale_adapter.dart';
import 'scale_reading.dart';

class ScaleController extends ChangeNotifier {
  ScaleController(
    this.adapter, {
    this.connectTimeout = const Duration(seconds: 5),
    this.staleAfter = const Duration(seconds: 3),
  }) {
    _connSub = adapter.connectionChanges.listen((s) {
      if (s != ScaleConnectionState.connected) _clearReading();
      if (s == ScaleConnectionState.disconnected && _error == null) {
        _error = 'The scale is disconnected.';
      }
      _notify();
    });
    _readSub = adapter.readings.listen(_onReading);
  }

  final ScaleAdapter adapter;

  /// connect() gives up after this long.
  final Duration connectTimeout;

  /// A reading older than this is not offered (no data from the scale).
  final Duration staleAfter;

  late final StreamSubscription<ScaleConnectionState> _connSub;
  late final StreamSubscription<ScaleReading> _readSub;
  Timer? _staleTimer;
  ScaleReading? _reading;
  String? _error;
  bool _disposed = false;

  ScaleConnectionState get connectionState => adapter.connectionState;
  bool get isConnected => connectionState == ScaleConnectionState.connected;
  bool get isSimulated => adapter.isSimulated;
  String get name => adapter.name;
  ScaleCapabilities get capabilities => adapter.capabilities;

  /// The latest reading while it is fresh, else null.
  ScaleReading? get reading => _reading;

  /// The last problem (connection, timeout, zero/tare), cashier-facing.
  String? get error => _error;

  /// The latest reading converted for a WEIGHT line (or why it cannot be used).
  ScaleSaleWeight get saleWeight => isConnected
      ? saleWeightFrom(_reading)
      : const ScaleSaleWeight.refused('The scale is not connected.');

  /// Connects unless already connected. Never throws: failures and timeouts
  /// become [error]; manual weight entry keeps working regardless.
  Future<void> connect() async {
    if (isConnected || connectionState == ScaleConnectionState.connecting) {
      return;
    }
    _error = null;
    _notify();
    try {
      await adapter.connect().timeout(connectTimeout);
    } on TimeoutException {
      _error = 'The scale did not respond. Enter the weight manually.';
      unawaited(_safeDisconnect());
    } on ScaleException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'The scale could not be used. Enter the weight manually.';
    }
    _notify();
  }

  Future<void> disconnect() async {
    await _safeDisconnect();
    _clearReading();
    _notify();
  }

  Future<void> zero() => _command(adapter.capabilities.canZero, adapter.zero);
  Future<void> tare() => _command(adapter.capabilities.canTare, adapter.tare);

  Future<void> _command(bool supported, Future<void> Function() run) async {
    if (!supported) {
      _error = 'This scale does not support that from the POS.';
      _notify();
      return;
    }
    try {
      await run().timeout(connectTimeout);
      _error = null;
    } on TimeoutException {
      _error = 'The scale did not respond.';
    } on ScaleException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'The scale could not do that.';
    }
    _notify();
  }

  Future<void> _safeDisconnect() async {
    try {
      await adapter.disconnect();
    } catch (_) {
      // Already gone; nothing else to do.
    }
  }

  void _onReading(ScaleReading r) {
    if (!isConnected) return;
    _reading = r;
    if (_error != null && _error != 'The scale is disconnected.') {
      // A fresh reading clears transient problems such as a slow response.
      _error = null;
    }
    _staleTimer?.cancel();
    _staleTimer = Timer(staleAfter, () {
      _reading = null;
      _error = 'No reading from the scale. Check the scale or enter the weight manually.';
      _notify();
    });
    _notify();
  }

  void _clearReading() {
    _staleTimer?.cancel();
    _reading = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _staleTimer?.cancel();
    _connSub.cancel();
    _readSub.cancel();
    super.dispose();
  }
}
