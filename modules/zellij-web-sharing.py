"""Enable sharing for new sessions without replacing the user's Zellij config."""
import os
from pathlib import Path
import re
import shutil

path = Path.home() / ".config/zellij/config.kdl"
path.parent.mkdir(parents=True, exist_ok=True)
original = path.read_text() if path.exists() else ""
updated = original
for key, value in [("web_sharing", '"on"'), ("web_server_port", "18082")]:
    pattern = rf'^{key}[^\S\n]+[^\n]*$'
    updated, count = re.subn(pattern, f"{key} {value}", updated, flags=re.MULTILINE)
    if not count:
        updated = updated.rstrip() + f"\n\n{key} {value}\n"
if updated != original:
    backup = path.with_name("config.kdl.before-zellij-web")
    if path.exists() and not backup.exists():
        shutil.copyfile(path, backup)
        backup.chmod(0o600)
    temporary = path.with_name("config.kdl.zellij-web-new")
    temporary.write_text(updated)
    temporary.chmod(0o600)
    os.replace(temporary, path)
