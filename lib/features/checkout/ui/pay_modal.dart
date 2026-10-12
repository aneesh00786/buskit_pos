import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/json_read.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../../cart/state/cart_controller.dart';
import '../../cart/ui/cart_panel.dart' show confirmVoid;
import '../../offline/offline_payment_policy.dart';
import '../../offline/ui/offline_sale_views.dart';
import '../../receipt/models/receipt_formatter.dart';
import '../../receipt/state/receipt_services.dart';
import '../../receipt/ui/cash_drawer_auto_open.dart';
import '../../receipt/ui/receipt_actions.dart';
import '../data/payment_terminal_service.dart';
import '../models/payment.dart';
import '../models/terminal_payment.dart';
import '../state/payment_plan.dart';
import 'qr_payment_dialog.dart';
import 'terminal_payment_dialog.dart';
import '../../../core/ui/safe_insets.dart';
import '../../../core/desktop/exit_guard.dart';

/// Opens the payment screen for the open sale: a dialog on tablets, a tall
/// bottom sheet on phones. It cannot be dismissed by tapping outside (that
/// could hide a completed sale or an in-flight payment); use its buttons.
Future<void> showPay(BuildContext context) {
  final cart = context.read<CartController>();
  cart.acknowledgeCompletion(); // a fresh checkout never re-shows an old receipt
  cart.acknowledgeOfflineCompletion();
  cart.clearError();
  final size = MediaQuery.sizeOf(context);
  final session = context.read<SessionController>();
  final receipts = context.read<ReceiptServices>();
  Widget content() => MultiProvider(
    providers: [
      ChangeNotifierProvider<CartController>.value(value: cart),
      ChangeNotifierProvider<SessionController>.value(value: session),
      Provider<ReceiptServices>.value(value: receipts),
    ],
    child: const PayModal(),
  );

  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: size.height * 0.92,
          ),
          child: content(),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => SizedBox(
      height: size.height * 0.95,
      child: SheetSafeArea(child: content()),
    ),
  );
}

/// Wording for checkout failures, with product names where the server sent ids.
String describeCheckoutError(ApiException e, Map<int, String> names) {
  String nameOf(Object? id) => names[asInt(id)] ?? 'an item';
  switch (e.errorCode) {
    case PosErrorCodes.insufficientStock:
      final shortages = asList(e.dataMap?['shortages'])
          .map(asMap)
          .whereType<Map<String, dynamic>>();
      final parts = [
        for (final s in shortages)
          '${nameOf(s['item_id'])} (${formatQty(asDouble(s['requested']))} requested, ${formatQty(asDouble(s['available']))} available)',
      ];
      if (parts.isNotEmpty) {
        return 'Not enough stock: ${parts.join('; ')}. Adjust the cart and try again.';
      }
      return 'Not enough stock to complete this sale.';
    case PosErrorCodes.weightUnitNotSupported:
      final ids = asList(e.dataMap?['weight_unit_item_ids']);
      final list = ids.isEmpty ? '' : ' (${ids.map(nameOf).join(', ')})';
      return 'This sale has products sold by weight or volume$list, which cannot be sold at the POS yet. '
          'Remove them from the cart and try again.';
  }
  return describeApiError(e);
}

class PayModal extends StatefulWidget {
  const PayModal({super.key});

  @override
  State<PayModal> createState() => _PayModalState();
}

class _PayModalState extends State<PayModal> {
  PayMode _mode = PayMode.cash;

  /// Tender modes this staff member may use (Phase C5). Mirrors the backend's
  /// method -> permission map (services/pos/posPaymentPermissions.js): cash
  /// needs payments.accept_cash, card payments.accept_card, other
  /// payments.accept_other (generic, country-independent — migration 023).
  /// Hidden only when the loaded permissions positively deny — the backend
  /// still decides at completion.
  List<PayMode> _availableModes(BuildContext context) {
    final session = context.watch<SessionController>();
    final cash = !session.isDenied('payments.accept_cash');
    final card = !session.isDenied('payments.accept_card');
    final other = !session.isDenied('payments.accept_other');
    return [
      if (cash) PayMode.cash,
      if (card) PayMode.card,
      if (other) PayMode.other,
      if (cash && (card || other)) PayMode.split,
    ];
  }

