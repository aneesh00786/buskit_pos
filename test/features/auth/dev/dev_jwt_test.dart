import 'dart:convert';

import 'package:buskit_pos/features/auth/dev/dev_jwt.dart';
import 'package:flutter_test/flutter_test.dart';

String fakeJwt(Map<String, dynamic> payload) {
  String seg(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${seg({'alg': 'none'})}.${seg(payload)}.sig';
}

void main() {
  test('reads the payload of a well-formed token without verifying it', () {
    final token = fakeJwt({'store_id': 213, 'register_id': 191});
    final claims = decodeJwtPayloadUnverified(token);
    expect(claims, {'store_id': 213, 'register_id': 191});
  });

  test('handles base64url padding correctly', () {
    for (var i = 1; i <= 6; i++) {
      final token = fakeJwt({'x': 'a' * i});
      expect(decodeJwtPayloadUnverified(token), {'x': 'a' * i});
    }
  });

  test('malformed tokens return null instead of throwing', () {
    expect(decodeJwtPayloadUnverified('not-a-jwt'), isNull);
    expect(decodeJwtPayloadUnverified('a.b'), isNull);
    expect(decodeJwtPayloadUnverified('a.!!!not-base64!!!.c'), isNull);
    expect(decodeJwtPayloadUnverified(''), isNull);
  });

  test('a payload that is not a JSON object returns null', () {
    String seg(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final token = '${seg('header')}.${seg([1, 2, 3])}.sig';
    expect(decodeJwtPayloadUnverified(token), isNull);
  });
}
