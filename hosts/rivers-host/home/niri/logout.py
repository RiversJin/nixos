"""Request normal application shutdown before ending the Wayland session."""
import json
import os
import subprocess
import time


def graceful_logout(
    ipc, alive, notify, sleep=time.sleep, now=time.monotonic, timeout=30, settle_seconds=5
):
    windows = ipc("--json", "windows")
    pids = {w["pid"] for w in windows if w.get("pid")}
    for window in windows:
        ipc("action", "close-window", "--id", str(window["id"]))
    deadline = now() + timeout
    empty_since = None
    while True:
        remaining = ipc("--json", "windows")
        if remaining:
            empty_since = None
            if now() >= deadline:
                break
        else:
            if empty_since is None:
                empty_since = now()
            # Closing the last window need not terminate a tray/background app.
            # Allow process cleanup, but do not let such apps veto logout forever.
            if not any(alive(pid) for pid in pids) or now() - empty_since >= settle_seconds:
                ipc("action", "quit", "--skip-confirmation")
                return True
        sleep(0.25)
    notify("注销已取消", "仍有窗口未关闭。请处理保存提示，然后再次注销。")
    return False


def ipc(*args):
    result = subprocess.run(["niri", "msg", *args], check=True, capture_output=True, text=True)
    return json.loads(result.stdout) if args[0] == "--json" else None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def notify(title, message):
    subprocess.run(["notify-send", "-u", "normal", title, message], check=False)


if __name__ == "__main__":
    try:
        graceful_logout(ipc, alive, notify)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        notify("注销已取消", "无法确认应用已安全退出。")
        raise SystemExit(str(error))
