import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/pos_tokens.dart';
import '../data/printer_driver.dart';
import '../data/printer_settings.dart';
import '../data/receipt_delivery.dart';
import '../models/receipt.dart';
import '../printing/escpos_receipt_service.dart';
import '../printing/network_printer_adapter.dart';
import '../state/print_service.dart';
import '../state/receipt_services.dart';

/// "Print Receipt", "Email / SMS" and a printer-setup shortcut, shown on the
/// sale-complete screen.
class ReceiptActions extends StatefulWidget {
  const ReceiptActions({super.key, required this.receipt, this.autoPrintKey});
  final ReceiptData receipt;

  /// Phase 14B: set ONLY on the sale-complete screen (`sale:<id>`). When the
  /// "Auto print receipt" setting is on, the receipt is printed once through
  /// the same print flow as the button; the button stays for reprints.
  final String? autoPrintKey;

  @override
  State<ReceiptActions> createState() => _ReceiptActionsState();
}

class _ReceiptActionsState extends State<ReceiptActions> {
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPrintKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoPrint());
    }
  }

  /// Phase 14B: after the sale is complete (this screen only exists then),
  /// print once if the store turned auto-print on. Never awaited by checkout;
  /// a failure is reported like a manual print and the button remains.
  Future<void> _autoPrint() async {
    final key = widget.autoPrintKey;
    if (key == null || !mounted) return;
    final services = context.read<ReceiptServices>();
    bool enabled;
    try {
      enabled = (await services.settings.load()).autoPrint;
    } catch (_) {
      enabled = false;
    }
    if (!enabled || !mounted || !services.print.claimAutoPrint(key)) return;
    await _print();
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _print() async {
    if (_printing) return;
    final services = context.read<ReceiptServices>();
    setState(() => _printing = true);
    String message;
    try {
      final out = await services.print.print(widget.receipt);
      if (out.cancelled) {
        message = 'Printing cancelled.';
      } else if (out.fellBack) {
        message =
            '${out.thermalError ?? 'The receipt printer is unavailable.'} '
            'Sent to the device printer instead.';
      } else if (out.channel == PrintChannel.thermal) {
        message = 'Receipt printed.';
      } else {
        message = 'Receipt sent to the device printer.';
      }
    } on PrintException catch (e) {
      message = 'Could not print: ${e.message}';
    } catch (_) {
      message = 'Could not print the receipt.';
    }
    if (!mounted) return;
    setState(() => _printing = false);
    _say(message);
  }

  Future<void> _send() async {
    final sent = await showDialog<String>(
      context: context,
      builder: (_) => Provider<ReceiptServices>.value(
        value: context.read<ReceiptServices>(),
        child: SendReceiptDialog(receipt: widget.receipt),
      ),
    );
    if (sent != null && mounted) _say(sent);
  }

  Future<void> _setup() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => Provider<ReceiptServices>.value(
        value: context.read<ReceiptServices>(),
        child: PrinterSetupDialog(receipt: widget.receipt),
      ),
    );
    if (saved == true && mounted) _say('Printer settings saved.');
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _printing ? null : _print,
            icon: _printing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.print_outlined),
            label: Text(_printing ? 'Printing…' : 'Print Receipt'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
        const SizedBox(width: PosTokens.s8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _send,
            icon: const Icon(Icons.mail_outline),
            label: const Text('Email / SMS'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
        const SizedBox(width: PosTokens.s4),
        IconButton(
          tooltip: 'Printer setup',
          onPressed: _setup,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }
}

enum _Channel { email, sms }

/// Asks for the customer's email or phone and hands the receipt to the
/// device's mail / messaging app. Nothing is stored. Pops with a message to
/// show once sent.
class SendReceiptDialog extends StatefulWidget {
  const SendReceiptDialog({super.key, required this.receipt});
  final ReceiptData receipt;

  @override
  State<SendReceiptDialog> createState() => _SendReceiptDialogState();
}

class _SendReceiptDialogState extends State<SendReceiptDialog> {
  final _form = GlobalKey<FormState>();
  final _controller = TextEditingController();
  _Channel _channel = _Channel.email;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    final services = context.read<ReceiptServices>();
    final value = _controller.text;
    final uri = _channel == _Channel.email
        ? ReceiptShare.emailUri(value, widget.receipt)
        : ReceiptShare.smsUri(value, widget.receipt);
    setState(() {
      _busy = true;
      _error = null;
    });
    var opened = false;
    try {
      opened = await services.delivery.open(uri);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (opened) {
      Navigator.of(context).pop(
        _channel == _Channel.email
            ? 'Email draft opened — send it from your mail app.'
            : 'Message opened — send it from your messaging app.',
      );
    } else {
      setState(() {
        _busy = false;
        _error = _channel == _Channel.email
            ? 'No email app is available on this device.'
            : 'No messaging app is available on this device.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = _channel == _Channel.email;
    return AlertDialog(
      title: const Text('Send receipt'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<_Channel>(
                segments: const [
                  ButtonSegment(
                    value: _Channel.email,
                    icon: Icon(Icons.mail_outline),
                    label: Text('Email'),
                  ),
                  ButtonSegment(
                    value: _Channel.sms,
                    icon: Icon(Icons.sms_outlined),
                    label: Text('SMS'),
                  ),
                ],
                selected: {_channel},
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() {
                        _channel = s.first;
                        _error = null;
                        _controller.clear();
                      }),
              ),
              const SizedBox(height: PosTokens.s16),
              TextFormField(
                key: ValueKey(_channel),
                controller: _controller,
                autofocus: true,
                enabled: !_busy,
                keyboardType: email
                    ? TextInputType.emailAddress
                    : TextInputType.phone,
                textInputAction: TextInputAction.send,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: email ? 'Customer email' : 'Customer phone',
                  hintText: email ? 'name@example.com' : '+1 555 123 4567',
                  border: const OutlineInputBorder(),
                ),
                validator: (v) => email
                    ? ReceiptShare.validateEmail(v ?? '')
                    : ReceiptShare.validatePhone(v ?? ''),
              ),
              const SizedBox(height: PosTokens.s8),
              Text(
                'This opens the ${email ? 'email' : 'messaging'} app on this '
                'device with the receipt filled in. You send it from there; '
                'the contact is not saved.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_error != null) ...[
                const SizedBox(height: PosTokens.s8),
                Text(
                  _error!,
                  style: TextStyle(color: PosTokens.of(context).danger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(email ? 'Open email' : 'Open messages'),
        ),
      ],
    );
  }
}

/// Where to print: a LAN thermal printer (address, port, paper width) or, when
/// the address is left empty, the device's own print dialog.
class PrinterSetupDialog extends StatefulWidget {
  const PrinterSetupDialog({super.key, required this.receipt});
  final ReceiptData receipt;

  @override
  State<PrinterSetupDialog> createState() => _PrinterSetupDialogState();
}

class _PrinterSetupDialogState extends State<PrinterSetupDialog> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '${PrinterSettings.defaultPort}');
  PaperWidth _paper = PaperWidth.mm80;
  ThermalMode _mode = ThermalMode.image;
  bool _cashDrawer = false;
  bool _autoPrint = false;
  bool _loaded = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final s = await context.read<ReceiptServices>().settings.load();
    if (!mounted) return;
    setState(() {
      _host.text = s.host;
      _port.text = '${s.port}';
      _paper = s.paper;
      _mode = s.mode;
      _cashDrawer = s.cashDrawer;
      _autoPrint = s.autoPrint;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  PrinterSettings get _current => PrinterSettings(
    host: _host.text.trim(),
    port: int.tryParse(_port.text.trim()) ?? PrinterSettings.defaultPort,
    paper: _paper,
    mode: _mode,
    cashDrawer: _cashDrawer,
    autoPrint: _autoPrint,
  );

  Future<void> _save() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    await context.read<ReceiptServices>().settings.save(_current);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _test() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    if (!_current.thermalConfigured) {
      setState(() => _message = 'Enter the printer address to test it.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    String message;
    try {
      if (_current.mode == ThermalMode.escPos) {
        final r = await EscPosReceiptService(
          adapter: NetworkPrinterAdapter(settings: _current),
          config: NetworkPrinterAdapter.configFor(_current),
        ).print(widget.receipt);
        message = r.ok
            ? 'Test receipt sent.'
            : (r.message ?? 'The test print failed.');
      } else {
        await NetworkEscPosPrinter(settings: _current).print(widget.receipt);
        message = 'Test receipt sent.';
      }
    } on PrintException catch (e) {
      message = e.message;
    } catch (_) {
      message = 'The test print failed.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Printer setup'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: !_loaded
            ? const Padding(
                padding: EdgeInsets.all(PosTokens.s16),
                child: Center(child: CircularProgressIndicator()),
              )
            : Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _host,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Printer address',
                        hintText: '192.168.1.50',
                        helperText:
                            'Leave empty to use the device print dialog.',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          PrinterSettings.validate(v ?? '', _port.text),
                    ),
                    const SizedBox(height: PosTokens.s12),
                    TextFormField(
                      controller: _port,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: PosTokens.s12),
                    SegmentedButton<PaperWidth>(
                      segments: [
                        for (final p in PaperWidth.values)
                          ButtonSegment(value: p, label: Text(p.label)),
                      ],
                      selected: {_paper},
                      onSelectionChanged: _busy
                          ? null
                          : (s) => setState(() => _paper = s.first),
                    ),
                    const SizedBox(height: PosTokens.s12),
                    // Phase 11C: how receipts go to the LAN printer
                    // (Image = unchanged default).
                    SegmentedButton<ThermalMode>(
                      key: const Key('printer-mode'),
                      segments: [
                        for (final m in ThermalMode.values)
                          ButtonSegment(value: m, label: Text(m.label)),
                      ],
                      selected: {_mode},
                      onSelectionChanged: _busy
                          ? null
                          : (s) => setState(() => _mode = s.first),
                    ),
                    // Phase 14A: a cash drawer on this printer's drawer port
                    // (opened after cash sales and by "no sale").
                    const SizedBox(height: PosTokens.s8),
                    Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Cash drawer connected'),
                              Text(
                                'Open it after cash sales and for "no sale".',
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          key: const Key('printer-cash-drawer'),
                          value: _cashDrawer,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _cashDrawer = v),
                        ),
                      ],
                    ),
                    // Phase 14B: print automatically after a completed sale.
                    Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Auto print receipt'),
                              Text('Print after every completed sale.'),
                            ],
                          ),
                        ),
                        Switch(
                          key: const Key('printer-auto-print'),
                          value: _autoPrint,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _autoPrint = v),
                        ),
                      ],
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: PosTokens.s12),
                      Text(_message!),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _busy || !_loaded ? null : _test,
          child: const Text('Test print'),
        ),
        FilledButton(
          onPressed: _busy || !_loaded ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
