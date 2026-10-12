import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// TEMPORARY (testing): Android and iOS phones and tablets always show the
/// app in landscape (landscape-left or landscape-right), even when the device
/// is held upright. Desktop (macOS / Windows) is not affected.
///
/// How, per platform (change these together):
/// - Android: [applyLandscapeLock] plus, in
///   android/app/src/main/AndroidManifest.xml, MainActivity
///   `android:screenOrientation="sensorLandscape"` and the
///   `PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY` property. Where Android
///   still gives a portrait window, [ForcedLandscape] turns the app.
/// - iPhone: ios/Runner/Info.plist lists only the landscape orientations, so
///   iOS turns the screen.
/// - iPad: Info.plist lists ALL orientations and keeps
///   `UIRequiresFullScreen`; held upright, the app gets a full-screen portrait
///   window and [ForcedLandscape] draws it in landscape. (A landscape-only iPad
///   app is letterboxed by iPadOS 26 instead of turned.)
///
/// To restore normal orientation behaviour, set this to false and revert
/// those native settings (each is marked "TEMPORARY (testing)" in place).
/// Details and platform limits: docs/LANDSCAPE_TESTING_MODE.md.
const bool kForceLandscapeOnMobile = true;

const List<DeviceOrientation> landscapeOrientations = [
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

bool landscapeLockApplies(TargetPlatform platform) =>
    kForceLandscapeOnMobile &&
    !kIsWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

/// Android only: asks for landscape before `runApp()` so the first frame is
/// already landscape. Not used on iOS: Info.plist already makes iPhone
/// landscape-only, and on iPad this request would bring back iPadOS 26's
/// letterboxing (the iPad must accept portrait so [ForcedLandscape] can fill
/// the screen).
Future<void> applyLandscapeLock({TargetPlatform? platform}) async {
  final p = platform ?? defaultTargetPlatform;
  if (!landscapeLockApplies(p) || p != TargetPlatform.android) return;
  await SystemChrome.setPreferredOrientations(landscapeOrientations);
}

/// iPadOS 26 no longer turns the screen for an app (it letterboxes a
/// landscape-only app on an iPad held in portrait), and Android may ignore
/// the lock on some large screens. When the OS still hands the app a portrait
/// window on Android / iOS, this draws the whole app a quarter-turn
/// counter-clockwise so it fills the screen in landscape anyway.
///
/// - The widget tree has the same shape whether or not it is turned, so
///   turning the device never rebuilds the app or loses its state.
/// - Safe-area and keyboard insets are moved to the matching edges of the
///   turned UI. The on-screen keyboard and status bar stay in the device's
///   portrait orientation (the OS draws them); the keyboard therefore covers
///   the LEFT edge of the turned UI.
/// - Sits directly under the root View, above every MaterialApp, so dialogs
///   and overlays are turned too.
class ForcedLandscape extends StatelessWidget {
  const ForcedLandscape({super.key, required this.child, this.platform});

  final Widget child;

  /// For tests; defaults to [defaultTargetPlatform].
  final TargetPlatform? platform;

  /// Clockwise quarter turns applied in a portrait window (3 = one quarter
  /// turn counter-clockwise).
  static const int portraitQuarterTurns = 3;

  /// The [MediaQueryData] the turned UI sees: size flipped and each inset
  /// moved to the edge it lands on after a counter-clockwise quarter turn
  /// (device bottom -> UI left, left -> top, top -> right, right -> bottom).
  static MediaQueryData turned(MediaQueryData data) {
    EdgeInsets turn(EdgeInsets e) =>
        EdgeInsets.fromLTRB(e.bottom, e.left, e.top, e.right);
    return data.copyWith(
      size: data.size.flipped,
      padding: turn(data.padding),
      viewPadding: turn(data.viewPadding),
      viewInsets: turn(data.viewInsets),
      systemGestureInsets: turn(data.systemGestureInsets),
      displayFeatures: const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!landscapeLockApplies(platform ?? defaultTargetPlatform)) return child;
    final data = MediaQuery.of(context);
    final portrait = data.size.height > data.size.width;
    return MediaQuery(
      data: portrait ? turned(data) : data,
      child: RotatedBox(
        quarterTurns: portrait ? portraitQuarterTurns : 0,
        child: child,
      ),
    );
  }
}
