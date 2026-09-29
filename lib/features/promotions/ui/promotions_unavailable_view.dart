import 'package:flutter/material.dart';

/// Promotions have no POS-safe backend API yet — the sale-completion
/// calculation itself has no discount input at all (see
/// `docs/phase9-customer-promotion-capability-report.md`). Shown verbatim per
/// the agreed wording rather than a generic "coming soon", and never wired to
/// an Apply action that would not actually work.
Future<void> showPromotionsUnavailable(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Promotions'),
      content: const Text(
        'Promotions are not available from POS yet. Every sale total is '
        'calculated by the server with no discount applied.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
