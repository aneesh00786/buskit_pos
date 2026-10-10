import '../../features/auth/models/pos_auth_context.dart';

/// Phase 15D — which POS modules a business may see, by its business type
/// (from `GET /auth/me` only). UI visibility ONLY: the server enforces the
/// same rule on every module's API (a RETAIL business is refused restaurant
/// endpoints whatever the app shows).
///
/// Retail modules are the existing POS screens; every business type keeps
/// them. Restaurant modules are reserved for later phases: only a RESTAURANT
/// business is entitled to them, and none is built yet, so none is shown to
/// anyone ([isImplemented]).
enum PosModule {
  // Retail POS (existing screens).
  sales(restaurantOnly: false),
  heldSales(restaurantOnly: false),
  salesHistory(restaurantOnly: false),
  customers(restaurantOnly: false),
  inventory(restaurantOnly: false),
  promotions(restaurantOnly: false),
  analytics(restaurantOnly: false),
  reports(restaurantOnly: false),
  paymentExceptions(restaurantOnly: false),
  settings(restaurantOnly: false),
  // Restaurant-only (future; not implemented).
  restaurantOrders(restaurantOnly: true),
  tables(restaurantOnly: true),
  kitchen(restaurantOnly: true),
  kitchenDisplay(restaurantOnly: true);

  const PosModule({required this.restaurantOnly});
  final bool restaurantOnly;
}

abstract final class PosModules {
  /// Modules that exist in this app today.
  static bool isImplemented(PosModule m) => !m.restaurantOnly;

  /// The business rule (mirrors the server): restaurant-only modules need a
  /// RESTAURANT business; an unknown type is never entitled to them.
  static bool isEntitled(PosModule m, BusinessType? type) =>
      !m.restaurantOnly || type == BusinessType.restaurant;

  /// What the UI may show: entitled AND built.
  static bool isAvailable(PosModule m, BusinessType? type) =>
      isEntitled(m, type) && isImplemented(m);
}
