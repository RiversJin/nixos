"""Use the same Super+Space input-method shortcut as the desktop."""
from pathlib import Path
import re

path = Path.home() / '.config/fcitx5/config'
text = path.read_text() if path.exists() else ''
section = '[Hotkey/TriggerKeys]\n0=Super+space\n\n'
pattern = r'(?ms)^\[Hotkey/TriggerKeys\]\n.*?(?=^\[|\Z)'
if re.search(pattern, text):
    text = re.sub(pattern, lambda _: section, text)
else:
    text += '\n' + section
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(text)
