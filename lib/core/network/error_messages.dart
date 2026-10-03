import '../utils/format.dart';
import '../utils/json_read.dart';
import 'api_exception.dart';

/// Stable backend error codes the UI branches on.
class PosErrorCodes {
  static const weightUnitNotSupported = 'POS_WEIGHT_UNIT_NOT_SUPPORTED';
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
}

/// Turns an [ApiException] into a short, user-facing message. Codes are
/// preserved on the exception itself; this only decides the wording.
String describeApiError(ApiException e) {
  switch (e.errorCode) {
    case PosErrorCodes.weightUnitNotSupported:
      return 'This product is sold by weight or volume and cannot be sold at the POS yet. '
          'It has not been added to the cart.';
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
    case PosErrorCodes.permissionDenied:
      final permission = asString(e.dataMap?['permission']);
      if (permission == 'payments.refund') {
        return 'You do not have permission to refund sales. Ask a manager or administrator.';
      }
      if (permission == 'payments.cash_withdrawal') {
        return 'You do not have permission to withdraw cash. Ask a manager or administrator.';
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
