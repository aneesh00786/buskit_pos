import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../auth/state/session_controller.dart';
import '../models/cart_sale.dart';
import '../state/cart_controller.dart';
import '../../checkout/ui/pay_modal.dart';
import '../../loyalty/models/loyalty_sale_info.dart';
import '../../loyalty/ui/loyalty_picker.dart';
import '../../voice/ui/voice_test_view.dart';
import 'cart_item_tile.dart';
import 'customer_dialog.dart';
import 'discount_override_dialog.dart';
import 'promotion_picker.dart';

/// "Current Sale": the draft sale exactly as the server computed it, with
/// quantity update, remove, clear all and hold. Every price, tax figure and
/// total comes from the API response. Pay is shown but disabled — payment is a
/// later phase.
class CartPanel extends StatefulWidget {
  const CartPanel({super.key});

  @override
  State<CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends State<CartPanel> {
  @override
  void initState() {
    super.initState();
    // Show the server's latest view whenever the cart is opened. Deferred:
    // controller methods notify synchronously, which is illegal during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<CartController>().refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final sale = cart.sale;
    final t = PosTokens.of(context);
    // Add failures are reported where the item was added and resume failures in
    // the held-sales view, so the panel never repeats them.
    final panelError =
        (cart.error != null &&
            cart.errorOperation != CartOperation.add &&
            cart.errorOperation != CartOperation.resume &&
            cart.errorOperation != CartOperation.complete &&
            cart.errorOperation != CartOperation.cancelHeld)
        ? cart.error
        : null;

    final emptyDraft =
        sale == null ||
        (sale.items.isEmpty &&
            panelError == null &&
            cart.loadError == null &&
            sale.isDraft);
    final hasItems = sale != null && sale.items.isNotEmpty;
    final serverDraftIsEmpty =
        sale != null && sale.isDraft && sale.items.isEmpty;
    final editable = (sale?.isDraft ?? true) && !cart.isMutating;

    return Container(
      decoration: t.card(),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) {
          // On short panels (small phones, sheets with a banner) drop the
          // non-essential chrome so the item list keeps its room.
          final dense = box.maxHeight < 640;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                itemCount: sale?.itemCount ?? 0,
                canClear: hasItems && editable,
                dense: dense,
              ),
              SizedBox(
                height: 4,
                child: (cart.isRefreshing || cart.isMutating)
                    ? const LinearProgressIndicator()
                    : null,
              ),
              _CustomerRow(dense: dense),
              if (sale != null && sale.isLocal)
                const _LocalCartNotice(),
              if (sale != null && !sale.isDraft)
                _NotOpenNotice(status: sale.status, onNewCart: cart.reset),
              if (panelError != null)
                _Banner(
                  message: describeApiError(panelError),
                  onDismiss: cart.clearError,
                ),
              if (cart.loadError != null)
                _Banner(
                  message: describeApiError(cart.loadError!),
                  action: cart.loadError!.isRetryable
                      ? TextButton(
                          onPressed: cart.refresh,
                          child: const Text('Retry'),
                        )
                      : null,
                  onDismiss: cart.clearError,
                ),
              if (emptyDraft) ...[
                const Expanded(
                  child: EmptyView(
                    title: 'The cart is empty',
                    icon: Icons.shopping_cart_outlined,
                  ),
                ),
                // An empty draft still exists on the server (e.g. every item
                // was removed): let the cashier discard it explicitly.
                if (serverDraftIsEmpty)
                  _DiscardOrder(disabled: cart.isMutating),
              ] else ...[
                Expanded(
                  child: sale.items.isEmpty
                      ? const EmptyView(
                          title: 'The cart is empty',
                          icon: Icons.shopping_cart_outlined,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: PosTokens.s16,
                            vertical: PosTokens.s4,
                          ),
                          itemCount: sale.items.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (_, i) {
                            final line = sale.items[i];
                            return CartItemTile(
                              key: ValueKey('line-${line.id}'),
                              line: line,
                              label: cart.labelFor(line.productVariationId),
                              imageUrl: cart.imageFor(line.productVariationId),
                              enabled: editable,
                              inFlight: cart.mutatingItemId == line.id,
                            );
                          },
                        ),
                ),
                _Totals(sale: sale, dense: dense),
                if (sale.isDraft && sale.items.isNotEmpty)
                  _Actions(disabled: cart.isMutating)
                else if (serverDraftIsEmpty)
                  _DiscardOrder(disabled: cart.isMutating),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The existing "Clear the cart?" confirmation (Clear all / Phase 14E-A F8):
/// removes every line only after the cashier confirms.
Future<void> confirmClearCart(BuildContext context) async {
    final cart = context.read<CartController>();
    final count = cart.sale?.itemCount ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear the cart?'),
        content: Text(
          'Remove all $count ${count == 1 ? 'item' : 'items'} from this sale? '
          'The sale stays open and empty.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (ok == true) await cart.clearAll();
}

class _Header extends StatelessWidget {
  const _Header({
    required this.itemCount,
    required this.canClear,
    this.dense = false,
  });
  final int itemCount;
  final bool canClear;

  /// Short panels (see CartPanel's `dense`): no top padding, so a header
  /// that had to wrap onto a second line still leaves the list its room.
  final bool dense;

  Future<void> _clear(BuildContext context) => confirmClearCart(context);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PosTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        PosTokens.s16,
        dense ? 0 : PosTokens.s8,
        PosTokens.s8,
        0,
      ),
      // Phase 16A: a Wrap, not a single Row. At normal sizes the title sits
      // left and the actions right on one line, exactly as before; when they
      // cannot share a line (small phone, large accessibility text) the
      // actions move to the next line — and the mic and "Clear all" may stack
      // — instead of overflowing and squeezing the title to nothing.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: PosTokens.s8,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
                Flexible(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Current Sale',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ),
                if (itemCount > 0) ...[
                  const SizedBox(width: PosTokens.s8),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: t.surfaceMuted,
                        borderRadius: BorderRadius.circular(PosTokens.rPill),
                      ),
                      child: Text(
                        '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                  ),
                ],
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Phase 13C-C: speak a quick bill into an EMPTY cart; Confirm
              // Bill then opens the existing checkout (showPay).
              if (itemCount == 0)
                IconButton(
                  key: const Key('cart-voice-bill'),
                  tooltip: 'Voice bill',
                  onPressed: () =>
                      startVoiceBill(context, openCheckout: showPay),
                  icon: const Icon(Icons.mic_none),
                ),
              TextButton(
                onPressed: canClear ? () => _clear(context) : null,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: const Text('Clear all'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Who the sale is for: guest checkout (default) or a customer ID. The backend
/// takes the customer only when the sale is created, so it can be changed while
/// no sale exists yet; afterwards it is shown read-only.
class _CustomerRow extends StatelessWidget {
  const _CustomerRow({this.dense = false});

  /// Short panels keep the row (the customer must stay choosable) but drop its
  /// vertical padding.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final id = cart.customerId;
    final label = cart.pendingCustomerLabel;
    final editable = cart.canChooseCustomer;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        PosTokens.s16,
        dense ? 0 : PosTokens.s4,
        PosTokens.s16,
        dense ? PosTokens.s4 : PosTokens.s8,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: PosTokens.s12),
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          color: t.surfaceMuted,
          borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
        ),
        child: Row(
          children: [
            Icon(
              Icons.person_outline,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: PosTokens.s8),
            Expanded(
              child: Text(
                id == null ? 'Guest checkout' : (label ?? 'Customer $id'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Tooltip(
              message: editable ? 'Choose the customer for this sale' : 'The customer is set when the sale starts. Void the sale to change it.',
              child: TextButton(
                onPressed: editable
                    ? () async {
                        final choice = await showCustomerDialog(
                          context,
                          current: cart.pendingCustomerId,
                        );
                        if (choice != null) {
                          cart.setPendingCustomer(
                            choice.customerId,
                            label: choice.label,
                          );
                        }
                      }
                    : null,
                child: const Text('Change'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Promotion": no promotion / an applied one (with Change/Remove) / an
/// applied-but-no-longer-eligible one (shown as a warning, not silently
/// dropped — the cart contents or the promotion itself changed since it was
/// applied). The discount shown always comes from the server.
class _PromotionRow extends StatelessWidget {
  const _PromotionRow({required this.sale});
  final CartSale sale;

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final promo = sale.promotion;
    final editable = cart.canChoosePromotion;

    if (promo == null) {
      // Phase C5: hidden only when the loaded permissions positively lack
      // promotions.apply (the backend decides either way).
      if (context.watch<SessionController>().isDenied('promotions.apply')) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: PosTokens.s8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: editable ? () => showPromotionPicker(context) : null,
            icon: const Icon(Icons.local_offer_outlined),
            label: const Text('Add Promotion'),
          ),
        ),
      );
    }

    final warning = !promo.eligible;
    return Padding(
      padding: const EdgeInsets.only(bottom: PosTokens.s8),
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s12),
        decoration: BoxDecoration(
          color: warning ? theme.colorScheme.errorContainer : t.surfaceMuted,
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_offer_outlined,
                  size: 18,
                  color: warning ? theme.colorScheme.error : t.success,
                ),
                const SizedBox(width: PosTokens.s8),
                Expanded(
                  child: Text(
                    promo.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (editable) ...[
                  TextButton(
                    onPressed: () => showPromotionPicker(context),
                    child: const Text('Change'),
                  ),
                  TextButton(
                    onPressed: cart.removePromotion,
                    child: const Text('Remove'),
                  ),
                ],
              ],
            ),
            if (warning)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  promo.message ?? 'This promotion is no longer available.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Discount": the manual override, if any. EVERY manual discount is an
/// override (`discounts.override`) — there is no "normal discount" tier in
/// this system, so the Add/Change/Remove actions are hidden entirely for a
/// staff member who lacks that permission. The discount itself (if one is
/// already applied) stays visible to everyone — it already affects the
/// total shown either way, same as promotion/loyalty above. Backend remains
/// authoritative; a missing/failed permission context never hides this
/// (SessionController.isDenied — see Refund/Cancel for the same rule).
class _DiscountOverrideRow extends StatelessWidget {
  const _DiscountOverrideRow({required this.sale});
  final CartSale sale;

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final session = context.watch<SessionController>();
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final discount = sale.discountOverride;
    final editable = cart.canChooseDiscount && !session.isDenied('discounts.override');

    if (discount == null) {
      if (!editable) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: PosTokens.s8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showDiscountOverrideDialog(context),
            icon: const Icon(Icons.percent),
            label: const Text('Add Discount'),
          ),
        ),
      );
    }

    final label = discount.discountType == 'percentage'
        ? '${formatMoney(discount.discountValue)}% off'
        : '${formatMoney(discount.discountValue)} off';
    return Padding(
      padding: const EdgeInsets.only(bottom: PosTokens.s8),
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s12),
        decoration: BoxDecoration(
          color: t.surfaceMuted,
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
        child: Row(
          children: [
            Icon(Icons.percent, size: 18, color: t.success),
            const SizedBox(width: PosTokens.s8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (editable) ...[
              TextButton(
                onPressed: () => showDiscountOverrideDialog(context, current: discount),
                child: const Text('Change'),
              ),
              TextButton(
                onPressed: cart.removeDiscountOverride,
                child: const Text('Remove'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LoyaltyRow extends StatelessWidget {
  const _LoyaltyRow({required this.sale});
  final CartSale sale;

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final loyalty = sale.loyalty;
    final editable = cart.canChooseLoyalty;

    if (loyalty == null) return const SizedBox.shrink();

    final hasRedemption =
        loyalty.pointsRedeemed > 0 || loyalty.walletRedeemed > 0;
    final hasTierDiscount = loyalty.tierDiscountAmount > 0;
    final warning = !loyalty.eligible;

    if (!hasRedemption && !hasTierDiscount && !warning) {
      if (!editable) return const SizedBox.shrink();
      // Phase C5: no redemption permission at all -> nothing to offer.
      if (context.watch<SessionController>().isDeniedAll(const ['loyalty.redeem_points', 'loyalty.redeem_wallet'])) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: PosTokens.s8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showLoyaltyPicker(context),
            icon: const Icon(Icons.stars_outlined),
            label: const Text('Redeem Loyalty'),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: PosTokens.s8),
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s12),
        decoration: BoxDecoration(
          color: warning ? theme.colorScheme.errorContainer : t.surfaceMuted,
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.stars_outlined,
                  size: 18,
                  color: warning ? theme.colorScheme.error : t.success,
                ),
                const SizedBox(width: PosTokens.s8),
                Expanded(
                  child: Text(
                    _summaryLabel(loyalty),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (editable) ...[
                  TextButton(
                    onPressed: () => showLoyaltyPicker(context),
                    child: const Text('Change'),
                  ),
                  if (hasRedemption)
                    TextButton(
                      onPressed: cart.removeLoyaltyRedemption,
                      child: const Text('Remove'),
                    ),
                ],
              ],
            ),
            if (warning)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  loyalty.message ?? 'This redemption is no longer available.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _summaryLabel(LoyaltySaleInfo l) {
    final parts = <String>[];
    if (l.tierDiscountAmount > 0 && l.tier != null) {
      parts.add('${l.tier!.name} tier: -${formatMoney(l.tierDiscountAmount)}');
    }
    if (l.pointsRedeemed > 0) {
      parts.add(
        '${l.pointsRedeemed} pts: -${formatMoney(l.pointsRedeemedValue)}',
      );
    }
    if (l.walletRedeemed > 0) {
      parts.add('Wallet: -${formatMoney(l.walletRedeemed)}');
    }
    return parts.isEmpty ? 'Loyalty' : parts.join(' · ');
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.sale, this.dense = false});
  final CartSale sale;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = sale.totals;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        PosTokens.s16,
        dense ? PosTokens.s4 : PosTokens.s8,
        PosTokens.s16,
        PosTokens.s8,
      ),
      child: Column(
        children: [
          if (!dense) _PromotionRow(sale: sale),
          if (!dense) _LoyaltyRow(sale: sale),
          if (!dense) _DiscountOverrideRow(sale: sale),
          _row(context, 'Subtotal', t.subtotal),
          _row(context, 'Tax', t.taxTotal),
          if (t.discountTotal != null && t.discountTotal! > 0)
            _row(context, 'Discount', -t.discountTotal!),
          if (!dense) const Divider(height: PosTokens.s16),
          _row(context, 'Total', t.grandTotal, big: true),
          if (sale.hasUnavailableItems)
            Padding(
              padding: const EdgeInsets.only(top: PosTokens.s8),
              child: Text(
                'Some items are unavailable and are excluded from the total.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    double? v, {
    bool big = false,
  }) {
    final theme = Theme.of(context);
    final style = big
        ? theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: PosTokens.s8),
          Flexible(
            child: Text(
              formatMoney(v),
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hold, Pay and Void. Hold puts the sale aside (resume it from the held-sales
/// list); Pay opens the payment screen; Void cancels the sale after a
/// confirmation. The server confirms each before the cart changes.
class _Actions extends StatelessWidget {
  const _Actions({required this.disabled});
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final session = context.watch<SessionController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PosTokens.s16,
        0,
        PosTokens.s16,
        PosTokens.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  // Phase C5: disabled (not hidden, to keep the Hold/Pay row
                  // stable) when the loaded permissions lack sales.hold.
                  onPressed: disabled || context.watch<SessionController>().isDenied('sales.hold')
                      ? null
                      : () => _hold(context),
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text('Hold sale'),
                  // A red, filled-looking Hold (kept an OutlinedButton so the
                  // existing finders and semantics stay valid).
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: t.danger,
                    foregroundColor: t.onDanger,
                    disabledBackgroundColor: t.danger.withValues(alpha: 0.4),
                    disabledForegroundColor: t.onDanger,
                    side: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(width: PosTokens.s12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: disabled ? null : () => showPay(context),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Pay'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: t.success,
                    foregroundColor: t.onSuccess,
                    disabledBackgroundColor: t.success.withValues(alpha: 0.35),
                    disabledForegroundColor: t.onSuccess,
                  ),
                ),
              ),
            ],
          ),
          // Hidden (not just disabled) once the loaded permission context
          // positively lacks sales.cancel — a missing/failed context leaves
          // it visible, deferring to the backend's own 403. See
          // SessionController.isDenied.
          if (!session.isDenied('sales.cancel'))
            TextButton.icon(
              onPressed: disabled ? null : () => _void(context),
              icon: const Icon(Icons.block),
              label: const Text('Void sale'),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _hold(BuildContext context) async {
    final cart = context.read<CartController>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await cart.holdCurrent();
    if (ok && cart.lastHeldSaleId != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Sale #${cart.lastHeldSaleId} is on hold. Resume it from Held sales.',
          ),
        ),
      );
    }
  }

  Future<void> _void(BuildContext context) async {
    final cart = context.read<CartController>();
    final messenger = ScaffoldMessenger.of(context);
    final id = cart.sale?.id;
    final ok = await confirmVoid(context, subject: 'this sale');
    if (ok != true) return;
    if (await cart.cancelCurrent() && id != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Sale #$id voided')));
    }
  }
}

/// "Discard order" for a draft with no items (the Void sale action needs items).
class _DiscardOrder extends StatelessWidget {
  const _DiscardOrder({required this.disabled});
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    if (session.isDenied('sales.cancel')) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PosTokens.s16,
        0,
        PosTokens.s16,
        PosTokens.s8,
      ),
      child: TextButton.icon(
        onPressed: disabled ? null : () => _discard(context),
        icon: const Icon(Icons.delete_outline),
        label: const Text('Discard order'),
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  Future<void> _discard(BuildContext context) async {
    final cart = context.read<CartController>();
    final messenger = ScaffoldMessenger.of(context);
    final id = cart.sale?.id;
    final ok = await confirmVoid(
      context,
      subject: 'this empty order',
      title: 'Discard this order?',
      keepLabel: 'Keep order',
      confirmLabel: 'Discard order',
    );
    if (ok != true) return;
    if (await cart.cancelCurrent() && id != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Order #$id discarded')));
    }
  }
}

/// Confirmation before voiding: cancelling cannot be undone.
Future<bool?> confirmVoid(
  BuildContext context, {
  required String subject,
  String title = 'Void this sale?',
  String keepLabel = 'Keep sale',
  String confirmLabel = 'Void sale',
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(
        'This cancels $subject on the server. It cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(keepLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, this.action, this.onDismiss});
  final String message;
  final Widget? action;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(
          PosTokens.s12,
          PosTokens.s4,
          PosTokens.s12,
          0,
        ),
        padding: const EdgeInsets.fromLTRB(
          PosTokens.s12,
          PosTokens.s8,
          4,
          PosTokens.s8,
        ),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            ?action,
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onDismiss,
                icon: Icon(Icons.close, color: scheme.onErrorContainer),
              ),
          ],
        ),
      ),
    );
  }
}

class _NotOpenNotice extends StatelessWidget {
  const _NotOpenNotice({required this.status, required this.onNewCart});
  final String status;
  final VoidCallback onNewCart;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      PosTokens.s16,
      PosTokens.s4,
      PosTokens.s16,
      0,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'This cart is no longer open ($status) and cannot be edited.',
          ),
        ),
        TextButton(onPressed: onNewCart, child: const Text('New cart')),
      ],
    ),
  );
}

/// Shown on a cart built while offline: it lives on this device only and is
/// recorded locally when paid (never sent to the server in this phase).
class _LocalCartNotice extends StatelessWidget {
  const _LocalCartNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PosTokens.s16,
        0,
        PosTokens.s16,
        PosTokens.s8,
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: PosTokens.s8),
          Expanded(
            child: Text(
              'Offline sale — prices from this device. It will be saved on '
              'this device when paid.',
              key: const Key('local-cart-notice'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
