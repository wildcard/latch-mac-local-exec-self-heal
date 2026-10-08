#!/usr/bin/env python3
"""Stand-in for /bin/ps. Honored only when the heal script is in HEAL_TEST_MODE.

Answers the two production calls:
  ps -axww -o pid=,ppid=,etime=,comm=
  ps -axww -o pid=,command=
GROK_APP_PATH is the app bundle this process tree lives under.
"""
import os
import sys

APP = os.environ.get("GROK_APP_PATH", "/Applications/Grok Bot.app")
HELPER = (
    APP
    + "/Contents/Frameworks/Grok Bot Helper.app/Contents/MacOS/Grok Bot Helper"
)

# pid, ppid, etime, comm, command
ROWS = [
    (4242, 1, "01-06:47:12", "Grok Bot", APP + "/Contents/MacOS/Grok Bot"),
    (
        4290,
        4242,
        "01-06:47:10",
        "Grok Bot Helper",
        APP
        + "/Contents/Frameworks/Grok Bot Helper (GPU).app/Contents/MacOS/Grok Bot Helper (GPU)"
        + " --type=gpu-process --seatbelt-client=31",
    ),
    (
        4291,
        4242,
        "01-06:47:10",
        "Grok Bot Helper (Renderer)",
        APP
        + "/Contents/Frameworks/Grok Bot Helper (Renderer).app/Contents/MacOS/Grok Bot Helper (Renderer)"
        + " --type=renderer --user-data-dir=/Users/fixture-user/Library/Application Support/Grok Bot"
        + " --field-trial-handle=fixture-handle-not-for-logs",
    ),
    (
        4300,
        4242,
        "01-06:47:09",
        "Grok Bot Helper",
        HELPER
        + " --type=utility --utility-sub-type=node.mojom.NodeService --lang=en-US"
        + " --field-trial-handle=fixture-handle-not-for-logs",
    ),
    (
        4301,
        4242,
        "01-06:47:09",
        "Grok Bot Helper",
        HELPER + " --type=utility --utility-sub-type=node.mojom.NodeService --lang=en-US",
    ),
    (
        4304,
        4242,
        "00:05",
        "Grok Bot Helper",
        HELPER + " --type=zygote",
    ),
    (
        4305,
        4242,
        "00:04",
        "Grok Bot Helper",
        HELPER + " --type=crashpad-handler",
    ),
    (
        4500,
        4242,
        "00:02",
        "Browser",
        "/Applications/Browser.app/Contents/MacOS/Browser"
        " https://example.invalid/cb?code=fixture-query-secret",
    ),
    (
        4501,
        4242,
        "00:01",
        "curl",
        '/bin/zsh -c \'curl -H "Authorization: Bearer fixture-bearer-token"'
        " https://example.invalid/x'",
    ),
    (
        4502,
        4242,
        "00:01",
        "zsh",
        '/bin/zsh -c \'"'
        + APP
        + '/Contents/MacOS/Grok Bot Helper" --type=utility'
        + " --utility-sub-type=node.mojom.NodeService'",
    ),
    (
        4503,
        4242,
        "00:01",
        "Bearer fixture-bearer-token",
        "/bin/echo should-not-appear-in-snapshot",
    ),
]


def main():
    argv = " ".join(sys.argv[1:])
    if "command=" in argv:
        for pid, _ppid, _etime, _comm, command in ROWS:
            sys.stdout.write("%s %s\n" % (pid, command))
        return
    for pid, ppid, etime, comm, _command in ROWS:
        sys.stdout.write("%s %s %s %s\n" % (pid, ppid, etime, comm))


if __name__ == "__main__":
    main()
