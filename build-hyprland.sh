#!/usr/bin/env bash
# Build a private Hyprland 0.56 stack on Ubuntu 24.04 ARM64. No sudo or system install.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STACK="$ROOT/.nested"
PREFIX="$STACK/prefix"
JOBS=${JOBS:-8}
mkdir -p "$STACK"/{sources,logs,prefix}
export CC=gcc-14 CXX=g++-14
export PYTHONPATH="$STACK/python${PYTHONPATH:+:$PYTHONPATH}"
export PATH="$STACK/python/bin:$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$PREFIX:/usr/local${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:/usr/local/lib:/usr/local/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"

fetch_git() {
    local name=$1 url=$2 rev=$3 path="$STACK/sources/$1"
    if [[ ! -d "$path/.git" ]]; then
        git init -q "$path"
        git -C "$path" remote add origin "$url"
    fi
    if ! git -C "$path" rev-parse --verify "$rev^{commit}" >/dev/null 2>&1; then
        git -C "$path" fetch --depth=1 origin "$rev"
        rev=FETCH_HEAD
    fi
    git -C "$path" checkout -q --detach "$rev"
}

if [[ ${1:-} != --rebuild ]]; then
if [[ ! -x "$STACK/python/bin/cmake" ]]; then
    uv pip install --target "$STACK/python" cmake==3.31.6 meson==1.7.2
fi
while read -r name rev; do
    fetch_git "$name" "https://github.com/hyprwm/$name.git" "$rev"
done < <(python3 - "$ROOT/flake.lock" <<'PINS'
import json, sys
nodes = json.load(open(sys.argv[1]))['nodes']
for name in ['hyprutils', 'hyprwayland-scanner', 'hyprlang', 'hyprcursor', 'hyprgraphics', 'aquamarine', 'hyprwire']:
    print(name, nodes[name]['locked']['rev'])
PINS
)
fetch_git glslang https://github.com/KhronosGroup/glslang.git 15.4.0
fetch_git glaze https://github.com/stephenberry/glaze.git v7.2.0
fetch_git wayland https://gitlab.freedesktop.org/wayland/wayland.git 1.25.0
fetch_git wayland-protocols https://gitlab.freedesktop.org/wayland/wayland-protocols.git 1.49
fetch_git libinput https://gitlab.freedesktop.org/libinput/libinput.git 1.29.1
fetch_git libei https://gitlab.freedesktop.org/libinput/libei.git 1.4.0
if [[ ! -f "$STACK/sources/lua-5.5.0/Makefile" ]]; then
    curl --fail --location --retry 3 https://www.lua.org/ftp/lua-5.5.0.tar.gz -o "$STACK/sources/lua-5.5.0.tar.gz"
    tar -xzf "$STACK/sources/lua-5.5.0.tar.gz" -C "$STACK/sources"
fi
git -C "$ROOT" submodule update --init subprojects/udis86 subprojects/hyprland-protocols
[[ ${1:-} != --fetch-only ]] || exit 0
python3 "$ROOT/scripts/nested/patch-deps.py" "$STACK/sources/hyprwire"

fi

cmake_build() {
    local name=$1
    shift
    cmake -S "$STACK/sources/$name" -B "$STACK/sources/$name/build" -G Ninja \
        -U 'pkgcfg_lib_*' -U '__pkg_config_checked_*' -DPKG_CONFIG_EXECUTABLE="$ROOT/scripts/nested/pkg-config.sh" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
        -DBUILD_TESTING=OFF "$@" || return
    cmake --build "$STACK/sources/$name/build" --parallel "$JOBS" || return
    cmake --install "$STACK/sources/$name/build"
}
meson_build() {
    local name=$1
    shift
    meson setup --reconfigure --clearcache "$STACK/sources/$name/build" "$STACK/sources/$name" \
        --prefix="$PREFIX" --libdir=lib --buildtype=release "$@" || return
    meson compile -C "$STACK/sources/$name/build" -j "$JOBS" || return
    meson install -C "$STACK/sources/$name/build" --no-rebuild
}
step() {
    local name=$1
    shift
    printf 'Building %s (log: %s/logs/%s.log)\n' "$name" "$STACK" "$name"
    if ( "$@" ) >"$STACK/logs/$name.log" 2>&1; then
        printf '%s: OK\n' "$name"
    else
        tail -80 "$STACK/logs/$name.log"
        return 1
    fi
}
build_lua() {
    make -C "$STACK/sources/lua-5.5.0" -j "$JOBS" linux MYCFLAGS=-fPIC || return
    make -C "$STACK/sources/lua-5.5.0" install INSTALL_TOP="$PREFIX" || return
    mkdir -p "$PREFIX/lib/pkgconfig"
    cat >"$PREFIX/lib/pkgconfig/lua5.5.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: Lua
Description: Lua language engine
Version: 5.5.0
Libs: -L\${libdir} -llua -lm -ldl
Cflags: -I\${includedir}
EOF
}

if [[ ${1:-} != --rebuild ]]; then
    step wayland meson_build wayland -Dtests=false -Ddocumentation=false
    step wayland-protocols meson_build wayland-protocols -Dtests=false
    step libinput meson_build libinput -Dtests=false -Ddocumentation=false -Ddebug-gui=false -Dlibwacom=false
    step libei meson_build libei -Dtests=disabled -Ddocumentation=[]
    step lua build_lua
    step glslang cmake_build glslang -DENABLE_OPT=OFF -DENABLE_GLSLANG_BINARIES=OFF -DENABLE_HLSL=OFF
    step hyprutils cmake_build hyprutils
    step hyprwayland-scanner cmake_build hyprwayland-scanner
    step hyprlang cmake_build hyprlang
    step hyprcursor cmake_build hyprcursor
    step hyprgraphics cmake_build hyprgraphics
    step aquamarine cmake_build aquamarine
    step hyprwire cmake_build hyprwire
fi

step configure cmake -S "$ROOT" -B "$ROOT/build" -G Ninja \
    -U 'pkgcfg_lib_*' -U '__pkg_config_checked_*' -DPKG_CONFIG_EXECUTABLE="$ROOT/scripts/nested/pkg-config.sh" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_RPATH="$PREFIX/lib" \
    -DCMAKE_INSTALL_RPATH="$PREFIX/lib" -DNO_HYPRPM=ON \
    -DPython3_EXECUTABLE=/usr/bin/python3 \
    -DFETCHCONTENT_SOURCE_DIR_GLAZE="$STACK/sources/glaze"
step Hyprland cmake --build "$ROOT/build" --parallel "$JOBS" --target Hyprland hyprctl
printf 'Built %s/build/Hyprland. Launch with %s/scripts/nested/run.sh\n' "$ROOT" "$ROOT"
