# ThriveWoo POS — desktop release builds (macOS and Windows)

Companion to `docs/ANDROID_RELEASE_BUILD.md`. Phase 6ZD (packaging and distribution).

## Status (2026-10-12)

Each milestone is listed separately. "Done" means it was executed and verified;
everything else is still open.

| Milestone | macOS | Windows |
|---|---|---|
| Release build | **Done** (`flutter build macos --release`) | Pending — needs a Windows host |
| Package created and verified | **Done** — ZIP and DMG, integrity + content + secret checks | Pending — `scripts/package_windows.ps1` written, **never run** |
| Ad-hoc signature verified | **Done** (`codesign --verify --deep --strict`) | n/a |
| Distribution signature (Developer ID / Authenticode) | **Not done** — no Developer ID Application certificate on the build Mac | **Not done** — no certificate |
| Notarization | **Not done** — no certificate and no notary credentials | n/a |
| Launch smoke test of the packaged app | **Done** (identity, config screen, single instance, no network) | Pending |
| Install and full runtime test (sign-in, sales) | Pending | Pending |
| Hardware (printer, drawer, scanner) | Pending — Phase 6ZE | Pending — Phase 6ZE |

The ad-hoc macOS package runs **only on the Mac that built it**. Gatekeeper
blocks it on any other Mac. Do not hand it to a store.

## Tools

| | Version used / required |
|---|---|
| Flutter / Dart | 3.47.5 / 3.13.4 (stable) |
| macOS build host | Xcode 26.4, CocoaPods 1.17.0; `ditto`, `hdiutil`, `codesign`, `xcrun notarytool`, `xcrun stapler` (all part of macOS/Xcode) |
| Windows build host | Windows 10/11 x64, Flutter 3.47.x, Visual Studio 2022 with **Desktop development with C++**, Windows SDK (`signtool`), PowerShell 5.1+ |
| Target machines | macOS 12.0 or later; Windows 10/11 x64 with the Microsoft Visual C++ 2015–2022 Redistributable (x64) |

No packaging tool is a project dependency; `pubspec.yaml` and `pubspec.lock`
are unchanged by packaging.

## Application identity

| | macOS | Windows |
|---|---|---|
| Visible name | `ThriveWoo POS` (Dock, menu bar, `ThriveWoo POS.app`) | `ThriveWoo POS` (window title, file properties) |
| Identifier | Bundle id `com.thrivewoo.buskitPos` — **do not change**: the sandbox container that holds the offline sales data is keyed to it | Executable `buskit_pos.exe` |
| Publisher / copyright | `Copyright © 2026 ThriveWoo. All rights reserved.` | Company `ThriveWoo`, same copyright |
| Category | `public.app-category.business` | — |
| Minimum OS | macOS 12.0 | Windows 10 (manifest) |
| Icon | Flutter default artwork | Flutter default artwork |

**Icons:** no ThriveWoo icon exists in the repository (Android and iOS also use
the Flutter default). Supply the approved artwork, then replace
`macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png` (16–1024 px)
and `windows/runner/resources/app_icon.ico` (a multi-size `.ico`, 16–256 px).

## Version

There is one source: `version:` in `pubspec.yaml` (`1.0.0+1` means version
1.0.0, build 1). It sets the macOS `CFBundleShortVersionString` /
`CFBundleVersion` and the Windows `FileVersion` / `ProductVersion`. The scripts
also pass `APP_VERSION` (the sidebar version) from it. Raise the build number
for every release.

## Server address (backend configuration)

The server address is fixed at build time with
`--dart-define=POS_BASE_URL=https://<api-host>`. The packaging scripts read it
from the `POS_BASE_URL` environment variable. There is no runtime settings
file, and nothing in the repository holds a production address.

- **Missing or unsafe address:** a release build without an address (or with a
  non-HTTPS, development or credential-bearing one) shows a configuration screen
  and starts nothing else. `lib/core/config/app_config.dart` and
  `config_error_app.dart` handle this, and `test/core/config/release_config_test.dart`
  covers it. The scripts refuse such addresses before building; the exception is
  `--unconfigured` / `-Unconfigured`, which is for local smoke builds only.
- **One build per environment:** build separately for staging and production,
  each with its own address. The archive name says `configured` or `unconfigured`
  but not which server, so keep a release note of the address used.
- **Verified on macOS:**
  - An unconfigured package showed the configuration path: the offline store was
    never created and no socket was opened.
  - A package built with the reserved, never-resolving
    `https://pos.example.invalid` contained that address and started the normal
    app (the offline store was created).
  - Neither contacted any real server.

## macOS

### Build and package

```
POS_BASE_URL=https://<api-host> scripts/package_macos.sh --dmg   # store build
scripts/package_macos.sh --unconfigured --dmg                    # local smoke build
```

The script:

1. Builds the release app.
2. Copies it to `build/dist/macos/`, without extended attributes.
3. Checks the bundle id and version.
4. Re-signs the app. Nested frameworks are signed first, deepest first; then the
   app is signed with exactly `macos/Runner/Release.entitlements`. This also
   removes the debug-only `get-task-allow` entitlement that Xcode's local
   signing adds.
