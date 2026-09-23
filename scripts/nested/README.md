# Hyprland 0.56.2 nested test desktop

This branch ports the fork's GCC 14 / Ubuntu 24.04 ARM64 compatibility fixes
to upstream v0.56.2. The build and launcher keep the installed desktop separate.

From this checkout:

```sh
./build-hyprland.sh                 # first build, including private dependencies
./scripts/nested/run.sh            # open the test desktop in the current session
./scripts/nested/run.sh status
./scripts/nested/run.sh stop
./build-hyprland.sh --rebuild       # rebuild Hyprland after editing its source
./scripts/nested/run.sh
```

The first build needs the development packages already used for this fork,
GCC 14, `/usr/bin/python3` 3.12+, `uv`, Git, curl, and Ninja. CMake and Meson
are downloaded into `.nested/python`. Hyprland ecosystem revisions come from
the release's `flake.lock`; other dependency versions are pinned in the script.
`JOBS=4 ./build-hyprland.sh` lowers build concurrency from the default of eight.

The build stages dependencies under `.nested/prefix` and leaves Hyprland and
its matching hyprctl in `build/`. It never installs into `/usr` or `/usr/local`.
The original compiler workarounds are retained, with the embedded default Lua
config generated from the current example instead of a stale copied config.
Hyprwire's range appends receive equivalent GCC 14-compatible inserts.

The window appears as **aquamarine - WAYLAND-1**. The launcher starts six
disposable Kitty terminals in a vertical scrolling layout. Two terminals fit
in the viewport; moving focus reveals the others. Their shells skip personal
startup files.
When launched from Hyprland, the launcher floats and centers only its own new
window at 900 × 1400 (or smaller if needed), before opening the demo terminals.

| Shortcut inside the test window | Action |
| --- | --- |
| Alt + Up / Down | Focus the previous / next terminal and scroll to it |
| Alt + Enter | Open another test terminal |
| Alt + Q | Close the focused terminal |
| Alt + S / D / M | Select scrolling / dwindle / master |
| Alt + Shift + Escape | Exit the nested desktop |

Super shortcuts remain handled by the outer desktop. Click inside the test
window before using its Alt shortcuts.

All test IPC commands use the private runtime and explicit instance signature:

```sh
./scripts/nested/run.sh ctl configerrors
./scripts/nested/run.sh ctl clients -j
./scripts/nested/run.sh ctl output create wayland
```

The last command creates another virtual monitor as another window. Do not
send test commands through an unqualified system `hyprctl` from an outer terminal.

The launcher uses a private runtime in `/tmp/h56-*` to keep Unix socket paths
short. It connects to the parent's absolute Wayland socket, forces libseat to
an absent private seatd socket, and disables systemd environment updates and
notifications. The test compositor therefore cannot acquire the physical
display seat or replace the parent's session environment. Test configuration,
cache, data, and state live under `.nested/`.

Build logs are in `.nested/logs/`; the compositor log is
`.nested/logs/desktop.log`, and `.nested/desktop.json` records its PID, socket,
and instance. No physical-monitor config, normal startup commands, or existing
applications are imported into the test desktop. Nested testing exercises the
new layouts and rendering; direct display modes and monitor wake still require
a later real-session test.
