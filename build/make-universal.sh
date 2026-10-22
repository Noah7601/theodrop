#!/usr/bin/env bash
# Combines the osx-arm64 and osx-x64 portable packages into one universal macOS package.
# Both inputs must be unpacked package folders (the folders build/build-portable.sh leaves behind).
#
# Usage: build/make-universal.sh <arm64-package-dir> <x64-package-dir> [--version X.Y.Z] [--output DIR] [--sign IDENTITY]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arm_package="${1:?arm64 package folder is required}"
x64_package="${2:?x64 package folder is required}"
shift 2
version=""
output="$root/Releases"
identity="-"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --sign) identity="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then echo "Run this script on macOS." >&2; exit 1; fi
arm_app="$arm_package/TheoDrop.app"
x64_app="$x64_package/TheoDrop.app"
for app in "$arm_app" "$x64_app"; do
  if [ ! -d "$app/Contents/MacOS" ]; then echo "Not a package folder: $app" >&2; exit 1; fi
done
if ! file "$arm_app/Contents/MacOS/Filee" | grep -q arm64; then echo "$arm_app is not an arm64 build." >&2; exit 1; fi
if ! file "$x64_app/Contents/MacOS/Filee" | grep -q x86_64; then echo "$x64_app is not an x86_64 build." >&2; exit 1; fi

if [ -z "$version" ]; then
  version="$(python3 - "$root/Directory.Build.props" <<'PY'
import re, sys
match = re.search(r'<Version>([^<]+)</Version>', open(sys.argv[1], encoding='utf-8').read())
print(match.group(1) if match else '')
PY
)"
fi
version="${version#v}"

package_name="TheoDrop-$version-osx-universal"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
archive="$output/$package_name.tar.gz"
sums="$output/$package_name-SHA256SUMS.txt"
if [ -e "$archive" ] || [ -e "$sums" ]; then
  echo "Package $package_name already exists. Use another output folder or version." >&2
  exit 1
fi

stage="$root/build/.cache/universal/$(uuidgen | tr -d -)"
package="$stage/$package_name"
app="$package/TheoDrop.app"
macos="$app/Contents/MacOS"
mkdir -p "$macos"

# Everything outside Contents/MacOS is architecture independent: take it from the arm64 package.
cp "$arm_app/Contents/Info.plist" "$app/Contents/Info.plist"
cp -R "$arm_app/Contents/Resources" "$app/Contents/Resources"
for file in LICENSE THIRD-PARTY-NOTICES.md install.sh uninstall.sh INSTALL.txt; do
  if [ -f "$arm_package/$file" ]; then cp "$arm_package/$file" "$package/"; fi
done
chmod +x "$package/install.sh" "$package/uninstall.sh"

# One complete payload per architecture, plus a universal trampoline for each entry point.
ditto "$arm_app/Contents/MacOS" "$macos/arm64"
ditto "$x64_app/Contents/MacOS" "$macos/x64"
for slice in arm64 x64; do
  rm -rf "$macos/$slice/_CodeSignature"
done
for entry in Filee filee-cli; do
  clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -O2 \
    -o "$macos/$entry" "$root/build/macos-universal-launcher.c"
  chmod +x "$macos/$entry"
  lipo -archs "$macos/$entry" | grep -q arm64
  lipo -archs "$macos/$entry" | grep -q x86_64
done

entitlements="$root/installer/macos/entitlements.plist"
sign_options=(--force --sign "$identity")
if [ "$identity" != "-" ]; then sign_options+=(--timestamp --options runtime); fi
order="$(python3 "$root/build/tools/sign-order.py" "$macos" Filee filee-cli | tr '\0' '\n')"
while IFS= read -r file; do
  codesign "${sign_options[@]}" --entitlements "$entitlements" "$file"
done <<< "$order"
codesign "${sign_options[@]}" --entitlements "$entitlements" "$macos/filee-cli"
codesign "${sign_options[@]}" --entitlements "$entitlements" "$macos/Filee"
codesign "${sign_options[@]}" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
ln -s "$macos/filee-cli" "$stage/theodrop"
"$stage/theodrop" --version >/dev/null

temporary="$archive.$(uuidgen | tr -d -).partial"
tar -czf "$temporary" -C "$stage" "$package_name"
mv "$temporary" "$archive"
(cd "$output" && shasum -a 256 "$package_name.tar.gz" > "$package_name-SHA256SUMS.txt")

echo "Package: $archive"
echo "Checksums: $sums"
echo "Unpacked build retained for testing: $package"
if [ "$identity" = "-" ]; then
  echo 'This macOS build is ad-hoc signed for testing; it is not notarized for public distribution.'
fi
