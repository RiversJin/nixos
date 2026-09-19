"""Run the tested natask recognizer only on an attached Apple Magic Trackpad."""
import builtins
from pathlib import Path
import time
import gestures

original_enqueue = gestures.Worker.enqueue


def enqueue(self):
    original_enqueue(self)
    if self.gesture_queue:
        builtins.print("Recognized:", vars(self.gesture["type"]), flush=True)


gestures.Worker.enqueue = enqueue
while True:
    for device in sorted(Path('/sys/class/input').glob('event*')):
        try:
            name = (device / 'device/name').read_text().strip()
        except OSError:
            continue
        if name == 'Apple Inc. Magic Trackpad':
            builtins.print(f'Listening to {name} ({device.name})', flush=True)
            gestures.test(device.name, 1, 'touchpad')
            raise SystemExit(1)
    time.sleep(2)
