#!/bin/sh
# Build the PEAK player on macOS. Publish only after verification.
set -eu

usage() {
    cat <<'EOF'
MaciPEAK builds the Steam Windows release of PEAK 3.1.0 for macOS.
Usage: sh build.sh --game WINDOWS_PEAK [--steam-library DIR | --output PATH] [options]
       sh build.sh --register-steam [--steam-library DIR]
       sh build.sh --unregister-steam [--steam-library DIR]
  --steam-library DIR  Steam library root (contains steamapps), e.g. /Volumes/Games/SteamLibrary
  --output PATH    Build a standalone .app at this path and skip Steam registration
  --arch ARCH      Game architecture: arm64, x86_64 or universal (default: universal)
  --register-steam    Register an existing MaciPEAK app or repair its Steam Play entry
  --unregister-steam  Remove the local MaciPEAK Steam registration and keep the app
  --editor PATH    Unity 6000.3.15f1 Unity.app, editor .pkg, or unityjit-macos profile
  --support PATH   Exact MacStandaloneSupport folder or Mac Mono support .pkg
  --deps DIR       Local Steam/EOS/Photon SDK inputs and optional shader tools
  --cache DIR      Download and shader cache (default: .macipeak-cache in the library
                   root or beside a standalone app)
  --python PATH    Use this Python 3.10+ interpreter
By default, install in steamapps/common/PEAK and register the real PEAK Library entry.
Running again with a compatible PEAK.app repairs its registration without rebuilding.
Steam opens after registration and restarts if it was running. Finish any running games first.
Missing host tools and the matching Unity modules are downloaded as needed.
Use an APFS or Mac OS Extended destination. Existing output is never replaced.
EOF
}
fail() { printf '%s\n' "$*" >&2; exit 1; }
game= output= library= deps= cache= python= target_arch= editor=auto support=auto action=build
while [ "$#" -gt 0 ]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --register-steam|--unregister-steam)
            [ "$action" = build ] || fail 'Choose one Steam registration action.'
            action=${1#--}; shift ;;
        --game|--output|--steam-library|--editor|--support|--deps|--cache|--python|--arch)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            [ -n "$2" ] || fail "Empty value for $1"
            case $1 in
                --game) game=$2 ;; --output) output=$2 ;; --editor) editor=$2 ;;
                --steam-library) library=$2 ;;
                --arch) target_arch=$2 ;;
                --support) support=$2 ;; --deps) deps=$2 ;; --cache) cache=$2 ;; --python) python=$2 ;;
            esac
            shift 2 ;;
        *) fail "Unknown option $1" ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'Run this script on macOS.'
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/scripts/host-tools.sh"
if [ -n "$library" ] && [ -n "$output" ]; then fail 'Choose --steam-library or --output.'; fi
steam_helper() {
    if [ -n "$library" ]; then set -- "$@" --steam-library "$library"; fi
    /usr/bin/python3 "$here/scripts/steam-install.py" "$@"
}
steam_running() { /usr/bin/pgrep -u "$(id -u)" -x steam_osx >/dev/null; }
steam_change() {
    steam_action=$1
    shift
    restart=no
    if steam_running; then
        printf '%s\n' 'Asking Steam to exit so it can reload the PEAK configuration.'
        /usr/bin/open 'steam://exit' || return 1
        seconds=0
        while steam_running; do
            if [ "$seconds" -ge 60 ]; then
                printf '%s\n' 'Steam is still running. Finish any running game, exit Steam, then retry the registration command.' >&2
                return 1
            fi
            sleep 1
            seconds=$((seconds+1))
        done
        restart=yes
    fi
    result=0
    steam_helper "$steam_action" "$@" || result=$?
    if [ "$restart" = yes ] || { [ "$steam_action" = register ] && [ "$result" -eq 0 ]; }; then
        /usr/bin/open -g -b com.valvesoftware.steam || return 1
    fi
    return "$result"
}
if [ "$action" != build ]; then
    [ -z "$game$output$deps$cache$python$target_arch" ] && [ "$editor" = auto ] && [ "$support" = auto ] || fail 'Registration takes only --steam-library.'
    require_apple_tools
    if [ "$action" = register-steam ]; then steam_helper inspect >/dev/null; fi
    steam_change "${action%-steam}"
    exit