  TenderMethod _secondary = TenderMethod.card;

  /// Card-terminal integration (optional): present only when the app wires a
  /// [PaymentTerminalService] and the server reports a provider with a
  /// terminal configured for THIS register. Otherwise card stays
  /// recorded-only, exactly as before.
  PaymentTerminalService? _terminalService;

  /// Server reachability (the API client's): provider payments (terminal,
  /// UPI QR) need the server and the provider, so they are blocked while it
  /// is unreachable — never simulated offline.
  ValueListenable<bool?>? _reachable;
  // A local (offline) cart has no server sale, so provider payments are
  // impossible for it even if the connection has come back.
  bool get _offline =>
      _reachable?.value == false || context.read<CartController>().isLocalSale;
  PaymentProviderInfo? _terminal;

  /// UPI / QR provider (tendered as "other"), when the server offers one.
  PaymentProviderInfo? _qr;
  bool _providersRequested = false;

  /// Phase 15G: a terminal payment is being started / is on screen — a
  /// second "Pay on terminal" tap is ignored (one terminal transaction).
  bool _terminalInProgress = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_providersRequested) return;
    _providersRequested = true;
    try {
      _reachable = Provider.of<PosApiClient?>(
        context,
        listen: false,
      )?.reachable;
    } on ProviderNotFoundException {
      _reachable = null;
    }
    try {
      _terminalService = Provider.of<PaymentTerminalService>(
        context,
        listen: false,
      );
    } on ProviderNotFoundException {
      _terminalService = null;
    }
    final service = _terminalService;
    if (service == null) return;
    service
        .listProviders()
        .then((providers) {
          if (!mounted) return;
          final usable = providers
              .where((p) => p.isUsableCardTerminal)
              .toList();
          final qr = providers.where((p) => p.isUsableQr).toList();
          setState(() {
            _terminal = usable.isEmpty ? null : usable.first;
            _qr = qr.isEmpty ? null : qr.first;
          });
        })
        .catchError((Object _) {
          // No provider list -> no terminal button; manual card still works.
        });
  }

  void _showOnlineRequired() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text(OfflinePaymentPolicy.onlineRequiredMessage)),
    );
  }

  /// Phase 6: a local reminder (the sale id only) BEFORE a provider payment
  /// starts, so a restart mid-payment is recovered from the server instead
  /// of starting a new sale. Best-effort: recovery also finds this device's
  /// drafts without it.
  Future<void> _rememberForRecovery(int saleId) async {
    try {
      await readOfflineServices(context)?.storage
          .addPaymentRecoveryMarker(saleId);
    } catch (_) {}
  }

  Future<void> _payOnTerminal(CartController cart, int totalMilli) async {
    if (_offline) return _showOnlineRequired();
    if (_terminalInProgress) return;
    final service = _terminalService;
    final provider = _terminal;
    final sale = cart.sale;
    if (service == null || provider == null || sale == null) return;
    setState(() => _terminalInProgress = true);
    final PaymentAttempt? attempt;
    try {
      await _rememberForRecovery(sale.id);
      if (!mounted) return;
      // Phase 6ZA: a terminal payment in progress blocks quitting the desktop app.
      attempt = await InFlightOperations.track(() => showTerminalPayment(
        context,
        service: service,
        saleId: sale.id,
        provider: provider,
        amountMilli: totalMilli,
      ));
    } finally {
      if (mounted) setState(() => _terminalInProgress = false);
    }
    if (attempt == null || !mounted) return;
    // The server re-verifies the captured attempt (sale, amount, method).
    await cart.completeSale([
      PaymentLine(
        method: TenderMethod.card,
        amountMilli: totalMilli,
        paymentAttemptId: attempt.id,
      ),
    ]);
  }

  Future<void> _payByQr(CartController cart, int totalMilli) async {
    if (_offline) return _showOnlineRequired();
    final service = _terminalService;
    final provider = _qr;
    final sale = cart.sale;
    if (service == null || provider == null || sale == null) return;
    await _rememberForRecovery(sale.id);
    if (!mounted) return;
    // Phase 6ZA: a QR payment in progress blocks quitting the desktop app.
    final attempt = await InFlightOperations.track(() => showQrPayment(
      context,
      service: service,
      saleId: sale.id,
      provider: provider,
      amountMilli: totalMilli,
      currencyLabel: provider.currencies.length == 1
          ? provider.currencies.first
          : '',
    ));
    if (attempt == null || !mounted) return;
    // QR is tendered as "other"; the server re-verifies the captured attempt.
    await cart.completeSale([
      PaymentLine(
        method: TenderMethod.other,
        amountMilli: totalMilli,
        paymentAttemptId: attempt.id,
      ),
    ]);
  }

  final _tendered = TextEditingController();
  final _cashApplied = TextEditingController();
  final _cashReceived = TextEditingController();
  final _reference = TextEditingController();

  @override
  void dispose() {
    _tendered.dispose();
    _cashApplied.dispose();
    _cashReceived.dispose();
    _reference.dispose();
    super.dispose();
  }

  /// Wallet redemption doesn't change the sale total — it's a payment-tender
  /// substitute, not a discount (see CartSale.loyalty) — so it reduces what
  /// cash/card/other must cover here, while the receipt/success view still
  /// shows the full sale total.
  int _walletMilli(CartController cart) =>
      milliFromDouble(cart.sale?.loyalty?.walletRedeemed ?? 0);

  int _totalMilli(CartController cart) =>
      milliFromDouble(cart.sale?.totals.grandTotal ?? 0) - _walletMilli(cart);

  PaymentPlan _plan(CartController cart) {
    final total = _totalMilli(cart);
    switch (_mode) {
      case PayMode.cash:
        return PaymentPlan(
          totalMilli: total,
          mode: _mode,
          cashReceivedMilli: parseMilli(_tendered.text),
        );
      case PayMode.card:
      case PayMode.other:
        return PaymentPlan(
          totalMilli: total,
          mode: _mode,
          reference: _reference.text,
        );
      case PayMode.split:
        final applied = parseMilli(_cashApplied.text);
        final receivedText = _cashReceived.text.trim();
        return PaymentPlan(
          totalMilli: total,
          mode: _mode,
          cashAppliedMilli: applied,
          cashReceivedMilli: receivedText.isEmpty
              ? applied
              : parseMilli(receivedText),
          secondary: _secondary,
          reference: _reference.text,
        );
    }
  }

  /// Phase 6ZC: desktop keyboard tills (macOS / Windows / Linux) only; the
  /// phone and tablet behaviour (no autofocus, no Enter action) is unchanged.
  static bool get _desktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// Enter in the amount field: does exactly what the Complete Sale button
  /// does, and only when that button would be enabled (not busy, a valid
  /// tender, not a draft already recorded offline — Phase 6S).
  void _completeFromKeyboard() {
    final cart = context.read<CartController>();
    if (cart.isMutating || cart.draftSyncedOffline) return;
    if (!_plan(cart).isValid) return;
    _complete(cart);
  }

  Future<void> _complete(CartController cart) async {
    final plan = _plan(cart);
    if (!plan.isValid) return;
    await cart.completeSale(plan.payments);
  }

  /// Phase 6S: the draft's cart is already a synced offline sale. Cancel the
  /// duplicate draft (existing void flow) only after the cashier confirms;
  /// the offline sale itself is never touched.
  Future<void> _cancelDuplicateDraft(CartController cart) async {
    final id = cart.sale?.id;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await confirmVoid(
      context,
      subject: 'this duplicate online draft (the offline sale already recorded is kept)',
      title: 'Cancel the duplicate draft?',
      keepLabel: 'Keep draft',
      confirmLabel: 'Cancel draft',
    );
    if (ok != true || !mounted) return;
    if (await cart.cancelDuplicateDraft()) {
      navigator.pop();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Duplicate draft${id == null ? '' : ' #$id'} cancelled. The offline sale already recorded is unchanged.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Never sit on a tender this staff member may not use (Phase C5).
    final available = _availableModes(context);
    if (available.isNotEmpty && !available.contains(_mode)) _mode = available.first;
    final sessionForTender = context.watch<SessionController>();
    if (_secondary == TenderMethod.card &&
        sessionForTender.isDenied('payments.accept_card')) {
      _secondary = TenderMethod.other;
    } else if (_secondary == TenderMethod.other &&
        sessionForTender.isDenied('payments.accept_other')) {
      _secondary = TenderMethod.card;
    }
    final cart = context.watch<CartController>();
    final done = cart.completedSale;
    if (done != null) {
      return _SuccessView(
        sale: done,
        names: cart.completedNames,
        variants: cart.completedVariants,
      );
    }

    final savedOffline = cart.completedOfflineSale;
    if (savedOffline != null) {
      void newSale() {
        cart.acknowledgeOfflineCompletion();
        Navigator.of(context).pop();
      }

      return _Shell(
        title: 'Sale saved offline',
        onClose: newSale,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Phase 14A: an offline CASH sale is complete on this device.
            CashDrawerAutoOpen(
              saleKey: 'local:${savedOffline.localSaleId}',
              tookCash: savedOffline.payments.any(
                (p) => p.method == 'cash' && p.amountMilli > 0,
              ),
            ),
            Expanded(
              child: OfflineSaleSavedView(sale: savedOffline, onNewSale: newSale),
            ),
          ],
        ),
      );
    }

    final sale = cart.sale;
    if (sale == null) {
      // The sale disappeared (voided elsewhere, session reset): nothing to pay.
      return _Shell(
        title: 'Take payment',
        onClose: () => Navigator.of(context).pop(),
        child: const Center(child: Text('There is no open sale.')),
      );
    }

    final plan = _plan(cart);
    final total = _totalMilli(cart);
    final busy = cart.isMutating;
    final duplicateDraft = cart.draftSyncedOffline;
    final failure =
        (cart.error != null &&
            (cart.errorOperation == CartOperation.complete ||
                (duplicateDraft && cart.errorOperation == CartOperation.cancel)))
        ? cart.error
        : null;
    final names = {
      for (final l in sale.items)
        l.id: l.productName ?? 'Item ${l.productVariationId}',
    };
    final retrying =
        !duplicateDraft &&
        cart.hasPendingCompletion &&
        failure != null &&
        cart.errorOperation == CartOperation.complete &&
        failure.isRetryable;

    return _Shell(
      title: 'Take payment',
      onClose: busy ? null : () => Navigator.of(context).pop(),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Always visible next to the button (the form above can scroll).
          if (plan.problem != null && _touched)
            Padding(
              padding: const EdgeInsets.only(bottom: PosTokens.s8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  plan.problem!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: PosTokens.s12),
              Expanded(
                flex: 2,
                child: duplicateDraft
                    ? FilledButton(
                        key: const Key('cancel-duplicate-draft'),
                        onPressed: busy ? null : () => _cancelDuplicateDraft(cart),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(context).colorScheme.onError,
                        ),
                        child: busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Cancel duplicate draft'),
                      )
                    : FilledButton(
                  onPressed: (!busy && plan.isValid)
                      ? () => _complete(cart)
                      : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: PosTokens.of(context).success,
                    foregroundColor: PosTokens.of(context).onSuccess,
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(retrying ? 'Retry payment' : 'Complete Sale'),
                ),
              ),
            ],
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.all(PosTokens.s16),
        children: [
          _AmountDue(totalMilli: total),
          if (_walletMilli(cart) > 0)
            Padding(
              padding: const EdgeInsets.only(top: PosTokens.s8),
              child: _KeyValue(
                label: 'Wallet applied',
                value: '-${formatMilli(_walletMilli(cart))}',
              ),
            ),
          ValueListenableBuilder<bool?>(
            valueListenable: _reachable ?? ValueNotifier<bool?>(null),
            builder: (context, _, _) => cart.willCompleteOffline
                ? Padding(
                    padding: const EdgeInsets.only(top: PosTokens.s8),
                    child: Text(
                      'Offline — this sale will be saved on this device. '
                      'It is not synced with the server yet.',
                      key: const Key('offline-checkout-note'),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: PosTokens.s12),
          if (failure != null) ...[
            _Failure(
              message: describeCheckoutError(failure, names),
              retrying: retrying,
            ),
            const SizedBox(height: PosTokens.s12),
          ],
          _ModePicker(
            mode: _mode,
            available: _availableModes(context),
            enabled: !busy,
            onChanged: (m) => setState(() => _mode = m),
          ),
          const SizedBox(height: PosTokens.s16),
          if ((_mode == PayMode.card && _terminal != null) ||
              (_mode == PayMode.other && _qr != null))
            ValueListenableBuilder<bool?>(
              valueListenable: _reachable ?? ValueNotifier<bool?>(null),
              builder: (context, reachable, _) {
                final offline = reachable == false || cart.isLocalSale;
                return Padding(
                  padding: const EdgeInsets.only(bottom: PosTokens.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_mode == PayMode.card)
                        _TerminalPayPanel(
                          provider: _terminal!,
                          enabled:
                              !busy &&
                              total > 0 &&
                              !offline &&
                              !_terminalInProgress,
                          onPressed: () => _payOnTerminal(cart, total),
                        )
                      else
                        _QrPayPanel(
                          provider: _qr!,
                          enabled: !busy && total > 0 && !offline,
                          onPressed: () => _payByQr(cart, total),
                        ),
                      if (offline)
                        Padding(
                          padding: const EdgeInsets.only(top: PosTokens.s8),
                          child: Text(
                            OfflinePaymentPolicy.onlineRequiredMessage,
                            key: const Key('online-required'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ..._modeBody(total, plan, busy),
        ],
      ),
    );
  }

  bool get _touched =>
      _tendered.text.isNotEmpty ||
      _cashApplied.text.isNotEmpty ||
      _cashReceived.text.isNotEmpty;

  List<Widget> _modeBody(int total, PaymentPlan plan, bool busy) {
    switch (_mode) {
      case PayMode.cash:
        return [
          _MoneyField(
            controller: _tendered,
            label: 'Amount tendered',
            enabled: !busy,
            onChanged: () => setState(() {}),
            // Phase 6ZC: a keyboard till types the amount straight away and
            // presses Enter — exactly the Complete Sale button (same guards).
            autofocus: _desktop,
            onSubmitted: _desktop ? _completeFromKeyboard : null,
          ),
          const SizedBox(height: PosTokens.s8),
          _QuickCash(
            dueMilli: total,
            enabled: !busy,
            onPick: (m) => setState(() => _tendered.text = formatMilli(m)),
          ),
          const SizedBox(height: PosTokens.s12),
          _ChangeRow(plan: plan, hasInput: _tendered.text.isNotEmpty),
        ];
      case PayMode.card:
      case PayMode.other:
        return [
          _RecordedOnlyNote(mode: _mode),
          const SizedBox(height: PosTokens.s12),
          _ReferenceField(
            controller: _reference,
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
        ];
      case PayMode.split:
        return [
          Text('Cash portion', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: PosTokens.s8),
          _MoneyField(
            controller: _cashApplied,
            label: 'Cash amount',
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: PosTokens.s8),
          _MoneyField(
            controller: _cashReceived,
            label: 'Cash received (optional, if more than the amount)',
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: PosTokens.s8),
          _QuickCash(
            dueMilli: plan.cashAppliedMilli ?? 0,
            enabled: !busy && plan.cashAppliedMilli != null,
            onPick: (m) => setState(() => _cashReceived.text = formatMilli(m)),
          ),
          const SizedBox(height: PosTokens.s16),
          Text(
            'Remaining balance',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: PosTokens.s8),
          SegmentedButton<TenderMethod>(
            segments: [
              if (!context.watch<SessionController>().isDenied(
                'payments.accept_card',
              ))
                const ButtonSegment(
                  value: TenderMethod.card,
                  label: Text('Card'),
                  icon: Icon(Icons.credit_card),
                ),
              if (!context.watch<SessionController>().isDenied(
                'payments.accept_other',
              ))
                const ButtonSegment(
                  value: TenderMethod.other,
                  label: Text('Other'),
                  icon: Icon(Icons.more_horiz),
                ),
            ],
            selected: {_secondary},
            onSelectionChanged: busy
                ? null
                : (s) => setState(() => _secondary = s.first),
          ),
          const SizedBox(height: PosTokens.s8),
          _KeyValue(
            label: '${_secondary.label} pays',
            value: plan.cashAppliedMilli == null || plan.remainderMilli <= 0
                ? '—'
                : formatMilli(plan.remainderMilli),
            bold: true,
          ),
          const SizedBox(height: PosTokens.s8),
          const _RecordedOnlyNote(mode: PayMode.card),
          const SizedBox(height: PosTokens.s8),
          _ReferenceField(
            controller: _reference,
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: PosTokens.s12),
          _ChangeRow(plan: plan, hasInput: _cashApplied.text.isNotEmpty),
        ];
    }
  }
}

class _Shell extends StatelessWidget {
  const _Shell({
    required this.title,
    required this.child,
    this.footer,
    this.onClose,
  });
  final String title;
  final Widget child;
  final Widget? footer;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PosTokens.s16,
            PosTokens.s8,
            PosTokens.s8,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(child: child),
        if (footer != null) ...[
          const Divider(),
          Padding(padding: const EdgeInsets.all(PosTokens.s16), child: footer),
        ],
      ],
    );
  }
}

class _AmountDue extends StatelessWidget {
  const _AmountDue({required this.totalMilli});
  final int totalMilli;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: 'Amount due ${formatMilli(totalMilli)}',
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: t.heroGradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(PosTokens.rCard),
        ),
        // Wraps (rather than clipping the amount) when text is very large.
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: PosTokens.s8,
          children: [
            Text(
              'Amount due',
              style: text.titleMedium?.copyWith(color: Colors.white),
            ),
            Text(
              formatMilli(totalMilli),
              style: text.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModePicker extends StatelessWidget {
  const _ModePicker({
    required this.mode,
    required this.available,
    required this.enabled,
    required this.onChanged,
  });
  final PayMode mode;
  final List<PayMode> available;
  final bool enabled;
  final ValueChanged<PayMode> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = {
      PayMode.cash: 'Cash',
      PayMode.card: 'Card',
      PayMode.other: 'Other',
      PayMode.split: 'Split',
    };
    return Wrap(
      spacing: PosTokens.s8,
      runSpacing: PosTokens.s8,
      children: [
        for (final m in available)
          ChoiceChip(
            label: Text(labels[m]!),
            selected: mode == m,
            showCheckmark: false,
            onSelected: enabled ? (_) => onChanged(m) : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
      ],
    );
  }
}

class _MoneyField extends StatelessWidget {
  const _MoneyField({
    required this.controller,
    required this.label,
    required this.onChanged,
    this.enabled = true,
    this.autofocus = false,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;
  final bool enabled;

  /// Phase 6ZC: focused when the payment screen opens (desktop keyboard tills).
  final bool autofocus;

  /// Phase 6ZC: Enter in the field (desktop keyboard tills).
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,3}')),
      ],
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => onChanged(),
      autofocus: autofocus,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
    );
  }
}

class _ReferenceField extends StatelessWidget {
  const _ReferenceField({
    required this.controller,
    required this.onChanged,
    this.enabled = true,
  });
  final TextEditingController controller;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      maxLength: PaymentPlan.maxReferenceLength,
      decoration: const InputDecoration(
        labelText: 'Reference (optional)',
        counterText: '',
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

class _QuickCash extends StatelessWidget {
  const _QuickCash({
    required this.dueMilli,
    required this.onPick,
    this.enabled = true,
  });
  final int dueMilli;
  final ValueChanged<int> onPick;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final amounts = PaymentPlan.quickCash(dueMilli);
    return Wrap(
      spacing: PosTokens.s8,
      runSpacing: PosTokens.s8,
      children: [
        OutlinedButton(
          onPressed: enabled ? () => onPick(dueMilli) : null,
          style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
          child: const Text('Exact'),
        ),
        for (final a in amounts)
          OutlinedButton(
            onPressed: enabled ? () => onPick(a) : null,
            style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
            child: Text(formatMilli(a).replaceAll(RegExp(r'\.00$'), '')),
          ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.plan, required this.hasInput});
  final PaymentPlan plan;
  final bool hasInput;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PosTokens.of(context);
    final short = plan.shortByMilli;
    final showShort = hasInput && short > 0;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s12),
        decoration: BoxDecoration(
          color: t.surfaceMuted,
          borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                showShort ? 'Short by' : 'Change due',
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: PosTokens.s8),
            Flexible(
              child: Text(
                showShort
                    ? formatMilli(short)
                    : formatMilli(plan.changeDueMilli),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: showShort ? theme.colorScheme.error : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalPayPanel extends StatelessWidget {
  const _TerminalPayPanel({
    required this.provider,
    required this.enabled,
    required this.onPressed,
  });
  final PaymentProviderInfo provider;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const Key('pay-on-terminal'),
          onPressed: enabled ? onPressed : null,
          icon: const Icon(Icons.point_of_sale),
          label: Text(
            'Pay on terminal (${provider.terminalName ?? provider.label})',
          ),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: PosTokens.s8),
        Text(
          'Or record a card payment taken on another terminal:',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _QrPayPanel extends StatelessWidget {
  const _QrPayPanel({
    required this.provider,
    required this.enabled,
    required this.onPressed,
  });
  final PaymentProviderInfo provider;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const Key('pay-by-qr'),
          onPressed: enabled ? onPressed : null,
          icon: const Icon(Icons.qr_code_2),
          label: Text('UPI QR (${provider.label})'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: PosTokens.s8),
        Text(
          'Or record another payment taken outside the POS:',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _RecordedOnlyNote extends StatelessWidget {
  const _RecordedOnlyNote({required this.mode});
  final PayMode mode;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: PosTokens.s8),
        Expanded(
          child: Text(
            'Recorded only — no card terminal is connected. Take the payment on your terminal, '
            'then enter its reference below.',
            style: text.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({
    required this.label,
    required this.value,
    this.bold = false,
  });
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.retrying});
  final String message;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            if (retrying)
              Padding(
                padding: const EdgeInsets.only(top: PosTokens.s8),
                child: Text(
                  'It is safe to retry: the same request key is sent again, so the customer is never charged twice.',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- success

class _SuccessView extends StatelessWidget {
  const _SuccessView({
    required this.sale,
    required this.names,
    required this.variants,
  });
  final CompletedSale sale;
  final Map<int, String> names;
  final Map<int, String> variants;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final when = sale.completedAt;
    final change = sale.changeDue;
    final session = context.read<SessionController>();

    return _Shell(
      title: 'Sale complete',
      onClose: () => _newSale(context),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: () => _newSale(context),
            icon: const Icon(Icons.add_shopping_cart),
            label: const Text('New Sale'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: t.success,
              foregroundColor: t.onSuccess,
            ),
          ),
          const SizedBox(height: PosTokens.s8),
          // Phase 14A: the sale is confirmed complete here — open the cash
          // drawer once if it took cash (never for card / QR / other only).
          CashDrawerAutoOpen(
            saleKey: 'sale:${sale.id}',
            tookCash: sale.payments.any(
              (p) => p.method == 'cash' && (p.amount ?? 0) > 0,
            ),
          ),
          ReceiptActions(
            // Phase 14B: auto-print once (if turned on) — completed sales only.
            autoPrintKey: 'sale:${sale.id}',
            receipt: ReceiptFormatter.build(
              sale: sale,
              names: names,
              variants: variants,
              staffId: session.salesmanId,
              deviceId: session.deviceIdentifier,
            ),
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.all(PosTokens.s16),
        children: [
          Center(child: Icon(Icons.check_circle, size: 56, color: t.success)),
          const SizedBox(height: PosTokens.s8),
          Center(
            child: Text('Payment received', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: PosTokens.s16),
          _KeyValue(label: 'Order', value: sale.displayNumber, bold: true),
          if (when != null)
            _KeyValue(label: 'Date / time', value: formatTimestamp(when)),
          if (sale.customerId != null)
            _KeyValue(label: 'Customer', value: sale.customerId!)
          else
            const _KeyValue(label: 'Customer', value: 'Guest checkout'),
          const Divider(height: PosTokens.s24),
          Text('Items', style: theme.textTheme.titleSmall),
          const SizedBox(height: PosTokens.s4),
          for (final line in sale.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          names[line.id] ?? 'Item ${line.productVariationId}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${line.quantityText} × ${formatMoney(line.unitPrice)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: PosTokens.s8),
                  Text(formatMoney(line.lineTotal)),
                ],
              ),
            ),
          const Divider(height: PosTokens.s24),
          _KeyValue(
            label: 'Subtotal',
            value: formatMoney(sale.totals.subtotal),
          ),
          _KeyValue(label: 'Tax', value: formatMoney(sale.totals.taxTotal)),
          if (sale.totals.discountTotal != null &&
              sale.totals.discountTotal != 0)
            _KeyValue(
              label: sale.promotion?.title ?? 'Discount',
              value: '-${formatMoney(sale.totals.discountTotal)}',
            ),
          _KeyValue(
            label: 'Total',
            value: formatMoney(sale.totals.grandTotal),
            bold: true,
          ),
          if (sale.loyalty != null) ...[
            const Divider(height: PosTokens.s24),
            Text('Loyalty', style: theme.textTheme.titleSmall),
            const SizedBox(height: PosTokens.s4),
            if (sale.loyalty!.walletRedeemed > 0)
              _KeyValue(
                label: 'Wallet redeemed',
                value: '-${formatMoney(sale.loyalty!.walletRedeemed)}',
              ),
            if (sale.loyalty!.pointsEarned > 0)
              _KeyValue(
                label: 'Points earned',
                value: '+${formatQty(sale.loyalty!.pointsEarned)}',
              ),
            if (sale.loyalty!.cashbackEarned > 0)
              _KeyValue(
                label: 'Cashback earned',
                value: '+${formatMoney(sale.loyalty!.cashbackEarned)}',
              ),
          ],
          const Divider(height: PosTokens.s24),
          Text('Payment', style: theme.textTheme.titleSmall),
          const SizedBox(height: PosTokens.s4),
          for (final p in sale.payments) ...[
            _KeyValue(
              label: _methodLabel(p.method),
              value: formatMoney(p.amount),
            ),
            if (p.tendered != null)
              _KeyValue(label: '  Tendered', value: formatMoney(p.tendered)),
            if ((p.changeDue ?? 0) > 0)
              _KeyValue(label: '  Change', value: formatMoney(p.changeDue)),
          ],
          if (change > 0) ...[
            const SizedBox(height: PosTokens.s8),
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.all(PosTokens.s12),
                decoration: BoxDecoration(
                  color: t.surfaceMuted,
                  borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Change due', style: theme.textTheme.titleMedium),
                    Text(
                      formatMoney(change),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _methodLabel(String wire) =>
      TenderMethod.fromWire(wire)?.label ?? wire;

  void _newSale(BuildContext context) {
    context.read<CartController>().acknowledgeCompletion();
    Navigator.of(context).pop();
  }
}
