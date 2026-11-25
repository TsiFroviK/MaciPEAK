#!/bin/sh
# Translate shader programs from the user's Windows installation in private staging.
set -eu
[ "$#" -eq 6 ] || { echo 'Expected python, Windows data, staged data, cache, SDK directory, work directory' >&2; exit 2; }
python=$1
source=$2
destination=$3
cache=$4
deps=$5
work=$6
here=$(cd "$(dirname "$0")/.." && pwd -P)
export PIP_CACHE_DIR="$cache/pip" PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONPYCACHEPREFIX="$work/pycache"
if ! "$python" -c 'import importlib.metadata as m; assert m.version("UnityPy")=="1.25.4" and m.version("lz4")=="4.4.5"' >/dev/null 2>&1; then
    "$python" -m venv "$work/venv"
    python="$work/venv/bin/python"
    "$python" -m pip install 'UnityPy==1.25.4' 'lz4==4.4.5'
fi
if [ -n "$deps" ] && [ -x "$deps/vkd3d-compiler" ] && [ -x "$deps/spirv-cross" ]; then
    compiler="$deps/vkd3d-compiler"
    cross="$deps/spirv-cross"
else
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    "$python" "$here/tools/shader_tools.py" --cache "$cache" > "$work/tool-paths"
    compiler=$(sed -n '1p' "$work/tool-paths")
    cross=$(sed -n '2p' "$work/tool-paths")
fi
[ -x "$compiler" ] && [ -x "$cross" ] || { echo 'Missing shader tools' >&2; exit 1; }
"$python" "$here/tools/prepare_content.py" --metal-work "$cache/programs" --vkd3d "$compiler" --spirv-cross "$cross" "$source" "$destination"
