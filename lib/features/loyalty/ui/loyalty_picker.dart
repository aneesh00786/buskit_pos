import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../cart/state/cart_controller.dart';
import '../../../core/ui/safe_insets.dart';

/// "Redeem Points" / "Use Wallet": reads the sale's already-computed loyalty
/// state (`CartController.sale!.loyalty` — the same live figures the draft
/// view carries, no separate fetch needed) and submits a requested amount.
/// The server recalculates and validates everything; nothing here decides
/// the final discount/redemption value.
Future<void> showLoyaltyPicker(BuildContext context) {
  final cart = context.read<CartController>();
  if (cart.sale == null) return Future<void>.value();

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider<CartController>.value(
      value: cart,
      child: const SheetSafeArea(child: _LoyaltyPicker()),
    ),
  );
}

class _LoyaltyPicker extends StatefulWidget {
  const _LoyaltyPicker();

  @override
  State<_LoyaltyPicker> createState() => _LoyaltyPickerState();
}

class _LoyaltyPickerState extends State<_LoyaltyPicker> {
  final _pointsController = TextEditingController();
  final _walletController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final loyalty = context.read<CartController>().sale?.loyalty;
    if (loyalty != null) {
      if (loyalty.pointsRedeemed > 0) {
        _pointsController.text = '${loyalty.pointsRedeemed}';
      }
      if (loyalty.walletRedeemed > 0) {
        _walletController.text = formatMoney(loyalty.walletRedeemed);
      }
    }
  }

  @override
  void dispose() {
    _pointsController.dispose();
    _walletController.dispose();
    super.dispose();
  }

  Future<void> _applyPoints(CartController cart) async {
    final points = int.tryParse(_pointsController.text.trim()) ?? 0;
    await cart.redeemLoyaltyPoints(points);
  }

  Future<void> _applyWallet(CartController cart) async {
    final amount = double.tryParse(_walletController.text.trim()) ?? 0;
    await cart.redeemLoyaltyWallet(amount);
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final loyalty = cart.sale?.loyalty;
    final busy = cart.isMutating;
    final showError =
        cart.errorOperation == CartOperation.loyalty && cart.error != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Loyalty',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (loyalty == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Loyalty is not available for this sale.',
                    textAlign: TextAlign.center,
                  ),
                )
              else ...[
                if (loyalty.tier != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: PosTokens.s8),
                    child: Text(
                      '${loyalty.tier!.name} member',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                if (showError)
                  Padding(
                    padding: const EdgeInsets.only(bottom: PosTokens.s12),
                    child: Text(
                      describeApiError(cart.error!),
                      style: TextStyle(color: PosTokens.of(context).danger),
                    ),
                  ),
                _LoyaltySection(
                  title: 'Redeem Points',
                  subtitle:
                      'Available: ${formatQty(loyalty.pointsBalance ?? 0)} points',
                  controller: _pointsController,
                  keyboardType: TextInputType.number,
                  label: 'Points to redeem',
                  busy: busy,
                  onApply: () => _applyPoints(cart),
                ),
                const SizedBox(height: PosTokens.s16),
                _LoyaltySection(
                  title: 'Use Wallet',
                  subtitle:
                      'Available: ${formatMoney(loyalty.walletBalance ?? 0)}',
                  controller: _walletController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  label: 'Wallet amount',
                  busy: busy,
                  onApply: () => _applyWallet(cart),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LoyaltySection extends StatelessWidget {
  const _LoyaltySection({
    required this.title,
    required this.subtitle,
    required this.controller,
    required this.keyboardType,
    required this.label,
    required this.busy,
    required this.onApply,
  });
  final String title;
  final String subtitle;
  final TextEditingController controller;
  final TextInputType keyboardType;
  final String label;
  final bool busy;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(PosTokens.s16),
      decoration: t.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          Text(subtitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: PosTokens.s12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: keyboardType,
                  enabled: !busy,
                  decoration: InputDecoration(labelText: label),
                ),
              ),
              const SizedBox(width: PosTokens.s8),
              FilledButton(
                onPressed: busy ? null : onApply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
