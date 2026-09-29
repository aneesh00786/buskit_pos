import '../../../core/utils/json_read.dart';

/// One row from the POS-safe customer endpoints (`GET /customers`,
/// `GET /customers/:id`, `POST /customers`, `PATCH /customers/:id`). Only the
/// fields those endpoints actually return — the shared `customers` table has
/// many more legacy columns (address, business/tax fields, delivery details)
/// that POS does not read or write.
class Customer {
  const Customer({
    required this.id,
    required this.customerId,
    required this.fullname,
    this.mobileno,
    this.email,
    this.status,
  });

  final int id;

  /// The display/foreign-key identifier (e.g. "CUSTO123") — what a sale's
  /// `customer_id` stores, not the internal numeric [id].
  final String customerId;
  final String fullname;
  final String? mobileno;
  final String? email;

  /// Raw server value; the backend's own status semantics are not
  /// reverse-engineered here — POS only ever reads customers already
  /// filtered to "not soft-deleted" by the backend.
  final int? status;

  static Customer? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final customerId = asString(m['customer_id']);
    final fullname = asString(m['fullname']);
    if (id == null || customerId == null || fullname == null) return null;
    return Customer(
      id: id,
      customerId: customerId,
      fullname: fullname,
      mobileno: asString(m['mobileno']),
      email: asString(m['email']),
      status: asInt(m['status']),
    );
  }
}
