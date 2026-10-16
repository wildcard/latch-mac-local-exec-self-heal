"""Codex keep-alive decision tests. No live app, no open, no kill."""
import importlib.util
from pathlib import Path
import json
import os
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("codex_watch", ROOT / "codex-watch.py")
codex = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codex)

APP = "/Applications/ChatGPT.app"
EXE = APP + "/Contents/MacOS/ChatGPT"


def row(pid, comm, exe, ppid=1):
    return {"pid": pid, "ppid": ppid, "comm": comm, "exe": exe, "command": exe}


def cfg(**kwargs):
    base = {
        "policy": "crash_only",
        "watch": "1",
        "app_path": APP,
        "app_present": True,
        "paused": False,
        "prev": {"pid": 9000, "launchedAtMs": 1_000_000, "running": True},
        "now_ms": 2_000_000,
        "rows": [],
        "crash_dir": "",
    }
    base.update(kwargs)
    return base


class MatchTests(unittest.TestCase):
    def test_main_process_matches_bundle_path(self):
        self.assertTrue(codex.is_main_process(row(9000, "ChatGPT", EXE), APP))

    def test_macos_full_path_comm_is_recognized(self):
        rows = codex.parse_ps_text("9000 1 10:00 " + EXE + "\t" + EXE + "\n")
        self.assertEqual(codex.evaluate(cfg(rows=rows))["status"], "up")
        self.assertFalse(codex.is_main_process(row(9, EXE + " Helper", EXE), APP))

    def test_failed_process_scan_never_authorizes_a_reopen(self):
        for policy in ("crash_only", "any_exit"):
            result = codex.evaluate(cfg(rows=None, policy=policy))
            self.assertEqual(result["status"], "process_scan_error")
            self.assertEqual(result["action"], "none")
        with patch.object(codex.subprocess, "run", side_effect=OSError):
            self.assertIsNone(codex.live_rows())
        for response in (SimpleNamespace(returncode=1, stdout=""),
                         SimpleNamespace(returncode=0, stdout="")):
            with patch.object(codex.subprocess, "run", return_value=response):
                self.assertIsNone(codex.live_rows())
        with tempfile.TemporaryDirectory() as directory:
            empty = Path(directory) / "empty.ps"
            self.assertIsNone(codex.read_rows(str(empty), True))
            empty.write_text("")
            self.assertEqual(codex.read_rows(str(empty), True), [])
        ready, result = codex.apply_probe({}, None, APP, 5000, "")
        self.assertFalse(ready)
        self.assertEqual(result["readiness"], "process_scan_error")

    def test_primary_identity_and_event_time_required(self):
        header = {"app_name": "ChatGPT", "bug_type": "309", "bundleID": "com.openai.codex",
                  "timestamp": "1970-01-01T00:30:00+00:00"}
        body = {"procName": "ChatGPT", "bundleInfo": {"CFBundleIdentifier": "com.openai.codex"}}
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "main.ips"
            def matches(h, b):
                report.write_text(json.dumps(h) + "\n" + json.dumps(b))
                os.utime(report, (2000, 2000))
                return codex.crash_report_matches(str(report), "com.openai.codex", 1000)
            self.assertTrue(matches(header, body))
            self.assertTrue(matches(header, {**body, "threads": "x" * 100000}))
            report.write_text(json.dumps(header))
            for launched in (-1, 3_000_000, True, "1000"):
                result = codex.evaluate(cfg(prev={"launchedAtMs": launched}, crash_dir=directory))
                self.assertEqual(result["action"], "none")
            self.assertFalse(matches({**header, "timestamp": "1970-01-01T00:01:00+00:00"}, body))
            self.assertFalse(matches({**header, "timestamp": "2999-01-01T00:00:00+00:00"}, body))
            self.assertFalse(matches({k: v for k, v in header.items() if k != "timestamp"}, body))
            self.assertFalse(matches(header, {**body, "bundleInfo": {"CFBundleIdentifier": "com.openai.chat"},
                                                   "loadedImages": ["com.openai.codex"]}))
            self.assertFalse(matches(header, {**body, "procName": "Codex (Renderer)"}))
            report.write_text("Process: ChatGPT [1]\nIdentifier: com.openai.codex\n"
                              "Date/Time: 1970-01-01 00:30:00.000 +0000\nCrashed Thread: 0\n")
            self.assertTrue(codex.crash_report_matches(str(report), "com.openai.codex", 1000))

    def test_shell_uses_default_state_path_for_previous_launch(self):
        # No HEAL_STATE export: this is how the production plist invokes the kit.
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            latch = base / "Library/Application Support/Latch"
            logs = base / "Library/Logs"
            (latch / "bin").mkdir(parents=True)
            logs.mkdir(parents=True)
            for name in ("codex-watch.py", "grok-bot-restart-guard.py"):
                (latch / "bin" / name).write_text((ROOT / name).read_text())
            app = base / "app"
            app.mkdir()
            ps = base / "ps"
            ps.write_text("")
            crash = base / "crashes"
            crash.mkdir()
            (crash / "main.ips").write_text(json.dumps({
                "app_name": "ChatGPT", "procName": "ChatGPT", "bug_type": "309",
                "bundleID": "com.openai.codex", "timestamp": "2026-01-01T00:00:00+00:00"}))
            state = logs / "GrokBotLocalExecHeal-last.json"
            state.write_text(json.dumps({"codex": {"pid": 9000, "launchedAtMs": 1000}}))
            env = {"PATH": os.environ["PATH"], "HOME": str(base), "HEAL_TEST_MODE": "1",
                   "HEAL_DRY_RUN": "1", "CODEX_APP_PATH": str(app), "CODEX_PS_FILE": str(ps),
                   "CODEX_CRASH_DIR": str(crash), "CODEX_READINESS_WAIT_SEC": "1",
                   "GROK_APP_PATH": str(base / "absent"), "PYTHON": codex.sys.executable}
            codex.subprocess.run(["/bin/bash", str(ROOT / "grok-bot-local-exec-heal.sh")],
                                 env=env, check=True, capture_output=True)
            result = json.loads(state.read_text())["codex"]
            self.assertEqual(result["action"], "reopen")
            self.assertEqual(result["status"], "reopen_incomplete")

    def test_helpers_and_other_apps_do_not_match(self):
        samples = [
            row(1, "Codex (Service)", APP + "/Contents/Frameworks/Codex (Service)"),
            row(2, "Codex (Renderer)", APP + "/Contents/Frameworks/Codex (Renderer)"),
            row(3, "codex", "/usr/local/bin/codex"),
            row(4, "node", "/usr/local/bin/node"),
            row(5, "ChatGPT Classic", "/Applications/ChatGPT Classic.app/Contents/MacOS/ChatGPT Classic"),
            row(6, "ChatGPT", "/Applications/ChatGPT.localized/Contents/MacOS/ChatGPT"),
            row(7, "ChatGPT", APP + "/Contents/Frameworks/ChatGPT"),
        ]
        for sample in samples:
            self.assertFalse(codex.is_main_process(sample, APP), sample["comm"])

    def test_running_main_is_a_noop_even_with_a_crash_report(self):
        result = codex.evaluate(cfg(rows=[row(9000, "ChatGPT", EXE)]))
        self.assertEqual(result["action"], "none")
        self.assertEqual(result["status"], "up")
        self.assertTrue(result["running"])
        self.assertEqual(result["pid"], 9000)

    def test_absent_app_is_a_noop(self):
        result = codex.evaluate(cfg(app_present=False, watch=""))
        self.assertEqual(result["status"], "app_absent")
        self.assertEqual(result["action"], "none")
        self.assertFalse(result["watched"])

    def test_watch_off(self):
        result = codex.evaluate(cfg(watch="0", rows=[]))
        self.assertEqual(result["status"], "unwatched")
        self.assertEqual(result["action"], "none")

    def test_pause_blocks_reopen(self):
        result = codex.evaluate(cfg(paused=True, policy="any_exit"))
        self.assertEqual(result["status"], "paused")
        self.assertEqual(result["action"], "none")

    def test_crash_only_without_report_does_not_reopen(self):
        result = codex.evaluate(cfg())
        self.assertEqual(result["status"], "crash_required")
        self.assertEqual(result["action"], "none")

    def test_crash_only_with_matching_report_reopens(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "ChatGPT.ips"
            report.write_text(json.dumps({
                "app_name": "ChatGPT",
                "bug_type": "309",
                "timestamp": "1970-01-01T00:30:00+00:00",
                "bundleID": "com.openai.codex",
                "procName": "ChatGPT",
            }))
            os.utime(report, (2_000, 2_000))
            result = codex.evaluate(cfg(crash_dir=directory))
            self.assertEqual(result["action"], "reopen")
            self.assertEqual(result["status"], "down_crash")

    def test_helper_old_and_other_bundle_reports_do_not_match(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "helper.ips"
            helper.write_text(json.dumps({
                "app_name": "Codex (Renderer)",
                "bug_type": "309",
                "timestamp": "1970-01-01T00:30:00+00:00",
                "bundleID": "com.openai.codex",
                "procName": "Codex (Renderer)",
            }))
            other = Path(directory) / "classic.ips"
            other.write_text(json.dumps({
                "app_name": "ChatGPT Classic",
                "bug_type": "309",
                "timestamp": "1970-01-01T00:30:00+00:00",
                "bundleID": "com.openai.chat",
                "procName": "ChatGPT Classic",
            }))
            disk = Path(directory) / "disk.ips"
            disk.write_text(json.dumps({
                "app_name": "ChatGPT",
                "bug_type": "327",
                "bundleID": "com.openai.codex",
                "procName": "ChatGPT",
                "action": "none",
            }))
            old = Path(directory) / "old.crash"
            old.write_text('Process: ChatGPT [1]\nCrashed Thread: 0\nbundle com.openai.codex\n')
            os.utime(old, (1, 1))
            for path in (helper, other, disk, old):
                self.assertFalse(
                    codex.crash_report_matches(str(path), "com.openai.codex", 1.5),
                    path.name,
                )

    def test_report_without_a_prior_launch_does_not_reopen(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "ChatGPT.ips"
            report.write_text(json.dumps({
                "procName": "ChatGPT",
                "bug_type": "309",
                "timestamp": "1970-01-01T00:30:00+00:00",
                "bundleID": "com.openai.codex",
            }))
            os.utime(report, (2_000, 2_000))
            result = codex.evaluate(cfg(prev={}, crash_dir=directory))
            self.assertEqual(result["action"], "none")
            self.assertEqual(result["status"], "crash_required")

    def test_any_exit_reopens_without_a_report(self):
        result = codex.evaluate(cfg(policy="any_exit", prev={}))
        self.assertEqual(result["action"], "reopen")
        self.assertEqual(result["status"], "down")

    def test_probe_ready_on_process_up_and_optional_wal(self):
        current = {"action": "reopen", "status": "down"}
        ready, obj = codex.apply_probe(
            current,
            [row(9100, "ChatGPT", EXE)],
            APP,
            5_000,
            "",
        )
        self.assertTrue(ready)
        self.assertEqual(obj["status"], "reopened")
        self.assertEqual(obj["pid"], 9100)
        with tempfile.TemporaryDirectory() as directory:
            wal = Path(directory) / "logs_2.sqlite-wal"
            wal.write_text("")
            os.utime(wal, (1, 1))
            ready, obj = codex.apply_probe(current, [row(9100, "ChatGPT", EXE)], APP, 5_000, str(wal))
            self.assertFalse(ready)
            self.assertEqual(obj["readiness"], "wal_stale")
            os.utime(wal, (time.time(), time.time()))
            ready, obj = codex.apply_probe(current, [row(9100, "ChatGPT", EXE)], APP, 5_000, str(wal))
            self.assertTrue(ready)


if __name__ == "__main__":
    unittest.main()
