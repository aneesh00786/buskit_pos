import '../utils/format.dart';
import '../utils/json_read.dart';
import 'api_exception.dart';

/// Stable backend error codes the UI branches on.
class PosErrorCodes {
  static const weightUnitNotSupported = 'POS_WEIGHT_UNIT_NOT_SUPPORTED';

  /// The product's POS selling mode is REVIEW (not configured for sale).
  static const productNotConfigured = 'POS_PRODUCT_NOT_CONFIGURED_FOR_SALE';
  static const insufficientStock = 'POS_INSUFFICIENT_STOCK';
  static const stockConflict = 'POS_STOCK_CONFLICT';

  /// The one identical code returned for every staff-login failure reason
  /// (wrong PIN, unknown/locked/inactive staff, wrong company) — deliberately
  /// generic to avoid account enumeration. A 401 from staff-login WITHOUT this
  /// code means the device token itself was rejected, not the PIN.
  static const invalidStaffCredentials = 'POS_INVALID_STAFF_CREDENTIALS';

  /// A customer create/update collided with another customer's mobile/email
  /// in the same company. `e.dataMap?['existing_customer_id']` carries the
  /// customer that already has it, so the UI can offer to use that one
  /// instead of just failing — see the customer form.
  static const duplicateMobile = 'POS_DUPLICATE_MOBILE';
  static const duplicateEmail = 'POS_DUPLICATE_EMAIL';

  /// A staff member's role does not grant the permission the action needs
  /// (e.g. `payments.refund`). Server-authoritative and dynamic — a role
  /// change on the admin portal takes effect on this exact same signed-in
  /// session's very next request, no re-login or app rebuild needed.
  static const permissionDenied = 'POS_PERMISSION_DENIED';

  /// Shift Close: the register has no open shift (closed or never opened).
  static const noOpenShift = 'POS_NO_OPEN_SHIFT';
  static const refundExceedsProviderRemaining = 'POS_PAYMENT_REFUND_EXCEEDS_REMAINING';
  static const paymentProviderUnavailable = 'POS_PAYMENT_PROVIDER_NOT_SUPPORTED';

  /// Phase 14B: more than one active product carries the scanned barcode;
  /// the server chose none.
  static const barcodeAmbiguous = 'POS_BARCODE_AMBIGUOUS';

  // Phase 15D — ThriveWoo POS licensing / business type (backend Phase 15C;
  // the backend keeps its internal "JACKY" code names).
  static const licenceNotActive = 'POS_JACKY_NOT_LICENSED';
  static const subscriptionInactive = 'POS_JACKY_SUBSCRIPTION_INACTIVE';
  static const businessTypeNotConfigured = 'POS_BUSINESS_TYPE_NOT_CONFIGURED';
  static const businessTypeDisabled = 'POS_BUSINESS_TYPE_DISABLED';
}

/// Phase 15D — customer-facing wording for licensing refusals (the product
/// is ThriveWoo POS; the server's own messages are never shown for these).
abstract final class LicenceMessages {
  static const notLicensed =
      'Your ThriveWoo POS licence is not active. Please contact your business administrator.';
  static const notActivated =
      'ThriveWoo POS is not activated for this business. Please contact your business administrator.';
  static const notConfigured =
      'ThriveWoo POS is not set up for this business yet. Please contact your business administrator.';
  static const notForBusinessType =
      'This feature is not available for your type of business.';
}

/// Phase C5 — 403 wording for the permissions enforced across the remaining
/// POS endpoints.
const _c5PermissionMessages = <String, String>{
  'sales.create': 'You do not have permission to start or complete sales. Ask a manager or administrator.',
  'sales.edit_current': 'You do not have permission to change this sale. Ask a manager or administrator.',
  'sales.hold': 'You do not have permission to hold sales.',
  'sales.resume': 'You do not have permission to resume held sales.',
  'customers.view': 'You do not have permission to view customers.',
  'customers.create': 'You do not have permission to add customers.',
  'customers.edit': 'You do not have permission to edit customers. Ask a manager or administrator.',
  'promotions.view': 'You do not have permission to view promotions.',
  'promotions.apply': 'You do not have permission to apply promotions.',
  'loyalty.view': 'You do not have permission to view loyalty details.',
  'loyalty.redeem_points': 'You do not have permission to redeem loyalty points.',
  'loyalty.redeem_wallet': 'You do not have permission to use the loyalty wallet.',
  'shifts.open': 'You do not have permission to open a shift. Ask a manager to open the shift for this register.',
  'shifts.close': 'You do not have permission to close the shift. Ask a manager.',
  'payments.accept_cash': 'You do not have permission to accept cash payments.',
  'reports.product': 'You do not have permission to view product sales reports.',
  'reports.cashier': 'You do not have permission to view cashier sales reports.',
  'reports.sales': 'You do not have permission to view sales reports.',
  'reports.tax': 'You do not have permission to view tax reports.',
  'payments.accept_card': 'You do not have permission to accept card payments.',
  'payments.accept_other': 'You do not have permission to accept this payment method.',
  // Phase 14A
  'payments.cash_drawer': 'You do not have permission to open the cash drawer. Ask a manager.',
};

