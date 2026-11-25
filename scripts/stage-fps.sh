#!/bin/sh
# Register the optional render counter using Unity's Mono player startup tables.
set -eu
[ "$#" -eq 3 ] || { echo 'usage: stage-fps.sh STAGED_APP DOTNET CSC_DLL' >&2; exit 2; }
data="$1/Contents/Resources/Data"
managed="$data/Managed"
host=$2
compiler=$3
here=$(cd "$(dirname "$0")" && pwd -P)
assembly=MaciPEAK.RenderFps
[ ! -e "$managed/$assembly.dll" ] || { echo 'FPS assembly already exists in staged app' >&2; exit 1; }
"$host" "$compiler" -nologo -noconfig -nostdlib+ -target:library -optimize+ -deterministic+ \
    "-r:$managed/mscorlib.dll" "-r:$managed/netstandard.dll" "-r:$managed/UnityEngine.CoreModule.dll" \
    "-r:$managed/UnityEngine.IMGUIModule.dll" "-out:$managed/$assembly.dll" "$here/RenderFps.cs"
"${PEAK_BUILD_PYTHON:-python3}" "$here/register-initializer.py" "$data" RenderFps after