fi
[ -n "$game" ] || { usage >&2; exit 2; }
requested_arch=$target_arch
target_arch=${target_arch:-universal}
case $target_arch in arm64|x86_64|universal) ;; *) fail 'Choose --arch arm64, x86_64 or universal.' ;; esac
game=$(cd "$game" && pwd -P)
data="$game/PEAK_Data"
require_input() { [ -s "$game/$1" ] || fail "Missing Steam PEAK input: $1"; }
for file in PEAK.exe version.txt PEAK_Data/Managed/Assembly-CSharp.dll; do require_input "$file"; done
for file in app.info boot.config globalgamemanagers globalgamemanagers.assets globalgamemanagers.assets.resS \
    resources.assets resources.assets.resS resources.resource RuntimeInitializeOnLoads.json ScriptingAssemblies.json \
    Resources/unity_builtin_extra StreamingAssets/maps/maps level4.resS; do
    require_input "PEAK_Data/$file"
done
for level in 0 1 2 3 4; do
    for file in "level$level" "sharedassets$level.assets" "sharedassets$level.assets.resS"; do
        require_input "PEAK_Data/$file"
    done
    if [ "$level" != 2 ]; then require_input "PEAK_Data/sharedassets$level.resource"; fi
done
# The seven Steam archives cover all 208 maps. A partial copy would otherwise
# silently produce an app that fails only when the missing map range is selected.
for range in 0-31 32-63 64-95 96-127 128-159 160-191 192-207; do
    require_input "PEAK_Data/StreamingAssets/maps/levels$range.assetbundle"
