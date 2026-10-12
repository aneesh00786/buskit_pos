// Responsive sign-in layout (device activation + cashier sign-in): split
// branding / form layout on wide windows with the form centred and capped at
// AuthLayout.formMaxWidth; a stacked layout with 24 px side margins on narrow
// screens; no overflow at any size, including with the keyboard open.
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/auth/ui/auth_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

final form = find.byKey(const Key('auth-form'));
final brandPanel = find.byKey(const Key('auth-brand-panel'));
final brandHeader = find.byKey(const Key('auth-brand-header'));

Future<SessionController> pumpAt(
  WidgetTester t,
  Widget page,
  Size size, {
  double keyboard = 0,
  FakeAuthService? auth,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(t.view.reset);
  final session = SessionController(
    auth ?? FakeAuthService(),
    MemoryTokenStore(),
  );
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: session,
      child: MaterialApp(theme: AppTheme.light(), home: page),
    ),
  );
  await t.pumpAndSettle();
  return session;
}

/// Inputs, primary button and supporting text all share the form's width.
void expectConsistentWidths(WidgetTester t) {
  final w = t.getSize(form).width;
  for (final f in [find.byType(TextField), find.byType(FilledButton)]) {
    for (final e in f.evaluate()) {
      expect(
        t.getSize(find.byWidget(e.widget)).width,
        moreOrLessEquals(w, epsilon: 0.5),
      );
    }
  }
}

const pages = <String, Widget>{
  'device activation': DeviceLoginPage(),
  'cashier sign-in': StaffLoginPage(),
};

void main() {
  for (final entry in pages.entries) {
    group(entry.key, () {
      for (final size in [
        const Size(1920, 1080),
        const Size(1366, 768),
        const Size(1024, 640),
      ]) {
        testWidgets(
          'large desktop ${size.width.toInt()}x${size.height.toInt()}: split layout, form capped at 420 and centred in the right panel',
          (t) async {
            await pumpAt(t, entry.value, size);
            expect(t.takeException(), isNull);
            expect(brandPanel, findsOneWidget);
            expect(brandHeader, findsNothing);
            final panel = t.getRect(brandPanel);
            expect(
              panel.width,
              moreOrLessEquals(
                AuthLayout.brandPanelWidth(size.width),
                epsilon: 0.5,
              ),
            );
            final r = t.getRect(form);
            expect(
              r.width,
              moreOrLessEquals(AuthLayout.formMaxWidth, epsilon: 0.5),
              reason: 'not stretched across a large window',
            );
            expect(
              r.center.dx,
              moreOrLessEquals((panel.right + size.width) / 2, epsilon: 1),
            );
            expect(r.center.dy, moreOrLessEquals(size.height / 2, epsilon: 1));
            expectConsistentWidths(t);
          },
        );
      }

      testWidgets('resizing keeps the form centred', (t) async {
        await pumpAt(t, entry.value, const Size(1920, 1080));
        t.view.physicalSize = const Size(1200, 900);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        final panelRight = t.getRect(brandPanel).right;
        final r = t.getRect(form);
        expect(
          r.center.dx,
          moreOrLessEquals((panelRight + 1200) / 2, epsilon: 1),
        );
        expect(r.center.dy, moreOrLessEquals(450, epsilon: 1));
      });

      for (final size in [
        const Size(900, 700),
        const Size(AuthLayout.splitMinWidth, 600),
      ]) {
        testWidgets(
          'medium ${size.width.toInt()}x${size.height.toInt()}: split kept, branding not squeezed, form shrinks with padding',
          (t) async {
            await pumpAt(t, entry.value, size);
            expect(t.takeException(), isNull);
            expect(brandPanel, findsOneWidget);
            final panel = t.getRect(brandPanel);
            expect(panel.width, greaterThanOrEqualTo(320));
            final r = t.getRect(form);
            expect(r.width, lessThanOrEqualTo(AuthLayout.formMaxWidth));
            expect(
              r.left - panel.right,
              greaterThanOrEqualTo(AuthLayout.splitGutter - 0.5),
            );
            expect(
              size.width - r.right,
              greaterThanOrEqualTo(AuthLayout.splitGutter - 0.5),
            );
            expect(
              r.center.dx,
              moreOrLessEquals((panel.right + size.width) / 2, epsilon: 1),
            );
            expectConsistentWidths(t);
          },
        );
      }

      for (final size in [
        const Size(390, 844),
        const Size(360, 640),
        const Size(AuthLayout.splitMinWidth - 1, 700),
      ]) {
        testWidgets(
          'narrow ${size.width.toInt()}x${size.height.toInt()}: stacked layout, full width minus 24 px margins (capped at 420)',
          (t) async {
            await pumpAt(t, entry.value, size);
            expect(t.takeException(), isNull);
            expect(brandPanel, findsNothing);
            expect(brandHeader, findsOneWidget);
            expect(t.getRect(brandHeader).width, size.width);
            final r = t.getRect(form);
            final expected = (size.width - 2 * AuthLayout.stackedGutter).clamp(
              0.0,
              AuthLayout.formMaxWidth,
            );
            expect(r.width, moreOrLessEquals(expected, epsilon: 0.5));
            expect(r.center.dx, moreOrLessEquals(size.width / 2, epsilon: 1));
            expect(
              t.getRect(form).top,
              greaterThan(t.getRect(brandHeader).bottom),
            );
            expectConsistentWidths(t);
          },
        );
      }

      testWidgets(
        'phone with the keyboard open: no overflow, still scrollable to the button',
        (t) async {
          await pumpAt(t, entry.value, const Size(360, 640), keyboard: 300);
          await t.tap(find.byType(TextField).first);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          final r = t.getRect(form);
          expect(
            r.left,
            moreOrLessEquals(AuthLayout.stackedGutter, epsilon: 0.5),
          );
          expect(
            r.right,
            moreOrLessEquals(360 - AuthLayout.stackedGutter, epsilon: 0.5),
          );
          await t.ensureVisible(find.byType(FilledButton));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(
            t.getRect(find.byType(FilledButton)).bottom,
            lessThanOrEqualTo(640 - 300),
          );
        },
      );

      testWidgets(
        'short landscape window with the keyboard open: no overflow',
        (t) async {
          await pumpAt(t, entry.value, const Size(1024, 400), keyboard: 200);
          expect(t.takeException(), isNull);
          expect(brandPanel, findsOneWidget);
        },
      );
    });
  }

  testWidgets(
    'the error message uses the form width (large desktop, failed activation)',
    (t) async {
      final auth = FakeAuthService()
        ..onDevice = (i, s) async =>
            throw apiError(401, message: 'Invalid device credentials');
      await pumpAt(
        t,
        const DeviceLoginPage(),
        const Size(1920, 1080),
        auth: auth,
      );
      await t.enterText(
        find.widgetWithText(TextField, 'Device identifier'),
        'dev-1',
      );
      await t.enterText(
        find.widgetWithText(TextField, 'Device secret'),
        'secret',
      );
      await t.pump();
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      final message = find.descendant(
        of: form,
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(message, findsOneWidget);
      expect(
        t.getSize(message).width,
        moreOrLessEquals(AuthLayout.formMaxWidth, epsilon: 0.5),
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'other screens sharing the scaffold (open shift) keep their layout',
    (t) async {
      await pumpAt(t, const ShiftOpenPage(), const Size(1920, 1080));
      expect(brandPanel, findsNothing);
      expect(brandHeader, findsNothing);
      expect(form, findsNothing);
      expect(find.text('Open shift'), findsWidgets);
    },
  );
}
