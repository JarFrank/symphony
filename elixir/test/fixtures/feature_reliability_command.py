#!/usr/bin/python3
"""Synchronization boundary around real commands; never fabricates their results."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(os.environ["FEATURE_ACCEPTANCE_ROOT"])
settings = json.loads((root / "command-boundary.json").read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
real = settings["commands"][name]
mode = settings["mode"]

if os.getpgrp() != os.getpid():
    os.setsid()
pid = os.getpid()
# A start-time token lets teardown avoid signalling a recycled PID/group.
token = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()[19]
(root / "wrappers" / f"{pid}.owner").write_text(f"{pid} {token}")


def boundary():
    (root / "boundary.json").write_text(json.dumps({"command": name, "args": args}))
    deadline = time.monotonic() + 15
    while not (root / "proceed").exists():
        if time.monotonic() >= deadline:
            sys.exit(124)
        time.sleep(0.01)


if name == "systemd-run":
    unit = args[args.index("--unit") + 1]
    (root / "wrappers" / f"{unit}.unit").write_text(unit)
    if mode == "before_launch":
        boundary()
elif name == "git" and mode == "before_commit" and "commit" in args:
    boundary()
elif name == "realpath" and mode == "before_release":
    import sqlite3

    with sqlite3.connect(f"file:{root}/runtime/state.sqlite3?mode=ro", uri=True) as db:
        state = json.loads(db.execute("SELECT state_json FROM features WHERE id = 'feature'").fetchone()[0])
    if state["phase"] == "ReadyForHuman" and not (root / "proceed").exists():
        boundary()

result = subprocess.run([real, *args], timeout=10)

if result.returncode == 0:
    if name == "git" and mode == "after_checkout" and "checkout" in args:
        boundary()
    elif name == "systemd-run" and mode == "after_validator_exit":
        # Wait for the real unit's exit, not an arbitrary delay. A future
        # implementation may retain an exited unit to preserve its identity.
        deadline = time.monotonic() + 5
        while True:
            observed = subprocess.run(
                [settings["systemctl"], "--user", "show", unit,
                 "-p", "LoadState", "-p", "ActiveState", "-p", "SubState"],
                capture_output=True, text=True, timeout=3,
            ).stdout
            if any(value in observed.splitlines() for value in (
                "LoadState=not-found", "ActiveState=inactive", "ActiveState=failed", "SubState=exited"
            )):
                break
            if time.monotonic() >= deadline:
                sys.exit(124)
            time.sleep(0.01)
        boundary()

sys.exit(result.returncode)
