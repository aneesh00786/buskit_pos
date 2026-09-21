import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../utils/json_read.dart';
import 'api_exception.dart';

typedef TokenProvider = String? Function();

/// Thin HTTP layer for the POS backend (`/api/v1/pos`). Owns: URL building,
/// the `Authorization: Bearer` header, timeouts, envelope parsing
/// (`{status_code,status,message,data,error_code?}`) and mapping every
/// failure to [ApiException]. It never logs and never puts tokens, request
/// bodies or raw responses into an exception.
class PosApiClient {
  PosApiClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.tokenProvider,
    this.onUnauthorized,
    this.timeout = AppConfig.requestTimeout,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;
  final TokenProvider? tokenProvider;

  /// Called with the bearer token that was rejected, so the session can ignore
  /// a 401 for a token it has already replaced (parallel requests all fail together).
  final void Function(String? failedToken)? onUnauthorized;
  final Duration timeout;

  /// Whether the last request reached the server: null before any request,
  /// true after any HTTP response (even an error status), false after a
  /// timeout or a connection failure. Drives the header's status indicator; it
  /// is not a substitute for a system connectivity check.
  final ValueNotifier<bool?> reachable = ValueNotifier<bool?>(null);

  Uri buildUri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(
      path: '$prefix${AppConfig.apiPrefix}$path',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  /// Returns the envelope's `data`. [token] overrides the provider (used by
  /// the login steps). [notifyUnauthorized] must be false for endpoints where
  /// a 401 means "bad credentials" rather than "session expired".
  Future<Object?> request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? token,
    bool authenticated = true,
    bool notifyUnauthorized = true,
  }) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    final bearer = authenticated ? (token ?? tokenProvider?.call()) : null;
    if (bearer != null && bearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $bearer';
    }

    final req = http.Request(method, buildUri(path, query))
      ..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);

    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _http.send(req).timeout(timeout),
      );
    } on TimeoutException {
      reachable.value = false;
      throw const ApiException(
        kind: ApiErrorKind.timeout,
        message: 'The server took too long to respond. Please try again.',
      );
    } on SocketException {
      reachable.value = false;
      throw const ApiException(
        kind: ApiErrorKind.network,
        message:
            'Cannot reach the server. Check your connection and try again.',
      );
    } on http.ClientException {
      reachable.value = false;
      throw const ApiException(
        kind: ApiErrorKind.network,
        message:
            'Cannot reach the server. Check your connection and try again.',
      );
    }

    reachable.value = true;

    Map<String, dynamic>? envelope;
    try {
      envelope = asMap(jsonDecode(utf8.decode(res.bodyBytes)));
    } on FormatException {
      envelope = null;
    }

    final ok =
        res.statusCode >= 200 &&
        res.statusCode < 300 &&
        (envelope == null || envelope['status'] != false);
    if (ok) return envelope?['data'];

    final ex = ApiException.fromStatus(
      res.statusCode,
      message: asString(envelope?['message']),
      errorCode: asString(envelope?['error_code']),
      data: envelope?['data'],
    );
    if (ex.isUnauthorized && authenticated && notifyUnauthorized) {
      onUnauthorized?.call(bearer);
    }
    throw ex;
  }

  Future<Object?> get(
    String path, {
    Map<String, String>? query,
    String? token,
  }) => request('GET', path, query: query, token: token);

  Future<Object?> patch(String path, {Object? body, String? token}) => request(
    'PATCH',
    path,
    body: body ?? const <String, dynamic>{},
    token: token,
  );

  Future<Object?> delete(
    String path, {
    Map<String, String>? query,
    String? token,
  }) => request('DELETE', path, query: query, token: token);

  Future<Object?> post(
    String path, {
    Object? body,
    String? token,
    bool authenticated = true,
    bool notifyUnauthorized = true,
  }) => request(
    'POST',
    path,
    body: body ?? const <String, dynamic>{},
    token: token,
    authenticated: authenticated,
    notifyUnauthorized: notifyUnauthorized,
  );

  void close() {
    reachable.dispose();
    _http.close();
  }
}
