#!/bin/sh
# Private macOS build tools. Archives are cached; extracted executables live in staging.

require_apple_tools() {
    if /usr/bin/xcode-select -p >/dev/null 2>&1 &&
       /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 &&
       /usr/bin/xcrun --find clang >/dev/null 2>&1; then
        return
    fi
    if [ -t 0 ] && [ -t 2 ]; then
        /usr/bin/xcode-select --install >&2 || :
    fi
    fail 'Install Apple Command Line Tools with xcode-select --install (or select an installed Xcode), finish the Apple installer, then run this command again.'
}

# Resolve missing directories before creating them, so --cache can never create
# files under the Windows installation, including when a parent is a symlink.
resolve_cache_path() (
    case $1 in /*) path=$1 ;; *) path="$(pwd -P)/$1" ;; esac
    if [ -d "$path" ]; then CDPATH= cd -P "$path" && pwd -P; exit; fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "Cache path is not a directory: $path"
    fi
    prefix=$(resolve_cache_path "$(dirname "$path")")
    leaf=$(basename "$path")
    case $leaf in
        .) printf '%s\n' "$prefix" ;;
        ..) dirname "$prefix" ;;
        *) printf '%s/%s\n' "${prefix%/}" "$leaf" ;;
    esac
)

host_archive() (
    name=$1 url=$2 expected=$3 mirror=$4
    check_digest() {
        digest=$(/usr/bin/shasum -a 256 < "$1")
        [ "${digest%% *}" = "$expected" ]
    }
    if [ -n "$mirror" ] && [ -f "$mirror/$name" ]; then
        check_digest "$mirror/$name" || fail "SHA-256 mismatch for $mirror/$name"
        printf '%s\n' "$mirror/$name"
        exit
    fi
    saved="$MACIPEAK_CACHE/host-archives/$name"
    if [ -f "$saved" ] && check_digest "$saved"; then
        printf '%s\n' "$saved"
        exit
    fi
    mkdir -p "$(dirname "$saved")"
    partial=$(mktemp "$MACIPEAK_CACHE/host-archives/.download.XXXXXXXX")
    trap 'rm -f "$partial"' EXIT
    trap 'exit 1' HUP INT TERM
    printf 'Downloading %s\n' "$name" >&2
    /usr/bin/curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' -o "$partial" "$url"
    check_digest "$partial" || fail "SHA-256 mismatch for downloaded $name"
    /bin/mv -f "$partial" "$saved"
    printf '%s\n' "$saved"
)

bootstrap_python() (
    work_dir=$1 mirror=$2
    case $(uname -m) in
        arm64) arch=aarch64; digest=1ee404a045f3de0e4ed59476fc9ec8c24ddece1e2a4c549a192a04b04b03b8c1 ;;
        x86_64) arch=x86_64; digest=204e7d25132cd8e511c938d74dd6393a911d557a822289019302496befa2c4bd ;;
        *) fail 'Unsupported macOS build architecture.' ;;
    esac
    name="cpython-3.13.18+20261123-$arch-apple-darwin-install_only_stripped.tar.gz"
    package=$(host_archive "$name" "https://github.com/astral-sh/python-build-standalone/releases/download/20261123/$name" "$digest" "$mirror")
    mkdir -p "$work_dir/host-python"
    /usr/bin/tar -xzf "$package" -C "$work_dir/host-python"
    printf '%s\n' "$work_dir/host-python/python/bin/python3"
)

# Sets host and compiler for the existing Roslyn build steps.
bootstrap_csharp() {
    case $(uname -m) in
        arm64) runtime_arch=arm64; runtime_digest=3211be3138d83af7a389649b50443c3d9015972ef8e228e2612230a3bd1d715d ;;
        x86_64) runtime_arch=x64; runtime_digest=c89c0fc6b95b3c42394eb726ae333f15ac41d65553e16ef6290e5a5ea30e9e85 ;;
        *) fail 'Unsupported macOS build architecture.' ;;
    esac
    runtime_name="dotnet-runtime-10.0.15-osx-$runtime_arch.tar.gz"
    runtime_package=$(host_archive "$runtime_name" "https://builds.dotnet.microsoft.com/dotnet/Runtime/10.0.15/$runtime_name" "$runtime_digest" "$2")
    roslyn_name=microsoft.net.compilers.toolset.5.12.0.nupkg
    roslyn_package=$(host_archive "$roslyn_name" "https://api.nuget.org/v3-flatcontainer/microsoft.net.compilers.toolset/5.12.0/$roslyn_name" 1a498048ddc7bd5fdc2883e7c77f733a3727693e88518851cf8a8ef93cb5fa8d "$2")
    mkdir -p "$1/host-dotnet" "$1/host-roslyn"
    /usr/bin/tar -xzf "$runtime_package" -C "$1/host-dotnet"
    /usr/bin/unzip -q "$roslyn_package" 'tasks/netcore/bincore/*' -d "$1/host-roslyn"
    host="$1/host-dotnet/dotnet"
    compiler="$1/host-roslyn/tasks/netcore/bincore/csc.dll"
    "$host" "$compiler" -nologo -version >/dev/null || fail 'Cannot run the downloaded Roslyn compiler.'
}
