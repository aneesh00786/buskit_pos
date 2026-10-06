import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/pos_tokens.dart';
import '../../auth/state/session_controller.dart';
import '../data/voice_platform.dart';
import '../state/voice_controller.dart';

/// Phase 13A — DEVELOPER test screen for the voice foundation: start / stop /
/// cancel listening and see the recognized text with the voice session and
/// request ids. It only shows text — no billing, no POS action (Phase 13B).
/// The microphone is asked for on the first "Start Voice", never earlier.
Future<void> showVoiceTest(
  BuildContext context, {
  MicrophonePermission? permission,
  SpeechRecognizer? recognizer,
}) {
  final session = context.read<SessionController>();
  final controller = VoiceController(
    permission: permission ?? const PermissionHandlerMicrophone(),
    recognizer: recognizer ?? SpeechToTextRecognizer(),
    scope: () => session.tokenScope,
  );
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<VoiceController>.value(
      value: controller,
      child: const VoiceTestView(),
    ),
  ).whenComplete(controller.dispose);
}

class VoiceTestView extends StatelessWidget {
  const VoiceTestView({super.key});

  static String stateLabel(VoiceState s) => switch (s) {
    VoiceState.idle => 'Idle',
    VoiceState.requestingPermission => 'Requesting microphone permission…',
    VoiceState.listening => 'Listening…',
    VoiceState.processing => 'Processing…',
    VoiceState.recognized => 'Recognized',
    VoiceState.error => 'Error',
  };

  @override
  Widget build(BuildContext context) {
    final v = context.watch<VoiceController>();
    final theme = Theme.of(context);
    final session = v.session;
    final busy =
        v.state == VoiceState.requestingPermission ||
        v.state == VoiceState.processing;
    return AlertDialog(
      title: const Text('Voice (developer test)'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Technical test only: speech becomes text. Nothing is billed or sent to the POS.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: PosTokens.s12),
              _Line(
                'State',
                stateLabel(v.state),
                key: const Key('voice-state'),
              ),
              _Line(
                'Voice session',
                session?.voiceSessionId ?? '—',
                key: const Key('voice-session-id'),
              ),
              _Line(
                'Request',
                v.request?.requestId ?? '—',
                key: const Key('voice-request-id'),
              ),
              _Line(
                'Staff / device / company',
                session == null
                    ? '—'
                    : '${session.staffId ?? '—'} / ${session.deviceId ?? '—'} / ${session.companyId ?? '—'}',
              ),
              const SizedBox(height: PosTokens.s12),
              if (v.text.isNotEmpty) ...[
                Text('Recognized text:', style: theme.textTheme.titleSmall),
                Text(
                  '"${v.text}"',
                  key: const Key('voice-text'),
                  style: theme.textTheme.titleMedium,
                ),
              ],
              if (v.error != null) ...[
                const SizedBox(height: PosTokens.s8),
                Text(
                  v.error!,
                  key: const Key('voice-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                if (v.needsSettings)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('voice-open-settings'),
                      onPressed: v.openSettings,
                      child: const Text('Open settings'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('voice-new-session'),
          onPressed: busy ? null : v.newSession,
          child: const Text('New session'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (v.isListening) ...[
          TextButton(
            key: const Key('voice-cancel'),
            onPressed: v.cancel,
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const Key('voice-stop'),
            onPressed: v.stop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        ] else
          FilledButton.icon(
            key: const Key('voice-start'),
            onPressed: busy ? null : v.start,
            icon: const Icon(Icons.mic),
            label: const Text('Start Voice'),
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 170, child: Text(label)),
        Expanded(
          child: SelectableText(
            value,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}
