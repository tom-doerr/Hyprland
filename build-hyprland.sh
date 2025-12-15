#!/bin/bash

# Hyprland Build Script for Ubuntu 24.04
# Runs independent builds in parallel and collects all errors

BUILD_DIR="$HOME/git/hyprland-deps"
JOBS=$(nproc)
LOG_DIR="$BUILD_DIR/logs"
ERRORS=()

# Use GCC 14 for most builds (has #embed support and libstdc++ ABI compatibility)
# Only hyprwire uses clang-18/libc++ for append_range support
export CC=gcc-14
export CXX=g++-14
export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"

# Ensure locally built libraries are found
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib/aarch64-linux-gnu:$LD_LIBRARY_PATH"
export LIBRARY_PATH="/usr/local/lib:/usr/local/lib/aarch64-linux-gnu:$LIBRARY_PATH"
export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"

echo "=== Hyprland Build Script ==="
echo "Build directory: $BUILD_DIR"
echo "Using $JOBS parallel jobs"
echo "Compiler: $CXX"
echo ""

mkdir -p "$BUILD_DIR"
mkdir -p "$LOG_DIR"

# Function to log and track errors
log_error() {
    ERRORS+=("$1")
    echo "ERROR: $1"
}

# Function to build a cmake project
build_cmake() {
    local name=$1
    local repo=$2
    local opts=${3:-""}
    local log="$LOG_DIR/${name}.log"

    echo "=== Building $name ===" | tee "$log"

    cd "$BUILD_DIR"

    if [ -d "$name" ]; then
        echo "Updating $name..." | tee -a "$log"
        cd "$name"
        git pull >> "$log" 2>&1 || { log_error "$name: git pull failed"; return 1; }
    else
        git clone --depth 1 "$repo" "$name" >> "$log" 2>&1 || { log_error "$name: git clone failed"; return 1; }
        cd "$name"
    fi

    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_COMPILER=gcc-14 \
        -DCMAKE_CXX_COMPILER=g++-14 \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
        -DCMAKE_SHARED_LINKER_FLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
        $opts >> "$log" 2>&1
    if [ $? -ne 0 ]; then
        log_error "$name: cmake configure failed (see $log)"
        return 1
    fi

    cmake --build build -j$JOBS >> "$log" 2>&1
    if [ $? -ne 0 ]; then
        log_error "$name: cmake build failed (see $log)"
        return 1
    fi

    sudo cmake --install build >> "$log" 2>&1
    if [ $? -ne 0 ]; then
        log_error "$name: cmake install failed (see $log)"
        return 1
    fi

    echo "$name: SUCCESS" | tee -a "$log"
    return 0
}

# Fix expired NVIDIA workbench repo key (if present)
if [ -f /etc/apt/sources.list.d/nvidia-workbench.list ]; then
    echo "=== Disabling expired NVIDIA Workbench repo ==="
    sudo mv /etc/apt/sources.list.d/nvidia-workbench.list /etc/apt/sources.list.d/nvidia-workbench.list.disabled 2>/dev/null || true
fi

# Install system dependencies
echo "=== Installing system dependencies ==="
sudo apt update || true  # Continue even if some repos fail

# Install clang-18 and libc++ for C++23 support (GCC 14's libstdc++ doesn't support append_range)
echo "Installing clang-18 and libc++..."
sudo apt install -y clang-18 libc++-18-dev libc++abi-18-dev

