import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../models/quick_bill_preview.dart';

/// Phase 13C-B — asks the backend to resolve and price a spoken quick bill.
/// READ ONLY on the server: no sale, cart, payment or stock is created.
abstract class VoicePreviewService {
  /// Throws [ApiException] on failure (including an unusable response).
  Future<QuickBillPreview> previewQuickBill(QuickBillRequest request);
}

class ApiVoicePreviewService implements VoicePreviewService {
  ApiVoicePreviewService(this._client);
  final PosApiClient _client;

  static const path = '/voice/quick-bill/preview';

  @override
  Future<QuickBillPreview> previewQuickBill(QuickBillRequest request) async {
    final data = await _client.post(path, body: request.toJson());
    final preview = QuickBillPreview.fromJson(data);
    if (preview == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'The bill preview could not be read. Please try again.',
      );
    }
    return preview;
  }
}
