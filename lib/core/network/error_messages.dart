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
      return 'Not enough stock to complete this sale.';
    case PosErrorCodes.stockConflict:
      return 'Stock changed while the sale was being processed. Please try again.';
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
