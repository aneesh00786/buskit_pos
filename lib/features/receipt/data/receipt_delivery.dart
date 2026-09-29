import 'package:url_launcher/url_launcher.dart';

import '../models/receipt.dart';
import '../models/receipt_formatter.dart';

/// Opens a `mailto:` / `sms:` link in the device's own app. There is no
/// backend endpoint for receipts, so the app never sends anything itself: it
/// only pre-fills the customer's mail or messaging app.
abstract class ReceiptDelivery {
  Future<bool> open(Uri uri);
}

class UrlLauncherDelivery implements ReceiptDelivery {
  const UrlLauncherDelivery();
  @override
  Future<bool> open(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

class ReceiptShare {
  const ReceiptShare._();

  static String? validateEmail(String input) {
    final v = input.trim();
    if (v.isEmpty) return 'Enter an email address.';
    if (v.length > 254 ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(v)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  static String? validatePhone(String input) {
    final v = input.trim();
    if (v.isEmpty) return 'Enter a phone number.';
    if (!RegExp(r'^\+?[\d\s\-()]{6,20}$').hasMatch(v)) {
      return 'Enter a valid phone number.';
    }
    if (v.replaceAll(RegExp(r'\D'), '').length < 6) {
      return 'Enter a valid phone number.';
    }
    return null;
  }

  static String _digits(String phone) {
    final t = phone.trim();
    return (t.startsWith('+') ? '+' : '') + t.replaceAll(RegExp(r'\D'), '');
  }

  // Percent-encoded (%20), not query-form (+): mail apps would show literal pluses.
  static Uri emailUri(String to, ReceiptData receipt) => Uri(
    scheme: 'mailto',
    path: to.trim(),
    query:
        'subject=${Uri.encodeComponent('Your receipt ${receipt.orderNumber}')}'
        '&body=${Uri.encodeComponent(receipt.toPlainText())}',
  );

  static Uri smsUri(String phone, ReceiptData receipt) => Uri(
    scheme: 'sms',
    path: _digits(phone),
    query: 'body=${Uri.encodeComponent(receipt.shortText)}',
  );
}
