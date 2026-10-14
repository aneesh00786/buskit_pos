import '../../../core/network/api_exception.dart';
import '../../cart/state/cart_controller.dart';
import '../../checkout/data/payment_recovery_service.dart';
import '../models/voice_language.dart';

/// Phase 1 — the payment status of a voice bill, in plain English. Read only
/// from authoritative state the app already has: the server's sale
/// completion (the cart's [CartController.completedSale]), the cart's own
/// record of a sale completed offline / a completion still in flight, and
/// the server's read-only payment-recovery view of the sale (attempt
/// statuses decided by the server / provider). Never from speech, a parser
/// or a client-side assumption.
enum VoicePaymentStatus {
  unpaid('Unpaid'),
  pending('Payment pending'),
  paid('Paid'),
  failed('Failed'),
  cancelled('Cancelled'),

  /// The app cannot tell — shown with recovery guidance, never as paid.
  unknown('Payment status unknown');

  const VoicePaymentStatus(this.label);
  final String label;
}

class VoicePaymentOutcome {
  const VoicePaymentOutcome(this.status, this.message);
  final VoicePaymentStatus status;

  /// What the cashier sees: the status and, when needed, what to do next.
  final String message;

  /// Phase 3A: [message] in [language] (the status itself never changes;
  /// English, or a language without its own wording, gets [message]).
  String messageIn(VoiceLanguage language) =>
      language == VoiceLanguage.malayalam
      ? (_malayalam[message] ?? message)
      : message;
}

const _recoveryHintMl =
    'വീണ്ടും പണം വാങ്ങുന്നതിന് മുമ്പ് Payment Recovery തുറന്ന് പരിശോധിക്കുക.';

/// Phase 3A — Malayalam wording of each status message above.
const _malayalam = {
  'Paid — the sale is complete.': 'പണം ലഭിച്ചു — വിൽപ്പന പൂർത്തിയായി.',
  'Paid — recorded on this device while offline; it will sync when the connection is back.': 'പണം ലഭിച്ചു — ഓഫ്‌ലൈനായി ഈ ഉപകരണത്തിൽ രേഖപ്പെടുത്തി; കണക്ഷൻ തിരികെ വരുമ്പോൾ സിങ്ക് ചെയ്യും.',
  'Payment pending — the sale has not been confirmed by the server yet. $_recoveryHint':
      'പണമടയ്ക്കൽ ബാക്കി — സെർവർ ഇതുവരെ വിൽപ്പന സ്ഥിരീകരിച്ചിട്ടില്ല. $_recoveryHintMl',
  'Payment status unknown. $_recoveryHint':
      'പണമടയ്ക്കൽ നില അറിയില്ല. $_recoveryHintMl',
  'Payment status could not be checked. $_recoveryHint':
      'പണമടയ്ക്കൽ നില പരിശോധിക്കാൻ കഴിഞ്ഞില്ല. $_recoveryHintMl',
  'Cancelled — the sale was closed without payment.':
      'റദ്ദാക്കി — പണം ലഭിക്കാതെ വിൽപ്പന അവസാനിപ്പിച്ചു.',
  'Unpaid — no payment has been taken for this bill.':
      'പണം ലഭിച്ചിട്ടില്ല — ഈ ബില്ലിന് ഇതുവരെ പണം വാങ്ങിയിട്ടില്ല.',
  'Payment pending — waiting for the payment provider. $_recoveryHint':
      'പണമടയ്ക്കൽ ബാക്കി — പേയ്‌മെന്റ് ദാതാവിന്റെ മറുപടിക്കായി കാത്തിരിക്കുന്നു. $_recoveryHintMl',
  'Payment received but the sale is not finished. Open Payment Recovery to complete it — do not take payment again.': 'പണം ലഭിച്ചു, പക്ഷേ വിൽപ്പന പൂർത്തിയായിട്ടില്ല. പൂർത്തിയാക്കാൻ Payment Recovery തുറക്കുക — വീണ്ടും പണം വാങ്ങരുത്.',
  'Payment failed. The bill is still unpaid — take payment again in checkout.': 'പണമടയ്ക്കൽ പരാജയപ്പെട്ടു. ബില്ലിന് ഇപ്പോഴും പണം ലഭിച്ചിട്ടില്ല — ചെക്കൗട്ടിൽ വീണ്ടും പണം വാങ്ങുക.',
  'Payment cancelled. The bill is still unpaid.':
      'പണമടയ്ക്കൽ റദ്ദാക്കി. ബില്ലിന് ഇപ്പോഴും പണം ലഭിച്ചിട്ടില്ല.',
};

