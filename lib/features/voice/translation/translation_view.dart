import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/pos_tokens.dart';
import '../data/voice_platform.dart';
import '../data/voice_tts.dart';
import '../models/voice_language.dart';
import 'translation_controller.dart';
import 'translation_service.dart';

/// Phase 3B — opens translation mode on its own screen with its OWN
/// controller: speech heard here goes only to translation, never to the
/// billing voice controller or the POS command parser. Leaving the screen
/// drops all of its text. The bill / cart behind it are untouched.
Future<void> showTranslationMode(
  BuildContext context, {
  required MicrophonePermission permission,
  required SpeechRecognizer recognizer,
  required TranslationService service,
  VoiceTtsService? tts,
  VoiceLanguage staffLanguage = VoiceLanguage.english,
}) {
  final customer = VoiceLanguage.supported.firstWhere(
    (l) => l != staffLanguage,
    orElse: () => staffLanguage,
  );
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ChangeNotifierProvider<TranslationController>(
        create: (_) => TranslationController(
          permission: permission,
          recognizer: recognizer,
          service: service,
          tts: tts,
          staffLanguage: staffLanguage,
          customerLanguage: customer,
        ),
        child: const TranslationView(),
      ),
    ),
  );
}

class TranslationView extends StatefulWidget {
  const TranslationView({super.key});

  @override
  State<TranslationView> createState() => _TranslationViewState();
}

