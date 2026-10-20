#!/usr/bin/env python3
"""Codex desktop keep-alive decision. Does not quit, kill, or open processes.

The heal script performs `open -g <verified app path>` only after this module returns
action=reopen and the shared restart guard allows that key. Match the main
process by bundle executable path and pid. Display names and helper comm names
do not count.
"""
import json
from datetime import datetime
import os
import plistlib
import re
import stat
import subprocess
import sys
import time


BUNDLE_ID = "com.openai.codex"
MAIN_COMM = "ChatGPT"
HELPER_COMMS = {
    "Codex (Service)",
    "Codex (Renderer)",
    "codex",
    "node",
    "ChatGPT Classic",
    "ChatGPT.localized",
}
SUPPORTED_BUNDLES = {"com.openai.codex", "com.openai.chat"}
CRASH_SUFFIXES = (".ips", ".crash")
CRASH_READ_MAX = 4 * 1024 * 1024


def main_executable(app_path):
    name = MAIN_COMM
    try:
        with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as handle:
            candidate = plistlib.load(handle).get("CFBundleExecutable")
        if candidate in ("ChatGPT", "Codex"):
            name = candidate
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return app_path.rstrip("/") + "/Contents/MacOS/" + name


def parse_ps_text(text):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        left, sep, command = line.partition("\t")
        match = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$", left)
        if not match:
            continue
        comm = match.group(4).strip()
        cmd = command.strip() if sep else ""
        exe = cmd.split(" ")[0] if cmd else ""
        rows.append({
            "pid": int(match.group(1)),
            "ppid": int(match.group(2)),
            "comm": comm,
            "exe": exe,
            "command": cmd,
        })
    return rows


def is_main_process(row, app_path):
    """True only for the ChatGPT main executable inside this bundle.

    Helper comm names, ChatGPT Classic, and a ChatGPT.localized path do not match.
    """
    comm = row.get("comm")
    if comm not in (os.path.basename(main_executable(app_path)), main_executable(app_path)):
        return False
    expected = main_executable(app_path)
    return row.get("exe") == expected


def find_main(rows, app_path):
    found = [row for row in rows if is_main_process(row, app_path)]
    if not found:
        return None
    found.sort(key=lambda row: row["pid"])
    return found[0]


def parse_report_timestamp(value):
    """Normalize Apple's space/+HHMM timestamps and 1..9 fractional digits.

    Python 3.9 fromisoformat accepts only 3 or 6 fractional digits; report
    producers commonly emit four. Nanoseconds are conservatively truncated.
    """
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2})", value)
    if not match:
        return None
    date, clock, fraction, offset = match.groups()
    offset = "+00:00" if offset == "Z" else re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", offset)
    fraction = "." + fraction.ljust(6, "0")[:6] if fraction else ""
    try:
        return datetime.fromisoformat(date + "T" + clock + fraction + offset)
    except ValueError:
        return None


def crash_identity(text):
    """Read primary report fields, never bundle/name tokens in loaded images."""
    try:
        decoder = json.JSONDecoder()
        header, end = decoder.raw_decode(text.lstrip())
        if not isinstance(header, dict):
            return None
        rest = text.lstrip()[end:].strip()
        body = json.loads(rest) if rest else header
        if not isinstance(body, dict):
            return None
        bundle = body.get("bundleInfo", {}).get("CFBundleIdentifier") if isinstance(body.get("bundleInfo", {}), dict) else None
        bundle = bundle or header.get("bundleID")
        name = body.get("procName") or header.get("app_name")
        timestamp = body.get("captureTime") or header.get("timestamp")
        crash = str(header.get("bug_type")) == "309"
    except (ValueError, TypeError):
        def field(label):
            match = re.search(r"^" + re.escape(label) + r":\s*(.+)$", text, re.M)
            return match.group(1).strip() if match else None
        bundle = field("Identifier")
        process = field("Process") or ""
        name = re.sub(r"\s+\[\d+\]$", "", process)
        timestamp = field("Date/Time")
        crash = field("Crashed Thread") is not None
    try:
        when = parse_report_timestamp(timestamp)
        if when is None:
            return None
        return bundle, name, crash, when.timestamp()
    except (ValueError, TypeError, AttributeError, OverflowError):
        return None


