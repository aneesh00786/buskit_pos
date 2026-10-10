import 'package:flutter/material.dart';

import '../../../core/layout/responsive.dart';
import '../../../core/theme/pos_tokens.dart';

/// The POS shell. It arranges pre-built pieces for the current width class and
/// owns no business state.
///
///  * compact   : app bar (menu opens the sidebar as a drawer) + [body] +
///                [bottomBar] (cart summary / sheet launcher)
///  * medium    : icon rail | header + [body] | side [cart]
///  * expanded  : sidebar   | header + [body] | side [cart]
///  * wide      : as expanded plus the [summary] column
class PosScaffold extends StatelessWidget {
  const PosScaffold({
    super.key,
    required this.layout,
    required this.sidebarBuilder,
    required this.body,
    required this.cart,
    required this.header,
    required this.compactTitle,
    this.compactActions = const [],
    this.bottomBar,
    this.summary,
    this.banner,
  });

  final PosLayoutClass layout;

  /// Builds the sidebar; `collapsed` is true for the icon rail.
  final Widget Function(bool collapsed) sidebarBuilder;
  final Widget body;

  /// The current-sale panel shown beside the catalog (non-compact layouts).
  final Widget cart;
  final Widget header;
  final String compactTitle;
  final List<Widget> compactActions;
  final Widget? bottomBar;
  final Widget? summary;

  /// A full-width notice shown above [body] in every layout (e.g. the
  /// offline banner). Should size itself to nothing when not needed.
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);

    if (layout.isCompact) {
      return Scaffold(
        appBar: AppBar(
          title: Text(compactTitle),
          backgroundColor: t.surface,
          surfaceTintColor: Colors.transparent,
          shape: Border(bottom: BorderSide(color: t.border)),
          actions: compactActions,
        ),
        drawer: Drawer(child: sidebarBuilder(false)),
        // Phase 16B: the AppBar already clears the status bar / notch; the
        // body clears the side cut-outs and — when there is no bottom bar
        // (which pads itself) — the navigation / gesture area.
        body: SafeArea(
          top: false,
          bottom: bottomBar == null,
          child: banner == null
              ? body
              : Column(
                  children: [
                    banner!,
                    Expanded(child: body),
                  ],
                ),
        ),
        bottomNavigationBar: bottomBar,
      );
    }

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The sidebar keeps its own SafeArea (its dark panel still runs
          // behind the status bar, as before).
          sidebarBuilder(!layout.hasFullSidebar),
          // Phase 16B: header, catalogue, cart and summary stay inside the
          // safe area — clear of the status bar / camera cut-out on top, the
          // gesture area / home indicator below and a landscape cut-out on
          // the right (the sidebar already covers the left edge).
          Expanded(
            child: SafeArea(
              left: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        header,
                        ?banner,
                        Expanded(child: body),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: layout.sideCartWidth,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        0,
                        PosTokens.s12,
                        PosTokens.s12,
                        PosTokens.s12,
                      ),
                      child: cart,
                    ),
                  ),
                  if (layout.hasSummary && summary != null)
                    SizedBox(
                      width: 300,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          0,
                          PosTokens.s12,
                          PosTokens.s12,
                          PosTokens.s12,
                        ),
                        child: summary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
