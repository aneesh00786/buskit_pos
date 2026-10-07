import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../cart/state/cart_controller.dart';
import '../../cart/ui/cart_panel.dart';
import '../../checkout/ui/pay_modal.dart';

/// Phase 14E-A — a few keyboard shortcuts for keyboard tills, on the sales
/// screen only (dialogs have their own focus, so these never fire inside
/// one). Function keys only: they never collide with typing in a text field
/// or with a barcode scanner (digits + Enter). Without a hardware keyboard
/// nothing changes.
///
///   F2  focus the product search
///   F4  open payment — only when the Pay button would (a draft with items,
///       no cart change running)
///   F8  new sale — nothing to do on an empty cart; a finished sale is
///       cleared; a sale WITH items asks the existing "Clear the cart?"
///       confirmation first
///
/// Escape is left to Flutter: it closes dismissible dialogs; the payment
/// screen is deliberately not dismissible and stays open.
class PosShortcuts extends StatelessWidget {
  const PosShortcuts({
    super.key,
    required this.searchFocus,
    required this.child,
    this.openPay = showPay,
  });

  final FocusNode searchFocus;
  final Widget child;

  /// The existing payment screen (injectable for tests).
  final Future<void> Function(BuildContext context) openPay;

  static bool canPay(CartController cart) {
    final sale = cart.sale;
    return sale != null &&
        sale.isDraft &&
        sale.items.isNotEmpty &&
        !cart.isMutating;
  }

  void _pay(BuildContext context) {
    final cart = context.read<CartController>();
    if (canPay(cart)) openPay(context);
  }

  void _newSale(BuildContext context) {
    final cart = context.read<CartController>();
    if (cart.isMutating) return;
    final sale = cart.sale;
    if (sale == null) return; // already a new, empty sale
    if (!sale.isDraft) {
      cart.reset(); // a finished / held / cancelled sale on screen
    } else if (sale.items.isNotEmpty) {
      confirmClearCart(context); // the existing confirmation
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f2): searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.f4): () => _pay(context),
        const SingleActivator(LogicalKeyboardKey.f8): () => _newSale(context),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