def crash_report_matches(path, bundle_id, launched_at_s, main_name=MAIN_COMM, expected_pid=None):
    """A regular .ips/.crash file for this bundle main process, newer than launch."""
    if launched_at_s is None:
        return False
    try:
        if os.path.islink(path) or not os.path.isfile(path):
            return False
        if not path.endswith(CRASH_SUFFIXES):
            return False
        st = os.lstat(path)
        if not stat_is_reg(st.st_mode):
            return False
        if st.st_mtime <= float(launched_at_s):
            return False
        if st.st_size > CRASH_READ_MAX:
            return False
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "r", errors="replace") as handle:
            actual = os.fstat(handle.fileno())
            if not stat.S_ISREG(actual.st_mode) or actual.st_size > CRASH_READ_MAX:
                return False
            text = handle.read(CRASH_READ_MAX)
    except OSError:
        return False
    if expected_pid is not None:
        try:
            decoder = json.JSONDecoder()
            header, end = decoder.raw_decode(text.lstrip())
            rest = text.lstrip()[end:].strip()
            body = json.loads(rest) if rest else header
            report_pid = body.get("pid")
        except (ValueError, TypeError, AttributeError):
            match = re.search(r"^Process:\s*.*?\[(\d+)\]\s*$", text, re.M)
            report_pid = int(match.group(1)) if match else None
        if type(report_pid) is not int or report_pid != expected_pid:
            return False
    identity = crash_identity(text)
    if identity is None:
        return False
    bundle, name, crashed, occurred = identity
    return (bundle == bundle_id and name == main_name and crashed
            and float(launched_at_s) < occurred <= time.time())


def stat_is_reg(mode):
    return stat.S_ISREG(mode)


def find_matching_crash(directory, bundle_id, launched_at_s, main_name=MAIN_COMM, expected_pid=None):
    if not directory or not os.path.isdir(directory):
        return None
    try:
        names = sorted(name for name in os.listdir(directory) if name.endswith(CRASH_SUFFIXES))
        if len(names) > 128:
            return None  # bounded read budget; ask owner to review retention
    except OSError:
        return None
    for name in names:
        path = os.path.join(directory, name)
        if crash_report_matches(path, bundle_id, launched_at_s, main_name, expected_pid):
            return name
    return None


def _int_or_none(value):
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def load_prev_codex(state_path):
    if not state_path or not os.path.isfile(state_path):
        return {}
    try:
        with open(state_path) as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    codex = data.get("codex") if isinstance(data, dict) else None
    return codex if isinstance(codex, dict) else {}


def read_rows(ps_file, test_mode):
    if test_mode:
        if not ps_file or not os.path.isfile(ps_file) or os.path.islink(ps_file):
            return None
        try:
            with open(ps_file) as handle:
                return parse_ps_text(handle.read())
        except OSError:
            return None
    return live_rows()


