#!/usr/bin/env python3
"""Fail-closed restart gate. Never accesses credentials or invokes processes.

One ledger file, separate attempt lists per key. Grok Bot restarts share the
"grok" key. Codex reopens use "codex". A maintenance hold blocks every key.
"""
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time


KEY_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")
LEDGER_MAX_BYTES = 8192


def validate_element(now, value):
    """Reject a ledger element that is not a finite, non-negative, non-future timestamp.

    Bool is rejected even though it is an int subclass. A bad element fails the
    whole state; callers must not drop it and continue.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("malformed attempt")
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("malformed attempt")
    if value < 0 or value > now:
        raise ValueError("malformed attempt")


def recent_attempts(now, attempts):
    if not isinstance(attempts, list):
        raise ValueError("invalid attempts")
    recent = []
    for value in attempts:
        validate_element(now, value)
        if now - float(value) < 3600:
            recent.append(value)
    return recent


def decision(now, pid, lease, attempts, held=False, idle_required=True):
    if held:
        return "maintenance_hold"
    recent = recent_attempts(now, attempts)
    if len(recent) >= 3:
        return "circuit_open"
    if recent and now - max(recent) < min(1800, 300 * 2 ** (len(recent) - 1)):
        return "retry_backoff"
    if not idle_required:
        return "allow"
    if not isinstance(lease, dict):
        return "idle_authorization_required"
    issued, expiry = lease.get("issuedAt"), lease.get("expiresAt")
    if (type(issued) not in (int, float) or type(expiry) not in (int, float)
            or not 0 < expiry - issued <= 900 or not issued <= now < expiry):
        return "idle_authorization_expired_or_invalid"
    if lease.get("idleConfirmed") is not True or type(lease.get("pid")) is not int:
        return "idle_authorization_invalid"
    if lease["pid"] != pid:
        return "idle_authorization_pid_changed"
    return "allow"


def normalize_attempts(now, attempts):
    """Return {key: [timestamps]}. Legacy flat lists are the grok key.

    Every element of every list is validated. One bad element raises.
    """
    if attempts is None:
        return {}
    if isinstance(attempts, list):
        for value in attempts:
            validate_element(now, value)
        return {"grok": list(attempts)}
    if isinstance(attempts, dict):
        out = {}
        for key, values in attempts.items():
            if not isinstance(key, str) or KEY_RE.fullmatch(key) is None:
                raise ValueError("malformed attempt key")
            if not isinstance(values, list):
                raise ValueError("invalid attempts")
            for value in values:
                validate_element(now, value)
            out[key] = list(values)
        return out
    raise ValueError("invalid attempts")


def private_json(path, optional=False):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        if optional:
            return None
        raise
    with os.fdopen(fd) as handle:
        st = os.fstat(handle.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise ValueError("unsafe state file")
        raw = handle.read(LEDGER_MAX_BYTES + 1)
        if len(raw) > LEDGER_MAX_BYTES:
            raise ValueError("state too large")
        if raw.strip() == "":
            raise ValueError("empty state")
        return json.loads(raw)


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix=".restart-guard-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def prune_window(now, values):
    return [value for value in values if 0 <= now - float(value) < 3600]


def observation_status(now, monotonic, previous, mode):
    """Conservative continuity check; a wake-like wall/uptime divergence blocks recovery.

    This is not an authoritative sleep/wake or all-lanes-idle signal.
    """
    if mode != "active" or not isinstance(previous, dict) or previous.get("mode") != "active":
        return "observation_required"
    wall, uptime = previous.get("wall"), previous.get("monotonic")
    for value in (now, monotonic, wall, uptime):
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            return "observation_required"
    elapsed, running = now - wall, monotonic - uptime
    if not 0 < elapsed <= 180 or running <= 0 or abs(elapsed - running) > 2:
        return "observation_required"
    return "continuous"


def observe(directory):
    path = Path(directory) / "grok-bot-observation-clock.json"
    try:
        previous = private_json(path, optional=True)
        now, monotonic = time.time(), time.monotonic()
        mode = "active" if os.environ.get("RECOVERY_MODE") == "active" else "observe"
        result = observation_status(now, monotonic, previous, mode)
        atomic_json(path, {"wall": now, "monotonic": monotonic, "mode": mode})
        print(result)
    except Exception:
        print("observation_error")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) == 2 and argv[0] == "--observe":
        observe(argv[1])
        return
    directory, raw_pid = argv[0:2]
    reason = argv[2] if len(argv) > 2 else "helper_missing"
    key = argv[3] if len(argv) > 3 else "grok"
    if KEY_RE.fullmatch(key) is None:
        print("restart_guard_error")
        return
    base = Path(directory)
    hold = base / "grok-bot-restart.hold"
    lease_path = base / "grok-bot-restart-idle.json"
    state_path = base / "grok-bot-restart-attempts.json"
    if hold.exists() or hold.is_symlink():
        print("maintenance_hold")
        return
    # Policy (a): helper loss relaunches without an idle authorization.
    # HELPER_IDLE_REQUIRED=1 restores the PID-bound one-use idle gate.
    idle_required = reason == "helper_missing" and os.environ.get("HELPER_IDLE_REQUIRED", "0") == "1"
    try:
        pid = int(raw_pid) if raw_pid else 0
        lease = private_json(lease_path, optional=True) if idle_required else None
        state = private_json(state_path, optional=True)
        if state is not None and not isinstance(state, dict):
            raise ValueError("malformed state")
        if state is None:
            if state_path.exists():
                raise ValueError("null state")
            attempts_raw = None
        elif "attempts" not in state:
            raise ValueError("missing attempts")
        else:
            attempts_raw = state["attempts"]
            if attempts_raw is None:
                raise ValueError("invalid attempts")
        now = time.time()
        by_key = normalize_attempts(now, attempts_raw)
        mine = by_key.get(key, [])
        result = decision(now, pid, lease, mine, idle_required=idle_required)
        if result == "allow":
            # Record before any quit/open. A crash cannot erase an attempt.
            stored = {}
            for name, values in by_key.items():
                kept = prune_window(now, values)
                if kept:
                    stored[name] = kept
            stored[key] = prune_window(now, mine) + [now]
            atomic_json(state_path, {"v": 2, "attempts": stored})
            # One authorization permits exactly one attempt, bound to this PID.
            if idle_required:
                lease_path.unlink()
        print(result)
    except Exception:
        # Malformed, untrusted, unreadable, or unwritable state cannot authorize a restart.
        print("restart_guard_error")


if __name__ == "__main__":
    main()
