import '../utils/json_read.dart';

enum ApiErrorKind {
  network,
  timeout,
  unauthorized,
  forbidden,
  notFound,
  validation,
  conflict,
  server,
  unknown,
}

/// Typed API failure. Keeps the backend's `error_code` and `data` so the UI
/// can branch on them (e.g. POS_WEIGHT_UNIT_NOT_SUPPORTED). Never carries
/// stack traces, raw response bodies, tokens or request payloads.
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.errorCode,
    this.data,
  });

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;
  final String? errorCode;
  final Object? data;

  Map<String, dynamic>? get dataMap => asMap(data);

  /// The server's current sale version, present on optimistic-concurrency
  /// conflicts (`data.current_version`).
  int? get currentVersion => asInt(dataMap?['current_version']);

  bool get isVersionConflict =>
      kind == ApiErrorKind.conflict && currentVersion != null;

  /// Same failure (kind, status, error_code, data) with cashier-facing wording.
  ApiException withMessage(String newMessage) => ApiException(
    kind: kind,
    message: newMessage,
    statusCode: statusCode,
    errorCode: errorCode,
    data: data,
  );

  /// Only transient failures are worth offering a retry for; validation,
  /// auth and conflict errors will fail identically until something changes.
  bool get isRetryable =>
      kind == ApiErrorKind.network ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.server;

  bool get isUnauthorized => kind == ApiErrorKind.unauthorized;

  static ApiException fromStatus(
    int status, {
    String? message,
    String? errorCode,
    Object? data,
  }) {
    final ApiErrorKind kind;
    if (status == 401) {
      kind = ApiErrorKind.unauthorized;
    } else if (status == 403) {
      kind = ApiErrorKind.forbidden;
    } else if (status == 404) {
      kind = ApiErrorKind.notFound;
    } else if (status == 409) {
      kind = ApiErrorKind.conflict;
    } else if (status == 400 || status == 422) {
      kind = ApiErrorKind.validation;
    } else if (status >= 500) {
      kind = ApiErrorKind.server;
    } else {
      kind = ApiErrorKind.unknown;
    }
    // Server-side (5xx) messages are never shown verbatim.
    final safe = kind == ApiErrorKind.server ? null : _clip(message);
    return ApiException(
      kind: kind,
      statusCode: status,
      errorCode: errorCode,
      data: data,
      message: safe ?? _defaultMessage(kind),
    );
  }

  static String? _clip(String? m) {
    if (m == null) return null;
    final t = m.trim();
    if (t.isEmpty) return null;
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }

  static String _defaultMessage(ApiErrorKind kind) {
    switch (kind) {
      case ApiErrorKind.unauthorized:
        return 'Your session has expired. Please sign in again.';
      case ApiErrorKind.server:
        return 'Something went wrong on the server. Please try again shortly.';
      case ApiErrorKind.network:
        return 'Cannot reach the server. Check your connection and try again.';
      case ApiErrorKind.timeout:
        return 'The server took too long to respond. Please try again.';
      default:
        return 'The request could not be completed.';
    }
  }

  @override
  String toString() =>
      'ApiException(${kind.name}, status: $statusCode, code: $errorCode)';
}
