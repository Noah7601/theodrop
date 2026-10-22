#!/usr/bin/env bash
# Builds a macOS portable package (TheoDrop.app + CLI) without PowerShell.
# Mirrors build/build-portable.ps1 for the osx-* runtimes.
#
# Usage: build/build-portable.sh [osx-arm64|osx-x64] [--version X.Y.Z] [--output DIR] [--sign IDENTITY]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime=""
version=""
output="$root/Releases"
identity="-"

while [ $# -gt 0 ]; do
  case "$1" in
    osx-arm64|osx-x64) runtime="$1"; shift ;;
    --version) version="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --sign) identity="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then echo "Run this script on macOS." >&2; exit 1; fi
if [ -z "$runtime" ]; then runtime="osx-$(uname -m | sed 's/^x86_64$/x64/;s/^aarch64$/arm64/')"; fi

if [ -z "$version" ]; then
  version="$(python3 - "$root/Directory.Build.props" <<'PY'
import re,sys
text=open(sys.argv[1],encoding='utf-8').read()
match=re.search(r'<Version>([^<]+)</Version>',text)
print(match.group(1) if match else '')
PY
)"
fi
version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || { echo "Version must be X.Y.Z[-pre]." >&2; exit 1; }
bundle_version="${version%%-*}"

package_name="TheoDrop-$version-$runtime"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
archive="$output/$package_name.tar.gz"
sums="$output/$package_name-SHA256SUMS.txt"
if [ -e "$archive" ] || [ -e "$sums" ]; then
  echo "Package $package_name already exists. Use another output folder or version." >&2
  exit 1
fi

stage="$root/build/.cache/portable/$(uuidgen | tr -d -)"
package="$stage/$package_name"
app="$package/TheoDrop.app"
publish="$app/Contents/MacOS"
mkdir -p "$publish"

for project in Filee.App Filee.Cli; do
  dotnet publish "$root/src/$project/$project.csproj" -c Release -r "$runtime" --self-contained true \
    "-p:Version=$version" -p:FileeRelease=true -p:PublishReadyToRun=false -o "$publish"
done

"$root/build/fetch-portable-engines.sh" "$runtime" "$publish/engines"

for name in Filee filee-cli; do
  [ -f "$publish/$name" ] || { echo "Publish did not produce $name" >&2; exit 1; }
  chmod +x "$publish/$name"
done

for notice in LICENSE THIRD-PARTY-NOTICES.md; do
  if [ -f "$root/$notice" ]; then cp "$root/$notice" "$package/"; fi
done

contents="$app/Contents"
resources="$contents/Resources"
mkdir -p "$resources"
python3 - "$root/installer/macos/Info.plist" "$contents/Info.plist" "$bundle_version" <<'PY'
import sys
source,target,version=sys.argv[1:4]
text=open(source,encoding='utf-8').read()
open(target,'w',encoding='utf-8').write(text.replace('__VERSION__',version).replace('__BUNDLE_VERSION__',version))
PY
plutil -lint "$contents/Info.plist"

iconset="$stage/theodrop.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$root/src/Filee.App/Assets/Icons/theodrop.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$root/src/Filee.App/Assets/Icons/theodrop.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$resources/theodrop.icns"

for localization in "$root"/installer/macos/*.lproj; do
  if [ -d "$localization" ]; then cp -R "$localization" "$resources/"; fi
done

entitlements="$root/installer/macos/entitlements.plist"
sign_options=(--force --sign "$identity")
if [ "$identity" != "-" ]; then sign_options+=(--timestamp --options runtime); fi
main_executable="$publish/Filee"
# Deepest paths first so nested code is sealed before its container; the main executable signs last.
order="$(python3 "$root/build/tools/sign-order.py" "$publish" Filee | tr '\0' '\n')"
while IFS= read -r file; do
  codesign "${sign_options[@]}" --entitlements "$entitlements" "$file"
done <<< "$order"
codesign "${sign_options[@]}" --entitlements "$entitlements" "$main_executable"
codesign "${sign_options[@]}" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"

for file in install.sh uninstall.sh INSTALL.txt; do
  cp "$root/installer/macos/$file" "$package/"
done
chmod +x "$package/install.sh" "$package/uninstall.sh"

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
