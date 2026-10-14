import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/quantity.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/models/pos_token_scope.dart';
import '../../auth/state/session_controller.dart';
import '../../cart/state/cart_controller.dart';
import '../../cart/ui/quantity_dialog.dart';
import '../../checkout/data/payment_recovery_service.dart';
import '../data/voice_order_service.dart';
import '../data/voice_platform.dart';
import '../data/voice_preview_service.dart';
import '../data/voice_tts.dart';
import '../intent/voice_intent.dart';
import '../models/quick_bill_preview.dart';
import '../models/voice_language.dart';
import '../state/voice_controller.dart';
import '../state/voice_payment_status.dart';
import '../translation/api_translation_service.dart';
import '../translation/translation_service.dart';
import '../translation/translation_view.dart';

/// Phase 13A — DEVELOPER test screen for the voice foundation: start / stop /
/// cancel listening and see the recognized text with the voice session and
/// request ids. The microphone is asked for on the first "Start Voice".
///
/// Phase 13C-B: a CREATE_QUICK_BILL intent is sent for a backend preview
/// (server-matched products, prices and tax) and shown for verification.
/// Phase 13C-C: with a [cart], "Confirm Bill" adds the confirmed lines to it
/// through the existing cart path and the dialog closes with true — the
/// caller then opens the EXISTING checkout. Nothing here pays or completes.
Future<bool> showVoiceTest(
  BuildContext context, {
  MicrophonePermission? permission,
  SpeechRecognizer? recognizer,
  VoicePreviewService? previewService,
  CartController? cart,
  PosTokenScope? Function()? scope,
  VoiceTtsService? tts,
  VoiceSettings? settings,
  VoiceOrderService? orderService,
  TranslationService? translationService,
}) {
  final readScope = scope ?? _sessionScope(context);
  final controller = VoiceController(
    permission: permission ?? defaultMicrophonePermission(),
    recognizer: recognizer ?? SpeechToTextRecognizer(),
    scope: readScope,
    previewService:
        previewService ?? ApiVoicePreviewService(context.read<PosApiClient>()),
    cart: cart,
    // Phase 2: existing orders by voice (operator screen only).
    orderService:
        orderService ?? (cart != null ? _apiOrderService(context) : null),
    // Phase 13F: spoken replies on the operator Quick Bill screen only.
    tts: tts ?? (cart != null ? FlutterTtsService() : null),
    settings: settings ?? voiceSettings,
  );
  return showDialog<bool>(
    context: context,
    builder: (_) => MultiProvider(
      providers: [
        ChangeNotifierProvider<VoiceController>.value(value: controller),
        // Phase 3B.1: the store server's Google Cloud Translation when the
        // app has its API client; otherwise translation is plainly
        // unavailable (never pretended).
        Provider<TranslationService>.value(
          value:
              translationService ??
              _apiTranslationService(context) ??
              const UnavailableTranslationService(),
        ),
      ],
      child: _CloseWhenConfirmedByVoice(
        controller: controller,
        child: const VoiceTestView(),
      ),
    ),
  ).then((added) => added == true).whenComplete(controller.dispose);
}

/// Phase 13G — the app's voice language setting (local to the app, English
/// by default; only implemented languages can be selected).
final voiceSettings = VoiceSettings();

/// The app's API client when one is provided (null in screens / tests
/// without one — existing orders by voice are then not offered).
VoiceOrderService? _apiOrderService(BuildContext context) {
  try {
    return ApiVoiceOrderService(context.read<PosApiClient>());
  } on ProviderNotFoundException {
    return null;
  }
}

TranslationService? _apiTranslationService(BuildContext context) {
  try {
    return ApiTranslationService(context.read<PosApiClient>());
  } on ProviderNotFoundException {
    return null;
  }
}

PosTokenScope? Function() _sessionScope(BuildContext context) {
  final session = context.read<SessionController>();
  return () => session.tokenScope;
}

