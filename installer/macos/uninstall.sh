#!/bin/sh
set -eu

install_dir="$HOME/Applications/TheoDrop.app"
if [ -L "$install_dir" ] || [ ! -d "$install_dir" ]; then
    printf '%s\n' "No ordinary TheoDrop app bundle was found at $install_dir."
    exit 1
fi
resolved_parent=$(CDPATH= cd -- "$HOME/Applications" && pwd -P)
resolved_app=$(CDPATH= cd -- "$install_dir" && pwd -P)
if [ "$resolved_app" != "$resolved_parent/TheoDrop.app" ]; then
    printf '%s\n' 'Refusing to remove an app outside the expected Applications directory.'
    exit 1
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_dir/Contents/Info.plist")
if [ "$bundle_id" != 'com.theo.drop' ]; then
    printf '%s\n' 'The bundle is not TheoDrop.'
    exit 1
fi
"$install_dir/Contents/MacOS/Filee" --uninstall-cleanup
if [ -L "$HOME/.local/bin/theodrop" ] && [ "$(readlink "$HOME/.local/bin/theodrop")" = "$install_dir/Contents/MacOS/filee-cli" ]; then
    rm -- "$HOME/.local/bin/theodrop"
fi
rm -rf -- "$install_dir"
printf '%s\n' 'TheoDrop was removed. Your settings and conversion results were kept.'
