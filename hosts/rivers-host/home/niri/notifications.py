"""Small read-only history viewer for Mako, using the existing Rofi theme."""
import html
import json
import re
import subprocess
import sys


def run(*args, **kwargs):
    return subprocess.run(args, text=True, **kwargs)


def plain(value):
    return html.unescape(re.sub(r"<[^>]*>", "", value or "")).replace("\x00", "")


if sys.argv[1:] == ["dnd"]:
    raise SystemExit(run("makoctl", "mode", "-t", "do-not-disturb").returncode)

items = []
seen = set()
for command in ("list", "history"):
    result = run("makoctl", command, "-j", capture_output=True, check=True)
    for item in json.loads(result.stdout):
        if item["id"] not in seen:
            seen.add(item["id"])
            items.append(item)
if not items:
    run("rofi", "-e", "暂无通知历史")
else:
    rows = [" · ".join((plain(n.get("app_name")), plain(n.get("summary")), plain(n.get("body"))))
            .replace("\n", " ").replace("\r", " ")[:220] for n in items]
    choice = run("rofi", "-dmenu", "-i", "-p", "通知历史", "-format", "i",
                 input="\n".join(rows), capture_output=True)
    if choice.returncode == 0 and choice.stdout.strip().isdigit():
        index = int(choice.stdout)
        if 0 <= index < len(items):
            n = items[index]
            detail = "\n\n".join(plain(n.get(k)) for k in ("app_name", "summary", "body"))
            run("rofi", "-e", html.escape(detail))