# All other packages - fixed package names
PACKAGES=(
    # Build tools
    meson ninja-build cmake-extras cmake gettext gettext-base scdoc check
    # Font/text
    fontconfig libfontconfig-dev
    # Core libs
    libffi-dev libxml2-dev libdrm-dev libpixman-1-dev libudev-dev libseat-dev seatd
    # XKB build deps
    libxkbcommon-x11-dev libxkbregistry-dev libxkbcommon-dev
    libxcb-xkb-dev libxml2-dev bison byacc flex doxygen
    # Vulkan/GL
    libvulkan-dev libvulkan-volk-dev vulkan-utility-libraries-dev libvkfft-dev libgulkan-dev
    libegl-dev libgles2 libegl1-mesa-dev glslang-tools
    # XCB
    libxcb-dri3-dev libxcb-composite0-dev libxcb-ewmh2 libxcb-ewmh-dev libxcb-present-dev
    libxcb-icccm4-dev libxcb-render-util0-dev libxcb-res0-dev libxcb-xinput-dev
    # Input/AV
    libinput-bin libinput-dev libavutil-dev libavcodec-dev libavformat-dev
    # Wayland build deps
    libwayland-dev libwayland-client0 libwayland-egl1 libwlroots-dev
    libffi-dev libxml2-dev graphviz
    # Display
    hwdata libdisplay-info-dev libliftoff-dev libgbm-dev
    # Misc libs
    libsystemd-dev libtomlplusplus-dev libmagic-dev libzip-dev librsvg2-dev libpugixml-dev
    # NEW: re2 and muparser for Hyprland
    libre2-dev libmuparser-dev
    # UUID
    uuid-dev
    # Cairo/Pango
    libcairo2-dev libpango1.0-dev
    # XWayland deps
    xwayland libxcb-util-dev libxcb-cursor-dev
    # Portal
    xdg-desktop-portal-wlr
)

echo "Installing ${#PACKAGES[@]} packages..."
sudo apt install -y "${PACKAGES[@]}" 2>&1 | tee "$LOG_DIR/apt-install.log"
APT_STATUS=${PIPESTATUS[0]}

if [ $APT_STATUS -ne 0 ]; then
    log_error "Some apt packages failed to install (see $LOG_DIR/apt-install.log)"
    echo ""
    echo "Continuing anyway to identify build issues..."
    echo ""
fi

# Verify compilers are available
echo ""
echo "Checking compilers..."
gcc-14 --version | head -1
g++-14 --version | head -1
clang-18 --version | head -1  # Needed for hyprwire

sudo ldconfig

# ============================================================
# STAGE 0: Build system libraries from source (wayland, xkbcommon, etc)
# ============================================================
echo ""
echo "=== STAGE 0a: Building wayland from source ==="

WAYLAND_LOG="$LOG_DIR/wayland.log"
echo "=== Building wayland ===" | tee "$WAYLAND_LOG"
cd "$BUILD_DIR"

if [ -d "wayland" ]; then
    cd wayland && git fetch >> "$WAYLAND_LOG" 2>&1
else
    git clone https://gitlab.freedesktop.org/wayland/wayland.git >> "$WAYLAND_LOG" 2>&1
    cd wayland
fi
rm -rf build
git checkout 1.23.1 >> "$WAYLAND_LOG" 2>&1

meson setup build --prefix=/usr/local -Ddocumentation=false -Dtests=false >> "$WAYLAND_LOG" 2>&1
ninja -C build -j$JOBS >> "$WAYLAND_LOG" 2>&1 && sudo ninja -C build install >> "$WAYLAND_LOG" 2>&1
if [ $? -eq 0 ]; then
    echo "wayland: SUCCESS" | tee -a "$WAYLAND_LOG"
else
    log_error "wayland: build failed (see $WAYLAND_LOG)"
fi
sudo ldconfig

echo ""
echo "=== STAGE 0b: Building wayland-protocols from source ==="

PROTOCOLS_LOG="$LOG_DIR/wayland-protocols.log"
echo "=== Building wayland-protocols ===" | tee "$PROTOCOLS_LOG"
cd "$BUILD_DIR"

if [ -d "wayland-protocols" ]; then
    cd wayland-protocols && git fetch >> "$PROTOCOLS_LOG" 2>&1
else
    git clone https://gitlab.freedesktop.org/wayland/wayland-protocols.git >> "$PROTOCOLS_LOG" 2>&1
    cd wayland-protocols
fi
rm -rf build
git checkout 1.46 >> "$PROTOCOLS_LOG" 2>&1  # Need >= 1.45 for Hyprland

meson setup build --prefix=/usr/local >> "$PROTOCOLS_LOG" 2>&1
ninja -C build -j$JOBS >> "$PROTOCOLS_LOG" 2>&1 && sudo ninja -C build install >> "$PROTOCOLS_LOG" 2>&1
if [ $? -eq 0 ]; then
    echo "wayland-protocols: SUCCESS" | tee -a "$PROTOCOLS_LOG"
else
    log_error "wayland-protocols: build failed (see $PROTOCOLS_LOG)"
fi
sudo ldconfig

echo ""
echo "=== STAGE 0c: Building xkbcommon from source ==="

