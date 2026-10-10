// Phase 15D — business type (RETAIL / RESTAURANT) and the ThriveWoo POS
// licence, read ONLY from the authenticated GET /auth/me context; module
// visibility by business type; the Quick Bill licence refusal wording.
// The server stays authoritative for both.
import 'package:buskit_pos/core/business/pos_modules.dart';
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/shell/ui/pos_sidebar.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide fail;
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import '../voice/voice_controller_test.dart' show FakeRecognizer;
import '../voice/voice_preview_test.dart'
    show FakeBackend, controllerFor, fail, readyCoffeeWater, speak;

Map<String, dynamic> me({
  String staff = 'S1',
  Object? businessType = 'RETAIL',
  Object? licensed = true,
  Map<String, dynamic> extra = const {},
}) => {
  'staff': {'salesman_id': staff, 'name': 'Staff $staff', 'role': null},
  'permissions': ['sales.view'],
  'business': {'business_type': businessType},
  'jacky': {'licensed': licensed},
  ...extra,
};

PosAuthContext ctx(Map<String, dynamic> json) => PosAuthContext.fromJson(json)!;

/// A device-signed-in session whose /auth/me answers come from [answers]
/// (per staff id); a missing entry throws (fetch failed).
Future<SessionController> session(
  Map<String, Map<String, dynamic>> answers, {
  TokenStore? store,
}) async {
  final auth = FakeAuthService()
    ..onStaff = ((d, id, p) async => 'token-$id')
    ..onAuthContext = (t) async {
      final json = answers[t.replaceFirst('token-', '')];
      if (json == null) {
        throw const ApiException(
          kind: ApiErrorKind.network,
          message: 'offline',
        );
      }
      return PosAuthContext.fromJson(json);
    };
  final s = SessionController(auth, store ?? MemoryTokenStore());
  await s.loginDevice('REG-1', 'secret');
  return s;
}

const sidebarLabels = [
  'Sales',
  'Orders',
  'Sales history',
  'Customers',
  'Inventory',
  'Promotions',
  'Analytics',
  'Reports',
  'Settings',
];
const restaurantWords = [
  'Kitchen',
  'Table',
  'Restaurant',
  'Preparing',
  'Ready',
];

