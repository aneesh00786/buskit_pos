#!/bin/bash
# ThriveWoo POS — check a desktop distribution artifact before it is shared
# (Phase 6ZD). Works on this Mac for both platforms' outputs:
#
#   scripts/verify_desktop_artifact.sh <file.zip | file.dmg | folder>
#
# Fails if the artifact contains source, development configuration,
# environment files, signing material or private keys. Never prints matched
# file CONTENTS — only file names.
set -euo pipefail

target="${1:?usage: verify_desktop_artifact.sh <file.zip|file.dmg|folder>}"
work="$(mktemp -d)"
mounted=""
cleanup() {
  [ -z "$mounted" ] || hdiutil detach "$mounted" -quiet || true
  rm -rf "$work"
}
trap cleanup EXIT

case "$target" in
  *.zip)
    unzip -tq "$target" >/dev/null || { echo "FAIL: zip integrity test" >&2; exit 1; }
    echo "zip integrity: OK"
    ditto -x -k "$target" "$work/x"
    root="$work/x"
    ;;
  *.dmg)
    hdiutil verify "$target" >/dev/null 2>&1 || { echo "FAIL: dmg checksum" >&2; exit 1; }
    echo "dmg checksum: OK"
    mounted="$work/mnt"
    mkdir -p "$mounted"
    hdiutil attach "$target" -nobrowse -readonly -mountpoint "$mounted" -quiet
    root="$mounted"
    ;;
  *)
    [ -d "$target" ] || { echo "not a zip, dmg or folder: $target" >&2; exit 1; }
    root="$target"
    ;;
esac

problems=0
report() { echo "FAIL: $1" >&2; problems=$((problems + 1)); }

# macOS metadata stored beside the files (merged away again on extraction by
# ditto, but scattered as ._ files by other unzip tools).
if [ "${target##*.}" = "zip" ] && unzip -Z1 "$target" >"$work/listing" &&
   grep -qE '(^|/)(__MACOSX/|\._)' "$work/listing"; then
  report "zip contains __MACOSX / ._ AppleDouble entries"
fi

# Forbidden by name: environment files, signing material, keys, source and
# project/development configuration.
while IFS= read -r -d '' f; do
  report "forbidden file: ${f#"$root"/}"
done < <(find "$root" \( \
    -name '.env' -o -name '.env.*' -o -name '.env_*' -o -name '*.env' \
    -o -name '*.p12' -o -name '*.pfx' -o -name '*.p8' -o -name '*.pem' -o -name '*.key' \
    -o -name '*.jks' -o -name '*.keystore' -o -name 'key.properties' -o -name '*.mobileprovision' \
    -o -name '*.provisionprofile' -o -name '*.cer' -o -name '*.certSigningRequest' \
    -o -name '*.dart' -o -name 'pubspec.yaml' -o -name 'pubspec.lock' -o -name '.git' \
    -o -name '.dart_tool' -o -name 'analysis_options.yaml' -o -name '*.xcconfig' \
    -o -name 'Podfile*' -o -name 'CMakeLists.txt' -o -name '*.pdb' \
    -o -name '__MACOSX' -o -name '._*' \
  \) -print0)

# Forbidden by content: private keys and secret-style assignments.
while IFS= read -r -d '' f; do
  if LC_ALL=C grep -aqE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$f"; then
    report "private key material in: ${f#"$root"/}"
  fi
  if LC_ALL=C grep -aqE '(^|[^A-Za-z0-9_])[A-Z0-9_]*(SECRET|PASSWORD|PASSWD|PRIVATE_KEY|API_KEY)[A-Z0-9_]*=[^[:space:]]{4,}' "$f"; then
    report "secret-style KEY=value assignment in: ${f#"$root"/}"
  fi
done < <(find "$root" -type f -print0)

count="$(find "$root" -type f | wc -l | tr -d ' ')"
size="$(du -sh "$root" | cut -f1)"
echo "files: $count   size: $size"
echo "top level:"
(cd "$root" && find . -maxdepth 1 -mindepth 1 | sed 's#^\./#  #' | sort)

if [ "$problems" -gt 0 ]; then
  echo "ARTIFACT CHECK FAILED ($problems problem(s))" >&2
  exit 1
fi
echo "artifact check: OK (no source, development configuration, environment files, keys or signing material)"