const _recoveryHint =
    'Open Payment Recovery to check it before taking payment again.';

/// The status of the voice bill [saleId] (the draft the confirmed bill was
/// added to) after the existing checkout closed. [recovery] is the existing
/// read-only `GET /payment-recovery` service; when it is missing or fails,
/// the status is [VoicePaymentStatus.unknown] — never guessed.
Future<VoicePaymentOutcome> voicePaymentOutcome({
  required CartController cart,
  required int? saleId,
  PaymentRecoveryService? recovery,
}) async {
  final completed = cart.completedSale;
  if (completed != null && (saleId == null || completed.id == saleId)) {
    return const VoicePaymentOutcome(
      VoicePaymentStatus.paid,
      'Paid — the sale is complete.',
    );
  }
  if (cart.completedOfflineSale != null) {
    return const VoicePaymentOutcome(
      VoicePaymentStatus.paid,
      'Paid — recorded on this device while offline; it will sync when the '
      'connection is back.',
    );
  }
  if (cart.hasPendingCompletion) {
    return const VoicePaymentOutcome(
      VoicePaymentStatus.pending,
      'Payment pending — the sale has not been confirmed by the server yet. '
      '$_recoveryHint',
    );
  }
  if (saleId == null || recovery == null) {
    return const VoicePaymentOutcome(
      VoicePaymentStatus.unknown,
      'Payment status unknown. $_recoveryHint',
    );
  }
  final PaymentRecoveryResult result;
  try {
    result = await recovery.fetch(saleIds: [saleId]);
  } on ApiException {
    return const VoicePaymentOutcome(
      VoicePaymentStatus.unknown,
      'Payment status could not be checked. $_recoveryHint',
    );
  }
  return describeRecovery(result, saleId);
}

/// Maps the server's recovery view of [saleId] to a status. Exposed for
/// tests; see [voicePaymentOutcome].
VoicePaymentOutcome describeRecovery(PaymentRecoveryResult r, int saleId) {
  final resolved = r.resolved.where((s) => s.saleId == saleId).firstOrNull;
  if (resolved != null) {
    return resolved.completed
        ? const VoicePaymentOutcome(
            VoicePaymentStatus.paid,
            'Paid — the sale is complete.',
          )
        : const VoicePaymentOutcome(
            VoicePaymentStatus.cancelled,
            'Cancelled — the sale was closed without payment.',
          );
  }
  final open = r.recoverable.where((s) => s.saleId == saleId).firstOrNull;
  if (open == null) {
    return const VoicePaymentOutcome(
      VoicePaymentStatus.unpaid,
      'Unpaid — no payment has been taken for this bill.',
    );
  }
  return switch (open.state) {
    RecoveryState.noPayment => const VoicePaymentOutcome(
      VoicePaymentStatus.unpaid,
      'Unpaid — no payment has been taken for this bill.',
    ),
    RecoveryState.pending => const VoicePaymentOutcome(
      VoicePaymentStatus.pending,
      'Payment pending — waiting for the payment provider. $_recoveryHint',
    ),
    // Money may have been taken but the sale is not complete: never "paid"
    // and never "unpaid" — finish it from Payment Recovery.
    RecoveryState.captured ||
    RecoveryState.authorized => const VoicePaymentOutcome(
      VoicePaymentStatus.pending,
      'Payment received but the sale is not finished. Open Payment '
      'Recovery to complete it — do not take payment again.',
    ),
    RecoveryState.failed => const VoicePaymentOutcome(
      VoicePaymentStatus.failed,
      'Payment failed. The bill is still unpaid — take payment again in '
      'checkout.',
    ),
    RecoveryState.cancelled => const VoicePaymentOutcome(
      VoicePaymentStatus.cancelled,
      'Payment cancelled. The bill is still unpaid.',
    ),
  };
}
