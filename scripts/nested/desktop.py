#!/usr/bin/env python3
"""Start and control only the private 0.56 desktop, never the host compositor."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
STACK = ROOT / ".nested"
BINARY = ROOT / "build/Hyprland"
CTL = ROOT / "build/hyprctl/hyprctl"
STATE = STACK / "desktop.json"
LOG = STACK / "logs/desktop.log"


def environment(runtime):
    env = os.environ.copy()
    for key in ("HYPRLAND_INSTANCE_SIGNATURE", "NOTIFY_SOCKET", "WATCHDOG_PID", "WATCHDOG_USEC"):
        env.pop(key, None)
    env.update({
        "XDG_RUNTIME_DIR": str(runtime),
        "HYPRLAND_NO_SD_VARS": "1",
        "HYPRLAND_NO_SD_NOTIFY": "1",
        "HYPRLAND_NO_RT": "1",
        # Force libseat to fail before opening a physical display session.
        "LIBSEAT_BACKEND": "seatd",
        "SEATD_SOCK": str(Path(runtime) / "no-seatd.sock"),
        "LD_LIBRARY_PATH": f"{STACK}/prefix/lib:/usr/local/lib:/usr/local/lib/aarch64-linux-gnu",
        "PKG_CONFIG_PATH": f"{STACK}/prefix/lib/pkgconfig:{STACK}/prefix/share/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig",
        "PATH": f"{ROOT}/build/hyprctl:{STACK}/prefix/bin:{env.get('PATH', '')}",
        "HYPRLAND_NESTED_ROOT": str(ROOT),
    })
    for key, name in (("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_STATE_HOME", "state"), ("XDG_DATA_HOME", "data")):
        directory = STACK / name
        directory.mkdir(parents=True, exist_ok=True)
        env[key] = str(directory)
    return env


def alive(state):
    try:
        return Path(f"/proc/{state['pid']}/exe").resolve(strict=True) == BINARY.resolve()
    except (FileNotFoundError, PermissionError):
        return False


def control(state, args, **kwargs):
    if not alive(state):
        raise SystemExit("The nested desktop is not running. Start it with scripts/nested/run.sh")
    return subprocess.run([str(CTL), "-i", state["instance"], *args],
                          env=environment(state["runtime"]), check=True, **kwargs)


def place_window(pid):
    """Give only our new window a useful size when the parent is Hyprland."""
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    hostctl = shutil.which("hyprctl")
    if not signature or not hostctl:
        return

    def host(*args):
        return subprocess.check_output([hostctl, "-i", signature, *args], text=True, timeout=5)

    try:
        for _ in range(30):
            clients = json.loads(host("clients", "-j"))
            window = next((c for c in clients if c["pid"] == pid), None)
            if window:
                break
            time.sleep(0.1)
        else:
            return
        monitor = next(m for m in json.loads(host("monitors", "-j")) if m["id"] == window["monitor"])
        width, height = monitor["width"] / monitor["scale"], monitor["height"] / monitor["scale"]
        if monitor["transform"] % 2:
            width, height = height, width
        left, top, right, bottom = monitor["reserved"]
        width, height = width - left - right, height - top - bottom
        test_width, test_height = min(900, int(width - 40)), min(1400, int(height - 40))
        x = round(monitor["x"] + left + (width - test_width) / 2)
        y = round(monitor["y"] + top + (height - test_height) / 2)
        address = "address:" + window["address"]
        host("dispatch", "setfloating", address)
        host("dispatch", "resizewindowpixel", f"exact {test_width} {test_height},{address}")
        host("dispatch", "movewindowpixel", f"exact {x} {y},{address}")
        time.sleep(0.3)
    except (subprocess.SubprocessError, ValueError, KeyError, StopIteration) as error:
        print(f"Automatic test-window placement skipped: {error}", file=sys.stderr)


def demo(state):
    for number in range(1, 7):
        command = shlex.quote(str(ROOT / "scripts/nested/terminal.sh")) + f" {number}"
        control(state, ["eval", f"hl.exec_cmd({json.dumps(command)})"], capture_output=True)
        # Wait for each window to map so the numbered demo has a stable spatial order.
        for _ in range(30):
            clients = json.loads(control(state, ["clients", "-j"], capture_output=True, text=True).stdout)
            if any(c["title"] == f"Hyprland 0.56.2 — terminal {number}" for c in clients):
                break
            time.sleep(0.1)


def start():
    if STATE.exists():
        previous = json.loads(STATE.read_text())
        if alive(previous):
            print(f"Nested desktop is already running (PID {previous['pid']}).")
            return
    if not BINARY.is_file() or not CTL.is_file():
        raise SystemExit("Build first with ./build-hyprland.sh")
    display = os.environ.get("WAYLAND_DISPLAY")
    if not display:
        raise SystemExit("Run this from inside your existing Wayland desktop.")
    parent_socket = Path(display)
    if not parent_socket.is_absolute():
        parent_socket = Path(os.environ["XDG_RUNTIME_DIR"]) / parent_socket
    if not parent_socket.is_socket():
        raise SystemExit(f"Parent Wayland socket does not exist: {parent_socket}")
    # Keep the path short: Hyprland's instance names approach AF_UNIX's path limit.
    runtime = tempfile.mkdtemp(prefix="h56-")
    env = environment(runtime)
    env["WAYLAND_DISPLAY"] = str(parent_socket)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("w") as log:
        proc = subprocess.Popen([str(BINARY), "--config", str(ROOT / "scripts/nested/test.lua")],
                                env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(150):
        if proc.poll() is not None:
            raise SystemExit(f"Nested desktop exited ({proc.returncode}). See {LOG}")
        result = subprocess.run([str(CTL), "instances", "-j"], env=env,
                                capture_output=True, text=True, timeout=5)
        try:
            instances = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError):
            instances = []
        for instance in instances:
            if instance["pid"] != proc.pid:
                continue
            state = {**instance, "runtime": runtime, "parent_socket": str(parent_socket)}
            ipc = Path(runtime) / "hypr" / instance["instance"] / ".socket.sock"
            if not ipc.is_socket():
                continue
            STATE.write_text(json.dumps(state, indent=2) + "\n")
            place_window(proc.pid)
            demo(state)
            print(f"Nested Hyprland started (PID {proc.pid}). Log: {LOG}")
            return
        time.sleep(0.2)
    proc.terminate()
    raise SystemExit(f"Nested desktop did not become ready. See {LOG}")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "start"
    if action == "start":
        start()
        return
    if not STATE.exists():
        raise SystemExit("No nested desktop has been started yet.")
    state = json.loads(STATE.read_text())
    if action == "stop":
        control(state, ["dispatch", "hl.dsp.exit()"])
    elif action == "status":
        control(state, ["version"])
        control(state, ["monitors"])
    elif action == "ctl":
        if len(sys.argv) < 3:
            raise SystemExit("Usage: run.sh ctl <hyprctl arguments>")
        control(state, sys.argv[2:])
    else:
        raise SystemExit("Usage: run.sh [start|stop|status|ctl <hyprctl arguments>]")


if __name__ == "__main__":
    main()
