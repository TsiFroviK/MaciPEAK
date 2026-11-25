#!/bin/sh
# stage-player.sh auto|MacStandaloneSupport|support.pkg NEW_APP EXISTING_WORK_DIR
set -eu

die() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -eq 3 ] || die "Usage: stage-player.sh auto|MacStandaloneSupport|support.pkg NEW_APP EXISTING_WORK_DIR"
support=$1
app=$2
work=$3
[ -d "$work" ] || die "Missing build work directory: $work"
[ ! -e "$app" ] && [ ! -L "$app" ] || die "Staging path already exists: $app"

variation=Variations/macos_x64arm64_player_nondevelopment_mono/UnityPlayer.app
entry=Source/Player/MacPlayer/MacPlayerEntryPoint/Resources
if [ "$support" = auto ] || [ -f "$support" ]; then
    unpack=$(mktemp -d "$work/player.XXXXXXXX")
    here=$(cd "$(dirname "$0")" && pwd -P)
    if [ "$support" = auto ]; then
        package=UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg
        url=https://download.unity3d.com/download_unity/c1aa84e375f6/MacEditorTargetInstaller/UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg
        support=$("${PEAK_BUILD_PYTHON:-python3}" "$here/fetch-dependency.py" "${MACIPEAK_CACHE:-$work/cache}" "${MACIPEAK_DEPS:-}" "$package" "$url" \
            4606aadbb6d5977a8355962a6c4708d3bd5e08d3789b5027da275ef1b2b47e1b)
    else
        digest=$(shasum -a 256 < "$support")
        [ "${digest%% *}" = 4606aadbb6d5977a8355962a6c4708d3bd5e08d3789b5027da275ef1b2b47e1b ] || die "SHA-256 mismatch for Unity 6000.3.15f1 Mac Mono package"
    fi
    "${PEAK_BUILD_PYTHON:-python3}" "$here/xar-member.py" "$support" TargetSupport.pkg.tmp/Payload | \
        /usr/bin/tar -xf - -C "$unpack" "./$variation" "./MonoBleedingEdge/etc" "./$entry/MainMenu.nib"
    support=$unpack
fi

template="$support/$variation/Contents"
runtime="$template/Frameworks/UnityPlayer.dylib"
[ -s "$runtime" ] || die "Expected a MacStandaloneSupport directory containing $variation"
LC_ALL=C grep -aFq '6000.3.15f1 (c1aa84e375f6)' "$runtime" || die "Wrong Unity revision; PEAK requires 6000.3.15f1 (c1aa84e375f6)"
for required in "$template/MacOS/UnityPlayer" "$template/Resources/Data/Resources/unity default resources" \
    "$template/Frameworks/libmonobdwgc-2.0.dylib" "$template/Frameworks/libmono-native.dylib" \
    "$template/Frameworks/libMonoPosixHelper.dylib" "$support/MonoBleedingEdge/etc/mono/config" \
    "$support/$entry/MainMenu.nib/keyedobjects.nib"; do
    [ -s "$required" ] || die "Incomplete Unity Mac Mono module: $required"
done

mkdir "$app"
cp -R "$template" "$app/Contents"
mv "$app/Contents/MacOS/UnityPlayer" "$app/Contents/MacOS/PEAK"
chmod +x "$app/Contents/MacOS/PEAK"
mkdir -p "$app/Contents/MonoBleedingEdge"
cp -R "$support/MonoBleedingEdge/etc" "$app/Contents/MonoBleedingEdge/etc"
cp -R "$support/$entry/MainMenu.nib" "$app/Contents/Resources/MainMenu.nib"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>English</string>
    <key>CFBundleExecutable</key><string>PEAK</string>
    <key>CFBundleIdentifier</key><string>local.peak.macport</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PEAK</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>PEAK uses the microphone for in-game voice chat.</string>
    <key>NSMainNibFile</key><string>MainMenu</string>
    <key>NSPrincipalClass</key><string>PlayerApplication</string>
</dict>
</plist>
PLIST