XKB_LOG="$LOG_DIR/xkbcommon.log"
echo "=== Building xkbcommon ===" | tee "$XKB_LOG"
cd "$BUILD_DIR"

if [ -d "libxkbcommon" ]; then
    cd libxkbcommon && git fetch >> "$XKB_LOG" 2>&1
else
    git clone https://github.com/xkbcommon/libxkbcommon.git >> "$XKB_LOG" 2>&1
    cd libxkbcommon
fi
rm -rf build
git checkout xkbcommon-1.13.1 >> "$XKB_LOG" 2>&1  # Need >= 1.11.0 for Hyprland

meson setup build --prefix=/usr/local -Denable-docs=false >> "$XKB_LOG" 2>&1
ninja -C build -j$JOBS >> "$XKB_LOG" 2>&1 && sudo ninja -C build install >> "$XKB_LOG" 2>&1
if [ $? -eq 0 ]; then
    echo "xkbcommon: SUCCESS" | tee -a "$XKB_LOG"
else
    log_error "xkbcommon: build failed (see $XKB_LOG)"
fi
sudo ldconfig

# ============================================================
# STAGE 0d: Build xcb-errors from source (not in Ubuntu 24.04)
# ============================================================
echo ""
echo "=== STAGE 0d: Building xcb-errors from source ==="

XCBERR_LOG="$LOG_DIR/xcb-errors.log"
echo "=== Building xcb-errors ===" | tee "$XCBERR_LOG"
cd "$BUILD_DIR"

# Need xcb-proto, autotools, and xcb-util-common for m4 macros
sudo apt install -y xcb-proto python3-xcbgen autoconf automake libtool xutils-dev \
    libxcb-util-dev libxcb1-dev xorg-macros >> "$XCBERR_LOG" 2>&1

# Remove old checkout and get fresh with submodules
rm -rf xcb-errors
git clone https://gitlab.freedesktop.org/xorg/lib/libxcb-errors.git xcb-errors >> "$XCBERR_LOG" 2>&1
cd xcb-errors

# Get the xcb-util-m4 submodule which provides XCB_UTIL_M4_WITH_INCLUDE_PATH
git submodule update --init >> "$XCBERR_LOG" 2>&1

# Make sure aclocal can find the m4 macros
export ACLOCAL_PATH="$BUILD_DIR/xcb-errors/m4:$ACLOCAL_PATH"
export ACLOCAL="aclocal -I m4"

autoreconf -ivf >> "$XCBERR_LOG" 2>&1
./configure --prefix=/usr/local >> "$XCBERR_LOG" 2>&1
make -j$JOBS >> "$XCBERR_LOG" 2>&1 && sudo make install >> "$XCBERR_LOG" 2>&1
if [ $? -eq 0 ]; then
    echo "xcb-errors: SUCCESS" | tee -a "$XCBERR_LOG"
else
    log_error "xcb-errors: build failed (see $XCBERR_LOG)"
fi
sudo ldconfig

# ============================================================
# STAGE 1: Independent builds (can run in parallel)
# ============================================================
echo ""
echo "=== STAGE 1: Building independent dependencies (parallel) ==="

build_cmake "hyprwayland-scanner" "https://github.com/hyprwm/hyprwayland-scanner" &
PID_SCANNER=$!

build_cmake "hyprutils" "https://github.com/hyprwm/hyprutils" &
PID_UTILS=$!

