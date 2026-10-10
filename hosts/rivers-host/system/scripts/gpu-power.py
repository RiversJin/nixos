"""Temporary DPM selection for the host's two RX 7900 XTX cards."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import sys


IDENTITIES = ("529896520e6a2a91", "843943f9c1667c30")


def discover():
    devices = {}
    for card in Path("/sys/class/drm").glob("card*"):
        if not re.fullmatch(r"card\d+", card.name):
            continue
        device = (card / "device").resolve()
        try:
            identity = (device / "unique_id").read_text().strip()
        except OSError:
            continue
        if identity in IDENTITIES:
            if identity in devices:
                raise RuntimeError(f"Duplicate GPU identity: {identity}")
            devices[identity] = device
    if set(devices) != set(IDENTITIES):
        raise RuntimeError("Both expected GPUs must be present")
    return devices


def read_state(device):
    table = (device / "pp_power_profile_mode").read_text()
    active = re.search(r"^\s*(\d+)\s+(\w+)\s*\*\s*:", table, re.M)
    if not active:
        raise RuntimeError(f"Cannot parse active profile: {device.name}")
    compute = re.search(r"^\s*(\d+)\s+COMPUTE\s*\*?\s*:", table, re.M)
    return {
        "dpm": (device / "power_dpm_force_performance_level").read_text().strip(),
        "profile": active[2],
        "profile_index": active[1],
        "compute_index": compute[1] if compute else None,
    }


def write_dpm(device, mode):
    (device / "power_dpm_force_performance_level").write_text(mode)


def restore(device, state):
    write_dpm(device, "auto")
    write_dpm(device, "manual")
    (device / "pp_power_profile_mode").write_text(state["profile_index"])
    write_dpm(device, state["dpm"])


def run(mode):
    devices = discover()
    before = {uid: read_state(devices[uid]) for uid in IDENTITIES}
    if mode == "compute" and any(s["compute_index"] is None for s in before.values()):
        raise RuntimeError("COMPUTE profile must be available on both GPUs")
    touched = []
    try:
        if mode != "status":
            for uid in IDENTITIES:
                device = devices[uid]
                touched.append(uid)
                if mode == "compute":
                    # SMU13 needs AUTO to clear HIGH's previous soft clock limits.
                    write_dpm(device, "auto")
                    write_dpm(device, "manual")
                    (device / "pp_power_profile_mode").write_text(before[uid]["compute_index"])
                else:
                    write_dpm(device, mode)
        after = {uid: read_state(devices[uid]) for uid in IDENTITIES}
        for uid, state in after.items():
            if mode == "compute":
                valid = state["dpm"] == "manual" and state["profile"] == "COMPUTE"
            else:
                valid = mode == "status" or state["dpm"] == mode
            if not valid:
                raise RuntimeError(f"Mode readback failed: {uid}")
    except BaseException:
        for uid in reversed(touched):
            try:
                restore(devices[uid], before[uid])
            except Exception as exc:
                print(f"Rollback failed for {uid}: {exc}", file=sys.stderr)
        raise
    for uid, state in after.items():
        print(f"{devices[uid].name} [{uid}]  DPM={state['dpm']}  profile={state['profile']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("status", "high", "compute", "auto", "profile_standard"))
    args = parser.parse_args()
    if args.mode == "status":
        run(args.mode)
    else:
        if os.geteuid() != 0:
            parser.error("Use gpu-power to switch modes with the scoped sudo rule")
        # Serialize invocations; /run is root-owned and users cannot replace this file.
        with open("/run/gpu-power.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            run(args.mode)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as exc:
        sys.exit(f"gpu-power: {exc}")
