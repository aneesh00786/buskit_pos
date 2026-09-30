import '../../../core/network/pos_api_client.dart';
import '../models/loyalty_profile.dart';

abstract class LoyaltyService {
  /// `GET /customers/:id/loyalty` — read-only.
  Future<LoyaltyProfile> getProfile(String customerId);
}

/// Verified against the backend: `GET /customers/:id/loyalty` — POS-scoped
/// from the device/staff token, never a client-supplied company id. No
/// create/edit/delete anywhere — loyalty programs/tiers are configured
/// directly (no Admin/Web UI exists yet), same situation promotions started
/// in; sale-scoped redemption lives on [CartService] (applyPromotion's
/// sibling — see cart_service.dart), not here.
class ApiLoyaltyService implements LoyaltyService {
  ApiLoyaltyService(this._client);
  final PosApiClient _client;

  @override
  Future<LoyaltyProfile> getProfile(String customerId) async {
    final data = await _client.get('/customers/$customerId/loyalty');
    return LoyaltyProfile.fromJson(data);
  }
}
