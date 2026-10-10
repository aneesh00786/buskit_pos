/// Phase 18A — a SIMULATED scale for development and automated tests. It is
/// not a hardware driver and its readings are never real weights: the
/// adapter reports [isSimulated] and the UI labels it "Simulated scale".
library;

import 'dart:async';

import 'scale_adapter.dart';
import 'scale_reading.dart';

class MockScaleAdapter implements ScaleAdapter {
  MockScaleAdapter({
    this.capabilities = const ScaleCapabilities(canZero: true, canTare: true),
    this.connectDelay = Duration.zero,
    this.failConnect = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  @override
  final ScaleCapabilities capabilities;

  /// How long connect() takes (a long delay simulates a connect timeout).
  final Duration connectDelay;

  /// connect() fails (device not found / refused).
  bool failConnect;

  final DateTime Function() _clock;
  final _readings = StreamController<ScaleReading>.broadcast();
  final _connection = StreamController<ScaleConnectionState>.broadcast();
  ScaleConnectionState _state = ScaleConnectionState.disconnected;
  Timer? _demo;
  bool _disposed = false;

  /// Zero / tare offsets applied to later readings (thousandths of the unit).
  int _offsetMilli = 0;
  int _grossMilli = 0;

  @override
  String get name => 'Simulated scale';

  @override
  bool get isSimulated => true;

  @override
  ScaleConnectionState get connectionState => _state;

  @override
  Stream<ScaleConnectionState> get connectionChanges => _connection.stream;

  @override
  Stream<ScaleReading> get readings => _readings.stream;

  void _set(ScaleConnectionState s) {
    if (_disposed || _state == s) return;
    _state = s;
    _connection.add(s);
  }

  @override
  Future<void> connect() async {
    if (_disposed) {
      throw const ScaleException(
        'not_connected',
        'The scale is not available.',
      );
    }
    if (_state == ScaleConnectionState.connected) return;
    _set(ScaleConnectionState.connecting);
    if (connectDelay > Duration.zero) await Future<void>.delayed(connectDelay);
    if (_disposed) return;
    if (failConnect) {
      _set(ScaleConnectionState.error);
      throw const ScaleException(
        'connection_failed',
        'Could not connect to the scale.',
      );
    }
    _set(ScaleConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _demo?.cancel();
    _demo = null;
    _set(ScaleConnectionState.disconnected);
  }

  void _requireConnected() {
    if (_state != ScaleConnectionState.connected) {
      throw const ScaleException(
        'not_connected',
        'The scale is not connected.',
      );
    }
  }

  @override
  Future<void> zero() async {
    if (!capabilities.canZero) {
      throw const ScaleException(
        'unsupported',
        'This scale cannot be zeroed from the POS.',
      );
    }
    _requireConnected();
    _offsetMilli = _grossMilli;
  }

  @override
  Future<void> tare() async {
    if (!capabilities.canTare) {
      throw const ScaleException(
        'unsupported',
        'This scale cannot be tared from the POS.',
      );
    }
    _requireConnected();
    _offsetMilli = _grossMilli;
  }

  // ---- simulation controls (tests and the developer demo) ----

  /// Reports [valueMilli] thousandths of [unit] (gross, before zero/tare).
  void emitWeight(
    int valueMilli, {
    ScaleUnit unit = ScaleUnit.kilogram,
    bool stable = true,
  }) {
    if (_disposed || _state != ScaleConnectionState.connected) return;
    _grossMilli = valueMilli;
    _readings.add(
      ScaleReading(
        valueMilli: valueMilli - _offsetMilli,
        unit: unit,
        status: stable
            ? ScaleReadingStatus.stable
            : ScaleReadingStatus.unstable,
        at: _clock(),
      ),
    );
  }

  /// Reports a reading with a non-weight [status] (overload, underload, invalid).
  void emitStatus(
    ScaleReadingStatus status, {
    ScaleUnit unit = ScaleUnit.kilogram,
  }) {
    if (_disposed || _state != ScaleConnectionState.connected) return;
    _readings.add(
      ScaleReading(valueMilli: null, unit: unit, status: status, at: _clock()),
    );
  }

  /// The device drops off (cable pulled, out of range).
  void simulateDisconnect() {
    _demo?.cancel();
    _demo = null;
    _set(ScaleConnectionState.disconnected);
  }

  /// Developer demo: a weight that moves for a moment and then settles,
  /// repeating through a few example weights.
  void startDemo({Duration step = const Duration(milliseconds: 400)}) {
    _demo?.cancel();
    const targets = [250, 1250, 0, 2480, 615];
    var tick = 0;
    _demo = Timer.periodic(step, (_) {
      final target = targets[(tick ~/ 6) % targets.length];
      final phase = tick % 6;
      if (phase < 3) {
        emitWeight(target + (3 - phase) * 37, stable: false);
      } else {
        emitWeight(target);
      }
      tick++;
    });
  }

  @override
  Future<void> dispose() async {
    _demo?.cancel();
    _disposed = true;
    _state = ScaleConnectionState.disconnected;
    await _readings.close();
    await _connection.close();
  }
}
