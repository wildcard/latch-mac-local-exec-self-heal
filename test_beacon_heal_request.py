"""Hermetic checks for the worker-host heal-request command. Fake token file only."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest


CMD = Path(__file__).resolve().parent / "worker-beacon" / "bin" / "beacon-heal-request"
TOKEN = "super-secret-writer-token-value"


def run(args, token_mode=0o600, url="https://beacon.example/base", extra_env=None):
    with tempfile.TemporaryDirectory() as directory:
        token_path = Path(directory) / "WRITER_TOKEN"
        token_path.write_text(TOKEN + "\n")
        token_path.chmod(token_mode)
        env = {
            "PATH": os.environ.get("PATH", ""),
            "BEACON_URL": url,
            "BEACON_WRITER_TOKEN_FILE": str(token_path),
        }
        if extra_env:
            env.update(extra_env)
        proc = subprocess.run(
            [sys.executable, str(CMD), *args],
            env=env,
            text=True,
            capture_output=True,
        )
        return proc


class BeaconHealRequestTests(unittest.TestCase):
    def test_dry_run_prints_status_and_request_id_without_token(self):
        proc = run(["--dry-run", "machine-1"], url="https://127.0.0.1:9/beacon")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertRegex(proc.stdout, r"^dry-run [0-9a-f-]{36}\n$")
        blob = proc.stdout + proc.stderr
        self.assertNotIn(TOKEN, blob)
        self.assertNotIn("WRITER_TOKEN", blob)

    def test_http_url_refused_and_token_absent(self):
        proc = run(["machine-1"], url="http://beacon.example/base")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("https", proc.stderr)
        blob = proc.stdout + proc.stderr
        self.assertNotIn(TOKEN, blob)
        self.assertNotRegex(proc.stdout, re.compile(r"\d{3} "))

    def test_non_https_schemes_refused(self):
        for url in ("", "http://127.0.0.1/v1", "file:///tmp/x", "https://", "https://user:secret@host/v1"):
            proc = run(["--dry-run", "machine-1"], url=url)
            self.assertNotEqual(proc.returncode, 0, url)
            self.assertNotIn(TOKEN, proc.stdout + proc.stderr)

    def test_open_token_file_refused_without_echoing_it(self):
        proc = run(["--dry-run", "machine-1"], token_mode=0o644)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("perms", proc.stderr)
        self.assertNotIn(TOKEN, proc.stdout + proc.stderr)

    def test_bad_machine_id_refused(self):
        proc = run(["--dry-run", "not a machine"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn(TOKEN, proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
