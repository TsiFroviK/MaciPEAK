#!/bin/sh
# Build the macOS ABI bindings for PEAK's Steamworks 1.61 and EOS 1.19.1.2.
# Invoke only on a private build of the app, before signing.
set -eu

fail() { printf 'stage-plugins: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 3 ] || fail 'usage: stage-plugins.sh WINDOWS_GAME STAGED_APP OPTIONAL_SDK_DIRECTORY'
game=$(cd "$1" && pwd -P)
app=$(cd "$2" && pwd -P)
deps=$3
[ -z "$deps" ] || [ ! -d "$deps" ] || deps=$(cd "$deps" && pwd -P)
source_plugins="$game/PEAK_Data/Plugins/x86_64"
managed="$app/Contents/Resources/Data/Managed"
plugins="$app/Contents/PlugIns"
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/host-tools.sh"
[ -f "$managed/PortningsbolagetMemory.dll" ] || fail 'missing staged PEAK Managed directory'
work=$(mktemp -d "$(dirname "$app")/.peak-plugins.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
export TMPDIR="$work"

checksum() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
verify() { [ "$(checksum "$1")" = "$2" ] || fail "SHA-256 mismatch: $1"; }
fetch() {
    "${PEAK_BUILD_PYTHON:-python3}" "$here/fetch-dependency.py" "${MACIPEAK_CACHE:-$work/cache}" "$deps" "$1" "$2" "$3"
}

# Check the vendor ABI used by the input. Other SDK versions need their own bindings.
verify "$source_plugins/steam_api64.dll" 670d654aa3255c5061cf0236a1cdbb2f5076cbd5ae44f613b6f4921558e83e2d
verify "$source_plugins/EOSSDK-Win64-Shipping.dll" 9c498fe31c8df1d9085dfa9c71c6d50ec6b569acdb29f1decb97be105b6341dc
verify "$game/PEAK_Data/Managed/com.rlabrecque.steamworks.net.dll" 17afda90ce1056dae23633edfdd4fd8c6920e65d011881adc4cab7b6a42c8e85
verify "$game/PEAK_Data/Managed/EpicOnlineService.dll" 83dd757b4ce1b224a67afedcc6047e8d43ef15554927af6a282825b7c7839695
verify "$game/PEAK_Data/Managed/PortningsbolagetMemory.dll" 0bbbde431c2d51edee20dd68335d9ac5719dcb7a21423272d2f25c7ddf00014a
steam_archive=$(fetch Steamworks.NET-2025.161.0.tar.gz \
    https://codeload.github.com/rlabrecque/Steamworks.NET/tar.gz/refs/tags/2025.161.0 \
    4b7bfcbed16040442e1f8e0e5e14e65c9618684b732f3f3e996531c63ee2f52b)
eos_dylib=$(fetch libEOSSDK-Mac-Shipping.dylib \
    https://media.githubusercontent.com/media/EOS-Contrib/eos_plugin_for_unity/v6.1.0/Assets/Plugins/macOS/libEOSSDK-Mac-Shipping.dylib \
    51b644a123d9446e1f6e7098d264f57d09826d47e1b5bbcdd1d8172a3e208f9d)
eos_release=https://raw.githubusercontent.com/EOS-Contrib/eos_plugin_for_unity/v6.1.0/Assets/Plugins/macOS
eos_license=$(fetch EOS-license.txt "$eos_release/license.txt" \
    775719b33434ee0a1fecb70a44feb477ca9d8f9dc8d9877e4ba73af1f2332afe)
eos_notices=$(fetch EOS-ThirdPartySoftwareNotice.txt "$eos_release/ThirdPartySoftwareNotice.txt" \
    9aa38890a43af9304c06ac03f8ba6288bba7373ad73474633b6200caf3198c32)
tar -xzf "$steam_archive" -C "$work"
sdk="$work/Steamworks.NET-2025.161.0/com.rlabrecque.steamworks.net"

# Compile the upstream Unity wrapper for macOS. Its callbacks and structs have
# platform-specific packing. A rename of the Windows import would corrupt them.
export DOTNET_CLI_HOME="$work" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
compiler=
for editor in "${UNITY_EDITOR_APP:-}" /Applications/Unity/Hub/Editor/*/Unity.app; do
    [ -n "$editor" ] || continue
    sdkroot="$editor/Contents/Resources/Scripting/DotNetSdk"
    for compiler_path in "$sdkroot"/sdk/*/Roslyn/bincore/csc.dll; do
        if [ -x "$sdkroot/dotnet" ] && [ -f "$compiler_path" ]; then
            host="$sdkroot/dotnet"
            compiler=$compiler_path
            break 2
        fi
    done
done
if [ -z "$compiler" ] && command -v dotnet >/dev/null 2>&1; then
    host=$(command -v dotnet)
    compiler=$("$host" --list-sdks | sed -nE 's/^([^ ]+) \[(.*)\]$/\2\/\1\/Roslyn\/bincore\/csc.dll/p' | tail -n 1)
fi
if [ ! -f "$compiler" ] || ! "$host" "$compiler" -nologo -version >/dev/null 2>&1; then
    : "${MACIPEAK_CACHE:=$work/cache}"
    bootstrap_csharp "$work" "$deps"
fi
cecil_package=$(fetch mono.cecil.0.11.6.nupkg \
    https://api.nuget.org/v3-flatcontainer/mono.cecil/0.11.6/mono.cecil.0.11.6.nupkg \
    d2a23832aaa948ba9a01acc42b5726e34c5f995958f1b30d45c0e7c70b3a72d5)
sh "$here/stage-mic.sh" "$game" "$app" "$work" "$host" "$compiler" "$cecil_package"
sh "$here/stage-fps.sh" "$app" "$host" "$compiler"
sh "$here/stage-display.sh" "$app" "$host" "$compiler"
(
    cd "$sdk/Runtime"
    "$host" "$compiler" -noconfig -nologo -nostdlib+ -target:library -optimize+ -deterministic+ -unsafe+ \
        -define:UNITY_STANDALONE_OSX,UNITY_STANDALONE,UNITY_64,UNITY_5_3_OR_NEWER,UNITY_2017_1_OR_NEWER \
        "-r:$managed/mscorlib.dll" "-r:$managed/netstandard.dll" "-r:$managed/System.dll" \
        "-r:$managed/System.Core.dll" "-r:$managed/UnityEngine.CoreModule.dll" \
        "-out:$work/com.rlabrecque.steamworks.net.dll" '-recurse:*.cs'
)
mkdir -p "$plugins" "$app/Contents/Resources/Licenses"
require_universal_macho "$sdk/Plugins/steam_api.bundle/Contents/MacOS/libsteam_api.dylib"
require_universal_macho "$eos_dylib"
cp "$work/com.rlabrecque.steamworks.net.dll" "$managed/"
cp "$sdk/Plugins/steam_api.bundle/Contents/MacOS/libsteam_api.dylib" "$plugins/"
cp "$sdk/LICENSE.md" "$app/Contents/Resources/Licenses/Steamworks.NET.md"
cp "$eos_license" "$app/Contents/Resources/Licenses/EOS-license.txt"
cp "$eos_notices" "$app/Contents/Resources/Licenses/EOS-ThirdPartySoftwareNotice.txt"
# Unity indexes macOS plug-ins by their actual filenames before resolving
# P/Invokes. Preserve the requested module basenames from the shipped IL.
cp "$eos_dylib" "$plugins/libEOSSDK-Win64-Shipping.dylib"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -dynamiclib \
    -install_name @rpath/libMemoryWrapper-x64-Release.dylib "$here/eos-memory.c" -o "$plugins/libMemoryWrapper-x64-Release.dylib"
require_universal_macho "$plugins/libMemoryWrapper-x64-Release.dylib"

map_library() {
    cat > "$managed/$1.dll.config" <<EOF
<configuration>
  <dllmap os="osx" dll="$2" target="@executable_path/../PlugIns/$3" />
</configuration>
EOF
}
map_library com.rlabrecque.steamworks.net steam_api libsteam_api.dylib
printf '%s\n' 'Staged macOS Steamworks SDK 1.61, EOS SDK 1.19.1.2 and the native EOS allocation bridge.'

sh "$here/stage-voice.sh" "$game" "$app" "$deps"