/// Turns an [ApiException] into a short, user-facing message. Codes are
/// preserved on the exception itself; this only decides the wording.
String describeApiError(ApiException e) {
  switch (e.errorCode) {
    case PosErrorCodes.weightUnitNotSupported:
      return 'This product is sold by weight, which the POS does not support yet. '
          'It has not been added to the cart.';
    case PosErrorCodes.productNotConfigured:
      return 'This product is not configured for POS sale. It has not been added to the cart.';
    case PosErrorCodes.insufficientStock:
      final shortages = asList(e.dataMap?['shortages']);
      if (shortages.isNotEmpty) {
        final s = asMap(shortages.first);
        final requested = asDouble(s?['requested']);
        final available = asDouble(s?['available']);
        if (requested != null && available != null) {
          return 'Not enough stock: ${formatQty(requested)} requested, ${formatQty(available)} available.';
        }
      }
      // Inventory adjustment's shape: {current_stock, requested}.
      final current = asDouble(e.dataMap?['current_stock']);
      final requested = asDouble(e.dataMap?['requested']);
      if (current != null && requested != null) {
        return 'Not enough stock: tried to remove ${formatQty(requested)}, only ${formatQty(current)} available.';
      }
      return 'Not enough stock to complete this sale.';
    case PosErrorCodes.stockConflict:
      return 'Stock changed while the sale was being processed. Please try again.';
    case PosErrorCodes.refundExceedsProviderRemaining:
      return 'This refund is more than what is left to refund on the customer\'s original payment.';
    case PosErrorCodes.licenceNotActive:
      return LicenceMessages.notLicensed;
    case PosErrorCodes.subscriptionInactive:
      return LicenceMessages.notActivated;
    case PosErrorCodes.businessTypeNotConfigured:
      return LicenceMessages.notConfigured;
    case PosErrorCodes.businessTypeDisabled:
      return LicenceMessages.notForBusinessType;
    case PosErrorCodes.barcodeAmbiguous:
      return 'More than one product uses this barcode, so nothing was added. '
          'Search for the product and add it from the list.';
    case PosErrorCodes.paymentProviderUnavailable:
      return 'The payment provider for this payment is not available right now. Ask an administrator.';
    case PosErrorCodes.permissionDenied:
      final permission = asString(e.dataMap?['permission']);
      // Endpoints that accept any of several permissions (cash movement
      // history) — the first key alone would misdescribe the action.
      final anyOf = asList(e.dataMap?['any_of']);
      if (anyOf.contains('payments.cash_deposit') &&
          anyOf.contains('payments.cash_withdrawal')) {
        return 'You do not have permission to view cash movements.';
      }
      // Phase C5 — screens the backend opens with any one of several.
      if (anyOf.contains('reports.sales')) {
        return 'You do not have permission to view sales reports.';
      }
      if (anyOf.contains('loyalty.redeem_points') && anyOf.contains('loyalty.redeem_wallet')) {
        return 'You do not have permission to change loyalty redemptions. Ask a manager or administrator.';
      }
      final c5 = _c5PermissionMessages[permission];
      if (c5 != null) return c5;
      if (permission == 'payments.refund') {
        return 'You do not have permission to refund sales. Ask a manager or administrator.';
      }
      if (permission == 'payments.cash_withdrawal') {
        return 'You do not have permission to withdraw cash. Ask a manager or administrator.';
      }
      if (permission == 'payments.cash_deposit') {
        return 'You do not have permission to deposit cash. Ask a manager or administrator.';
      }
      if (permission == 'discounts.override') {
        return 'You do not have permission to apply a discount. Ask a manager or administrator.';
      }
      if (permission == 'inventory.adjust') {
        return 'You do not have permission to adjust inventory. Ask a manager or administrator.';
      }
      if (permission == 'products.price_change') {
        return 'You do not have permission to change prices. Ask a manager or administrator.';
      }
      if (permission == 'inventory.view') {
        return 'You do not have permission to view inventory history.';
      }
      if (permission == 'sales.view') {
        return 'You do not have permission to view sales. Ask a manager or administrator.';
      }
      if (permission == 'shifts.view') {
        return 'You do not have permission to view shifts.';
      }
      if (permission == 'settings.view') {
        return 'You do not have permission to view store settings. Ask a manager or administrator.';
      }
      if (permission == 'settings.store' || permission == 'settings.edit') {
        return 'You do not have permission to edit the store. Ask a manager or administrator.';
      }
      if (permission == 'settings.register') {
        return 'You do not have permission to manage registers. Ask a manager or administrator.';
      }
      if (permission == 'settings.device') {
        return 'You do not have permission to manage devices. Ask a manager or administrator.';
      }
      return 'You do not have permission to do that.';
  }
  switch (e.kind) {
    case ApiErrorKind.network:
    case ApiErrorKind.timeout:
    case ApiErrorKind.unauthorized:
    case ApiErrorKind.server:
      return e.message;
    case ApiErrorKind.conflict:
      return e.message;
    default:
      return e.message;
  }
}