class _TranslationViewState extends State<TranslationView> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _label(TranslationDirection d) =>
      d == TranslationDirection.staffToCustomer ? 'Staff' : 'Customer';

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TranslationController>();
    final theme = Theme.of(context);
    // Recognised text flows into the editable box (the staff member's own
    // edits are not overwritten while they type).
    if (_text.text != c.sourceText &&
        (c.step == TranslationStep.listening || !_focus.hasFocus)) {
      _text.value = TextEditingValue(
        text: c.sourceText,
        selection: TextSelection.collapsed(offset: c.sourceText.length),
      );
    }
    final scheme = theme.colorScheme;
    final listening = c.step == TranslationStep.listening;
    final translating = c.step == TranslationStep.translating;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.tertiaryContainer,
        foregroundColor: scheme.onTertiaryContainer,
        leading: IconButton(
          key: const Key('translation-close'),
          tooltip: 'Back to billing',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Translate — customer conversation'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(PosTokens.s16),
              children: [
                Container(
                  key: const Key('translation-mode-banner'),
                  padding: const EdgeInsets.all(PosTokens.s12),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(PosTokens.rSmall),
                  ),
                  child: const Text(
                    'Translation mode. Nothing said here changes the bill, the cart or a payment.',
                  ),
                ),
                const SizedBox(height: PosTokens.s12),
                Wrap(
                  spacing: PosTokens.s12,
                  runSpacing: PosTokens.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _LanguagePicker(
                      label: 'Staff speaks',
                      pickerKey: const Key('translation-staff-language'),
                      value: c.staffLanguage,
                      languages: c.languages,
                      canChoose: c.canChooseStaff,
                      enabled: !listening,
                      onChanged: (l) => c.setLanguages(staff: l),
                    ),
                    IconButton(
                      key: const Key('translation-swap'),
                      tooltip: 'Swap languages',
                      onPressed:
                          listening ||
                              !c.canChooseStaff(c.customerLanguage) ||
                              !c.canChooseCustomer(c.staffLanguage)
                          ? null
                          : () => c.setLanguages(
                              staff: c.customerLanguage,
                              customer: c.staffLanguage,
                            ),
                      icon: const Icon(Icons.swap_horiz),
                    ),
                    _LanguagePicker(
                      label: 'Customer speaks',
                      pickerKey: const Key('translation-customer-language'),
                      value: c.customerLanguage,
                      languages: c.languages,
                      canChoose: c.canChooseCustomer,
                      enabled: !listening,
                      onChanged: (l) => c.setLanguages(customer: l),
                    ),
                  ],
                ),
                if (!c.providerAvailable) ...[
                  const SizedBox(height: PosTokens.s8),
                  Text(
                    c.supportLoaded
                        ? 'Translation is not set up on the store server yet (Google Cloud Translation has to be configured and approved). Speech can still be captured and reviewed.'
                        : 'Checking which languages translation is set up for…',
                    key: const Key('translation-provider-unavailable'),
                    style: TextStyle(color: scheme.error),
                  ),
                ],
                const SizedBox(height: PosTokens.s12),
                Wrap(
                  spacing: PosTokens.s8,
                  runSpacing: PosTokens.s8,
                  children: [
                    if (listening) ...[
                      FilledButton.icon(
                        key: const Key('translation-stop'),
                        onPressed: c.stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                      TextButton(
                        key: const Key('translation-cancel-listening'),
                        onPressed: c.cancel,
                        child: const Text('Cancel'),
                      ),
                    ] else ...[
                      FilledButton.icon(
                        key: const Key('translation-staff-speak'),
                        onPressed: translating
                            ? null
                            : () => c.startListening(
                                TranslationDirection.staffToCustomer,
                              ),
                        icon: const Icon(Icons.mic),
                        label: Text('Staff speaks (${c.staffLanguage.label})'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('translation-customer-speak'),
                        onPressed: translating || !c.canTranslateReplies
                            ? null
                            : () => c.startListening(
                                TranslationDirection.customerToStaff,
                              ),
                        icon: const Icon(Icons.record_voice_over_outlined),
                        label: Text(
                          'Customer replies (${c.customerLanguage.label})',
                        ),
                      ),
                    ],
                  ],
                ),
                if (c.providerAvailable && !c.canTranslateReplies)
                  Padding(
                    padding: const EdgeInsets.only(top: PosTokens.s4),
                    child: Text(
                      "Translating the customer's reply into ${c.staffLanguage.label} is not switched on yet.",
                      key: const Key('translation-replies-off'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: PosTokens.s12),
                Text(
                  '${_label(c.direction)} said (${c.sourceLanguage.displayName})',
                  key: const Key('translation-source-label'),
                  style: theme.textTheme.labelLarge,
                ),
                TextField(
                  key: const Key('translation-source'),
                  controller: _text,
                  focusNode: _focus,
                  enabled: !listening && !translating,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: listening
                        ? 'Listening…'
                        : 'Speak, or type the text here',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: c.setSourceText,
                ),
                const SizedBox(height: PosTokens.s8),
                Wrap(
                  spacing: PosTokens.s8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const Key('translation-translate'),
                      onPressed:
                          (listening ||
                              translating ||
                              c.sourceText.trim().isEmpty)
                          ? null
                          : c.translate,
                      icon: const Icon(Icons.translate),
                      label: Text(
                        c.translatedText == null
                            ? 'Translate to ${c.targetLanguage.label}'
                            : 'Translate again',
                      ),
                    ),
                    if (translating)
                      TextButton(
                        key: const Key('translation-cancel-translate'),
                        onPressed: c.cancel,
                        child: const Text('Cancel'),
                      ),
                    TextButton(
                      key: const Key('translation-clear'),
                      onPressed: c.clear,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                if (translating)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: PosTokens.s8),
                    child: LinearProgressIndicator(
                      key: Key('translation-progress'),
                    ),
                  ),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: PosTokens.s8),
                    child: Text(
                      c.error!,
                      key: const Key('translation-error'),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                if (c.translatedText != null) ...[
                  const SizedBox(height: PosTokens.s12),
                  Card(
                    key: const Key('translation-result'),
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(PosTokens.s12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Translation (${c.targetLanguage.displayName})',
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: PosTokens.s4),
                          SelectableText(
                            c.translatedText!,
                            key: const Key('translation-text'),
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: PosTokens.s8),
                          Row(
                            children: [
                              FilledButton.icon(
                                key: const Key('translation-play'),
                                onPressed:
                                    c.canSpeak(c.targetLanguage) &&
                                        !c.isSpeaking
                                    ? c.speak
                                    : null,
                                icon: const Icon(Icons.volume_up),
                                label: const Text('Play'),
                              ),
                            ],
                          ),
                          if (!c.canSpeak(c.targetLanguage))
                            Text(
                              'Spoken playback is not available in ${c.targetLanguage.label} on this device. Show the text instead.',
                              key: const Key('translation-no-voice'),
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                SwitchListTile(
                  key: const Key('translation-auto-speak'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Play each translation automatically'),
                  value: c.autoSpeak,
                  onChanged: c.setAutoSpeak,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({
    required this.label,
    required this.pickerKey,
    required this.value,
    required this.languages,
    required this.canChoose,
    required this.enabled,
    required this.onChanged,
  });
  final String label;
  final Key pickerKey;
  final VoiceLanguage value;
  final List<VoiceLanguage> languages;

  /// Phase 3B.1: languages not switched on are shown, but cannot be chosen.
  final bool Function(VoiceLanguage) canChoose;
  final bool enabled;
  final ValueChanged<VoiceLanguage> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        DropdownButton<VoiceLanguage>(
          key: pickerKey,
          value: value,
          onChanged: enabled ? (l) => l == null ? null : onChanged(l) : null,
          items: [
            for (final l in languages)
              DropdownMenuItem(
                value: l,
                enabled: canChoose(l),
                child: Text(
                  canChoose(l)
                      ? l.displayName
                      : '${l.displayName} (not set up)',
                ),
              ),
          ],
        ),
      ],
    );
  }
}
