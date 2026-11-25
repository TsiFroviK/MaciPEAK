#!/bin/sh
# Select the game's native slices before the final app bundle signature.
set -eu
[ "$#" -eq 2 ] || { echo 'Usage: stage-arch.sh STAGED_APP arm64|x86_64|universal' >&2; exit 2; }
app=$(cd "$1" && pwd -P)
arch=$2
case $arch in arm64|x86_64|universal) ;; *) echo "Unsupported architecture: $arch" >&2; exit 2 ;; esac
contents="$app/Contents"
player="$contents/MacOS/PEAK"
[ -f "$player" ] && [ ! -L "$player" ] || { echo "Missing staged PEAK executable: $player" >&2; exit 1; }
scratch=$(mktemp -d "$(dirname "$app")/.peak-slices.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
find "$contents/MacOS" "$contents/Frameworks" "$contents/PlugIns" -type f -exec sh -ec '
    player=$1 arch=$2 scratch=$3
    shift 3
    for binary do
        case "$binary" in
            "$player"|*.dylib) ;;
            *) /usr/bin/file -b "$binary" | /usr/bin/grep -q "Mach-O" || continue ;;
        esac
        slices=$(/usr/bin/lipo -archs "$binary")
        case "$arch:$slices" in
            "universal:arm64 x86_64"|"universal:x86_64 arm64") ;;
            "arm64:arm64"|"x86_64:x86_64") ;;
            arm64:*|x86_64:*)
                /usr/bin/lipo "$binary" -thin "$arch" -output "$scratch/slice"
                chmod "$(/usr/bin/stat -f %Lp "$binary")" "$scratch/slice"
                mv -f "$scratch/slice" "$binary"
                [ "$(/usr/bin/lipo -archs "$binary")" = "$arch" ] || exit 1 ;;
            *) echo "Expected $arch in $binary, found $slices" >&2; exit 1 ;;
        esac
        if [ "$binary" != "$player" ]; then /usr/bin/codesign --force --sign - "$binary"; fi
    done
' sh "$player" "$arch" "$scratch" {} +