def live_rows():
    # macOS comm is the full executable path. One snapshot avoids joining
    # a main-process row to a later, potentially different command snapshot.
    # No process argv is collected or retained here.
    try:
        snapshot = subprocess.run(
            ["/bin/ps", "-axww", "-o", "pid=,ppid=,etime=,comm="],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if snapshot.returncode != 0 or not snapshot.stdout.strip():
        return None
    rows = []
    for line in snapshot.stdout.splitlines():
        match = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$", line)
        if not match:
            continue
        comm = match.group(4).strip()
        if comm in (MAIN_COMM, "Codex"):
            # An unsupported short-name format cannot prove bundle identity.
            return None
        rows.append({"pid": int(match.group(1)), "ppid": int(match.group(2)),
                     "comm": comm, "exe": comm if comm.startswith("/") else "",
                     "command": ""})
    return rows or None


def _base_result(policy, watched, app_present, bundle_id=BUNDLE_ID):
    return {
        "watched": watched,
        "appPresent": app_present,
        "policy": policy,
        "bundleId": bundle_id,
        "status": "unwatched",
        "running": False,
        "pid": None,
        "launchedAtMs": None,
        "action": "none",
        "readiness": None,
        "lastReopenAtMs": None,
    }


def evaluate(cfg):
    """Return the codex object for last.json. Never opens or signals a process."""
    bundle_id = cfg.get("bundle_id") or BUNDLE_ID
    policy = cfg.get("policy") or "crash_only"
    watch = cfg.get("watch")
    app_path = cfg.get("app_path") or "/Applications/ChatGPT.app"
    app_present = bool(cfg.get("app_present"))
    if watch == "0" or watch == 0:
        result = _base_result(policy if policy in ("crash_only", "any_exit") else "crash_only", False, app_present, bundle_id)
        result["status"] = "unwatched"
        return result
    if watch not in ("", "1", 1, None):
        result = _base_result(policy, False, app_present, bundle_id)
        result["status"] = "watch_invalid"
        result["watched"] = False
        return result
    if not app_present:
        result = _base_result(policy if policy in ("crash_only", "any_exit") else policy, False, False, bundle_id)
        result["status"] = "app_absent"
        result["policy"] = policy if policy in ("crash_only", "any_exit") else "crash_only"
        return result
    if policy not in ("crash_only", "any_exit"):
        result = _base_result(policy, True, True, bundle_id)
        result["status"] = "policy_invalid"
        return result

    if bundle_id not in SUPPORTED_BUNDLES or cfg.get("identity_valid") is False:
        result = _base_result(policy, True, True, bundle_id)
        result.update(status="app_identity_invalid", readiness="app_identity_invalid")
        return result
    # Production never reopens an intentional normal exit. Historical any_exit
    # fixture coverage remains available only under the explicit test harness.
    if policy == "any_exit" and not cfg.get("test_mode"):
        result = _base_result(policy, True, True, bundle_id)
        result.update(status="policy_invalid", readiness="policy_invalid")
        return result

    prev = cfg.get("prev") if isinstance(cfg.get("prev"), dict) else {}
    now_ms = int(cfg["now_ms"])
    rows = cfg.get("rows")
    if rows is None:
        result = _base_result(policy, True, True, bundle_id)
        result.update(status="process_scan_error", readiness="process_scan_error",
                      launchedAtMs=_int_or_none(prev.get("launchedAtMs")))
        return result
    main = find_main(rows, app_path)
    pause = bool(cfg.get("paused"))
    launched = _int_or_none(prev.get("launchedAtMs"))
    if launched is not None and not 0 < launched <= now_ms:
        launched = None
    result = _base_result(policy, True, True, bundle_id)
    result["launchedAtMs"] = launched
    result["lastReopenAtMs"] = _int_or_none(prev.get("lastReopenAtMs"))

    if main is not None:
        result["running"] = True
        result["pid"] = main["pid"]
        result["status"] = "paused" if pause else "up"
        result["readiness"] = "paused" if pause else "up"
        result["action"] = "none"
        if _int_or_none(prev.get("pid")) == main["pid"] and launched is not None:
            result["launchedAtMs"] = launched
        else:
            result["launchedAtMs"] = now_ms
        return result

    result["running"] = False
    result["pid"] = None
    if pause:
        result["status"] = "paused"
        result["readiness"] = "paused"
        result["action"] = "none"
        return result

    if policy == "any_exit":
        result["status"] = "down"
        result["readiness"] = "down"
        result["action"] = "reopen"
        return result

    launched_s = None if launched is None else launched / 1000.0
    report = find_matching_crash(cfg.get("crash_dir") or "", bundle_id, launched_s, os.path.basename(main_executable(app_path)))
    if report:
        result["status"] = "down_crash"
        result["readiness"] = "crash_matched"
        result["action"] = "reopen"
        return result
    result["status"] = "crash_required"
    result["readiness"] = "crash_required"
    result["action"] = "none"
    return result


def wal_fresh(wal_path, opened_ms):
    """Optional readiness signal. Missing file is not a failure. A stale file is."""
    if not wal_path:
        return True
    if os.path.islink(wal_path):
        return False
    if not os.path.isfile(wal_path):
        return True
    try:
        return os.path.getmtime(wal_path) >= (opened_ms / 1000.0) - 1.0
    except OSError:
        return False


def apply_probe(current, rows, app_path, opened_ms, wal_path):
    """Update current after an open attempt. Returns (ready, object)."""
    data = dict(current)
    if rows is None:
        data.update(status="reopen_incomplete", readiness="process_scan_error")
        return False, data
    main = find_main(rows, app_path)
    data["action"] = "reopen"
    data["lastReopenAtMs"] = int(opened_ms)
    if main is None:
        data["running"] = False
        data["pid"] = None
        data["status"] = "reopen_incomplete"
        data["readiness"] = "process_down"
        return False, data
    if not wal_fresh(wal_path, opened_ms):
        data["running"] = True
        data["pid"] = main["pid"]
        data["status"] = "reopen_incomplete"
        data["readiness"] = "wal_stale"
        data["launchedAtMs"] = int(opened_ms)
        return False, data
    data["running"] = True
    data["pid"] = main["pid"]
    data["status"] = "reopened"
    data["readiness"] = "process_up"
    data["launchedAtMs"] = int(opened_ms)
    return True, data


def _env_now_ms():
    raw = os.environ.get("HEAL_NOW_MS", "")
    if raw.strip():
        return int(raw)
    return int(time.time() * 1000)


def bundle_identity_valid(app_path, bundle_id):
    try:
        with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        return (bundle_id in SUPPORTED_BUNDLES
                and info.get("CFBundleIdentifier") == bundle_id
                and info.get("CFBundleExecutable") in (("ChatGPT", "Codex") if bundle_id == BUNDLE_ID else ("ChatGPT",)))
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def collect_cfg():
    app_path = os.environ.get("CODEX_APP_PATH") or "/Applications/ChatGPT.app"
    watch = os.environ.get("CODEX_WATCH", "")
    policy = os.environ.get("CODEX_REOPEN_POLICY") or "crash_only"
    test_mode = os.environ.get("HEAL_TEST_MODE") == "1"
    pause_path = os.environ.get("CODEX_PAUSE") or ""
    paused = bool(pause_path) and os.path.lexists(pause_path)
    prev = load_prev_codex(os.environ.get("HEAL_STATE") or "")
    app_present = os.path.isdir(app_path)
    rows = []
    if watch != "0" and app_present:
        rows = read_rows(os.environ.get("CODEX_PS_FILE") or "", test_mode)
    bundle_id = os.environ.get("CODEX_BUNDLE_ID") or BUNDLE_ID
    return {
        "bundle_id": bundle_id,
        "identity_valid": test_mode or bundle_identity_valid(app_path, bundle_id),
        "test_mode": test_mode,
        "policy": policy,
        "watch": watch,
        "app_path": app_path,
        "app_present": app_present,
        "paused": paused,
        "prev": prev,
        "now_ms": _env_now_ms(),
        "rows": rows,
        "crash_dir": os.environ.get("CODEX_CRASH_DIR") or "",
    }


def write_result(path, obj):
    with open(path, "w") as handle:
        json.dump(obj, handle)
        handle.write("\n")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) == 4 and argv[0] == "grok-crash":
        try:
            since, pid = int(argv[2]), int(argv[3])
            if since <= 0 or pid <= 0:
                return 1
            return 0 if find_matching_crash(argv[1], "com.anysphere.sand", since / 1000.0, "Grok Bot", pid) else 1
        except (ValueError, OSError):
            return 1
    if len(argv) < 2:
        print("usage: codex-watch.py decide|probe LATCH_DIR OUT [OPENED_MS]", file=sys.stderr)
        return 2
    command = argv[0]
    out_path = argv[2] if len(argv) > 2 else ""
    if command == "decide":
        if not out_path:
            return 2
        write_result(out_path, evaluate(collect_cfg()))
        return 0
    if command == "probe":
        if len(argv) < 4:
            return 2
        opened_ms = int(argv[3])
        try:
            with open(out_path) as handle:
                current = json.load(handle)
        except (OSError, ValueError):
            current = {}
        if not isinstance(current, dict):
            current = {}
        test_mode = os.environ.get("HEAL_TEST_MODE") == "1"
        app_path = os.environ.get("CODEX_APP_PATH") or "/Applications/ChatGPT.app"
        rows = read_rows(os.environ.get("CODEX_PS_FILE") or "", test_mode)
        wal = os.environ.get("CODEX_WAL_FILE") or ""
        ready, obj = apply_probe(current, rows, app_path, opened_ms, wal)
        write_result(out_path, obj)
        return 0 if ready else 1
    print("unknown command", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