# hyprwire - build with GCC after patching append_range calls
(
    WIRE_LOG="$LOG_DIR/hyprwire.log"
    echo "=== Building hyprwire ===" | tee "$WIRE_LOG"

    cd "$BUILD_DIR"
    if [ -d "hyprwire" ]; then
        echo "Updating hyprwire..." | tee -a "$WIRE_LOG"
        cd hyprwire
        git checkout . >> "$WIRE_LOG" 2>&1  # Reset any previous patches
        git pull >> "$WIRE_LOG" 2>&1
    else
        git clone --depth 1 https://github.com/hyprwm/hyprwire >> "$WIRE_LOG" 2>&1
        cd hyprwire
    fi
    rm -rf build

    # Patch append_range calls to use insert() for GCC compatibility
    echo "Patching hyprwire for GCC compatibility..." | tee -a "$WIRE_LOG"

    # Use Python for safer patching - write script to temp file and run it
    cat > /tmp/patch_hyprwire.py << 'PYSCRIPT'
import os
import re

def find_matching_paren(s, start):
    """Find the index of the closing paren matching the one at start"""
    depth = 1
    i = start + 1
    while i < len(s) and depth > 0:
        if s[i] == '(':
            depth += 1
        elif s[i] == ')':
            depth -= 1
        i += 1
    return i - 1 if depth == 0 else -1

def patch_append_range(content):
    result = []
    i = 0
    while i < len(content):
        # Look for .append_range( - capture full member chain (e.g., message.data)
        match = re.search(r'((?:\w+\.)*\w+)\.append_range\(', content[i:])
        if not match:
            result.append(content[i:])
            break

        # Add content before match
        result.append(content[i:i + match.start()])

        var = match.group(1)
        paren_start = i + match.end() - 1  # Index of (

        paren_end = find_matching_paren(content, paren_start)
        if paren_end == -1:
            # No matching paren, keep original
            result.append(match.group(0))
            i = i + match.end()
            continue

        # Extract the argument
        arg = content[paren_start + 1:paren_end].strip()

        # Create replacement
        replacement = f'{{ auto __ar = ({arg}); {var}.insert({var}.end(), __ar.begin(), __ar.end()); }}'
        result.append(replacement)

        i = paren_end + 1

    return ''.join(result)

for root, dirs, files in os.walk('src'):
    for fname in files:
        if fname.endswith('.cpp'):
            fpath = os.path.join(root, fname)
            with open(fpath, 'r') as f:
                content = f.read()
            patched = patch_append_range(content)
            if patched != content:
                with open(fpath, 'w') as f:
                    f.write(patched)
                print(f"Patched: {fpath}")
PYSCRIPT
    python3 /tmp/patch_hyprwire.py 2>&1 | tee -a "$WIRE_LOG"
    echo "hyprwire patched" | tee -a "$WIRE_LOG"

    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_COMPILER=gcc-14 \
        -DCMAKE_CXX_COMPILER=g++-14 >> "$WIRE_LOG" 2>&1

    # Build only the library and scanner, skip tests
    cmake --build build --target hyprwire -j$JOBS >> "$WIRE_LOG" 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: hyprwire library build failed" | tee -a "$WIRE_LOG"
        exit 1
    fi

    cmake --build build --target hyprwire-scanner -j$JOBS >> "$WIRE_LOG" 2>&1

    sudo cmake --install build >> "$WIRE_LOG" 2>&1
    echo "hyprwire: SUCCESS" | tee -a "$WIRE_LOG"
) &
PID_WIRE=$!

# Wait for stage 1
wait $PID_SCANNER
SCANNER_OK=$?
wait $PID_UTILS
UTILS_OK=$?
wait $PID_WIRE
WIRE_OK=$?

sudo ldconfig

# ============================================================
# STAGE 2: Depends on hyprutils
# ============================================================
echo ""
echo "=== STAGE 2: Building hyprlang (depends on hyprutils) ==="

if [ $UTILS_OK -eq 0 ]; then
    build_cmake "hyprlang" "https://github.com/hyprwm/hyprlang"
    LANG_OK=$?
else
    log_error "hyprlang: skipped (hyprutils failed)"
    LANG_OK=1
fi

sudo ldconfig

# ============================================================
# STAGE 3a: Build libinput from source (Ubuntu 24.04 has 1.25, need 1.28+)
# ============================================================
echo ""
echo "=== STAGE 3a: Building libinput 1.28 from source ==="

LIBINPUT_LOG="$LOG_DIR/libinput.log"
LIBINPUT_OK=1

echo "=== Building libinput ===" | tee "$LIBINPUT_LOG"
cd "$BUILD_DIR"

if [ -d "libinput" ]; then
    echo "Updating libinput..." | tee -a "$LIBINPUT_LOG"
    cd libinput
    git fetch >> "$LIBINPUT_LOG" 2>&1
else
    git clone https://gitlab.freedesktop.org/libinput/libinput.git >> "$LIBINPUT_LOG" 2>&1
    cd libinput
fi

# Clean old build and checkout version 1.28.0 (required by Hyprland)
rm -rf build
git checkout 1.28.0 >> "$LIBINPUT_LOG" 2>&1

# Install libinput build dependencies
sudo apt install -y libmtdev-dev libevdev-dev libwacom-dev libgtk-4-dev libsystemd-dev \
    libudev-dev check >> "$LIBINPUT_LOG" 2>&1

