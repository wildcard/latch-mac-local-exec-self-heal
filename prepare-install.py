#!/usr/bin/env python3
"""Prepare or verify a private maintenance candidate. Never loads jobs or apps."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
SOURCES = ('install.sh', 'grok-bot-local-exec-heal.sh', 'grok-bot-restart-guard.py',
           'codex-watch.py', 'com.latch.grok-bot-local-exec-heal.plist.tmpl', 'VERSION')
POLICY = {'RECOVERY_MODE': 'active', 'HEAL_ON_HELPER_MISSING': '1',
          'HELPER_IDLE_REQUIRED': '1', 'HELPER_MISSING_SEC': '300',
          'CODEX_WATCH': '1',
          'CODEX_REOPEN_POLICY': 'crash_only', 'CODEX_BUNDLE_ID': 'com.openai.codex',
          'CODEX_APP_PATH': '/Applications/ChatGPT.app'}
LABEL = 'com.latch.grok-bot-local-exec-heal.plist'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() and not path.is_symlink() else None


def private_write(path, data):
    with path.open('x') as handle:
        os.chmod(path, 0o600)
        json.dump(data, handle, indent=2)
        handle.write('\n')


def installed_hashes(home):
    base = home / 'Library/Application Support/Latch/bin'
    paths = {name: base / name for name in SOURCES[1:4]}
    paths['plist'] = home / 'Library/LaunchAgents' / LABEL
    return {name: digest(path) for name, path in paths.items()}


def verify(plan, home):
    data = json.loads((plan / 'manifest.json').read_text())
    return (data['source'] == {name: digest(ROOT / name) for name in SOURCES}
            and data['installedBefore'] == installed_hashes(home)
            and data['policy'] == digest(plan / 'recovery-policy.json')
            and data['candidate'] == digest(plan / 'candidate' / LABEL)
            and data['bin'] == {name: digest(plan / 'candidate/bin' / name) for name in SOURCES[1:4]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--desktop-bundle', choices=('com.openai.codex', 'com.openai.chat'), default='com.openai.codex')
    parser.add_argument('--desktop-app', default='/Applications/ChatGPT.app')
    args = parser.parse_args()
    home = Path.home()
    plan = args.destination.resolve()
    if args.check:
        try:
            ok = verify(plan, home)
        except (OSError, ValueError, KeyError, TypeError):
            ok = False
        print(json.dumps({'candidateUnchanged': ok, 'installedOrLoaded': False}))
        return 0 if ok else 1
    os.umask(0o077)
    plan.mkdir(mode=0o700, parents=False, exist_ok=False)
    policy = dict(POLICY, CODEX_BUNDLE_ID=args.desktop_bundle, CODEX_APP_PATH=args.desktop_app)
    private_write(plan / 'recovery-policy.json', policy)
    before = installed_hashes(home)
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(home), 'PYTHON': sys.executable,
           'INSTALL_PREPARE_DIR': str(plan / 'candidate'),
           'INSTALL_POLICY_FILE': str(plan / 'recovery-policy.json')}
    # Capture installer output privately: operator key names/paths never enter evidence.
    with (plan / 'prepare.log').open('x') as log:
        result = subprocess.run(['/bin/bash', str(ROOT / 'install.sh')], env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=60)
    if result.returncode or before != installed_hashes(home):
        print(json.dumps({'prepared': False, 'installedOrLoaded': False}))
        return 1
    private_write(plan / 'manifest.json', {
        'schema': 1, 'source': {name: digest(ROOT / name) for name in SOURCES},
        'installedBefore': before, 'policy': digest(plan / 'recovery-policy.json'),
        'candidate': digest(plan / 'candidate' / LABEL),
        'bin': {name: digest(plan / 'candidate/bin' / name) for name in SOURCES[1:4]}})
    print(json.dumps({'prepared': True, 'candidatePrivate': True, 'installedUnchanged': True,
                      'installedOrLoaded': False, 'policy': {k: v for k, v in policy.items() if k != 'CODEX_APP_PATH'}}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print('Preparation failed; inspect the private local evidence.', file=sys.stderr)
        sys.exit(1)
