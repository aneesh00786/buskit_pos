# Always-landscape mode (temporary, for testing)

On Android and iOS phones and tablets, ThriveWoo POS always shows its
landscape layout and fills the screen, even when the device is held upright.
Both landscape directions are allowed. macOS and Windows are not affected.
**Undo this before a production release** (see the last section).

## How each platform gets there

| Platform | Mechanism |
|---|---|
| Android | `applyLandscapeLock()` asks for landscape-left/right before `runApp()`. MainActivity has `android:screenOrientation="sensorLandscape"`, so the launch window is landscape too. On Android 16+ tablets, `PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY` stops the system ignoring the lock (API 36 only). |
| iPhone | `ios/Runner/Info.plist` `UISupportedInterfaceOrientations` lists only LandscapeLeft and LandscapeRight, so iOS turns the screen. |
| iPad | `UISupportedInterfaceOrientations~ipad` lists **all four** orientations, and `UIRequiresFullScreen` is true. When the iPad is held upright, the app gets a full-screen portrait window, and `ForcedLandscape` draws the app turned a quarter (see below). |
| Any Android/iOS portrait window | `ForcedLandscape` in `lib/core/platform/landscape_lock.dart` wraps the app (`runApp(ForcedLandscape(child: rootWidget(...)))`). It turns the whole app a quarter counter-clockwise and gives it a landscape screen size. |

**Why the iPad accepts portrait:** iPadOS 26 no longer turns the screen for a
landscape-only app. Held upright, it letterboxes the app, showing the
landscape layout with black bars above and below. Flutter's rotation request
is refused (`Failed to change device orientation … timeout`), with or without
`UIRequiresFullScreen`. So the iPad must accept portrait and let the app turn
itself. iPadOS 18 and earlier still turned the screen.

### ForcedLandscape details

- **Turned UI:** applies only on Android/iOS, and only while the window is
  portrait-shaped. A real landscape window is left alone.
- **App state is kept:** the widget tree has the same shape either way, so
  turning the device mid-sale keeps the cart, session and other state.
- **Insets are remapped:**

  | Device edge | Becomes the turned UI's |
  |---|---|
  | Status bar (device top) | Right edge |
  | Home indicator and on-screen keyboard (device bottom) | Left edge |

  Dialogs and overlays are turned too.
- **Limitation:** iOS draws the status bar and the on-screen keyboard in the
  device's real orientation, not the app's. With the iPad upright, the
  keyboard comes up along the turned UI's left edge, at 90° to the form.
  - On the sign-in screens, the form is on the right, so it stays visible.
  - A hardware keyboard or barcode scanner is unaffected.
  - Turning the iPad to landscape avoids the issue altogether.

## Verified (2026-10-12)

- **Tests:**
  - `test/core/platform/landscape_lock_test.dart`:
    - the Android request asks for landscape-left and landscape-right only;
    - there is no request on iOS, macOS, Windows or Linux;
    - the request comes before `runApp()`;
    - the native settings are as listed above.
  - `test/core/platform/forced_landscape_test.dart`:
    - the app is turned in a portrait window, and not in a landscape one or on
      desktop;
    - insets are remapped;
    - app state survives turning;
    - the real activation screen lays out and accepts typing and taps while
      turned.
- **Builds:**
  - `flutter build apk --debug`: the merged manifest has `sensorLandscape`
    and the large-screen property.
  - `flutter build ios --no-codesign`: the iPhone list is landscape-only and
    the iPad list has all four orientations.
- **iPad mini simulator, iPadOS 26.4, held upright:**
  - *before*: letterboxed;
  - *after*: the landscape sign-in layout fills the whole screen.

**Not verified:**

- Physical Android phones and tablets, and a physical iPad.
- Using the on-screen keyboard while the UI is turned.
- Navigating past device activation, which needs a backend sign-in.

## Known platform limits

- **Android 16+ tablets:** the opt-out property only works for apps that
  target API 36. If Android ignores the lock anyway, the app gets a portrait
  window and `ForcedLandscape` turns it.
- **iPad:** `UIRequiresFullScreen` is deprecated from iPadOS 26
  ([TN3192](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key)).
  If a future iPadOS ignores it, the app may run in a resizable window. A tall
  window would still be drawn in landscape.

## Restoring normal orientation (before production)

1. `lib/core/platform/landscape_lock.dart`: set
   `kForceLandscapeOnMobile = false`. This switches off both the Android
   request and `ForcedLandscape`. Alternatively, delete the file and, in
   `lib/main.dart`, remove `applyLandscapeLock()` and the `ForcedLandscape(...)`
   wrapper around `rootWidget(...)`.
2. `android/app/src/main/AndroidManifest.xml`: remove
   `android:screenOrientation="sensorLandscape"`, the
   `PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY` property and its comment.
3. `ios/Runner/Info.plist`:
   - add `UIInterfaceOrientationPortrait` back to the iPhone list
     `UISupportedInterfaceOrientations`;
   - remove `UIRequiresFullScreen` and the comment. The iPad list already has
     all four orientations.
4. Delete `test/core/platform/landscape_lock_test.dart` and
   `test/core/platform/forced_landscape_test.dart`, or update them. Then run
   `flutter test` and `flutter analyze`.

Every one of these settings is marked "TEMPORARY (testing)" in the code.