done
# The map-loader change relies on the exact managed gameplay assembly. Reject
# incompatible Steam updates before downloading the Unity player and build tools.
version=$(LC_ALL=C sed -nE '1s/^([0-9]+\.[0-9]+\.[0-9]+)([^0-9.].*)?$/\1/p' "$game/version.txt")
[ "$version" = 3.1.0 ] || fail "Unsupported PEAK version: ${version:-unknown}. Expected Steam PEAK 3.1.0 (BuildID 26542162)."
game_hash=$(shasum -a 256 < "$data/Managed/Assembly-CSharp.dll")
[ "${game_hash%% *}" = a3643f11dc444d86491270b224c0a0caf9126a10b26731feb97fc85ad1d82038 ] || fail 'Unsupported Assembly-CSharp.dll. Use an unmodified Windows copy of Steam PEAK 3.1.0 (BuildID 26542162).'
steam_install=no
if [ -z "$output" ]; then
    require_apple_tools
    output=$(steam_helper path)
    case $output in /*/steamapps/common/PEAK/PEAK.app) ;; *) fail 'Unexpected PEAK Steam installation path.' ;; esac
    library=${output%/steamapps/common/PEAK/PEAK.app}
    mkdir -p "$(dirname "$output")"
    steam_install=yes
fi
parent=$(cd "$(dirname "$output")" && pwd -P)
name=$(basename "$output")
case $name in *.app) ;; *) fail 'Output must end in .app' ;; esac
output="$parent/$name"
if [ "$steam_install" = yes ]; then
    workroot="$library/steamapps"
    default_cache="$library/.macipeak-cache"
    if [ -e "$output" ] || [ -L "$output" ]; then
        set --
        if [ -n "$requested_arch" ]; then set -- --expected-arch "$requested_arch"; fi
        steam_helper inspect "$@" >/dev/null
        printf 'Registering the existing PEAK.app at %s.\n' "$output"
        steam_change register "$@"
        exit
    fi
else
    case "$parent/" in "$game/"*) fail 'Choose an output outside the Windows installation.' ;; esac
    workroot="$parent"
    default_cache="$parent/.macipeak-cache"
    [ ! -e "$output" ] && [ ! -L "$output" ] || fail "Output already exists: $output"
    require_apple_tools
fi
if [ -n "$deps" ]; then deps=$(cd "$deps" && pwd -P); fi
work=$(mktemp -d "$workroot/.peak-build.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/tmp"
export TMPDIR="$work/tmp" PYTHONDONTWRITEBYTECODE=1 CLANG_MODULE_CACHE_PATH="$work/clang-cache"
cache=$(resolve_cache_path "${cache:-$default_cache}")
case "$cache/" in "$game/"*|"$output/"*) fail 'Choose a cache outside the input and output.' ;; esac
mkdir -p "$cache"
export MACIPEAK_CACHE="$cache" MACIPEAK_DEPS="$deps"

if [ -n "$python" ]; then
    "$python" -c 'import sys; sys.exit(sys.version_info < (3,10))' || fail 'The specified Python must be version 3.10 or newer.'
else
    for candidate in python3.13 python3 python3.14 python3.12 python3.11 python3.10 /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13; do
        if "$candidate" -c 'import sys; sys.exit(not (3, 10) <= sys.version_info[:2] <= (3, 14))' 2>/dev/null; then python=$candidate; break; fi
    done
    if [ -z "$python" ]; then python=$(bootstrap_python "$work" "$deps"); fi
fi
python=$("$python" -c 'import sys; print(sys.executable)')
export PEAK_BUILD_PYTHON="$python"
app="$work/PEAK.app"
if [ "$editor" = auto ] && [ -d /Applications/Unity/Hub/Editor/6000.3.15f1/Unity.app ]; then
    editor=/Applications/Unity/Hub/Editor/6000.3.15f1/Unity.app
fi
if [ "$support" = auto ] && [ -d "$editor" ]; then
    for module in "$editor/Contents/PlaybackEngines/MacStandaloneSupport" "$(dirname "$editor")/PlaybackEngines/MacStandaloneSupport"; do
        if [ -d "$module" ]; then support=$module; break; fi
    done
fi
if [ -d "$editor/Contents" ]; then export UNITY_EDITOR_APP="$editor"; fi
sh "$here/scripts/stage-player.sh" "$support" "$app" "$work"
"$python" "$here/scripts/stage-icon.py" "$game/PEAK.exe" "$app"
# PEAK uses Application.version to select its Photon matchmaking version.
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
dest="$app/Contents/Resources/Data"
# Clone unchanged multi-gigabyte streams when input and output share an APFS volume.
# On other volumes, cp -pR performs the same logical copy.
copy() {
    if ! /bin/cp -cRp "$1" "$2" 2>/dev/null; then /bin/cp -Rp "$1" "$2"; fi
}
for source in "$data"/*; do
    case $(basename "$source") in
        Plugins|Resources|globalgamemanagers|*.assets|level[0-9]|level[0-9][0-9]) continue ;;
        StreamingAssets)
            # These bundles are produced directly from the input by prepare_content.py.
            # Copying the Windows bundles first adds 14.5 GB of I/O on other volumes.
            mkdir -p "$dest/StreamingAssets"
            /usr/bin/rsync -a --exclude '*.assetbundle' --exclude '/maps/maps' "$source/" "$dest/StreamingAssets/"
            continue ;;
    esac
    copy "$source" "$dest/"
done
for source in "$data/Resources"/*; do
    [ -e "$source" ] || continue
    case $(basename "$source") in 'unity default resources'|unity_builtin_extra) continue ;; esac
    copy "$source" "$dest/Resources/"
done
sh "$here/scripts/stage-bcl.sh" "$game" "$app" "$editor"
sh "$here/scripts/stage-plugins.sh" "$game" "$app" "$deps"
sh "$here/scripts/stage-graphics.sh" "$python" "$data" "$dest" "$cache" "$deps" "$work"
"$python" "$here/scripts/stage-render-scale.py" "$dest/Managed/Assembly-CSharp.dll"

# Steam's direct-launch convention uses the game's actual AppID. Library
# initialization and account entitlement remain the responsibility of Steam.
printf '3527290\n' > "$app/Contents/Resources/steam_appid.txt"
ln -s ../Resources/steam_appid.txt "$app/Contents/MacOS/steam_appid.txt"
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$app/Contents/Info.plist"
# Unity chooses its Metal presentation path before any managed game code runs.
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment:UNITY_DISPLAYLINK_BLIT string 0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment:UNITY_USE_METAL_DISPLAY_LINK string 0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment:SteamAppId string 3527290' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment:SteamGameId string 3527290' "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
sh "$here/scripts/stage-arch.sh" "$app" "$target_arch"
codesign --force --sign - "$app"
codesign --verify --strict --deep --all-architectures "$app"
# renamex_np(RENAME_EXCL) is atomic and refuses races for the destination.
"$python" - "$app" "$output" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
if libc.renamex_np(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), 4):
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err), sys.argv[2])
PY
if [ -x /usr/bin/gktool ]; then
    printf '%s\n' 'Preparing PEAK for its first launch with macOS Gatekeeper…'
    if ! /usr/bin/gktool scan "$output"; then
        printf '%s\n' 'Gatekeeper could not complete the pre-launch scan. macOS will assess PEAK when it opens.' >&2
    fi
fi
printf 'Built %s\n' "$output"
if [ "$steam_install" = yes ]; then
    if ! steam_change register; then
        printf 'Your completed app is at %s. Retry with --register-steam --steam-library "%s".\n' "$output" "$library" >&2
        exit 1
    fi
fi
