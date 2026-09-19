"""Force-close the focused window's process, never a whole process group."""
import json
import os
from pathlib import Path
import signal
import subprocess


def focused_window():
    result = subprocess.run(
        ['niri', 'msg', '-j', 'focused-window'],
        check=True, capture_output=True, text=True, timeout=3,
    )
    return json.loads(result.stdout)


def main():
    window = focused_window()
    if not window:
        return
    pid = window.get('pid')
    if not isinstance(pid, int) or pid <= 1 or pid == os.getpid():
        return
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return
    try:
        process = Path('/proc') / str(pid)
        if process.stat().st_uid != os.getuid():
            return
        if process.joinpath('comm').read_text().strip() in (
            'niri', 'Xwayland', 'xwayland-satell', 'systemd',
        ):
            return
        # Abort if focus changed while resolving the process.
        current = focused_window()
        if not current or (current['id'], current.get('pid')) != (window['id'], pid):
            return
        signal.pidfd_send_signal(fd, signal.SIGKILL)
    except (FileNotFoundError, ProcessLookupError):
        pass
    finally:
        os.close(fd)


if __name__ == '__main__':
    main()
