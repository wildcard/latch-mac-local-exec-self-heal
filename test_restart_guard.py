import importlib.util
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
import io


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

    def test_continuity_gate_requires_two_valid_active_samples(self):
        previous = {"v": 2, "clockSource": "posix_monotonic", "wall": 1000, "monotonic": 500, "mode": "active"}
        self.assertEqual(guard.observation_status(1060, 560, previous, "active", "posix_monotonic"), "continuous")
        for now, uptime, prev, mode in (
            (1060,560,None,"active"), (1060,560,previous,"observe"),
            (1600,560,previous,"active"), (1060,501,previous,"active"),
            (999,560,previous,"active"), (1060,10,previous,"active"),
            (1060,560,{**previous,"wall":float("nan")},"active"),
            (1060,560,{**previous,"mode":"observe"},"active")):
            self.assertEqual(guard.observation_status(now, uptime, prev, mode, "posix_monotonic"), "observation_required")

    def test_clock_domains_and_legacy_samples_require_new_observation(self):
        previous = {"v": 2, "clockSource": "posix_monotonic", "wall": 1000,
                    "monotonic": 500, "mode": "active"}
        for sample, source in (({k:v for k,v in previous.items() if k not in ("v","clockSource")}, "posix_monotonic"),
                               (previous, "darwin_uptime_raw"), (previous, "unknown")):
            self.assertEqual(guard.observation_status(1060,560,sample,"active",source),"observation_required")

    def test_darwin_uses_system_uptime_and_never_process_monotonic(self):
        with patch.object(guard.sys,"platform","darwin"), \
             patch.object(guard.time,"CLOCK_UPTIME_RAW",123,create=True), \
             patch.object(guard.time,"clock_gettime",return_value=5000) as read, \
             patch.object(guard.time,"monotonic") as relative:
            self.assertEqual(guard.observation_clock(),(5000,"darwin_uptime_raw"))
            read.assert_called_once_with(123)
            relative.assert_not_called()

    def test_failed_system_clock_does_not_fallback_or_rewrite_state(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"grok-bot-observation-clock.json"
            path.write_text("{}");path.chmod(0o600)
            output=io.StringIO()
            with patch.object(guard.time,"clock_gettime",side_effect=OSError), \
                 patch.object(guard.time,"monotonic") as relative, redirect_stdout(output):
                guard.observe(directory)
            self.assertEqual(output.getvalue().strip(),"observation_error")
            relative.assert_not_called()
            self.assertEqual(path.read_text(),"{}")

    def test_separate_interpreters_share_clock_and_allow_elapsed_minute(self):
        # Real OS clock sampling, no app operations. Seed one synthetic earlier
        # sample with the system-wide clock from a different interpreter.
        code = ("import importlib.util,json,time; "
                "s=importlib.util.spec_from_file_location('g',"+repr(str(GUARD_PATH))+"); "
                "g=importlib.util.module_from_spec(s);s.loader.exec_module(g); "
                "v,k=g.observation_clock(); print(json.dumps({'v':2,'clockSource':k,"
                "'wall':time.time()-60,'monotonic':v-60,'mode':'active'}))")
        with tempfile.TemporaryDirectory() as directory:
            sample=subprocess.run([sys.executable,"-c",code],capture_output=True,text=True,check=True)
            path=Path(directory)/"grok-bot-observation-clock.json"
            path.write_text(sample.stdout);path.chmod(0o600)
            result=subprocess.run([sys.executable,str(GUARD_PATH),"--observe",directory],
                                  env={**os.environ,"RECOVERY_MODE":"active"},capture_output=True,text=True,check=True)
            self.assertEqual(result.stdout.strip(),"continuous")
            self.assertFalse((Path(directory)/"grok-bot-restart-attempts.json").exists())

    def test_legacy_clock_migrates_once_without_budget_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"grok-bot-observation-clock.json"
            path.write_text(json.dumps({'wall':time.time()-60,'monotonic':0.01,'mode':'active'}));path.chmod(0o600)
            def observe():
                return subprocess.run([sys.executable,str(GUARD_PATH),"--observe",directory],
                    env={**os.environ,"RECOVERY_MODE":"active"},capture_output=True,text=True,check=True).stdout.strip()
            self.assertEqual(observe(),"observation_required")
            self.assertEqual(json.loads(path.read_text())['v'],2)
            self.assertEqual(observe(),"continuous")
            self.assertFalse((Path(directory)/"grok-bot-restart-attempts.json").exists())

    def test_observation_clock_fails_closed_without_rewriting_unsafe_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "grok-bot-observation-clock.json"
            path.write_text("{}")
            path.chmod(0o644)
            proc = subprocess.run([sys.executable,str(GUARD_PATH),"--observe",directory],capture_output=True,text=True)
            self.assertEqual(proc.stdout.strip(), "observation_error")
            self.assertEqual(path.read_text(), "{}")

    def test_owned_0600_legacy_attempts_remain_capped_without_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "grok-bot-restart-attempts.json"
            now = time.time()
            path.write_text(json.dumps({"attempts": [now - 60, now - 50, now - 40]}))
            path.chmod(0o600)
            before = path.read_bytes()
            result = run_guard(directory, 42, reason="process_down")
            self.assertEqual(result.stdout.strip(), "circuit_open")
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

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
                "HEAL_TEST_MODE": "1", "HEAL_DRY_RUN": "1", "RECOVERY_MODE": "active", "HEAL_TEST_CONTINUOUS": "1",
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
