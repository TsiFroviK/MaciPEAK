#!/bin/sh
# stage-voice.sh WINDOWS_GAME STAGED_APP OPTIONAL_SDK_DIRECTORY
set -eu
[ "$#" -eq 3 ] || { echo 'usage: stage-voice.sh WINDOWS_GAME STAGED_APP OPTIONAL_SDK_DIRECTORY' >&2; exit 2; }
game=$(cd "$1" && pwd -P)
app=$(cd "$2" && pwd -P)
deps=$3
here=$(cd "$(dirname "$0")" && pwd -P)
managed="$app/Contents/Resources/Data/Managed"
plugins="$app/Contents/PlugIns"
licenses="$app/Contents/Resources/Licenses"
work=$(mktemp -d "$(dirname "$app")/.peak-voice.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
export TMPDIR="$work" PYTHONDONTWRITEBYTECODE=1
mkdir -p "$plugins" "$licenses"

if [ -n "$deps" ] && [ -f "$deps/PhotonVoice.unitypackage" ]; then
    "${PEAK_BUILD_PYTHON:-python3}" "$here/extract-voice-sdk.py" "$deps/PhotonVoice.unitypackage" "$work" "$game/PEAK_Data/Plugins/x86_64"
fi
for module in opus_egpv webrtc-audio; do
    if [ -f "$work/lib$module.dylib" ] || [ -z "$deps" ]; then continue; fi
    for file in "$deps/$module.bundle" "$deps/$module.bundle/Contents/MacOS/$module" "$deps/lib$module.dylib"; do
        if [ -f "$file" ]; then cp "$file" "$work/lib$module.dylib"; break; fi
    done
done

if [ ! -f "$work/libopus_egpv.dylib" ]; then
    archive=opus-1.5.2.tar.gz
    source_archive=$("${PEAK_BUILD_PYTHON:-python3}" "$here/fetch-dependency.py" "${MACIPEAK_CACHE:-$work/cache}" "$deps" "$archive" \
        "https://downloads.xiph.org/releases/opus/$archive" \
        65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1)
    tar -xzf "$source_archive" -C "$work"
    src="$work/opus-1.5.2"
    cp "$here/opus-abi.c" "$src/opus-abi.c"
    make -s -j4 -C "$src" -f "$here/opus.mk" libopus_egpv.dylib
    cp "$src/libopus_egpv.dylib" "$work/"
    cp "$src/COPYING" "$licenses/Xiph-Opus-1.5.2.txt"
fi
lipo "$work/libopus_egpv.dylib" -verify_arch arm64 x86_64
"${PEAK_BUILD_PYTHON:-python3}" "$here/test-opus.py" "$work/libopus_egpv.dylib"
cp "$work/libopus_egpv.dylib" "$plugins/"
{
    echo '<configuration>'
    echo '  <dllmap os="osx" dll="opus_egpv" target="@executable_path/../PlugIns/libopus_egpv.dylib" />'
    if [ -f "$work/libwebrtc-audio.dylib" ]; then
        lipo "$work/libwebrtc-audio.dylib" -verify_arch arm64 x86_64
        cp "$work/libwebrtc-audio.dylib" "$plugins/"
        echo '  <dllmap os="osx" dll="webrtc-audio" target="@executable_path/../PlugIns/libwebrtc-audio.dylib" />'
    else
        echo 'Optional Photon WebRTC DSP not supplied. PEAK recorders use the Unity microphone.' >&2
    fi
    echo '</configuration>'
} > "$managed/PhotonVoice.API.dll.config"
