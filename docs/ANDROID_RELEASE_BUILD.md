# Android release build — ThriveWoo POS

A release build (APK or App Bundle) needs two things. Without either one, it stops
before compiling (`:app:preReleaseBuild`), naming only the missing setting:

1. **A release signing key**, configured outside the repository. There is **no fallback
   to the debug key**.
2. **An HTTPS server address** passed at build time as `POS_BASE_URL`.

Debug builds are unchanged: debug signing and the development default
`http://localhost:3000`, overridable with `--dart-define=POS_BASE_URL=…`.

| | Debug (`flutter run`, `flutter build apk --debug`) | Release (`flutter build apk/appbundle --release`) |
|---|---|---|
| Signing | Android debug key | Your release/upload key only; build refused if incomplete |
| Server address | `POS_BASE_URL` or `http://localhost:3000` | `POS_BASE_URL` required: `https://`, real host, no credentials/query/fragment |
| Bad address at run time | — | The app shows "This ThriveWoo POS build is not configured" and sends nothing |

Rules are in `android/app/build.gradle.kts` (build time) and
`AppConfig.releaseBaseUrlProblem` in `lib/core/config/app_config.dart` (run time; also
covers iOS release builds).

The HTTPS rule is enforced by the app and the build, not by Android's cleartext setting.
The app's HTTP client (`dart:io`) does not follow Android's network security policy.

## 1. Create the keystore (once, by the person who owns releases)

Keep it **outside the project folder**, for example `~/thrivewoo-signing/`. The build
refuses a keystore inside the repository. Let `keytool` prompt for the passwords;
never type them on the command line.

```sh
mkdir -p ~/thrivewoo-signing && chmod 700 ~/thrivewoo-signing
keytool -genkeypair -v -keystore ~/thrivewoo-signing/thrivewoo-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
chmod 600 ~/thrivewoo-signing/thrivewoo-upload.jks
```

- Use Google Play App Signing. This key is then only the *upload* key, and a lost upload
  key can be reset through Play support.
- Back up the keystore and its passwords in the company password manager or secret
  store, not in email, chat or this repository.
- Losing the key, without Play App Signing, means you can never update the app.

## 2. Point the build at it (local machine)

**Option A — `android/key.properties`.** The file is git-ignored, so keep it that way.

```properties
storeFile=/Users/<you>/thrivewoo-signing/thrivewoo-upload.jks
storePassword=<from your password manager>
keyAlias=upload
keyPassword=<from your password manager>
```

Restrict it with `chmod 600 android/key.properties`.

**Option B — environment variables** (CI or a build machine; supply them from the CI
secret store):
`THRIVEWOO_ANDROID_KEYSTORE`, `THRIVEWOO_ANDROID_KEYSTORE_PASSWORD`,
`THRIVEWOO_ANDROID_KEY_ALIAS`, `THRIVEWOO_ANDROID_KEY_PASSWORD`.
A value in `key.properties` takes precedence over the variable.

Check that nothing secret is tracked:
`git check-ignore -v android/key.properties` and `git status`.
The root `.gitignore` also ignores `*.jks`, `*.keystore`, `*.p12`, `*.pk8`, `*.pem`,
`*.mobileprovision` and `key.properties` anywhere in the repository.

## 3. Build with the HTTPS server address

```sh
flutter build appbundle --release --dart-define=POS_BASE_URL=https://<your-api-host>
# or, for direct installs on store tablets:
flutter build apk --release --dart-define=POS_BASE_URL=https://<your-api-host>
```

- `POS_BASE_URL` is the backend origin, optionally with a path prefix, without
  `/api/v1/pos`.
- The server must present a valid TLS certificate for that host.
- Optionally add `--dart-define=APP_VERSION=<x.y.z>`, and keep `pubspec.yaml`'s
  `version:` in step (it sets `versionName` and `versionCode`).

## 4. Verify the release artifact

```sh
# Signed with the release key (prints certificate fingerprints, not secrets):
$ANDROID_HOME/build-tools/<version>/apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# Must NOT be the debug certificate:
$ANDROID_HOME/build-tools/<version>/apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk | grep -q "CN=Android Debug" && echo "WRONG KEY"
# App Bundle:
jarsigner -verify -verbose -certs build/app/outputs/bundle/release/app-release.aab | grep -m1 "CN="
```

Then install on a test device, sign the device in, and confirm requests reach the HTTPS
server.

A build made with a missing or non-HTTPS address cannot be produced by Gradle. If one
reaches a device by another route, it shows the configuration error screen.

## 5. Expected refusals (verified in Phase 17E)

| Situation | Result |
|---|---|
| No signing settings | `release signing: storeFile … storePassword … keyAlias … keyPassword … is not set` |
| Keystore path missing / inside the repository | `the keystore file named by storeFile does not exist` / `the keystore is inside the repository` |
| No `POS_BASE_URL` | `POS_BASE_URL is not set` |
| `http://…` | `POS_BASE_URL must use https://` |
| `localhost`, `127.x`, `10.0.2.2`, `0.0.0.0`, `::1` | `POS_BASE_URL is a development address` |
