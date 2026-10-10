// Phase 17E — a release build needs an HTTPS server address; debug builds
// keep the development default. The same rule is enforced at build time in
// android/app/build.gradle.kts.
import 'package:buskit_pos/app.dart';
import 'package:buskit_pos/core/config/app_config.dart';
import 'package:buskit_pos/core/config/config_error_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig.releaseBaseUrlProblem', () {
    test('accepts an HTTPS origin, with or without a port or path prefix', () {
      for (final url in [
        'https://pos.example.com',
        'https://pos.example.com:8443',
        'https://api.example.com/pos-gateway',
        '  https://pos.example.com  ',
      ]) {
        expect(AppConfig.releaseBaseUrlProblem(url), isNull, reason: url);
      }
    });

    test('refuses missing, non-HTTPS, development and malformed addresses', () {
      final refused = {
        '': 'No server address',
        '   ': 'No server address',
        'http://pos.example.com': 'https://',
        'HTTP://pos.example.com': 'https://',
        'ftp://pos.example.com': 'https://',
        'https://localhost:3000': 'development address',
        'https://127.0.0.1': 'development address',
        'https://127.1.2.3': 'development address',
        'https://10.0.2.2:3000': 'development address',
        'https://0.0.0.0': 'development address',
        'https://[::1]:3000': 'development address',
        'https://user:pass@pos.example.com': 'credentials',
        'https://pos.example.com?x=1': 'query',
        'https://pos.example.com#top': 'fragment',
        'pos.example.com': 'not a valid URL',
        'https://': 'not a valid URL',
        'not a url': 'not a valid URL',
      };
      refused.forEach((url, why) {
        final problem = AppConfig.releaseBaseUrlProblem(url);
        expect(problem, isNotNull, reason: url);
        expect(problem, contains(why), reason: url);
      });
    });

    test('the message never repeats the configured value', () {
      const secretish = 'http://user:hunter2@pos.example.com';
      expect(
        AppConfig.releaseBaseUrlProblem(secretish)!.contains('hunter2'),
        isFalse,
      );
      expect(
        AppConfig.releaseBaseUrlProblem(secretish)!.contains('pos.example.com'),
        isFalse,
      );
    });

    test('the development default is refused for release, so a release build must set POS_BASE_URL', () {
      expect(
        AppConfig.releaseBaseUrlProblem('http://localhost:3000'),
        isNotNull,
      );
    });
  });

  group('rootWidget', () {
    test(
      'debug builds start the POS with the development default (unchanged)',
      () {
        expect(
          rootWidget(release: false, baseUrl: 'http://localhost:3000'),
          isA<PosApp>(),
        );
        expect(rootWidget(release: false, baseUrl: ''), isA<PosApp>());
      },
    );

    test('release builds start the POS only with a valid HTTPS address', () {
      expect(
        rootWidget(release: true, baseUrl: 'https://pos.example.com'),
        isA<PosApp>(),
      );
      expect(
        rootWidget(release: true, baseUrl: 'http://pos.example.com'),
        isA<ConfigErrorApp>(),
      );
      expect(
        rootWidget(release: true, baseUrl: 'http://localhost:3000'),
        isA<ConfigErrorApp>(),
      );
    });

    testWidgets(
      'the configuration error screen explains the problem (ThriveWoo naming)',
      (tester) async {
        await tester.pumpWidget(
          rootWidget(release: true, baseUrl: 'http://pos.example.com'),
        );
        expect(
          find.text('This ThriveWoo POS build is not configured'),
          findsOneWidget,
        );
        expect(find.textContaining('must use https://'), findsOneWidget);
        expect(find.textContaining('Jacky'), findsNothing);
        expect(find.byType(PosApp), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
