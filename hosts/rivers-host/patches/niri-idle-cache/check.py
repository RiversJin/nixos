#!/usr/bin/env python3
"""Bounded, real-GPU regression for niri's render-independent cache cleanup.

Requires an AMD GPU and an already running, disposable niri instance. Its
outputs must initially be on. No client surface or frame callback is created.
The --output variant temporarily disables the named (sole) output completely.
"""

import argparse
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--socket', required=True)
parser.add_argument('--niri', default='niri')
parser.add_argument('--client', required=True)
parser.add_argument('--render-node', required=True)
parser.add_argument('--output', help='disable the sole output instead of DPMS')
parser.add_argument('--count', type=int, default=128)
parser.add_argument('--interval-ms', type=int, default=100)
parser.add_argument('--expect-leak', action='store_true')
parser.add_argument('--log', type=Path, required=True)
args = parser.parse_args()
match = re.fullmatch(r'niri\.(.+)\.(\d+)\.sock', Path(args.socket).name)
if match is None:
    parser.error('socket must be named niri.WAYLAND_DISPLAY.PID.sock')
wayland, pid = match.groups()
env = dict(os.environ, NIRI_SOCKET=args.socket, WAYLAND_DISPLAY=wayland)
MIB = 1024 * 1024
records = []


def ipc(*command):
    return subprocess.check_output([args.niri, 'msg', *command], env=env, text=True)


def memory(label):
    clients = {}
    for entry in Path(f'/proc/{pid}/fdinfo').iterdir():
        try:
            text = entry.read_text()
        except FileNotFoundError:
            continue
        fields = dict(line.split(':', 1) for line in text.splitlines() if ':' in line)
        if fields.get('drm-driver', '').strip() != 'amdgpu':
            continue
        key = fields['drm-pdev'].strip() + ':' + fields['drm-client-id'].strip()
        clients[key] = {k: v.strip() for k, v in fields.items() if k.startswith('drm-')}
    if not clients or any('drm-total-vram' not in c for c in clients.values()):
        raise RuntimeError('AMDGPU drm-total-* fdinfo statistics are required')
    total = 0
    for client in clients.values():
        for domain in ('vram', 'gtt', 'cpu'):
            value = client[f'drm-total-{domain}'].split()
            total += int(value[0]) * ({'KiB': 1024, 'MiB': MIB}.get(value[1], 1) if len(value) > 1 else 1)
    records.append(dict(time=time.time(), label=label, bytes=total, clients=clients))
    args.log.write_text(''.join(json.dumps(item) + '\n' for item in records))
    print(f'{label}: {total / MIB:.2f} MiB', flush=True)
    return total


def command(count, interval, hold=0):
    return [args.client, args.render_node, str(count), str(interval), str(hold)]


def wait_for_holding(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=15):
            raise RuntimeError('client did not reach live-buffer phase')
        line = process.stdout.readline()
        if not line.startswith('holding '):
            raise RuntimeError(f'client failed before live-buffer phase: {line!r}')


if args.output:
    outputs = json.loads(ipc('-j', 'outputs'))
    active = [k for k, v in outputs.items() if v['current_mode'] is not None]
    if active != [args.output]:
        parser.error('--output requires that named output to be the only active output')

ipc('action', 'power-on-monitors')
time.sleep(3)
memory('on-before')
try:
    if args.output:
        ipc('output', args.output, 'off')
    else:
        ipc('action', 'power-off-monitors')
    time.sleep(2)
    before = memory('inactive-before')
    subprocess.run(command(args.count, args.interval_ms), env=env, check=True,
                   timeout=args.count * args.interval_ms / 1000 + 20)
    memory('inactive-after-churn')
    time.sleep(4)
    after = memory('inactive-after-grace')
    delta = after - before
    if args.expect_leak:
        assert delta > args.count * 4 * MIB * 0.8, f'baseline did not reproduce: {delta / MIB:.2f} MiB'
    else:
        assert delta < 64 * MIB, f'dead imports retained: {delta / MIB:.2f} MiB'
        # The cleanup must retain still-live imports, then free them when the
        # client destroys its buffers, without requiring a rendered frame.
        before_live = memory('live-before')
        process = subprocess.Popen(command(32, 10, 6), env=env, text=True, stdout=subprocess.PIPE)
        try:
            wait_for_holding(process)
            time.sleep(3)
            live = memory('live-after-three-cleanup-ticks')
            assert live - before_live > 100 * MIB, 'live imports were prematurely evicted'
            process.communicate(timeout=15)
            assert process.returncode == 0, 'live-buffer client failed'
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        time.sleep(4)
        released = memory('live-after-destroy-and-grace')
        assert released - before_live < 64 * MIB, 'destroyed live imports were not reclaimed'
    print('PASS', flush=True)
finally:
    if args.output:
        ipc('output', args.output, 'on')
    ipc('action', 'power-on-monitors')
    time.sleep(3)
    memory('on-restored')
