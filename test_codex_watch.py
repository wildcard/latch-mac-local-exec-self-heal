"""Codex keep-alive decision tests. No live app, no open, no kill."""
import importlib.util
from pathlib import Path
import json
import os
import tempfile
import time
import unittest


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
                "bundleID": "com.openai.codex",
                "procName": "Codex (Renderer)",
            }))
            other = Path(directory) / "classic.ips"
            other.write_text(json.dumps({
                "app_name": "ChatGPT Classic",
                "bug_type": "309",
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