# Build with meson
meson setup build --prefix=/usr/local -Ddocumentation=false -Dtests=false -Ddebug-gui=false >> "$LIBINPUT_LOG" 2>&1
if [ $? -ne 0 ]; then
    log_error "libinput: meson configure failed (see $LIBINPUT_LOG)"
    LIBINPUT_OK=0
else
    ninja -C build -j$JOBS >> "$LIBINPUT_LOG" 2>&1
    if [ $? -ne 0 ]; then
        log_error "libinput: ninja build failed (see $LIBINPUT_LOG)"
        LIBINPUT_OK=0
    else
        sudo ninja -C build install >> "$LIBINPUT_LOG" 2>&1
        if [ $? -ne 0 ]; then
            log_error "libinput: install failed (see $LIBINPUT_LOG)"
            LIBINPUT_OK=0
        else
            echo "libinput: SUCCESS" | tee -a "$LIBINPUT_LOG"
        fi
    fi
fi

sudo ldconfig

# ============================================================
# STAGE 3b: Depends on hyprlang (can run in parallel)
# ============================================================
echo ""
echo "=== STAGE 3b: Building hyprcursor, hyprgraphics, and aquamarine (parallel) ==="

if [ $LANG_OK -eq 0 ]; then
    # Build hyprcursor - only the library (tests fail due to tomlplusplus ABI mismatch)
    (
        CURSOR_LOG="$LOG_DIR/hyprcursor.log"
        echo "=== Building hyprcursor ===" | tee "$CURSOR_LOG"
        cd "$BUILD_DIR"

        if [ -d "hyprcursor" ]; then
            echo "Updating hyprcursor..." | tee -a "$CURSOR_LOG"
            cd hyprcursor
            git pull >> "$CURSOR_LOG" 2>&1
        else
            git clone --depth 1 https://github.com/hyprwm/hyprcursor >> "$CURSOR_LOG" 2>&1
            cd hyprcursor
        fi
        rm -rf build

        cmake -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DCMAKE_C_COMPILER=gcc-14 \
            -DCMAKE_CXX_COMPILER=g++-14 >> "$CURSOR_LOG" 2>&1

        cmake --build build -j$JOBS >> "$CURSOR_LOG" 2>&1
        if [ $? -ne 0 ]; then
            echo "ERROR: hyprcursor library build failed" | tee -a "$CURSOR_LOG"
            exit 1
        fi

        sudo cmake --install build >> "$CURSOR_LOG" 2>&1
        echo "hyprcursor: SUCCESS" | tee -a "$CURSOR_LOG"
    ) &
    PID_CURSOR=$!

    # Build hyprgraphics - only the library
    (
        GRAPHICS_LOG="$LOG_DIR/hyprgraphics.log"
        echo "=== Building hyprgraphics ===" | tee "$GRAPHICS_LOG"
        cd "$BUILD_DIR"

        if [ -d "hyprgraphics" ]; then
            echo "Updating hyprgraphics..." | tee -a "$GRAPHICS_LOG"
            cd hyprgraphics
            git pull >> "$GRAPHICS_LOG" 2>&1
        else
            git clone --depth 1 https://github.com/hyprwm/hyprgraphics >> "$GRAPHICS_LOG" 2>&1
            cd hyprgraphics
        fi
        rm -rf build

        cmake -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DCMAKE_C_COMPILER=gcc-14 \
            -DCMAKE_CXX_COMPILER=g++-14 >> "$GRAPHICS_LOG" 2>&1

        cmake --build build -j$JOBS >> "$GRAPHICS_LOG" 2>&1
        if [ $? -ne 0 ]; then
            echo "ERROR: hyprgraphics library build failed" | tee -a "$GRAPHICS_LOG"
            exit 1
        fi

        sudo cmake --install build >> "$GRAPHICS_LOG" 2>&1
        echo "hyprgraphics: SUCCESS" | tee -a "$GRAPHICS_LOG"
    ) &
    PID_GRAPHICS=$!
else
    log_error "hyprcursor: skipped (hyprlang failed)"
    log_error "hyprgraphics: skipped (hyprlang failed)"
    PID_CURSOR=""
    PID_GRAPHICS=""
fi

