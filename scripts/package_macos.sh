#!/bin/bash
# ThriveWoo POS — macOS release packaging (Phase 6ZD).
# See docs/DESKTOP_RELEASE_BUILD.md.
#
#   POS_BASE_URL=https://<api-host> scripts/package_macos.sh [--dmg]
#   scripts/package_macos.sh --unconfigured [--dmg]   # local smoke test only
#
# Optional, for distribution (both read from the environment, never printed):
#   DEVELOPER_ID_APPLICATION="Developer ID Application: <Company> (<TEAMID>)"
#   NOTARY_PROFILE=<notarytool keychain profile name>   (requires the above)
#
# Without DEVELOPER_ID_APPLICATION the app is AD-HOC signed: it runs on the
# Mac that built it, and Gatekeeper blocks it on every other Mac.
#
# Output: build/dist/macos/ (gitignored). Nothing is uploaded unless
# NOTARY_PROFILE is set.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ThriveWoo POS"
BUNDLE_ID="com.thrivewoo.buskitPos"
ENTITLEMENTS="macos/Runner/Release.entitlements"
BUILT_APP="build/macos/Build/Products/Release/$APP_NAME.app"
OUT="build/dist/macos"

want_dmg=0
unconfigured=0
for arg in "$@"; do
  case "$arg" in
    --dmg) want_dmg=1 ;;
    --unconfigured) unconfigured=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
  fail "NOTARY_PROFILE needs DEVELOPER_ID_APPLICATION (an ad-hoc app cannot be notarized)"
fi

# --- Server address (mirrors AppConfig.releaseBaseUrlProblem) --------------
defines=()
if [ "$unconfigured" = 1 ]; then
  [ -z "${POS_BASE_URL:-}" ] || fail "--unconfigured and POS_BASE_URL are mutually exclusive"
  label="unconfigured"
  echo "NOTE: --unconfigured — the app will show its configuration screen and contact no server."
else
  url="${POS_BASE_URL:-}"
  [ -n "$url" ] || fail "POS_BASE_URL is not set (POS_BASE_URL=https://<api-host>), or pass --unconfigured for a local smoke build"
  case "$url" in https://?*) ;; *) fail "POS_BASE_URL must start with https://" ;; esac
  case "$url" in *\?*|*\#*|https://*@*) fail "POS_BASE_URL must not contain credentials, a query or a fragment" ;; esac
  host="$(printf '%s' "$url" | sed -E 's#^https://([^/:]+).*#\1#' | tr 'A-Z' 'a-z')"
  case "$host" in localhost|0.0.0.0|10.0.2.2|127.*|\[::1\]) fail "POS_BASE_URL is a development address" ;; esac
  defines+=("--dart-define=POS_BASE_URL=$url")
  label="configured"
fi

version_line="$(grep -E '^version: ' pubspec.yaml | head -1)"
version="${version_line#version: }"
build_name="${version%%+*}"
build_number="${version##*+}"
defines+=("--dart-define=APP_VERSION=$build_name")

# --- Build ------------------------------------------------------------------
flutter build macos --release "${defines[@]}"
[ -d "$BUILT_APP" ] || fail "build did not produce $BUILT_APP"

rm -rf "$OUT"
mkdir -p "$OUT"
APP="$OUT/$APP_NAME.app"
ditto --norsrc --noextattr "$BUILT_APP" "$APP"
xattr -cr "$APP" 2>/dev/null || true

plist="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "$BUNDLE_ID" ] || fail "unexpected bundle identifier"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$build_name" ] || fail "version does not match pubspec.yaml"

# --- Sign: nested code first, then the app ----------------------------------
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  sign_mode="developer-id"
  sign_args=(--force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION")
else
  sign_mode="adhoc"
  sign_args=(--force --sign -)
fi

# Deepest first (-depth), so every container is signed after its contents.
find "$APP/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) -print0 |
  while IFS= read -r -d '' item; do
    codesign "${sign_args[@]}" "$item"
  done
# The app itself, with exactly the release entitlements (this also drops the
# get-task-allow entitlement that Xcode's local signing adds).
codesign "${sign_args[@]}" --entitlements "$ENTITLEMENTS" "$APP"

# --- Verify signature and entitlements -------------------------------------
codesign --verify --deep --strict --verbose=2 "$APP"
ents="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - -)"
for key in com.apple.security.app-sandbox com.apple.security.network.client; do
  grep -q "\"$key\":true" <<<"$ents" || fail "missing entitlement $key"
done
for key in com.apple.security.get-task-allow com.apple.security.cs.allow-jit \
           com.apple.security.network.server com.apple.security.device.audio-input \
           com.apple.security.device.camera com.apple.security.files.user-selected.read-write \
           com.apple.security.cs.disable-library-validation; do
  if grep -q "\"$key\"" <<<"$ents"; then fail "release app must not have $key"; fi
done
echo "Entitlements OK: sandbox + outbound network only."

# --- Package -----------------------------------------------------------------
base="ThriveWoo-POS-$build_name-$build_number-macos-$sign_mode-$label"
zip="$OUT/$base.zip"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  # Notarize the app (submitted as a zip), staple the ticket to the app, then
  # build the final archive from the stapled app.
  submit="$OUT/notarize-submit.zip"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$submit"
  xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$submit"
fi

ditto -c -k --norsrc --noextattr --keepParent "$APP" "$zip"

if [ "$want_dmg" = 1 ]; then
  stage="$OUT/dmg-stage"
  mkdir -p "$stage"
  ditto "$APP" "$stage/$APP_NAME.app"
  ln -s /Applications "$stage/Applications"
  dmg="$OUT/$base.dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
  rm -rf "$stage"
  if [ "$sign_mode" = "developer-id" ]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dmg"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$dmg"
      xcrun stapler validate "$dmg"
    fi
  fi
  hdiutil verify "$dmg" >/dev/null
fi

scripts/verify_desktop_artifact.sh "$zip"
[ "$want_dmg" = 0 ] || scripts/verify_desktop_artifact.sh "$dmg"

if [ "$sign_mode" = "developer-id" ]; then
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo
echo "Signing: $sign_mode   Server: $label   Notarized: $([ -n "${NOTARY_PROFILE:-}" ] && echo yes || echo no)"
ls -l "$OUT"
if [ "$sign_mode" = "adhoc" ]; then
  echo "AD-HOC SIGNED — for testing on this Mac only. Not for distribution."
fi