5. Verifies the signature and entitlements. It fails on `get-task-allow`, JIT,
   inbound network, microphone, camera, user-file access or disabled library
   validation.
6. Writes the ZIP (`ditto -c -k --keepParent`) and, if `--dmg` is given, a DMG
   (`hdiutil`, with an Applications link).
7. Runs `scripts/verify_desktop_artifact.sh` on each archive.

Artifacts (gitignored; never commit them):

```
build/dist/macos/ThriveWoo POS.app
build/dist/macos/ThriveWoo-POS-<version>-<build>-macos-<adhoc|developer-id>-<configured|unconfigured>.zip
build/dist/macos/ThriveWoo-POS-<version>-<build>-macos-<adhoc|developer-id>-<configured|unconfigured>.dmg
```

**Verified result (unconfigured, ad-hoc, 2026-10-12):**

- **ZIP** `ThriveWoo-POS-1.0.0-1-macos-adhoc-unconfigured.zip`, 21.5 MB:
  - integrity OK;
  - 37 files under `ThriveWoo POS.app/`;
  - no `__MACOSX`/`._` entries;
  - artifact check OK.
- **DMG**, 24.7 MB: checksum VALID, artifact check OK.
- **Signature:** `Signature=adhoc`, `TeamIdentifier=not set`; the entitlements
  are only `app-sandbox` and `network.client`.
- **App bundle contents:**
  - the executable;
  - the frameworks `App`, `FlutterMacOS`, `flutter_tts` and `objective_c`;
  - `flutter_assets`: fonts, shaders, manifests and `NOTICES.Z`;
  - the plugin privacy-manifest bundles;
  - `AppIcon.icns`, `Assets.car` and `MainMenu.nib`.

  There is no Dart source, project configuration or environment file. The
  `mobile_scanner` bundle is only a privacy manifest: camera scanning is off on
  desktop and there is no camera entitlement.

### Developer ID signing and notarization (needs the company's Apple account)

The build Mac has only an *Apple Development* identity, plus Apple's
intermediate "Developer ID Certification Authority" certificates. It has no
*Developer ID Application* identity, no stored `notarytool` profile and no App
Store Connect API key. Signing for distribution and notarization have
therefore **not** been done.

Prerequisites:

1. **Membership:** an Apple Developer Program membership for the
   company/organisation. Only the **Account Holder** can create Developer ID
   certificates.
2. **Certificate:** a **Developer ID Application** certificate, created in Xcode
   (Settings → Accounts → Manage Certificates → + → Developer ID Application) or
   from a CSR on developer.apple.com. It must be installed **with its private
   key** in the build Mac's login keychain. Check this with
   `security find-identity -v -p codesigning`; it must list
   `Developer ID Application: <Company> (<TEAMID>)`.
3. **Notary credentials:** store them once in the keychain, choosing one of:
   ```
   xcrun notarytool store-credentials thrivewoo-notary \
       --apple-id <apple-id-email> --team-id <TEAMID>        # prompts for an app-specific password
   xcrun notarytool store-credentials thrivewoo-notary \
       --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>   # App Store Connect API key
   ```
   Keep the `.p8` key and the passwords out of the repository.

Then:

```
DEVELOPER_ID_APPLICATION="Developer ID Application: <Company> (<TEAMID>)" \
NOTARY_PROFILE=thrivewoo-notary \
POS_BASE_URL=https://<api-host> scripts/package_macos.sh --dmg
```

With those set, the script signs every nested framework and the app with
`--options runtime --timestamp` (hardened runtime plus a secure timestamp). It
then:

1. Submits the app for notarization (`notarytool submit --wait`).
2. Staples the ticket to the app and validates it.
3. Zips the stapled app.
4. Signs, notarizes, staples and validates the DMG.
5. Runs `spctl --assess --type execute`.

Without `NOTARY_PROFILE` it stops after signing; it never notarizes an ad-hoc
app. A ZIP cannot be stapled, but the app inside it is.

After the run, verify:

```
codesign --verify --deep --strict --verbose=2 "build/dist/macos/ThriveWoo POS.app"
codesign -dvv "build/dist/macos/ThriveWoo POS.app"          # Authority=Developer ID Application…, flags=…runtime
spctl --assess --type execute -vv "build/dist/macos/ThriveWoo POS.app"   # accepted, source=Notarized Developer ID
xcrun stapler validate build/dist/macos/<name>.dmg
```

Finally, open the DMG on a **different** Mac and launch the app: there must be
no Gatekeeper warning.

### Data on the Mac (per user)

`~/Library/Containers/com.thrivewoo.buskitPos/Data/Library/Application Support/com.thrivewoo.buskitPos/`
holds offline sales, drafts, the queue and synced records in `offline/`, plus
the single-instance lock file. The device sign-in token is kept in the login
Keychain. Replacing the app keeps all of this.

## Windows

Run everything in this section on a Windows 10/11 build machine. **None of it
has been executed yet.**

