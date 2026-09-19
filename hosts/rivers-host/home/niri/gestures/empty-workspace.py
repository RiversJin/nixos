import json
import subprocess

NIRI = '/run/current-system/sw/bin/niri'

def query(kind):
    return json.loads(subprocess.check_output([NIRI, 'msg', '-j', kind]))

workspaces = query('workspaces')
focused = next(w for w in workspaces if w['is_focused'])
occupied = {w['workspace_id'] for w in query('windows')}
empty = sorted((w for w in workspaces
                if w['output'] == focused['output'] and w['id'] not in occupied),
               key=lambda w: w['idx'])
if focused['id'] not in occupied:
    print('Already on an empty workspace', flush=True)
elif empty:
    target = empty[-1]
    subprocess.run([NIRI, 'msg', 'action', 'focus-workspace', str(target['idx'])], check=True)
    print(f"Focused empty workspace {target['idx']} on {target['output']}", flush=True)
else:
    raise SystemExit('No empty workspace on the focused output')