if [ $UTILS_OK -eq 0 ] && [ $LIBINPUT_OK -eq 1 ]; then
    # Build aquamarine separately - tests fail but library builds fine
    (
        AQUA_LOG="$LOG_DIR/aquamarine.log"
        echo "=== Building aquamarine ===" | tee "$AQUA_LOG"
        cd "$BUILD_DIR"

        if [ -d "aquamarine" ]; then
            echo "Updating aquamarine..." | tee -a "$AQUA_LOG"
            cd aquamarine
            git pull >> "$AQUA_LOG" 2>&1
        else
            git clone --depth 1 https://github.com/hyprwm/aquamarine >> "$AQUA_LOG" 2>&1
            cd aquamarine
        fi

        cmake -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DCMAKE_C_COMPILER=gcc-14 \
            -DCMAKE_CXX_COMPILER=g++-14 >> "$AQUA_LOG" 2>&1

        # Build just the library target, not tests
        cmake --build build --target aquamarine -j$JOBS >> "$AQUA_LOG" 2>&1
        if [ $? -ne 0 ]; then
            echo "ERROR: aquamarine library build failed" | tee -a "$AQUA_LOG"
            exit 1
        fi

        sudo cmake --install build >> "$AQUA_LOG" 2>&1
        echo "aquamarine: SUCCESS" | tee -a "$AQUA_LOG"
    ) &
    PID_AQUA=$!
else
    log_error "aquamarine: skipped (hyprutils or libinput failed)"
    PID_AQUA=""
fi

# Wait for stage 3
CURSOR_OK=1
GRAPHICS_OK=1
AQUA_OK=1
[ -n "$PID_CURSOR" ] && { wait $PID_CURSOR; CURSOR_OK=$?; }
[ -n "$PID_GRAPHICS" ] && { wait $PID_GRAPHICS; GRAPHICS_OK=$?; }
[ -n "$PID_AQUA" ] && { wait $PID_AQUA; AQUA_OK=$?; }

sudo ldconfig

# ============================================================
# STAGE 4: Build Hyprland
# ============================================================
echo ""
echo "=== STAGE 4: Building Hyprland ==="

HYPRLAND_LOG="$LOG_DIR/hyprland.log"

if [ $SCANNER_OK -eq 0 ] && [ $UTILS_OK -eq 0 ] && [ $WIRE_OK -eq 0 ] && [ $LANG_OK -eq 0 ] && [ $CURSOR_OK -eq 0 ] && [ $GRAPHICS_OK -eq 0 ] && [ $AQUA_OK -eq 0 ]; then
    # Check if Hyprland is already successfully installed
    if [ -f /usr/local/bin/Hyprland ] && [ -f /usr/local/bin/hyprctl ]; then
        echo "Hyprland already installed, skipping rebuild"
        echo "Hyprland: SUCCESS (already installed)" | tee -a "$HYPRLAND_LOG"
    else
        cd "$HOME/git/Hyprland"
        rm -rf build

    # Pre-processing: Replace #embed with actual config bytes (GCC 14 doesn't support #embed)
    echo "Pre-processing: Converting example config to C array..." | tee -a "$HYPRLAND_LOG"
    CONFIG_FILE="$HOME/git/Hyprland/example/hyprland.conf"
    HEADER_FILE="$HOME/git/Hyprland/src/config/defaultConfig.hpp"

    # Generate C array from config file using xxd
    CONFIG_BYTES=$(xxd -i < "$CONFIG_FILE" | tr -d '\n')

    # Create the header file with embedded config
    cat > "$HEADER_FILE" << 'HEADER_START'
#pragma once

#include <string>

inline constexpr std::string_view AUTOGENERATED_PREFIX   = R"#(
# #######################################################################################
# AUTOGENERATED HYPRLAND CONFIG.
# EDIT THIS CONFIG ACCORDING TO THE WIKI INSTRUCTIONS.
# #######################################################################################

autogenerated = 1 # remove this line to remove the warning

)#";
inline constexpr char             EXAMPLE_CONFIG_BYTES[] = {
HEADER_START

    xxd -i < "$CONFIG_FILE" >> "$HEADER_FILE"

    cat >> "$HEADER_FILE" << 'HEADER_END'
};

