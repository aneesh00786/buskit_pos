import 'package:flutter/material.dart';

/// Phase 2.1 — the optional table label of a held sale (server rule, see
/// buskit-web services/pos/posTableRef.js): 1-16 letters, digits, spaces or
/// hyphens, e.g. "6", "A1", "PATIO 2"; stored upper case.
class TableRef {
  static final _pattern = RegExp(r'^[A-Z0-9][A-Z0-9 -]{0,15}$');

  /// Normalised label, or null when [raw] is empty.
  static String? normalize(String raw) {
    final v = raw.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
    return v.isEmpty ? null : v;
  }

  /// Null when [raw] is a valid label (or empty = no table).
  static String? problem(String raw) {
    final v = normalize(raw);
    if (v == null) return null;
    if (v.length > 16 || !_pattern.hasMatch(v)) {
      return 'Use up to 16 letters, digits, spaces or hyphens (for example 6, A1 or PATIO 2).';
    }
    return null;
  }
}

/// The cashier's choice in [showTableRefDialog].
sealed class TableChoice {
  const TableChoice();
}

class SetTable extends TableChoice {
  const SetTable(this.tableRef);
  final String tableRef;
}

class ClearTable extends TableChoice {
  const ClearTable();
}

/// Asks for a table label. [initial] = the current table (offers Clear).
/// Returns null when cancelled.
Future<TableChoice?> showTableRefDialog(
  BuildContext context, {
  String? initial,
  String title = 'Table',
  String confirmLabel = 'Save',
}) {
  return showDialog<TableChoice>(
    context: context,
    builder: (_) => _TableRefDialog(
      initial: initial,
      title: title,
      confirmLabel: confirmLabel,
    ),
  );
}

class _TableRefDialog extends StatefulWidget {
  const _TableRefDialog({
    required this.initial,
    required this.title,
    required this.confirmLabel,
  });
  final String? initial;
  final String title;
  final String confirmLabel;

  @override
  State<_TableRefDialog> createState() => _TableRefDialogState();
}

class _TableRefDialogState extends State<_TableRefDialog> {
  late final _text = TextEditingController(text: widget.initial ?? '');
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = TableRef.problem(_text.text);
    final value = TableRef.normalize(_text.text);
    if (problem != null || value == null) {
      setState(() => _error = problem ?? 'Enter a table, for example 6.');
      return;
    }
    Navigator.of(context).pop(SetTable(value));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('table-ref-field'),
        controller: _text,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          labelText: 'Table',
          hintText: 'For example 6 or A1',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            key: const Key('table-ref-clear'),
            onPressed: () => Navigator.of(context).pop(const ClearTable()),
            child: const Text('Clear table'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('table-ref-save'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
