import 'package:flutter/foundation.dart';

import '../../auth/models/pos_token_scope.dart';
import '../data/voice_platform.dart';
import '../models/voice_session.dart';

/// Phase 13A — where the voice flow is.
enum VoiceState {
  idle,
  requestingPermission,
  listening,
  processing,
  recognized,
  error,
}

/// Phase 13A — the voice foundation: microphone permission (asked on first
/// use), listening, speech-to-text, and the session / request ids. It ends
/// at RECOGNIZED TEXT: nothing is interpreted and nothing is sent to the
/// POS backend; no sale, payment, stock or other POS state is touched
/// (Phase 13B adds intent handling).
///
/// One controller per screen; a voice session is per signed-in staff member
/// and device ([scope] is read from the existing POS session each time a
/// request starts — when it changes, a new session begins).
class VoiceController extends ChangeNotifier {
  VoiceController({
    required this.permission,
    required this.recognizer,
    required this.scope,
  });

  final MicrophonePermission permission;
  final SpeechRecognizer recognizer;

  /// The signed-in POS scope (company / store / register / device / staff)
  /// from the existing session; null when nobody is signed in.
  final PosTokenScope? Function() scope;

  VoiceState _state = VoiceState.idle;
  VoiceSession? _session;
  VoiceRequest? _request;
  VoicePermission? _permission;
  String? _error;
  bool _initialized = false;
  bool _busy = false; // a start / stop / cancel is in progress
  bool _disposed = false;

  VoiceState get state => _state;
  VoiceSession? get session => _session;
  VoiceRequest? get request => _request;
  VoicePermission? get lastPermission => _permission;
  String? get error => _error;
  String get text => _request?.text ?? '';
  bool get isListening => _state == VoiceState.listening;

  /// Permission is refused for good: only the device settings can fix it.
  bool get needsSettings => _permission == VoicePermission.permanentlyDenied;

  void _set(VoiceState s, {String? error}) {
    if (_disposed) return;
    _state = s;
    _error = error;
    notifyListeners();
  }

  /// Starts a fresh voice session (new voiceSessionId) for the current
  /// signed-in scope. Any request in progress is cancelled first.
  Future<void> newSession() async {
    if (_state == VoiceState.listening) await cancel();
    _session = VoiceSession.start(scope());
    _request = null;
    _set(VoiceState.idle);
  }

  /// Asks for the microphone (first use only), then listens for one request
  /// (new requestId). Returns false when it did not start — already busy
  /// or listening (duplicate start), permission refused, or the recognizer
  /// is unavailable ([error] says why).
  Future<bool> start() async {
    if (_busy ||
        _disposed ||
        _state == VoiceState.listening ||
        _state == VoiceState.processing) {
      return false;
    }
    _busy = true;
    try {
      // Permission — asked here, when voice is used, never at app start.
      var p = await permission.status();
      if (p == VoicePermission.denied) {
        _set(VoiceState.requestingPermission);
        p = await permission.request();
      }
      _permission = p;
      if (p != VoicePermission.granted) {
        _set(VoiceState.error, error: _permissionMessage(p));
        return false;
      }

      if (!_initialized) {
        _initialized = await recognizer.initialize(
          onError: _onRecognizerError,
          onStatus: _onRecognizerStatus,
        );
        if (!_initialized) {
          _set(
            VoiceState.error,
            error: 'Speech recognition is not available on this device.',
          );
          return false;
        }
      }

      // Session isolation: a different staff member / device / company never
      // continues someone else's session.
      final current = scope();
      if (_session == null || !_session!.belongsTo(current)) {
        _session = VoiceSession.start(current);
      }
      _request = VoiceRequest.start(_session!);
      _set(VoiceState.listening);
      await recognizer.listen(onResult: _onResult);
      return true;
    } catch (_) {
      _set(VoiceState.error, error: 'Voice could not start. Try again.');
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Stops listening; the recognized text follows ([VoiceState.processing]
  /// until it arrives). Ignored unless listening (duplicate stop).
  Future<void> stop() async {
    if (_busy || _state != VoiceState.listening) return;
    _busy = true;
    try {
      _set(VoiceState.processing);
      await recognizer.stop();
    } catch (_) {
      _set(VoiceState.error, error: 'Voice could not stop cleanly.');
    } finally {
      _busy = false;
    }
  }

  /// Stops listening and discards whatever was heard.
  Future<void> cancel() async {
    if (_state != VoiceState.listening && _state != VoiceState.processing) {
      return;
    }
    _busy = true;
    try {
      await recognizer.cancel();
    } catch (_) {
      // Released either way.
    } finally {
      _busy = false;
      _request = null;
      _set(VoiceState.idle);
    }
  }

  /// Opens the device settings (when permission was refused for good).
  Future<bool> openSettings() => permission.openSettings();

  void _onResult(String text, bool isFinal) {
    final r = _request;
    if (_disposed || r == null) return;
    if (_state != VoiceState.listening && _state != VoiceState.processing) {
      return; // cancelled / finished: late results are ignored
    }
    r.text = text.trim();
    if (isFinal) {
      if (r.text.isEmpty) {
        _set(VoiceState.error, error: 'Nothing was heard. Try again.');
      } else {
        r.recognizedAt = DateTime.now();
        _set(VoiceState.recognized);
      }
    } else if (!_disposed) {
      notifyListeners();
    }
  }

  void _onRecognizerStatus(String status) {
    // The recognizer finished without a final result (e.g. silence).
    if (status == 'done' &&
        (_state == VoiceState.listening || _state == VoiceState.processing)) {
      final r = _request;
      if (r != null && r.text.isNotEmpty) {
        r.recognizedAt = DateTime.now();
        _set(VoiceState.recognized);
      } else {
        _set(VoiceState.error, error: 'Nothing was heard. Try again.');
      }
    }
  }

  void _onRecognizerError(String error) {
    if (_state == VoiceState.idle || _state == VoiceState.recognized) return;
    _set(
      VoiceState.error,
      error: error.contains('no_match') || error.contains('speech_timeout')
          ? 'Nothing was heard. Try again.'
          : 'Speech recognition failed. Try again.',
    );
  }

  static String _permissionMessage(VoicePermission p) => switch (p) {
    VoicePermission.permanentlyDenied => 'Microphone access is turned off for this app. Turn it on in the device settings to use voice.',
    VoicePermission.unavailable =>
      'The microphone is not available on this device.',
    _ => 'Microphone access is needed to use voice.',
  };

  @override
  void dispose() {
    _disposed = true;
    if (_state == VoiceState.listening || _state == VoiceState.processing) {
      recognizer.cancel().catchError((_) {});
    }
    super.dispose();
  }
}
