#!/bin/sh
# Exercise the same slice selection and code signatures used by PEAK.app.
set -eu
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/host-tools.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/macipeak-arch.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
template="$work/Fixture.app"
contents="$template/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/PlugIns" "$contents/Resources"
cat > "$contents/Info.plist" <<'EOF'
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.macipeak.archtest</string>
<key>CFBundleExecutable</key><string>PEAK</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
echo 'int answer(void) { return 42; }' > "$work/library.c"
cat > "$work/player.c" <<'EOF'
#include <stdio.h>
extern int answer(void);
int main(void) {
#if defined(__arm64__)
    puts("arm64");
#else
    puts("x86_64");
#endif
    return answer() != 42;
}
EOF
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -dynamiclib "$work/library.c" \
    -install_name @rpath/libFixture.dylib -o "$contents/Frameworks/libFixture.dylib"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 "$work/player.c" \
    -L"$contents/Frameworks" -lFixture -Wl,-rpath,@executable_path/../Frameworks -o "$contents/MacOS/PEAK"
cp "$contents/Frameworks/libFixture.dylib" "$contents/PlugIns/PluginWithoutExtension"
echo 'fixture resource' > "$contents/Resources/ReadMe"
ln -s PluginWithoutExtension "$contents/PlugIns/PluginAlias"
for selected in arm64 x86_64 universal; do
    app="$work/$selected.app"
    cp -R "$template" "$app"
    sh "$here/stage-arch.sh" "$app" "$selected"
    for relative in MacOS/PEAK Frameworks/libFixture.dylib PlugIns/PluginWithoutExtension; do
        binary="$app/Contents/$relative"
        if [ "$selected" = universal ]; then
            require_universal_macho "$binary"
        else
            [ "$(/usr/bin/lipo -archs "$binary")" = "$selected" ]
        fi
    done
    [ -L "$app/Contents/PlugIns/PluginAlias" ]
    [ "$(cat "$app/Contents/Resources/ReadMe")" = 'fixture resource' ]
    codesign --force --sign - "$app"
    codesign --verify --strict --deep --all-architectures "$app"
    for cpu in arm64 x86_64; do
        if [ "$selected" != universal ] && [ "$selected" != "$cpu" ]; then continue; fi
        if /usr/bin/arch "-$cpu" /usr/bin/true 2>/dev/null; then
            [ "$(/usr/bin/arch "-$cpu" "$app/Contents/MacOS/PEAK")" = "$cpu" ]
            printf '%s ran as %s\n' "$selected" "$cpu"
        fi
    done
done
if require_universal_macho "$work/arm64.app/Contents/MacOS/PEAK"; then
    echo 'Accepted a thin binary in the universal library check' >&2
    exit 1
fi
if sh "$here/stage-arch.sh" "$work/arm64.app" universal; then
    echo 'Accepted an incomplete universal player' >&2
    exit 1
fi