void main() {
  group('business type from /auth/me', () {
    test('1 / 2. RETAIL and RESTAURANT are recognised', () {
      expect(ctx(me()).businessType, BusinessType.retail);
      expect(
        ctx(me(businessType: 'RESTAURANT')).businessType,
        BusinessType.restaurant,
      );
    });

    test('3. missing / invalid business type is null (never guessed)', () {
      for (final bad in [
        null,
        '',
        'retail',
        'Restaurant',
        'KITCHEN',
        1,
        true,
      ]) {
        expect(ctx(me(businessType: bad)).businessType, isNull, reason: '$bad');
      }
      final noBusiness = me()..remove('business');
      expect(ctx(noBusiness).businessType, isNull);
      expect(ctx({...me(), 'business': 'RETAIL'}).businessType, isNull);
    });

    test('8. only business.business_type counts — other / spoofed fields are ignored', () {
      final spoofed = ctx(
        me(
          extra: {'business_type': 'RESTAURANT', 'businessType': 'RESTAURANT'},
        ),
      );
      expect(spoofed.businessType, BusinessType.retail);
      final restaurant = ctx(
        me(businessType: 'RESTAURANT', extra: {'business_type': 'RETAIL'}),
      );
      expect(restaurant.businessType, BusinessType.restaurant);
    });
  });

  group('ThriveWoo POS licence from /auth/me', () {
    test('9 / 10. licensed only when the server says exactly true', () {
      expect(ctx(me()).licensed, isTrue);
      for (final v in [false, null, 'true', 1, 'yes']) {
        expect(ctx(me(licensed: v)).licensed, isFalse, reason: '$v');
      }
      expect(ctx(me()..remove('jacky')).licensed, isFalse);
      expect(ctx({...me(licensed: false), 'licensed': true}).licensed, isFalse);
    });
  });

  group('module boundary', () {
    const restaurantModules = [
      PosModule.restaurantOrders,
      PosModule.tables,
      PosModule.kitchen,
      PosModule.kitchenDisplay,
    ];
    final retailModules = PosModule.values.where((m) => !m.restaurantOnly);

    test('4 / 6. RETAIL (and an unknown type) is never entitled to restaurant modules', () {
      for (final t in [BusinessType.retail, null]) {
        for (final m in restaurantModules) {
          expect(PosModules.isEntitled(m, t), isFalse, reason: '$t $m');
          expect(PosModules.isAvailable(m, t), isFalse, reason: '$t $m');
        }
      }
    });

    test('RESTAURANT is entitled to restaurant modules but none is built, so none is shown', () {
      for (final m in restaurantModules) {
        expect(
          PosModules.isEntitled(m, BusinessType.restaurant),
          isTrue,
          reason: '$m',
        );
        expect(
          PosModules.isAvailable(m, BusinessType.restaurant),
          isFalse,
          reason: '$m',
        );
      }
    });

    test(
      '5. every existing retail module stays available for every business type',
      () {
        for (final t in [BusinessType.retail, BusinessType.restaurant, null]) {
          for (final m in retailModules) {
            expect(PosModules.isAvailable(m, t), isTrue, reason: '$t $m');
          }
        }
        for (final s in PosSection.values) {
          expect(moduleOf(s).restaurantOnly, isFalse, reason: '$s');
        }
      },
    );
  });

  group('sidebar', () {
    Future<void> pump(WidgetTester tester, SessionController? s) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bar = MaterialApp(
        home: Scaffold(
          body: PosSidebar(
            collapsed: false,
            brandTitle: 'ThriveWoo POS',
            onOpenReports: () {},
          ),
        ),
      );
      await tester.pumpWidget(
        s == null
            ? bar
            : ChangeNotifierProvider<SessionController>.value(
                value: s,
                child: bar,
              ),
      );
    }

    for (final type in ['RETAIL', 'RESTAURANT', null]) {
      testWidgets(
        '4 / 5. $type: the retail navigation is all there, nothing restaurant-only',
        (tester) async {
          final s = await session({'A': me(staff: 'A', businessType: type)});
          addTearDown(s.dispose);
          await s.loginStaff('A', '1234');
          await pump(tester, s);
          for (final label in sidebarLabels) {
            expect(find.text(label), findsOneWidget, reason: '$type $label');
          }
          for (final w in restaurantWords) {
            expect(find.textContaining(w), findsNothing, reason: '$type $w');
          }
        },
      );
    }

    testWidgets(
      'without a signed-in session the retail navigation still shows',
      (tester) async {
        await pump(tester, null);
        for (final label in sidebarLabels) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
      },
    );
  });

  group('session lifecycle', () {
    test('7 / 11. business type and licence come from the session and follow a refresh', () async {
      final answers = {'A': me(staff: 'A')};
      final s = await session(answers);
      addTearDown(s.dispose);
      expect(s.businessType, isNull);
      expect(s.isLicensed, isFalse);
      await s.loginStaff('A', '1234');
      expect(s.businessType, BusinessType.retail);
      expect(s.isLicensed, isTrue);
      answers['A'] = me(staff: 'A', licensed: false);
      await s.refreshAuthContext();
      expect(s.isLicensed, isFalse, reason: 'licence revoked server-side');
      expect(s.businessType, BusinessType.retail);
    });

    test(
      '8. a stored value on the device never changes the business type',
      () async {
        final store = MemoryTokenStore();
        await store.write('business_type', 'RESTAURANT');
        await store.write('licensed', 'true');
        final s = await session({
          'A': me(staff: 'A', licensed: false),
        }, store: store);
        addTearDown(s.dispose);
        await s.loginStaff('A', '1234');
        expect(s.businessType, BusinessType.retail);
        expect(s.isLicensed, isFalse);
      },
    );

    test('12. sign-out clears business type and licence', () async {
      final s = await session({
        'A': me(staff: 'A', businessType: 'RESTAURANT'),
      });
      addTearDown(s.dispose);
      await s.loginStaff('A', '1234');
      expect(s.businessType, BusinessType.restaurant);
      s.logoutStaff();
      expect(s.businessType, isNull);
      expect(s.isLicensed, isFalse);
    });

    test('13. the next user never inherits the previous user\'s business type / licence (even if their fetch fails)', () async {
      final s = await session({
        'A': me(staff: 'A', businessType: 'RESTAURANT'),
        'C': me(staff: 'C', licensed: false),
      });
      addTearDown(s.dispose);
      await s.loginStaff('A', '1234');
      expect(s.isLicensed, isTrue);
      // B signs in straight over A (no sign-out) and B's /auth/me fails.
      await s.loginStaff('B', '1234');
      expect(s.businessType, isNull);
      expect(s.isLicensed, isFalse);
      expect(s.authContext, isNull);
      // A again, then sign-out and C: C's own (unlicensed) state.
      await s.loginStaff('A', '1234');
      s.logoutStaff();
      await s.loginStaff('C', '1234');
      expect(s.isLicensed, isFalse);
      expect(s.businessType, BusinessType.retail);
    });

    test('a session expiry (401) clears them too', () async {
      final s = await session({'A': me(staff: 'A')});
      addTearDown(s.dispose);
      await s.loginStaff('A', '1234');
      s.handleUnauthorized();
      expect(s.isLicensed, isFalse);
      expect(s.businessType, isNull);
    });
  });

  group('Quick Bill licence refusal', () {
    Future<VoiceController> refusedWith(
      String code,
      String serverMessage,
    ) async {
      final backend = FakeBackend(
        (_) => (403, fail(403, serverMessage, code: code)),
      );
      final speech = FakeRecognizer();
      final v = controllerFor(backend, speech);
      addTearDown(v.dispose);
      await speak(v, speech, 'Bill two coffees');
      expect(v.previewState, VoicePreviewState.failed);
      expect(v.preview, isNull);
      return v;
    }

    test('14 / 15. no licence: a specific ThriveWoo POS message, never "Jacky", not retryable', () async {
      final v = await refusedWith(
        PosErrorCodes.licenceNotActive,
        'You do not have a Jacky licence. Ask your administrator.',
      );
      expect(
        v.previewError,
        'Your ThriveWoo POS licence is not active. Please contact your business administrator.',
      );
      expect(v.previewError!.toLowerCase(), isNot(contains('jacky')));
      expect(v.previewError, isNot(contains('Something went wrong')));
      expect(v.previewRetryable, isFalse);
    });

    test('14 / 15. business not activated / not set up: specific ThriveWoo POS messages', () async {
      final cases = {
        PosErrorCodes.subscriptionInactive: LicenceMessages.notActivated,
        PosErrorCodes.businessTypeNotConfigured: LicenceMessages.notConfigured,
      };
      for (final MapEntry(key: code, value: message) in cases.entries) {
        final v = await refusedWith(
          code,
          'Jacky is not active for this business',
        );
        expect(v.previewError, message, reason: code);
        expect(v.previewError!.toLowerCase(), isNot(contains('jacky')));
        expect(v.previewError, contains('ThriveWoo POS'));
      }
      for (final m in [
        LicenceMessages.notLicensed,
        LicenceMessages.notActivated,
        LicenceMessages.notConfigured,
        LicenceMessages.notForBusinessType,
      ]) {
        expect(m.toLowerCase(), isNot(contains('jacky')));
      }
    });

    test('16. other Quick Bill refusals keep their existing wording', () async {
      final v = await refusedWith(PosErrorCodes.permissionDenied, 'denied');
      expect(v.previewError, isNot(contains('ThriveWoo')));
      expect(v.previewError, contains('permission'));
    });

    test('17. a licensed user\'s Quick Bill is unchanged', () async {
      final backend = FakeBackend(readyCoffeeWater);
      final speech = FakeRecognizer();
      final v = controllerFor(backend, speech);
      addTearDown(v.dispose);
      await speak(v, speech, 'Bill two coffees and one water');
      expect(v.previewState, VoicePreviewState.loaded);
      expect(v.previewError, isNull);
    });
  });
}