### Build and package

```
flutter doctor -v
$env:POS_BASE_URL = "https://<api-host>"
.\scripts\package_windows.ps1                 # store build
.\scripts\package_windows.ps1 -Unconfigured   # local smoke build
```

The script:

1. Validates the address.
2. Runs `flutter build windows --release`.
3. Checks that the Release folder has `buskit_pos.exe`, `flutter_windows.dll`,
   `data\app.so`, `data\icudtl.dat` and `data\flutter_assets`.
4. Checks the version resource: ThriveWoo POS, ThriveWoo, `buskit_pos.exe` and
   the pubspec version.
5. Optionally signs the build.
6. Rejects source, key, debug-symbol and environment files.
7. Zips the **whole** Release folder as `ThriveWoo POS\`.
8. Re-opens the ZIP to confirm it is complete.

Output:
`build\dist\windows\ThriveWoo-POS-<version>-<build>-windows-x64-<unsigned|signed>-<configured|unconfigured>.zip`.

**Installing:**

- Install the Visual C++ 2015–2022 Redistributable (x64) if needed.
- Extract the ZIP to `C:\Program Files\ThriveWoo POS\`, or to a per-user
  folder.
- Run `buskit_pos.exe`, and pin it to the Start menu or taskbar.
- Always copy the whole folder, never the `.exe` alone.

**Installer:** the chosen format is the portable ZIP, which adds no new tool.
If an installer is wanted later, there are two options:

- an Inno Setup or WiX installer built on the Windows build machine (a tool
  outside the project);
- MSIX, which requires a signing certificate and an MSIX tool. The `msix` Dart
  package would change `pubspec.lock`, so that is a separate decision.

### Authenticode signing (needs a certificate)

1. **Certificate:** an OV or EV code-signing certificate from a public CA. Its
   private key must be on a hardware token or HSM; Azure Trusted Signing is an
   alternative. Unsigned builds trigger SmartScreen warnings.
2. **Configure the environment:** with the certificate in the Windows
   certificate store, set:
   ```
   $env:WINDOWS_SIGN_CERT_SHA1 = "<thumbprint>"
   $env:WINDOWS_SIGN_TIMESTAMP_URL = "<CA's RFC 3161 timestamp URL>"
   .\scripts\package_windows.ps1
   ```
   The script then runs `signtool sign /sha1 … /fd SHA256 /tr … /td SHA256` on
   `buskit_pos.exe` and every DLL, followed by `signtool verify /pa /all`.
3. **Check the file:** under file Properties → Digital Signatures, the signer
   should be ThriveWoo with a timestamp.

### Data on Windows (per user)

`%APPDATA%\ThriveWoo\ThriveWoo POS\` is Flutter's application-support folder,
named from the company and product names in the version resource. It holds
offline sales and the single-instance lock. The device token is stored by
`flutter_secure_storage` (Windows Credential Manager). This location has **not**
been confirmed on Windows yet.

## Secret exclusion

`scripts/verify_desktop_artifact.sh <zip|dmg|folder>` runs on macOS. It also
checks a Windows ZIP copied to the Mac. It:

- tests the archive's integrity;
- lists the top level;
- **fails** on any of these:
  - environment files (`.env*`);
  - signing material and keys (`.p12`, `.pfx`, `.p8`, `.pem`, `.key`, `.jks`,
    `.keystore`, `key.properties`, `.cer`, provisioning profiles);
  - source and project files (`.dart`, `pubspec.*`, `.xcconfig`, `Podfile`,
    `CMakeLists.txt`, `.git`, `.dart_tool`, `.pdb`);
  - AppleDouble entries (`__MACOSX`, `._*`);
  - any file containing a `-----BEGIN … PRIVATE KEY-----` block or a
    `…SECRET/PASSWORD/API_KEY…=value` assignment.

It prints file names only, never file contents. It was checked against a test
folder holding a fake `.env_production`, a `.p12`, a `.dart` file, a
private-key marker and a `PASSWORD=` line: all five were reported. The Windows
script repeats the name and private-key checks on its Release folder.

The app bundles no Flutter assets from the repository, because `pubspec.yaml`
has no `assets:` section. `test/core/desktop/packaging_config_test.dart`
checks this.

## Smoke test after installing (each platform)

1. The window and Dock or taskbar show *ThriveWoo POS*, and the window cannot
   shrink below the cashier minimum.
2. A second launch shows *ThriveWoo POS is already open on this computer*.
3. Sign in on the device, quit and relaunch: it is still signed in.
4. Open a shift. Scan with a keyboard-wedge scanner, then press F4, type the
   cash amount and press Enter: the sale completes.
5. Disconnect the network and make a sale: it is saved offline. Quit and
   relaunch: an unpaid offline cart comes back. Reconnect: the sale syncs.
6. Closing the window during a payment is refused, with an explanation.
7. A receipt prints on the LAN printer and the drawer opens (Phase 6ZE).

On macOS, steps 1 and 2 (the name and single instance) were checked on the
packaged app from a terminal. The others need a configured server and a person
at the till.
