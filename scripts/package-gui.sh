#!/bin/sh
# Package the universal MaciPEAK Builder for a GitHub Release.
set -eu
[ "$#" -eq 1 ] || { echo 'Usage: sh scripts/package-gui.sh OUTPUT.dmg|OUTPUT.zip' >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo 'Build the release on macOS with the Apple Command Line Tools.' >&2; exit 1; }
case $1 in
    *.dmg) format=dmg ;;
    *.zip) format=zip ;;
    *) echo 'Choose a .dmg or .zip output file.' >&2; exit 2 ;;
esac
output="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
[ ! -e "$output" ] && [ ! -L "$output" ] || { echo "Output already exists: $output" >&2; exit 1; }
if [ -n "${MACIPEAK_NOTARY_PROFILE:-}" ] && [ -z "${MACIPEAK_SIGN_IDENTITY:-}" ]; then
    echo 'Set MACIPEAK_SIGN_IDENTITY to the Developer ID Application identity for notarization.' >&2
    exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d "$(dirname "$output")/.macipeak-gui.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/tmp"
export TMPDIR="$work/tmp" CLANG_MODULE_CACHE_PATH="$work/tmp/modules"
app="$work/MaciPEAK Builder.app"
contents="$app/Contents"
payload="$contents/Resources/MaciPEAK"
mkdir -p "$contents/MacOS" "$payload/scripts" "$payload/tools" "$payload/licenses"
cp "$root/gui/Info.plist" "$contents/Info.plist"
/usr/bin/plutil -lint "$contents/Info.plist"
/usr/bin/xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -fobjc-arc -Os \
    -framework Cocoa "$root/gui/Builder.m" "$root/gui/ReleaseUpdate.m" "$root/gui/InstallUpdate.m" \
    -o "$contents/MacOS/MaciPEAK Builder"
/usr/bin/lipo "$contents/MacOS/MaciPEAK Builder" -verify_arch arm64 x86_64

icons="$work/MaciPEAK.iconset"
mkdir "$icons"
art="$root/gui/builder-icon.png"
for size in 16 32 128 256 512; do
    /usr/bin/sips -s format png -z "$size" "$size" "$art" --out "$icons/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -s format png -z "$double" "$double" "$art" --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$icons" -o "$contents/Resources/MaciPEAK.icns"

# Keep the release payload independent of untracked files in a developer checkout.
cp "$root/build.sh" "$root/LICENSE" "$root/THIRD_PARTY.md" "$payload/"
for name in bcl-6000.3.15f1.sha256 eos-memory.c extract-voice-sdk.py fetch-dependency.py host-tools.sh \
    mic-consent.m MicPatcher.cs opus-abi.c opus.mk RenderFps.cs DisplaySync.cs display-sync.m \
    register-initializer.py stage-arch.sh stage-bcl.sh stage-display.sh stage-fps.sh \
    stage-graphics.sh stage-icon.py stage-mic.sh stage-player.sh stage-plugins.sh stage-render-scale.py stage-voice.sh \
    steam_appinfo.py steam-install.py test-opus.py unity-mono-profile.py xar-member.py; do
    cp "$root/scripts/$name" "$payload/scripts/"
done
for name in metal_compute metal_constant_layout metal_resource_bindings metal_shader_parameters metal_shaders \
    prepare_content shader_tools unityfs_maps; do
    cp "$root/tools/$name.py" "$payload/tools/"
done
cp "$root/licenses/Mono.Cecil-MIT.txt" "$root/licenses/Risk2Mac-MIT.txt" "$payload/licenses/"

if [ -n "${MACIPEAK_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$MACIPEAK_SIGN_IDENTITY" "$app"
else
    /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --deep --strict --all-architectures "$app"
notarize() {
    /usr/bin/xcrun notarytool submit "$1" --keychain-profile "$MACIPEAK_NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$2"
    /usr/bin/xcrun stapler validate "$2"
}

release="$work/release.$format"
if [ "$format" = dmg ]; then
    mkdir "$work/volume"
    mv "$app" "$work/volume/"
    ln -s /Applications "$work/volume/Applications"
    /usr/bin/hdiutil create -srcfolder "$work/volume" -volname 'MaciPEAK Builder' \
        -fs HFS+ -format UDZO "$release"
    if [ -n "${MACIPEAK_SIGN_IDENTITY:-}" ]; then
        /usr/bin/codesign --timestamp --sign "$MACIPEAK_SIGN_IDENTITY" "$release"
    fi
    if [ -n "${MACIPEAK_NOTARY_PROFILE:-}" ]; then
        notarize "$release" "$release"
    fi
    /usr/bin/hdiutil verify "$release"
else
    if [ -n "${MACIPEAK_NOTARY_PROFILE:-}" ]; then
        /usr/bin/ditto -c -k --keepParent "$app" "$work/submission.zip"
        notarize "$work/submission.zip" "$app"
    fi
    /usr/bin/ditto -c -k --keepParent "$app" "$release"
fi
/bin/mv -n "$release" "$output"
[ ! -e "$release" ] || { echo "Output already exists: $output" >&2; exit 1; }
printf 'Built %s\n' "$output"
