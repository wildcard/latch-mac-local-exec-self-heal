import importlib.util
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent
GUARD_PATH = ROOT / "grok-bot-restart-guard.py"
HEAL_PATH = ROOT / "grok-bot-local-exec-heal.sh"

spec = importlib.util.spec_from_file_location("guard", GUARD_PATH)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def run_guard(directory, pid, reason="helper_missing", key="grok", env=None):
    command = [sys.executable, str(GUARD_PATH), directory, str(pid), reason, key]
    return subprocess.run(command, text=True, capture_output=True, env=env, check=False)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.lease = {"issuedAt": 990, "expiresAt": 1200, "pid": 42, "idleConfirmed": True}

    def test_active_work_is_held_even_with_valid_idle_file(self):
        self.assertEqual(guard.decision(1000, 42, self.lease, [], held=True), "maintenance_hold")

    def test_missing_authorization_denied(self):
        self.assertEqual(guard.decision(1000, 42, None, []), "idle_authorization_required")

    def test_established_recovery_paths_keep_working_with_rate_limit(self):
        self.assertEqual(guard.decision(1000, 42, None, [], idle_required=False), "allow")
        self.assertEqual(guard.decision(1000, 42, None, [900], idle_required=False), "retry_backoff")

    def test_current_idle_process_allowed(self):
        self.assertEqual(guard.decision(1000, 42, self.lease, []), "allow")

    def test_changed_process_denied(self):
        self.assertEqual(guard.decision(1000, 43, self.lease, []), "idle_authorization_pid_changed")

    def test_expired_or_excessive_window_denied(self):
        self.assertNotEqual(guard.decision(1200, 42, self.lease, []), "allow")
        self.lease["expiresAt"] = 3000
        self.assertNotEqual(guard.decision(1000, 42, self.lease, []), "allow")

    def test_backoff_and_hard_limit(self):
        self.assertEqual(guard.decision(1000, 42, self.lease, [900]), "retry_backoff")
        self.assertEqual(guard.decision(1000, 42, self.lease, [300, 700]), "retry_backoff")
        self.assertEqual(guard.decision(1000, 42, self.lease, [100, 500, 900]), "circuit_open")
        self.assertEqual(
            guard.decision(
                5000,
                42,
                {"issuedAt": 4990, "expiresAt": 5200, "pid": 42, "idleConfirmed": True},
                [100, 500, 900],
            ),
            "allow",
        )

    def test_malformed_ledger_elements_raise(self):
        samples = [
            None,
            True,
            False,
            "100",
            "900",
            float("nan"),
            float("inf"),
            float("-inf"),
            -1,
            1001,
            {"n": 1},
            [1],
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                with self.assertRaises(ValueError):
                    guard.decision(1000, 42, self.lease, [900, sample], idle_required=False)

    def test_old_timestamp_is_outside_the_hour_and_still_valid(self):
        self.assertEqual(guard.decision(5000, 42, None, [100], idle_required=False), "allow")

    def test_file_gate_consumes_once_and_refuses_unsafe_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            lease = base / "grok-bot-restart-idle.json"
            now = time.time()
            lease.write_text(json.dumps({
                "issuedAt": now - 1,
                "expiresAt": now + 60,
                "pid": 42,
                "idleConfirmed": True,
            }))
            lease.chmod(0o644)
            command_env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
            # Policy (a): the idle file is not consulted, so a loose lease does not block.
            first = run_guard(directory, 42, env=command_env)
            self.assertEqual(first.stdout.strip(), "allow", first.stderr)
            attempts = base / "grok-bot-restart-attempts.json"
            self.assertTrue(attempts.exists())
            self.assertTrue(lease.exists())
            attempts.unlink()
            # An unsafe ledger still fails closed under the default.
            attempts.write_text('{"v": 2, "attempts": {"grok": []}}\n')
            attempts.chmod(0o644)
            unsafe = run_guard(directory, 42, env=command_env)
            self.assertEqual(unsafe.stdout.strip(), "restart_guard_error")
            attempts.unlink()
            # Idle opt-in: loose lease refuses, a private lease is one use, then backoff.
            idle_env = dict(os.environ)
            idle_env["HELPER_IDLE_REQUIRED"] = "1"
            loose = run_guard(directory, 42, env=idle_env)
            self.assertEqual(loose.stdout.strip(), "restart_guard_error")
            lease.chmod(0o600)
            allowed = run_guard(directory, 42, env=idle_env)
            self.assertEqual(allowed.stdout.strip(), "allow")
            self.assertFalse(lease.exists())
            again = run_guard(directory, 42, env=idle_env)
            self.assertEqual(again.stdout.strip(), "retry_backoff")

    def test_policy_a_helper_loss_allowed_without_idle_file_but_rate_limited(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
            first = run_guard(directory, 42, env=env)
            self.assertEqual(first.stdout.strip(), "allow")
            self.assertTrue((Path(directory) / "grok-bot-restart-attempts.json").exists())
            second = run_guard(directory, 42, env=env)
            self.assertEqual(second.stdout.strip(), "retry_backoff")

    def test_policy_a_maintenance_hold_still_wins(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "grok-bot-restart.hold").write_text("hold")
            env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
            proc = run_guard(directory, 42, env=env)
            self.assertEqual(proc.stdout.strip(), "maintenance_hold")

    def test_each_bad_element_fails_closed_and_does_not_rewrite(self):
        now = time.time()
        samples = {
            "null": None,
            "bool": True,
            "string": "100",
            "nan": float("nan"),
            "inf": float("inf"),
            "negative": -5,
            "future": now + 100,
        }
        for name, sample in samples.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "grok-bot-restart-attempts.json"
                    payload = {"v": 2, "attempts": {"grok": [now - 10, sample]}}
                    path.write_text(json.dumps(payload))
                    path.chmod(0o600)
                    before = path.read_text()
                    env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
                    proc = run_guard(directory, 42, reason="process_down", env=env)
                    self.assertEqual(proc.stdout.strip(), "restart_guard_error", name)
                    self.assertEqual(path.read_text(), before)

    def test_existing_ledger_without_attempts_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "grok-bot-restart-attempts.json"
            for payload in ('{"v": 2}\n', 'null\n'):
                path.write_text(payload)
                path.chmod(0o600)
                before = path.read_bytes()
                proc = run_guard(directory, 42, reason="process_down")
                self.assertEqual(proc.stdout.strip(), "restart_guard_error")
                self.assertEqual(path.read_bytes(), before)

    def test_symlink_ledger_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            real = base / "real.json"
            real.write_text('{"v": 2, "attempts": {"grok": []}}\n')
            real.chmod(0o600)
            os.symlink(real, base / "grok-bot-restart-attempts.json")
            env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
            proc = run_guard(directory, 42, reason="process_down", env=env)
            self.assertEqual(proc.stdout.strip(), "restart_guard_error")

    def test_codex_key_has_its_own_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            now = time.time()
            path = Path(directory) / "grok-bot-restart-attempts.json"
            path.write_text(json.dumps({"v": 2, "attempts": {"grok": [now - 10, now - 20, now - 30]}}))
            path.chmod(0o600)
            env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
            grok = run_guard(directory, 42, reason="process_down", key="grok", env=env)
            self.assertEqual(grok.stdout.strip(), "circuit_open")
            codex = run_guard(directory, 0, reason="codex_reopen", key="codex", env=env)
            self.assertEqual(codex.stdout.strip(), "allow")
            stored = json.loads(path.read_text())
            self.assertEqual(len(stored["attempts"]["grok"]), 3)
            self.assertEqual(len(stored["attempts"]["codex"]), 1)

    def test_legacy_flat_list_is_the_grok_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "grok-bot-restart-attempts.json"
            path.write_text('{"attempts": []}\n')
            path.chmod(0o600)
            env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
            proc = run_guard(directory, 42, env=env)
            self.assertEqual(proc.stdout.strip(), "allow")
            stored = json.loads(path.read_text())
            self.assertEqual(stored["v"], 2)
            self.assertEqual(len(stored["attempts"]["grok"]), 1)

    def test_circuit_open_after_three_in_the_hour(self):
        with tempfile.TemporaryDirectory() as directory:
            now = time.time()
            path = Path(directory) / "grok-bot-restart-attempts.json"
            path.write_text(json.dumps({"v": 2, "attempts": {"grok": [now - 30, now - 20, now - 10]}}))
            path.chmod(0o600)
            env = {k: v for k, v in os.environ.items() if k != "HELPER_IDLE_REQUIRED"}
            proc = run_guard(directory, 42, reason="heartbeat_stale", env=env)
            self.assertEqual(proc.stdout.strip(), "circuit_open")

    def test_watchdog_dry_run_blocks_before_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            support = base / "support"
            sessions = support / "dune-reliability/sessions"
            sessions.mkdir(parents=True)
            (base / "bin").mkdir()
            (base / "app").mkdir()
            (base / "bin" / "grok-bot-restart-guard.py").write_text(GUARD_PATH.read_text())
            now = int(time.time() * 1000)
            (support / "desktop-status.json").write_text(json.dumps({"pid": 42}))
            (sessions / "fixture.running.json").write_text(json.dumps({
                "pid": 42, "heartbeatAtMs": now, "bootOutcome": "ready",
            }))
            (base / "grok-bot-local-exec-heal.request").touch()
            (base / "grok-bot-restart.hold").touch()
            env = {
                **os.environ,
                "LATCH_DIR": str(base),
                "GROK_SUPPORT_DIR": str(support),
                "GROK_APP_PATH": str(base / "app"),
                "HEAL_LOG": str(base / "heal.log"),
                "HEAL_STATE": str(base / "state.json"),
                "PYTHON": sys.executable,
                "HEAL_DRY_RUN": "1",
                "HEAL_TRUST_PID": "1",
                "HEAL_DISABLE_PGREP": "1",
                "HELPER_CHECK": "0",
                "CODEX_WATCH": "0",
                "BEACON_URL": "",
                "BEACON_MACHINE_ID": "",
                "BEACON_POLL_TOKEN_FILE": "",
                "BEACON_POLL_TOKEN": "",
            }
            subprocess.run(["bash", str(HEAL_PATH)], env=env, check=True, capture_output=True)
            state = json.loads((base / "state.json").read_text())
            self.assertEqual(state["status"], "restart_blocked")
            self.assertEqual(state["readiness"], "maintenance_hold")
            self.assertEqual(state["action"], "none")
            self.assertTrue((base / "grok-bot-local-exec-heal.request").exists())
            self.assertNotIn("heal start", (base / "heal.log").read_text())
            (base / "grok-bot-local-exec-heal.request").unlink()
            state.update(
                pid=42,
                helperBaselinePid=42,
                helperBaseline=2,
                helperExpected=2,
                helperMissingSinceMs=now - 400000,
            )
            (base / "state.json").write_text(json.dumps(state))
            fixture = base / "ps.txt"
            fixture.write_text(
                "42 1 10:00 Grok Bot\t%s/app/Contents/MacOS/Grok Bot\n"
                "43 42 10:00 Grok Bot Helper\t%s/app/Contents/Frameworks/Grok Bot Helper.app/Contents/MacOS/Grok Bot Helper --type=utility --utility-sub-type=node.mojom.NodeService\n"
                % (base, base)
            )
            env.update(
                HELPER_CHECK="1",
                HEAL_ON_HELPER_MISSING="1",
                HELPER_EXPECTED="2",
                HELPER_SOCKET_CHECK="0",
                HEAL_TEST_MODE="1",
                HELPER_PS_FILE=str(fixture),
            )
            subprocess.run(["bash", str(HEAL_PATH)], env=env, check=True, capture_output=True)
            state = json.loads((base / "state.json").read_text())
            self.assertEqual(state["reason"], "helper_missing")
            self.assertEqual(state["status"], "restart_blocked")
            self.assertEqual(state["helperCount"], 1)
            self.assertEqual(state["helperExpected"], 2)
            self.assertNotIn("heal start", (base / "heal.log").read_text())


if __name__ == "__main__":
    unittest.main()
