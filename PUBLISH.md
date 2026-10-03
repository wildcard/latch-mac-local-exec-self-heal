# Publish to GitHub

Do **not** create the repo until this tree has been reviewed. These are the exact steps for after that review. Nothing in this file has been run against GitHub.

- GitHub account: personal login **`wildcard`** (`gh api user` on the box where this was packed).
- Repo name: **`latch-mac-local-exec-self-heal`**
- Visibility: **public**
- License: MIT (`LICENSE`)

## Preflight

```bash
cd /workspace/latch-mac-local-exec-self-heal
test ! -f com.latch.grok-bot-local-exec-heal.plist
./tests/run-tests.sh
gh auth status
```

`gh auth status` must show the `wildcard` account. Stop if it shows a different login. The machine-specific plist (a home-directory path) is not in this tree. Install uses `com.latch.grok-bot-local-exec-heal.plist.tmpl` (`__HOME__` placeholder).

## Create and push

```bash
cd /workspace/latch-mac-local-exec-self-heal
git init
git add -A
git status
git commit -m "mac-local-exec-self-heal 1.3.0"
gh repo create latch-mac-local-exec-self-heal --public --source=. --remote=origin --description "LaunchAgent that relaunches the Grok Bot Mac app when local readiness signals go stale. Does not see cloud connect state."
git push -u origin HEAD
```

Resulting URL: `https://github.com/wildcard/latch-mac-local-exec-self-heal`

`gh repo create` does not push. `git push` is the step that publishes objects. If the name is taken, stop. Do not pass `--private`. Do not force-push.

```bash
gh repo view wildcard/latch-mac-local-exec-self-heal --json name,visibility,url
```
