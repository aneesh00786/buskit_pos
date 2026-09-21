import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';
import '../state/product_list_controller.dart';
import 'category_chip.dart';

String sortLabel(ProductSort s) => switch (s) {
  ProductSort.serverOrder => 'Default',
  ProductSort.nameAsc => 'A–Z',
  ProductSort.nameDesc => 'Z–A',
};

/// Category chips (server-provided) with the sort dropdown beside them. The
/// chips scroll; the dropdown stays put, so the two never overlap. When a local
/// sort is applied to a partial result, a note says so and offers "Load all".
class ProductFilterBar extends StatelessWidget {
  const ProductFilterBar({
    super.key,
    required this.controller,
    this.showSort = true,
  });
  final ProductListController controller;

  /// False when the page shows the sort dropdown elsewhere (narrow phones put
  /// it beside the grid/list toggle so the chips keep the whole row).
  final bool showSort;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return LayoutBuilder(
      builder: (context, box) {
        // Narrow phones: a lighter dropdown and smaller arrows keep the row on one line.
        final compact = box.maxWidth < 480;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  Expanded(
                    child: _Chips(controller: c, compact: compact),
                  ),
                  if (showSort) ...[
                    SizedBox(width: compact ? 4 : PosTokens.s8),
                    Padding(
                      padding: EdgeInsets.only(
                        right: compact ? PosTokens.s8 : PosTokens.s12,
                      ),
                      child: SortDropdown(
                        value: c.sort,
                        onChanged: c.setSort,
                        compact: compact,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (c.sortIsPartial) _PartialSortNote(controller: c),
          ],
        );
      },
    );
  }
}

/// The category chips, with `<` / `>` arrows at either end whenever the list is
/// wider than its space, so it is obvious the row scrolls. The arrow at an edge
/// is dimmed when there is nothing further in that direction.
class _Chips extends StatefulWidget {
  const _Chips({required this.controller, this.compact = false});
  final ProductListController controller;
  final bool compact;

  @override
  State<_Chips> createState() => _ChipsState();
}

class _ChipsState extends State<_Chips> {
  final _scroll = ScrollController();
  bool _scrollable = false;
  bool _canBack = false;
  bool _canForward = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Reads the scroll position (after layout) and updates the arrows.
  void _syncArrows() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    final scrollable = p.maxScrollExtent > 0.5;
    final back = scrollable && p.pixels > 0.5;
    final forward = scrollable && p.pixels < p.maxScrollExtent - 0.5;
    if (scrollable != _scrollable ||
        back != _canBack ||
        forward != _canForward) {
      setState(() {
        _scrollable = scrollable;
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  /// Called for scroll and metrics notifications (they can fire during layout,
  /// so the setState is deferred to after the frame).
  bool _schedule(Notification _) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrows());
    return false;
  }

  Future<void> _scrollBy(double direction) async {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final target = (p.pixels + direction * p.viewportDimension * 0.7).clamp(
      0.0,
      p.maxScrollExtent,
    );
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c.categoriesError != null && c.categories.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Categories could not be loaded',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: c.loadCategories, child: const Text('Retry')),
          ],
        ),
      );
    }
    // Content changes (categories arriving, a rebuild) may alter scrollability.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrows());

    return Row(
      children: [
        if (_scrollable)
          _ArrowButton(
            icon: Icons.chevron_left,
            tooltip: 'Scroll categories left',
            compact: widget.compact,
            onPressed: _canBack ? () => _scrollBy(-1) : null,
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _schedule,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: _schedule,
              child: ListView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(_scrollable ? 4 : 12, 8, 4, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CategoryChip(
                      label: 'All categories',
                      selected: c.categoryId == null,
                      onSelected: () => c.selectCategory(null),
                    ),
                  ),
                  for (final cat in c.categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: CategoryChip(
                        label: cat.name,
                        selected: c.categoryId == cat.id,
                        onSelected: () => c.selectCategory(cat.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_scrollable)
          _ArrowButton(
            icon: Icons.chevron_right,
            tooltip: 'Scroll categories right',
            compact: widget.compact,
            onPressed: _canForward ? () => _scrollBy(1) : null,
          ),
      ],
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.compact = false,
  });
  final bool compact;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 2),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          minimumSize: Size(compact ? 36 : 40, 48),
          fixedSize: Size(compact ? 36 : 40, 48),
          padding: EdgeInsets.zero,
          backgroundColor: t.surface,
          disabledBackgroundColor: t.surface.withValues(alpha: 0.6),
          side: BorderSide(color: t.border),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}

/// Default / A–Z / Z–A. Purely a local ordering of the loaded products.
class SortDropdown extends StatelessWidget {
  const SortDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
    this.expand = false,
  });

  /// Fill the width the parent offers (label ellipsizes) instead of sizing to
  /// the label, so the control can shrink in a tight row.
  final bool expand;

  /// Narrow layouts drop the leading icon and tighten the padding.
  final bool compact;
  final ProductSort value;
  final ValueChanged<ProductSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Sort products',
      value: sortLabel(value),
      child: Tooltip(
        message: 'Sort products',
        child: Container(
          height: 48,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? PosTokens.s8 : PosTokens.s12,
          ),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(PosTokens.rPill),
            border: Border.all(color: t.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<ProductSort>(
              value: value,
              isDense: true,
              isExpanded: expand,
              borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
              icon: Icon(
                Icons.keyboard_arrow_down,
                color: scheme.onSurfaceVariant,
              ),
              selectedItemBuilder: (_) => [
                for (final s in ProductSort.values)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.sort_by_alpha,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          sortLabel(s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
              ],
              items: [
                for (final s in ProductSort.values)
                  DropdownMenuItem<ProductSort>(
                    value: s,
                    child: Text(sortLabel(s)),
                  ),
              ],
              onChanged: (s) {
                if (s != null) onChanged(s);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Honest scope of a local sort: it only covers the products loaded so far.
class _PartialSortNote extends StatelessWidget {
  const _PartialSortNote({required this.controller});
  final ProductListController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final t = PosTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(
          PosTokens.s12,
          0,
          PosTokens.s12,
          PosTokens.s4,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: PosTokens.s12,
          vertical: PosTokens.s4,
        ),
        decoration: BoxDecoration(
          color: t.surfaceMuted,
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: PosTokens.s8,
          children: [
            Text(
              'Sorted within the ${c.loadedCount} of ${c.total} items loaded so far.',
              style: text.bodySmall,
            ),
            if (c.isLoadingAll)
              Text('Loading the rest…', style: text.bodySmall)
            else
              TextButton(
                onPressed: c.loadRemaining,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: const Text('Load all'),
              ),
          ],
        ),
      ),
    );
  }
}