/// Phase 13C-C — the cart's "Voice bill" action: speak, verify, Confirm
/// Bill (lines go into THIS cart through its existing add path), then the
/// EXISTING checkout opens via [openCheckout] (the cart passes `showPay`).
/// Returns true when checkout was opened.
///
/// Phase 1: when checkout closes, the bill's payment status is shown, read
/// from authoritative state only (see [voicePaymentOutcome]); [recovery]
/// defaults to the app's read-only payment-recovery service.
Future<bool> startVoiceBill(
  BuildContext context, {
  required Future<void> Function(BuildContext context) openCheckout,
  MicrophonePermission? permission,
  SpeechRecognizer? recognizer,
  VoicePreviewService? previewService,
  PosTokenScope? Function()? scope,
  VoiceTtsService? tts,
  VoiceSettings? settings,
  PaymentRecoveryService? recovery,
  VoiceOrderService? orderService,
  TranslationService? translationService,
}) async {
  final cart = context.read<CartController>();
  // Phase 3A: the status is shown in this staff member's voice language.
  final readScope = scope ?? _sessionScope(context);
  final staff = readScope();
  final statusLanguage = (settings ?? voiceSettings).languageFor(
    staff == null ? null : '${staff.companyId}:${staff.salesmanId}',
  );
  final added = await showVoiceTest(
    context,
    permission: permission,
    recognizer: recognizer,
    previewService: previewService,
    cart: cart,
    scope: scope,
    tts: tts,
    settings: settings,
    orderService: orderService,
    translationService: translationService,
  );
  if (!added || !context.mounted) return false;
  // The server draft the confirmed bill is now in (never a local id).
  final saleId = cart.isLocalSale ? null : cart.sale?.id;
  final paymentRecovery = recovery ?? _recoveryService(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  await openCheckout(context);
  final outcome = await voicePaymentOutcome(
    cart: cart,
    saleId: saleId,
    recovery: paymentRecovery,
  );
  messenger?.showSnackBar(
    SnackBar(
      key: const Key('voice-payment-status'),
      content: Text('Voice bill: ${outcome.messageIn(statusLanguage)}'),
      duration: Duration(
        seconds: outcome.status == VoicePaymentStatus.paid ? 4 : 10,
      ),
    ),
  );
  return true;
}

PaymentRecoveryService? _recoveryService(BuildContext context) {
  try {
    return Provider.of<PaymentRecoveryService?>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

/// What the cashier said, as shown on screen: the assistant's name in front
/// ("Jacky, bill …") is left out — the name is never displayed. Display only;
/// the parser still receives the full text.
String shownSpeech(String text) => text.replaceFirst(
  RegExp(r'^\s*jacky\b[\s,.:;!-]*', caseSensitive: false),
  '',
);

/// Phase 1: a spoken "yes" confirmed the bill (through the same
/// [VoiceController.confirmBill] as the button): close with true, exactly
/// like the button, so the caller opens the EXISTING checkout. Once only.
class _CloseWhenConfirmedByVoice extends StatefulWidget {
  const _CloseWhenConfirmedByVoice({
    required this.controller,
    required this.child,
  });
  final VoiceController controller;
  final Widget child;

  @override
  State<_CloseWhenConfirmedByVoice> createState() =>
      _CloseWhenConfirmedByVoiceState();
}

class _CloseWhenConfirmedByVoiceState
    extends State<_CloseWhenConfirmedByVoice> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
  }

  void _check() {
    if (_closed || !mounted || !widget.controller.confirmedByVoice) return;
    _closed = true;
    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
    // Phase 13D: launched from the cart it is the operator's Quick Bill
    // screen (no ids, no developer wording); from Settings it stays the
    // developer test screen.
    final operator = v.cart != null;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(operator ? 'Quick Bill' : 'Voice (developer test)'),
          ),
          // Phase 3B: a separate mode with its own controller — speech there
          // never reaches this bill. Closed again with its close button.
          IconButton(
            key: const Key('voice-translation-mode'),
            onPressed: v.canOpenTranslation
                ? () {
                    v.stopSpeaking();
                    showTranslationMode(
                      context,
                      permission: v.permission,
                      recognizer: v.recognizer,
                      service: context.read<TranslationService>(),
                      tts: v.tts,
                      staffLanguage: v.language,
                    );
                  }
                : null,
            icon: const Icon(Icons.translate),
            tooltip: 'Translation mode',
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                v.previewService == null
                    ? 'Technical test only: speech becomes text. Nothing is billed or sent to the POS.'
                    : !operator
                    ? 'Technical test only: a spoken quick bill is checked and priced by the server. Nothing is billed, paid or saved.'
                    : 'Say the bill, for example "bill two coffees and one water". Confirm Bill puts it in the cart; payment happens at checkout.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: PosTokens.s12),
              if (operator) ...[
                Text(
                  stateLabel(v.state),
                  key: const Key('voice-state'),
                  style: theme.textTheme.labelLarge,
                ),
                // Phase 13H: the current bill's language, and the language
                // for the next bill (an open bill keeps its own).
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Language: ${v.sessionLanguage.label}',
                        key: const Key('voice-language'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    DropdownButton<VoiceLanguage>(
                      key: const Key('voice-language-picker'),
                      value: v.language,
                      isDense: true,
                      onChanged: busy || v.isListening
                          ? null
                          : (l) => l == null ? null : v.selectLanguage(l),
                      items: [
                        for (final l in VoiceLanguage.supported)
                          DropdownMenuItem(
                            value: l,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(l.label),
                                // Phase 3A: the language's own name too.
                                if (l.nativeLabel != null)
                                  Text(
                                    ' ${l.nativeLabel}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                if (v.sessionLanguage != v.language)
                  Text(
                    'The next bill will use ${v.language.label}.',
                    key: const Key('voice-next-language'),
                    style: theme.textTheme.bodySmall,
                  ),
                // Phase 3A: what this device could not do in the language.
                if (!v.recognitionAvailable(v.language))
                  Text(
                    '${v.language.label} speech recognition is not available on this device.',
                    key: const Key('voice-recognition-unavailable'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (v.spokenRepliesNote != null)
                  Text(
                    v.spokenRepliesNote!,
                    key: const Key('voice-spoken-unavailable'),
                    style: theme.textTheme.bodySmall,
                  ),
                if (v.isSpeaking)
                  Text(
                    'ThriveWoo is speaking…',
                    key: const Key('voice-speaking'),
                    style: theme.textTheme.bodySmall,
                  ),
              ] else ...[
                _Line(
                  'State',
                  stateLabel(v.state),
                  key: const Key('voice-state'),
                ),
                _Line(
                  'Language',
                  '${v.sessionLanguage.label} (${v.sessionLanguage.code})',
                  key: const Key('voice-language'),
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
              ],
              const SizedBox(height: PosTokens.s12),
              if (v.text.isNotEmpty) ...[
                Text('Recognized text:', style: theme.textTheme.titleSmall),
                Text(
                  '"${shownSpeech(v.text)}"',
                  key: const Key('voice-text'),
                  style: theme.textTheme.titleMedium,
                ),
              ],
              // Phase 13B: what the text means — a PREVIEW only (no
              // prices: nothing has been matched or validated yet).
              if (v.intent case final intent?) ...[
                const SizedBox(height: PosTokens.s12),
                if (!operator) ...[
                  Text('Intent:', style: theme.textTheme.titleSmall),
                  Text(intent.type.wire, key: const Key('voice-intent')),
                  for (final (n, item) in intent.items.indexed)
                    Padding(
                      padding: const EdgeInsets.only(top: PosTokens.s4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item.quantity}${item.unit == null ? '' : ' ${item.unit}'} × ${item.productQuery}',
                            key: Key('voice-intent-item-$n'),
                            style: theme.textTheme.titleSmall,
                          ),
                          if (item.variantQuery != null)
                            Text('Variant: ${item.variantQuery}'),
                        ],
                      ),
                    ),
                ],
                if (intent.type == VoiceIntentType.needsClarification)
                  Text(
                    intent.clarification ?? 'Please say that again.',
                    key: const Key('voice-clarification'),
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
                if (intent.type == VoiceIntentType.unknown)
                  const Text(
                    "I couldn't identify a POS command.",
                    key: Key('voice-unknown'),
                  ),
                if (intent.type == VoiceIntentType.unsupportedLanguage)
                  Text(
                    'Voice commands in ${v.sessionLanguage.label} are not supported yet.',
                    key: const Key('voice-unsupported-language'),
                  ),
              ],
              // Phase 2: an existing order, for verification.
              if (v.orderState != VoiceOrderState.none) ...[
                const SizedBox(height: PosTokens.s12),
                _OrderSection(v),
              ],
              // Phase 13C-B: the server's preview, for verification.
              if (v.previewState != VoicePreviewState.none) ...[
                const SizedBox(height: PosTokens.s12),
                _PreviewSection(v),
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
        if (!operator)
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

/// Phase 13C-B — the backend preview: loading, a READY bill to verify, the
/// lines that need clarification, or a safe error with Retry.
class _PreviewSection extends StatelessWidget {
  const _PreviewSection(this.v);
  final VoiceController v;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = v.preview;
    final speakAgain = OutlinedButton.icon(
      key: const Key('voice-speak-again'),
      onPressed: v.billState == VoiceBillState.none && !v.isCorrecting
          ? v.speakAgain
          : null,
      icon: const Icon(Icons.mic),
      label: Text(
        preview?.isReady == true ? 'Edit / Speak Again' : 'Speak Again',
      ),
    );
    final cancel = TextButton(
      key: const Key('voice-cancel-bill'),
      onPressed: v.billState == VoiceBillState.none && !v.isCorrecting
          ? v.cancelBill
          : null,
      child: const Text('Cancel'),
    );

    if (v.previewState == VoicePreviewState.loading) {
      return const Row(
        key: Key('voice-preview-loading'),
        children: [
          SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: PosTokens.s8),
          Text('Checking the bill with the server…'),
        ],
      );
    }
    if (preview == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            v.previewError ?? 'The bill preview could not be loaded.',
            key: const Key('voice-preview-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: PosTokens.s8),
          Wrap(
            spacing: PosTokens.s8,
            children: [
              if (v.previewRetryable)
                FilledButton(
                  key: const Key('voice-preview-retry'),
                  onPressed: v.retryPreview,
                  child: const Text('Retry'),
                ),
              speakAgain,
              cancel,
            ],
          ),
        ],
      );
    }

    return Card(
      key: Key(
        preview.isReady ? 'voice-preview-ready' : 'voice-preview-unclear',
      ),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(PosTokens.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              preview.isReady ? 'Verify bill' : 'Needs clarification',
              style: theme.textTheme.titleMedium,
            ),
            Text(
              'You said: "${shownSpeech(preview.recognizedText)}"',
              key: const Key('voice-preview-said'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: PosTokens.s8),
            for (final line in preview.items)
              _PreviewLine(line, v: v.cart != null && v.canCorrect ? v : null),
            for (final issue in preview.issues)
              _IssueLine(issue, v: v.cart != null && v.canCorrect ? v : null),
            if (preview.isReady) ...[
              const Divider(),
              _Amount(
                'Subtotal',
                preview.subtotal,
                key: const Key('voice-preview-subtotal'),
              ),
              _Amount('Tax', preview.tax, key: const Key('voice-preview-tax')),
              _Amount(
                'Total',
                preview.total,
                key: const Key('voice-preview-total'),
                strong: true,
              ),
              if (preview.pricingNote != null)
                Text(
                  preview.pricingNote!,
                  key: const Key('voice-preview-note'),
                  style: theme.textTheme.bodySmall,
                ),
            ],
            const SizedBox(height: PosTokens.s8),
            if (v.billState == VoiceBillState.adding)
              const Text(
                'Adding the bill to the cart…',
                key: Key('voice-bill-adding'),
              ),
            if (v.billState == VoiceBillState.added)
              Text(
                'Bill confirmed. Payment: unpaid — continue in checkout.',
                key: const Key('voice-bill-added'),
                style: TextStyle(color: theme.colorScheme.primary),
              ),
            // Phase 13E: a spoken correction that was not applied (the bill
            // above is unchanged) and why.
            if (v.correctionQuestion != null)
              Text(
                v.correctionQuestion!,
                key: const Key('voice-correction-question'),
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
            if (v.isCorrecting)
              const Text(
                'Listening for your answer…',
                key: Key('voice-correction-listening'),
              ),
            // Phase 1: the bill is verified by the server and waits for an
            // explicit confirmation (spoken or tapped) — nothing is billed
            // or paid until then.
            if (preview.isReady &&
                v.cart != null &&
                v.billState == VoiceBillState.none &&
                !v.isCorrecting &&
                v.correctionQuestion == null &&
                v.billError == null)
              const Text(
                'Waiting for your confirmation. Tap Confirm Bill, or tap '
                'Answer by voice and say yes, no or a change.',
                key: Key('voice-awaiting-confirmation'),
              ),
            if (v.billError != null)
              Text(
                v.billError!,
                key: const Key('voice-bill-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            Wrap(
              spacing: PosTokens.s8,
              runSpacing: PosTokens.s4,
              children: [
                if (preview.isReady)
                  FilledButton.icon(
                    key: const Key('voice-confirm-bill'),
                    onPressed:
                        v.billState == VoiceBillState.none && !v.isCorrecting
                        ? () async {
                            // Payment and completion stay with the existing
                            // checkout, which the caller opens next.
                            if (await v.confirmBill() && context.mounted) {
                              Navigator.of(context).pop(true);
                            }
                          }
                        : null,
                    icon: const Icon(Icons.check),
                    label: const Text('Confirm Bill'),
                  ),
                // Phase 13E (operator screen): say a correction while the
                // bill stays on screen.
                if (v.cart != null && v.canCorrect)
                  OutlinedButton.icon(
                    key: const Key('voice-speak-correction'),
                    onPressed: v.startCorrection,
                    icon: const Icon(Icons.record_voice_over_outlined),
                    label: const Text('Answer by voice'),
                  ),
                speakAgain,
                cancel,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Phase 2 — an existing order: looking it up, not found, the server's view
/// for verification (spoken or touch confirmation), changed / no longer
/// billable (reload), or a recoverable error (retry). Confirming opens the
/// SAME sale in the existing checkout; nothing is paid here.
class _OrderSection extends StatelessWidget {
  const _OrderSection(this.v);
  final VoiceController v;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final idle = v.billState == VoiceBillState.none && !v.isAnsweringOrder;
    final speakAgain = OutlinedButton.icon(
      key: const Key('voice-order-speak-again'),
      onPressed: idle ? v.speakAgain : null,
      icon: const Icon(Icons.mic),
      label: const Text('Speak Again'),
    );
    final cancel = TextButton(
      key: const Key('voice-order-cancel'),
      onPressed: idle ? v.cancelBill : null,
      child: const Text('Cancel'),
    );
    final o = v.order;
    switch (v.orderState) {
      case VoiceOrderState.loading:
        return Row(
          key: const Key('voice-order-loading'),
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: PosTokens.s8),
            Text(
              v.orderNumber == null && v.tableRef != null
                  ? 'Looking up the orders at table ${v.tableRef}…'
                  : 'Looking up order ${v.orderNumber}…',
            ),
          ],
        );
      case VoiceOrderState.loaded when o != null:
        final t = o.totals;
        return Card(
          key: const Key('voice-order-ready'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(PosTokens.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Verify order #${o.id}',
                  style: theme.textTheme.titleMedium,
                ),
                if (o.tableRef != null)
                  Text(
                    'Table ${o.tableRef}',
                    key: const Key('voice-order-table'),
                    style: theme.textTheme.labelLarge,
                  ),
                const SizedBox(height: PosTokens.s8),
                for (final line in o.items)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${formatQuantity(line.quantity)} × ${line.productName ?? 'Item'}',
                        ),
                      ),
                      Text(formatMoney(line.lineTotal ?? 0)),
                    ],
                  ),
                const Divider(),
                if (t.subtotal != null) _Amount('Subtotal', t.subtotal),
                if ((t.discountTotal ?? 0) != 0)
                  _Amount('Discount', -(t.discountTotal ?? 0)),
                if (t.taxTotal != null) _Amount('Tax', t.taxTotal),
                _Amount(
                  'Total',
                  t.grandTotal,
                  key: const Key('voice-order-total'),
                  strong: true,
                ),
                const SizedBox(height: PosTokens.s8),
                if (v.billState == VoiceBillState.adding)
                  const Text(
                    'Opening the order for checkout…',
                    key: Key('voice-order-opening'),
                  ),
                if (v.isAnsweringOrder)
                  const Text(
                    'Listening for your answer…',
                    key: Key('voice-order-listening'),
                  ),
                if (v.correctionQuestion != null)
                  Text(
                    v.correctionQuestion!,
                    key: const Key('voice-order-question'),
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
                if (v.billError != null)
                  Text(
                    v.billError!,
                    key: const Key('voice-order-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (idle && v.correctionQuestion == null && v.billError == null)
                  const Text(
                    'Waiting for your confirmation. Tap Bill this order, or '
                    'tap Answer by voice and say yes or cancel. Nothing is '
                    'paid until checkout.',
                    key: Key('voice-order-awaiting'),
                  ),
                Wrap(
                  spacing: PosTokens.s8,
                  runSpacing: PosTokens.s4,
                  children: [
                    FilledButton.icon(
                      key: const Key('voice-bill-order'),
                      onPressed: idle
                          ? () async {
                              if (await v.confirmOrder() && context.mounted) {
                                Navigator.of(context).pop(true);
                              }
                            }
                          : null,
                      icon: const Icon(Icons.point_of_sale),
                      label: const Text('Bill this order'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('voice-order-answer'),
                      onPressed: idle ? v.startOrderAnswer : null,
                      icon: const Icon(Icons.record_voice_over_outlined),
                      label: const Text('Answer by voice'),
                    ),
                    speakAgain,
                    cancel,
                  ],
                ),
              ],
            ),
          ),
        );
      case VoiceOrderState.choosing:
        // Phase 2.1: several held orders at the table — the cashier picks
        // one explicitly; it is then looked up and verified as usual.
        return Card(
          key: const Key('voice-table-choices'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(PosTokens.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${v.tableOrders.length} orders at table ${v.tableRef}. '
                  'Choose the one to bill:',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: PosTokens.s8),
                for (final c in v.tableOrders)
                  ListTile(
                    key: Key('voice-table-order-${c.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('Order #${c.id}'),
                    subtitle: Text(
                      [
                        if (c.heldAt != null)
                          'Held ${formatTimestamp(c.heldAt!)}',
                        if (c.itemCount != null)
                          '${c.itemCount} item${c.itemCount == 1 ? '' : 's'}',
                      ].join(' · '),
                    ),
                    trailing: Text(formatMoney(c.grandTotal ?? 0)),
                    onTap: () => v.chooseTableOrder(c.id),
                  ),
                Wrap(spacing: PosTokens.s8, children: [speakAgain, cancel]),
              ],
            ),
          ),
        );
      default:
        final reload =
            v.orderState == VoiceOrderState.conflict ||
            v.orderState == VoiceOrderState.ineligible ||
            (v.orderState == VoiceOrderState.failed && v.orderRetryable);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              v.orderMessage ?? 'The order could not be shown.',
              key: Key('voice-order-${v.orderState.name}'),
              style: TextStyle(
                color: v.orderState == VoiceOrderState.unsupported
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: PosTokens.s8),
            Wrap(
              spacing: PosTokens.s8,
              children: [
                if (reload)
                  FilledButton(
                    key: const Key('voice-order-reload'),
                    onPressed: v.retryOrder,
                    child: Text(
                      v.orderState == VoiceOrderState.failed
                          ? 'Retry'
                          : 'Reload order',
                    ),
                  ),
                speakAgain,
                cancel,
              ],
            ),
          ],
        );
    }
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine(this.line, {this.v});
  final QuickBillLine line;

  /// Phase 13D (operator screen): Edit quantity / Remove send a NEW preview.
  final VoiceController? v;

  Future<void> _edit(BuildContext context, String name) async {
    final q = await showQuantityDialog(
      context,
      initial: line.quantity,
      itemName: name,
      weight: line.sellingMode == 'WEIGHT',
    );
    if (q != null && q != line.quantity) {
      await v!.changeQuantity(line.itemIndex, q);
    }
  }

  static String quantityLabel(QuickBillLine l) =>
      '${formatQty(l.quantity)}${l.unit == null ? '' : ' ${l.unit}'}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = line.variantName == null
        ? line.productName
        : '${line.productName} — ${line.variantName}';
    final taxLabel = line.taxIncluded
        ? 'Tax ${formatMoney(line.tax)} (${formatQty(line.taxPercent)}% incl.)'
        : 'Tax ${formatMoney(line.tax)} (${formatQty(line.taxPercent)}%)';
    return Padding(
      key: Key('voice-preview-line-${line.itemIndex}'),
      padding: const EdgeInsets.only(bottom: PosTokens.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${quantityLabel(line)} × $name',
                  key: Key('voice-preview-line-${line.itemIndex}-name'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                formatMoney(line.lineTotal),
                key: Key('voice-preview-line-${line.itemIndex}-total'),
                style: theme.textTheme.titleSmall,
              ),
              if (v != null) ...[
                IconButton(
                  key: Key('voice-edit-line-${line.itemIndex}'),
                  tooltip: 'Edit quantity',
                  onPressed: () => _edit(context, name),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                IconButton(
                  key: Key('voice-remove-line-${line.itemIndex}'),
                  tooltip: 'Remove line',
                  onPressed: () => v!.removeLine(line.itemIndex),
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ],
          ),
          Text(
            'Unit price ${formatMoney(line.unitPrice)} · $taxLabel',
            key: Key('voice-preview-line-${line.itemIndex}-detail'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _IssueLine extends StatelessWidget {
  const _IssueLine(this.issue, {this.v});
  final QuickBillIssue issue;

  /// Phase 13D (operator screen): the cashier may explicitly choose one of
  /// the server's candidates, or remove the line.
  final VoiceController? v;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = issue.itemIndex;
    return Padding(
      key: Key('voice-preview-issue-$i'),
      padding: const EdgeInsets.only(bottom: PosTokens.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '"${issue.said}"',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (v != null)
                IconButton(
                  key: Key('voice-remove-issue-$i'),
                  tooltip: 'Remove line',
                  onPressed: () => v!.removeLine(i),
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
            ],
          ),
          Text(
            issue.message,
            key: Key('voice-preview-issue-$i-message'),
            style: TextStyle(color: theme.colorScheme.tertiary),
          ),
          // Never chosen FOR the cashier. Developer screen: text only. Operator
          // screen: the cashier may tap one — an explicit choice the server
          // re-validates in a new preview.
          if (issue.candidates.isNotEmpty && v == null) ...[
            const Text('Did you mean one of these? Say it again:'),
            for (final (n, c) in issue.candidates.indexed)
              Text('• ${c.label}', key: Key('voice-candidate-$i-$n')),
          ],
          if (issue.candidates.isNotEmpty && v != null) ...[
            const Text('Choose the right product, or speak again:'),
            Wrap(
              spacing: PosTokens.s8,
              runSpacing: PosTokens.s4,
              children: [
                for (final (n, c) in issue.candidates.indexed)
                  OutlinedButton(
                    key: Key('voice-candidate-$i-$n'),
                    onPressed: c.productVariationId == null
                        ? null
                        : () => v!.chooseCandidate(i, c),
                    child: Text(c.label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Amount extends StatelessWidget {
  const _Amount(this.label, this.value, {super.key, this.strong = false});
  final String label;
  final double? value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final style = strong
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Expanded(child: Text(label, style: style)),
        Text(formatMoney(value), style: style),
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
