// Left-side POS illustration (assets/images/img_left.png) on the device
// activation and cashier sign-in screens: centred in the branding panel
// between the heading and the supporting text, within 80% of the panel's
// content width and 42% of its height, aspect ratio kept, never behind the
// form; on narrow screens a smaller copy only when there is room and the
// keyboard is closed.
import 'dart:ui' as ui;

import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/auth/ui/auth_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

final illustration = find.byKey(const Key('auth-illustration'));
final brandPanel = find.byKey(const Key('auth-brand-panel'));
final brandHeader = find.byKey(const Key('auth-brand-header'));
final form = find.byKey(const Key('auth-form'));

Future<void> pumpAt(
  WidgetTester t,
  Widget page,
  Size size, {
  double keyboard = 0,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(t.view.reset);
  final session = SessionController(FakeAuthService(), MemoryTokenStore());
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: session,
      child: MaterialApp(theme: AppTheme.light(), home: page),
    ),
  );
  await t.pumpAndSettle();
}

void expectAspectKept(Rect r) => expect(
  r.width / r.height,
  moreOrLessEquals(AuthLayout.illustrationAspectRatio, epsilon: 0.01),
);

Finder inPanel(String text) =>
    find.descendant(of: brandPanel, matching: find.text(text));

const pages = <String, Widget>{
  'device activation': DeviceLoginPage(),
  'cashier sign-in': StaffLoginPage(),
};

