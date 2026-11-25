#!/bin/sh
# Build the display-sync bridge in the private staging app before signing.
set -eu
[ "$#" -eq 3 ] || { echo 'Usage: stage-display.sh STAGED_APP DOTNET CSC_DLL' >&2; exit 2; }
app=$(cd "$1" && pwd -P)
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/host-tools.sh"
data="$app/Contents/Resources/Data"
managed="$data/Managed"
plugins="$app/Contents/PlugIns"
native=libMaciPEAKDisplaySync.dylib
assembly=MaciPEAK.DisplaySync.dll
work=$(mktemp -d "$(dirname "$app")/.macipeak-display.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
"$2" "$3" -nologo -noconfig -nostdlib+ -target:library -optimize+ -deterministic+ \
    "-r:$managed/mscorlib.dll" "-r:$managed/netstandard.dll" "-r:$managed/System.dll" \
    "-r:$managed/Assembly-CSharp.dll" "-r:$managed/Zorro.Settings.Runtime.dll" \
    "-r:$managed/Unity.Localization.dll" "-r:$managed/UnityEngine.CoreModule.dll" \
    "-out:$work/$assembly" "$here/DisplaySync.cs"
/usr/bin/xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -O2 -fobjc-arc -dynamiclib \
    -install_name "@rpath/$native" "$here/display-sync.m" -framework AppKit -framework QuartzCore \
    -framework Metal -o "$work/$native"
require_universal_macho "$work/$native"
mkdir -p "$plugins"
mv -f "$work/$assembly" "$managed/$assembly"
mv -f "$work/$native" "$plugins/$native"
"${PEAK_BUILD_PYTHON:-python3}" "$here/register-initializer.py" "$data" DisplaySync before
