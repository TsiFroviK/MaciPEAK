#!/bin/sh
# Stage on a private, unsigned build before the builder signs the app. Mono.Cecil is build-only.
set -eu
[ "$#" -eq 6 ] || { echo 'usage: stage-mic.sh WINDOWS_GAME STAGED_APP WORK_DIR DOTNET CSC_DLL CECIL_NUPKG' >&2; exit 2; }
game=$1
app=$2
work=$3/microphone
host=$4
compiler=$5
package=$6
here=$(cd "$(dirname "$0")" && pwd -P)
managed="$app/Contents/Resources/Data/Managed"
plugins="$app/Contents/PlugIns"
original="$game/PEAK_Data/Managed/PhotonVoice.dll"
[ -f "$original" ] && cmp -s "$original" "$managed/PhotonVoice.dll" || { echo 'Expected an unmodified staged PhotonVoice.dll' >&2; exit 1; }
[ ! -e "$plugins/libPeakMicConsent.dylib" ] || { echo 'Microphone plugin already staged' >&2; exit 1; }
mkdir -p "$work" "$plugins"
actual=$(shasum -a 256 < "$package")
[ "${actual%% *}" = d2a23832aaa948ba9a01acc42b5726e34c5f995958f1b30d45c0e7c70b3a72d5 ] || { echo 'Invalid Mono.Cecil 0.11.6 tool package' >&2; exit 1; }
/usr/bin/unzip -p "$package" lib/netstandard2.0/Mono.Cecil.dll > "$work/Mono.Cecil.dll"
"$host" "$compiler" -nologo -noconfig -nostdlib+ -target:exe -optimize+ \
    "-r:$managed/mscorlib.dll" "-r:$managed/System.dll" "-r:$managed/System.Core.dll" "-r:$managed/netstandard.dll" \
    "-r:$work/Mono.Cecil.dll" "-out:$work/MicPatcher.dll" "$here/MicPatcher.cs"
"$host" exec --runtimeconfig "${compiler%.dll}.runtimeconfig.json" "$work/MicPatcher.dll" "$original" "$work/PhotonVoice.dll"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -std=c11 -fobjc-arc -fblocks -dynamiclib \
    -install_name @rpath/libPeakMicConsent.dylib "$here/mic-consent.m" -framework AVFoundation -framework Foundation \
    -o "$work/libPeakMicConsent.dylib"
lipo "$work/libPeakMicConsent.dylib" -verify_arch arm64 x86_64
# rename, rather than open/truncate existing files (also safe in a hard-linked test clone).
cp "$work/libPeakMicConsent.dylib" "$plugins/libPeakMicConsent.dylib"
cp "$work/PhotonVoice.dll" "$managed/PhotonVoice.mac-staged"
mv -f "$managed/PhotonVoice.mac-staged" "$managed/PhotonVoice.dll"
