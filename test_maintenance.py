"""Private candidate and supported app-boundary regressions; no live operations."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('watch', ROOT / 'codex-watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


class MaintenanceTests(unittest.TestCase):
    def test_production_any_exit_rejected(self):
        result = watch.evaluate({'policy': 'any_exit', 'watch': '1', 'app_present': True})
        self.assertEqual(result['status'], 'policy_invalid')
        self.assertEqual(result['action'], 'none')

    def test_chatgpt_identity_and_wrong_bundle_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'ChatGPT.app'
            (app / 'Contents').mkdir(parents=True)
            info = app / 'Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.openai.chat', 'CFBundleExecutable': 'ChatGPT'}))
            self.assertTrue(watch.bundle_identity_valid(str(app), 'com.openai.chat'))
            self.assertFalse(watch.bundle_identity_valid(str(app), 'com.openai.codex'))
            for bundle in ('invalid.bundle', 'com.openai.chat'):
                result = watch.evaluate({'bundle_id': bundle, 'watch': '1', 'app_present': True,
                                         'identity_valid': False, 'rows': []})
                self.assertEqual(result['status'], 'app_identity_invalid')
                self.assertEqual(result['action'], 'none')

    def test_chatgpt_crash_matches_selected_bundle_only(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'main.ips'
            report.write_text(json.dumps({'app_name': 'ChatGPT', 'procName': 'ChatGPT',
                'bundleID': 'com.openai.chat', 'bug_type': '309', 'timestamp': '2026-01-01T00:00:00Z'}))
            cfg = {'watch': '1', 'app_present': True, 'bundle_id': 'com.openai.chat',
                   'prev': {'launchedAtMs': 1000}, 'now_ms': 2000000000000,
                   'rows': [], 'crash_dir': directory}
            self.assertEqual(watch.evaluate(cfg)['status'], 'down_crash')
            cfg['bundle_id'] = 'com.openai.codex'
            self.assertEqual(watch.evaluate(cfg)['action'], 'none')

    def test_crash_directory_read_budget(self):
        with patch.object(watch.os.path, 'isdir', return_value=True), \
             patch.object(watch.os, 'listdir', return_value=[str(n)+'.ips' for n in range(129)]), \
             patch.object(watch, 'crash_report_matches') as read:
            self.assertIsNone(watch.find_matching_crash('unused', watch.BUNDLE_ID, 1))
            read.assert_not_called()

    def test_prepare_does_not_write_installed_files_and_check_detects_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            agent = home / 'Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist'
            agent.parent.mkdir(parents=True)
            old = plistlib.dumps({'EnvironmentVariables': {'CUSTOM': 'private-fixture', 'CODEX_WATCH': '0'}})
            agent.write_bytes(old)
            plan = home / 'plan'
            env = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
            command = [sys.executable, str(ROOT / 'prepare-install.py'), str(plan)]
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('private-fixture', result.stdout)
            self.assertEqual(agent.read_bytes(), old)
            self.assertFalse((home / 'Library/Application Support/Latch/bin').exists())
            candidate = plan / 'candidate' / agent.name
            data = plistlib.loads(candidate.read_bytes())
            policy = data['EnvironmentVariables']
            self.assertEqual(policy['RECOVERY_MODE'], 'active')
            self.assertEqual(policy['HELPER_IDLE_REQUIRED'], '1')
            self.assertEqual(policy['CODEX_WATCH'], '1')
            self.assertEqual(policy['CODEX_REOPEN_POLICY'], 'crash_only')
            self.assertEqual(policy['CUSTOM'], 'private-fixture')
            self.assertIn(str(home), data['ProgramArguments'][1])
            self.assertNotIn('/plan/', data['ProgramArguments'][1])
            self.assertEqual(candidate.stat().st_mode & 0o777, 0o600)
            check = subprocess.run(command+['--check'], env=env, capture_output=True)
            self.assertEqual(check.returncode, 0)
            agent.write_bytes(old+b'\n')
            self.assertNotEqual(subprocess.run(command+['--check'],env=env,capture_output=True).returncode,0)

    def test_bad_existing_plist_never_replaces_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            agent = home / 'Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist'
            agent.parent.mkdir(parents=True)
            agent.write_text('invalid plist')
            target = home / 'Library/Application Support/Latch/bin/grok-bot-local-exec-heal.sh'
            target.parent.mkdir(parents=True)
            target.write_text('prior-executable')
            env = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                   'PYTHON': sys.executable, 'INSTALL_SKIP_LAUNCHD': '1'}
            result = subprocess.run(['/bin/bash',str(ROOT/'install.sh')],env=env,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(target.read_text(),'prior-executable')
            self.assertEqual(agent.read_text(),'invalid plist')

    def test_modern_codex_executable_from_verified_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Codex.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.openai.codex', 'CFBundleExecutable': 'Codex'}))
            self.assertTrue(watch.bundle_identity_valid(str(app), 'com.openai.codex'))
            executable = str(app / 'Contents/MacOS/Codex')
            self.assertTrue(watch.is_main_process({'comm': executable, 'exe': executable}, str(app)))
            self.assertFalse(watch.bundle_identity_valid(str(app), 'com.openai.chat'))

    def test_live_install_without_maintenance_refuses_before_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            target = home / 'Library/Application Support/Latch/bin/grok-bot-local-exec-heal.sh'
            target.parent.mkdir(parents=True)
            target.write_text('prior-executable')
            env = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'PYTHON': sys.executable}
            result = subprocess.run(['/bin/bash', str(ROOT/'install.sh')],env=env,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(target.read_text(),'prior-executable')
            self.assertFalse((home/'Library/LaunchAgents/com.latch.grok-bot-local-exec-heal.plist').exists())