void main() {
  test('the illustration is bundled and decodes (1536 x 1024, matching the aspect ratio used for layout)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final data = await rootBundle.load(AuthLayout.illustrationAsset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    expect([frame.image.width, frame.image.height], [1536, 1024]);
    expect(
      frame.image.width / frame.image.height,
      AuthLayout.illustrationAspectRatio,
    );
  });

  for (final entry in pages.entries) {
    group(entry.key, () {
      for (final size in [
        const Size(1920, 1080), // large desktop
        const Size(1366, 768),
        const Size(1024, 768), // tablet landscape
        const Size(1024, 640), // desktop minimum window
        const Size(900, 700), // medium
      ]) {
        testWidgets(
          'split ${size.width.toInt()}x${size.height.toInt()}: centred in the panel between heading and text, within 80% width / 42% height, not behind the form',
          (t) async {
            await pumpAt(t, entry.value, size);
            expect(t.takeException(), isNull);
            expect(illustration, findsOneWidget);
            final panel = t.getRect(brandPanel);
            final img = t.getRect(illustration);
            expectAspectKept(img);
            expect(
              img.width,
              lessThanOrEqualTo((panel.width - 80) * 0.8 + 0.5),
            );
            expect(
              img.height,
              lessThanOrEqualTo((panel.height - 80) * 0.42 + 0.5),
            );
            // At least 65% of the width, unless the height cap is what limits it.
            final contentH = panel.height - 80;
            final heightCap = (contentH * 0.42).clamp(
              0.0,
              contentH - AuthLayout.brandPanelTextHeight,
            );
            expect(
              img.width >= (panel.width - 80) * 0.65 - 0.5 ||
                  img.height >= heightCap - 0.5,
              isTrue,
            );
            expect(
              img.center.dx,
              moreOrLessEquals(panel.center.dx, epsilon: 1),
            );
            expect(
              t.getRect(inPanel('ThriveWoo POS')).bottom,
              lessThan(img.top),
            );
            expect(
              t.getRect(inPanel('Point of sale')).top,
              greaterThan(img.bottom),
            );
            expect(
              t.getRect(inPanel('Point of sale')).bottom,
              lessThanOrEqualTo(panel.bottom),
              reason: 'fits without scrolling',
            );
            expect(
              img.right,
              lessThanOrEqualTo(t.getRect(form).left),
              reason: 'never behind the form',
            );
            expect(
              panel.contains(img.topLeft) &&
                  panel.contains(img.bottomRight - const Offset(1, 1)),
              isTrue,
            );
          },
        );
      }

      testWidgets(
        'short window with the keyboard open (split): illustration left out, no overflow',
        (t) async {
          await pumpAt(t, entry.value, const Size(1024, 400), keyboard: 200);
          expect(t.takeException(), isNull);
          expect(brandPanel, findsOneWidget);
          expect(illustration, findsNothing);
        },
      );

      for (final size in [const Size(390, 844), const Size(800, 1280)]) {
        testWidgets(
          'stacked ${size.width.toInt()}x${size.height.toInt()}: smaller illustration between brand strip and form; the form stays on screen',
          (t) async {
            await pumpAt(t, entry.value, size);
            expect(t.takeException(), isNull);
            expect(brandHeader, findsOneWidget);
            expect(illustration, findsOneWidget);
            final img = t.getRect(illustration);
            expectAspectKept(img);
            expect(
              img.width,
              lessThanOrEqualTo(AuthLayout.stackedIllustrationMaxWidth + 0.5),
            );
            expect(
              img.width,
              lessThanOrEqualTo(
                size.width - 2 * AuthLayout.stackedGutter + 0.5,
              ),
            );
            expect(img.height, lessThanOrEqualTo(size.height * 0.25 + 0.5));
            expect(img.center.dx, moreOrLessEquals(size.width / 2, epsilon: 1));
            expect(img.top, greaterThan(t.getRect(brandHeader).bottom));
            expect(img.bottom, lessThan(t.getRect(form).top));
            expect(
              t.getRect(find.byType(FilledButton)).bottom,
              lessThanOrEqualTo(size.height),
              reason: 'primary action visible without scrolling',
            );
          },
        );
      }

      testWidgets(
        'portrait tablet 800x1280 with the keyboard open: illustration hidden even though height remains',
        (t) async {
          await pumpAt(t, entry.value, const Size(800, 1280));
          expect(illustration, findsOneWidget);
          t.view.viewInsets = const FakeViewPadding(bottom: 400);
          await t.tap(find.byType(TextField).first);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(illustration, findsNothing);
          expect(
            t.getRect(find.byType(FilledButton)).bottom,
            lessThanOrEqualTo(1280 - 400),
          );
        },
      );

      testWidgets('short phone 360x640: no illustration, form unchanged', (
        t,
      ) async {
        await pumpAt(t, entry.value, const Size(360, 640));
        expect(t.takeException(), isNull);
        expect(illustration, findsNothing);
        expect(t.getRect(form).top, greaterThan(t.getRect(brandHeader).bottom));
      });

      testWidgets(
        'phone with the keyboard open: illustration hidden, inputs and button reachable, no overflow',
        (t) async {
          await pumpAt(t, entry.value, const Size(390, 844));
          expect(illustration, findsOneWidget);
          t.view.viewInsets = const FakeViewPadding(bottom: 336);
          await t.tap(find.byType(TextField).first);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(illustration, findsNothing);
          expect(
            t.getRect(find.byType(TextField).first).bottom,
            lessThanOrEqualTo(844 - 336),
          );
          await t.ensureVisible(find.byType(FilledButton));
          await t.pumpAndSettle();
          expect(
            t.getRect(find.byType(FilledButton)).bottom,
            lessThanOrEqualTo(844 - 336),
          );
          final r = t.getRect(form);
          expect(
            r.left,
            moreOrLessEquals(AuthLayout.stackedGutter, epsilon: 0.5),
          );
          expect(
            r.right,
            moreOrLessEquals(390 - AuthLayout.stackedGutter, epsilon: 0.5),
          );
        },
      );
    });
  }

  testWidgets(
    'the image actually renders in the panel (decoded asset, framed card)',
    (t) async {
      await pumpAt(t, const DeviceLoginPage(), const Size(1366, 768));
      final image = t.widget<Image>(
        find.descendant(of: illustration, matching: find.byType(Image)),
      );
      expect(image.fit, BoxFit.contain);
      expect(image.excludeFromSemantics, isTrue, reason: 'decorative');
      await t.runAsync(
        () => precacheImage(image.image, t.element(illustration)),
      );
      await t.pumpAndSettle();
      expect(
        find.descendant(of: illustration, matching: find.byType(RawImage)),
        findsOneWidget,
      );
      final raw = t.widget<RawImage>(
        find.descendant(of: illustration, matching: find.byType(RawImage)),
      );
      expect(raw.image, isNotNull);
      expect(
        find.descendant(of: illustration, matching: find.byType(ClipRRect)),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'open shift (same scaffold, not a sign-in screen) shows no illustration',
    (t) async {
      await pumpAt(t, const ShiftOpenPage(), const Size(1920, 1080));
      expect(illustration, findsNothing);
    },
  );
}
