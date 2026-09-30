import 'package:buskit_pos/features/loyalty/data/loyalty_service.dart';
import 'package:buskit_pos/features/loyalty/models/loyalty_profile.dart';

Map<String, dynamic> loyaltyProfileJson({
  bool enabled = true,
  Map<String, dynamic>? tier,
  double pointsBalance = 0,
  double walletBalance = 0,
  Map<String, dynamic>? nextTier,
}) => {
  'enabled': enabled,
  'tier': tier,
  'points_balance': pointsBalance,
  'wallet_balance': walletBalance,
  'next_tier': nextTier,
};

class FakeLoyaltyService implements LoyaltyService {
  final List<String> getProfileCalls = [];
  Future<LoyaltyProfile> Function(String customerId) onGetProfile = (_) async =>
      LoyaltyProfile.fromJson(loyaltyProfileJson());

  @override
  Future<LoyaltyProfile> getProfile(String customerId) {
    getProfileCalls.add(customerId);
    return onGetProfile(customerId);
  }
}
