// TEMPORARY (testing): ForcedLandscape draws the app a quarter-turn
// counter-clockwise when Android / iOS hand it a portrait window (iPadOS 26
// letterboxes instead of turning the screen), so it always fills the screen
// in landscape. Desktop untouched; app state survives turning the device.
import 'dart:io';

import 'package:buskit_pos/core/platform/landscape_lock.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/auth/ui/auth_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

const portrait = Size(744, 1133); // iPad mini, held upright
const landscape = Size(1133, 744);

void setView(
  WidgetTester t,
  Size size, {
  FakeViewPadding padding = FakeViewPadding.zero,
  double keyboard = 0,
}) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.view.padding = padding;
  t.view.viewPadding = padding;
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
}

/// Reports the MediaQuery the app sees, and keeps a counter to prove state
/// survives turning.
class Probe extends StatefulWidget {
  const Probe({super.key});
  static MediaQueryData? seen;
  @override
  State<Probe> createState() => ProbeState();
}

class ProbeState extends State<Probe> {
  int taps = 0;
  @override
  Widget build(BuildContext context) {
    Probe.seen = MediaQuery.of(context);
    return GestureDetector(
      onTap: () => setState(() => taps++),
      child: Text('taps $taps', textDirection: TextDirection.ltr),
    );
  }
}

int turnsOf(WidgetTester t) =>
    t.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns;

void main() {
  tearDown(() => Probe.seen = null);

  for (final p in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '$p portrait window: app turned a quarter counter-clockwise and sees a landscape screen',
      (t) async {
        setView(t, portrait);
        addTearDown(t.view.reset);
        await t.pumpWidget(ForcedLandscape(platform: p, child: const Probe()));
        expect(turnsOf(t), ForcedLandscape.portraitQuarterTurns);
        expect(Probe.seen!.size, landscape);
        expect(Probe.seen!.orientation, Orientation.landscape);
      },
    );
  }

  testWidgets(
    'landscape window (OS turned the screen): nothing is turned or changed',
    (t) async {
      setView(t, landscape, padding: const FakeViewPadding(top: 24));
      addTearDown(t.view.reset);
      await t.pumpWidget(
        const ForcedLandscape(platform: TargetPlatform.iOS, child: Probe()),
      );
      expect(turnsOf(t), 0);
      expect(Probe.seen!.size, landscape);
      expect(Probe.seen!.padding, const EdgeInsets.only(top: 24));
    },
  );

  for (final p in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('$p (desktop): never turned, even in a tall window', (t) async {
      setView(t, portrait);
      addTearDown(t.view.reset);
      await t.pumpWidget(ForcedLandscape(platform: p, child: const Probe()));
      expect(find.byType(RotatedBox), findsNothing);
      expect(Probe.seen!.size, portrait);
    });
  }

  testWidgets(
    'insets move with the turn: status bar -> right, home indicator and keyboard -> left',
    (t) async {
      setView(
        t,
        portrait,
        padding: const FakeViewPadding(top: 24, bottom: 20),
        keyboard: 300,
      );
      addTearDown(t.view.reset);
      await t.pumpWidget(
        const ForcedLandscape(platform: TargetPlatform.iOS, child: Probe()),
      );
      final m = Probe.seen!;
      expect(m.padding.right, 24, reason: 'status bar (device top)');
      expect(m.padding.top, 0);
      expect(m.viewInsets.left, 300, reason: 'keyboard (device bottom)');
      expect(m.viewInsets.bottom, 0);
      expect(m.viewPadding.left, 20, reason: 'home indicator (device bottom)');
    },
  );

  testWidgets('turning the device keeps app state (no rebuild of the app)', (
    t,
  ) async {
    setView(t, portrait);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      const ForcedLandscape(platform: TargetPlatform.iOS, child: Probe()),
    );
    final before = t.state<ProbeState>(find.byType(Probe));
    await t.tap(find.byType(Probe));
    await t.pump();
    setView(t, landscape);
    await t.pump();
    expect(turnsOf(t), 0);
    expect(identical(t.state<ProbeState>(find.byType(Probe)), before), isTrue);
    expect(find.text('taps 1'), findsOneWidget);
    setView(t, portrait);
    await t.pump();
    expect(turnsOf(t), ForcedLandscape.portraitQuarterTurns);
    expect(identical(t.state<ProbeState>(find.byType(Probe)), before), isTrue);
  });

  testWidgets(
    'real activation screen on an upright iPad: split landscape layout, fills the screen, typing and tapping work',
    (t) async {
      FlutterSecureStorage.setMockInitialValues({});
      setView(t, portrait);
      addTearDown(t.view.reset);
      final auth = FakeAuthService();
      final calls = <String>[];
      auth.onDevice = (id, secret) async {
        calls.add('$id/$secret');
        return 'device-token';
      };
      final session = SessionController(auth, MemoryTokenStore());
      await t.pumpWidget(
        ForcedLandscape(
          platform: TargetPlatform.iOS,
          child: ChangeNotifierProvider.value(
            value: session,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const DeviceLoginPage(),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(
        find.byKey(const Key('auth-brand-panel')),
        findsOneWidget,
        reason: 'wide (landscape) layout',
      );
      // The turned app covers the whole upright screen.
      final screen = t.getRect(find.byType(MaterialApp));
      expect(screen.width, moreOrLessEquals(portrait.width, epsilon: 0.01));
      expect(screen.height, moreOrLessEquals(portrait.height, epsilon: 0.01));
      await t.enterText(
        find.widgetWithText(TextField, 'Device identifier'),
        'DEV-1',
      );
      await t.enterText(
        find.widgetWithText(TextField, 'Device secret'),
        's3cret',
      );
      await t.pump();
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      expect(calls, [
        'DEV-1/s3cret',
      ], reason: 'hit testing goes through the turn');
    },
  );

  test('main() wraps the app in ForcedLandscape', () {
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains(
        'runApp(ForcedLandscape(child: rootWidget(release: kReleaseMode)))',
      ),
    );
  });
}