inline constexpr std::string_view EXAMPLE_CONFIG = {EXAMPLE_CONFIG_BYTES, sizeof(EXAMPLE_CONFIG_BYTES)};
HEADER_END

    echo "Config header generated" | tee -a "$HYPRLAND_LOG"

    # Fix XWM.hpp ternary operator type mismatch (GCC 14 is stricter than clang here)
    XWM_FILE="$HOME/git/Hyprland/src/xwayland/XWM.hpp"
    sed -i 's/return m_connection ? \*m_connection : nullptr;/return m_connection ? static_cast<xcb_connection_t*>(*m_connection) : nullptr;/' "$XWM_FILE"
    echo "XWM.hpp patched" | tee -a "$HYPRLAND_LOG"

    # Fix insert_range (C++23 feature not in GCC 14's libstdc++)
    MONITOR_FILE="$HOME/git/Hyprland/src/helpers/Monitor.cpp"
    sed -i 's/requestedModes\.insert_range(requestedModes\.end(), sortedModes | std::views::reverse);/{ auto rev = sortedModes | std::views::reverse; requestedModes.insert(requestedModes.end(), rev.begin(), rev.end()); }/' "$MONITOR_FILE"
    echo "Monitor.cpp patched" | tee -a "$HYPRLAND_LOG"

    # Fix hyprctl string_view concatenation (GCC 14 libstdc++ doesn't have string + string_view operator)
    HYPRCTL_FILE="$HOME/git/Hyprland/hyprctl/src/main.cpp"
    sed -i 's|getRuntimeDir() + "/" + instanceSignature + "/" + filename|getRuntimeDir() + "/" + instanceSignature + "/" + std::string(filename)|g' "$HYPRCTL_FILE"
    echo "hyprctl/main.cpp patched" | tee -a "$HYPRLAND_LOG"

    echo "Configuring Hyprland..." | tee -a "$HYPRLAND_LOG"
    # Note: Use GCC 14 for Hyprland - disable hyprpm which has tomlplusplus ABI issues
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_COMPILER=gcc-14 \
        -DCMAKE_CXX_COMPILER=g++-14 \
        -DNO_SYSTEMD=OFF \
        -DNO_HYPRPM=ON >> "$HYPRLAND_LOG" 2>&1

    if [ $? -ne 0 ]; then
        log_error "Hyprland: cmake configure failed (see $HYPRLAND_LOG)"
    else
        echo "Building Hyprland..." | tee -a "$HYPRLAND_LOG"
        cmake --build build -j$JOBS --verbose >> "$HYPRLAND_LOG" 2>&1

        if [ $? -ne 0 ]; then
            log_error "Hyprland: cmake build failed (see $HYPRLAND_LOG)"
        else
            echo "Installing Hyprland..." | tee -a "$HYPRLAND_LOG"
            sudo cmake --install build >> "$HYPRLAND_LOG" 2>&1

            if [ $? -ne 0 ]; then
                log_error "Hyprland: cmake install failed (see $HYPRLAND_LOG)"
            else
                # Install desktop entry
                sudo mkdir -p /usr/share/wayland-sessions
                sudo cp build/hyprland.desktop /usr/share/wayland-sessions/ 2>/dev/null || \
                sudo cp example/hyprland.desktop /usr/share/wayland-sessions/ 2>/dev/null || \
                echo "Note: Could not find desktop entry file"

                echo "Hyprland: SUCCESS" | tee -a "$HYPRLAND_LOG"
            fi
        fi
    fi
    fi  # close "already installed" check
else
    log_error "Hyprland: skipped (dependencies failed)"
fi

sudo ldconfig

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "=============================================="
echo "                BUILD SUMMARY                 "
echo "=============================================="
echo ""
echo "Log files: $LOG_DIR/"
ls -la "$LOG_DIR/"
echo ""

if [ ${#ERRORS[@]} -eq 0 ]; then
    echo "SUCCESS! All components built successfully."
    echo ""
    echo "To use Hyprland:"
    echo "1. Log out"
    echo "2. At the login screen, click the gear icon"
    echo "3. Select 'Hyprland'"
    echo "4. Log in"
    echo ""
    echo "Config file: ~/.config/hypr/hyprland.conf"
    echo ""
    echo "Recommended extras:"
    echo "  sudo apt install kitty wofi waybar swaybg swaylock grim slurp"
else
    echo "ERRORS ENCOUNTERED: ${#ERRORS[@]}"
    echo ""
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    echo ""
    echo "Check the log files above for details."
    echo "Fix the issues and run this script again."
fi
