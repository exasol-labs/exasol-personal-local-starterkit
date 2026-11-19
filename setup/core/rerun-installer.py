"""Run the downloaded platform installer once, for `exakit update`.

    rerun-installer.py --platform macos|linux|windows --kit-root DIR
                       [--fallback-root DIR] [--powershell EXE] [--no-stdin]

`exakit update` calls this when tasks.json names a core task this machine has
not completed. The installer is the one place that holds each task's setup and
checks, so the update reruns it rather than duplicating them.

The rerun keeps what the user already has:
  - EXAKIT_CORE_RERUN=1 tells the installer it was started by an update. The
    choices the first install asked about - the sample data, the AI clients,
    the skills and the marketplace - are not asked again.
  - The caller pins each component to the version installed now
    (EXAKIT_<COMPONENT>_VERSION), so the rerun installs no component the update
    did not, and a deferred database change stays deferred.
  - The installer never starts another update, and this refuses to run inside
    a rerun, so the two cannot loop.

Exit codes: the installer's own exit code; 6 when called from inside a rerun;
7 when no installer script can be found.
"""

import argparse
import os
import subprocess
import sys

EXIT_NESTED = 6
EXIT_NOT_FOUND = 7

SCRIPTS = {
    "macos": "setup-macos.sh",
    "linux": "setup-linux.sh",
    "windows": "setup-windows.ps1",
}


def find_installer(platform, roots):
    """The first existing setup/<script> under the given roots."""
    script = SCRIPTS[platform]
    for root in roots:
        if not root:
            continue
        candidate = os.path.join(root, "setup", script)
        if os.path.isfile(candidate):
            return candidate
    return None


def installer_command(platform, script, powershell):
    if platform == "windows":
        return [powershell or "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", script]
    return ["bash", script]


def main(argv=None):
    parser = argparse.ArgumentParser(prog="rerun-installer.py")
    parser.add_argument("--platform", required=True, choices=sorted(SCRIPTS))
    parser.add_argument("--kit-root", required=True)
    parser.add_argument("--fallback-root", default="")
    parser.add_argument("--powershell", default="")
    parser.add_argument("--no-stdin", action="store_true",
                        help="give the installer no stdin (an unattended update)")
    args = parser.parse_args(argv)

    if os.environ.get("EXAKIT_CORE_RERUN") == "1":
        print("rerun-installer: already inside an installer rerun; not starting another",
              file=sys.stderr)
        return EXIT_NESTED

    script = find_installer(args.platform, [args.kit_root, args.fallback_root])
    if script is None:
        print("rerun-installer: no setup/%s under %s%s" % (
            SCRIPTS[args.platform], args.kit_root,
            " or %s" % args.fallback_root if args.fallback_root else ""), file=sys.stderr)
        return EXIT_NOT_FOUND

    env = dict(os.environ)
    env["EXAKIT_CORE_RERUN"] = "1"
    # The banner belongs to a first install, not to a step inside an update.
    env["EXAKIT_BANNER_SHOWN"] = "1"
    stdin = subprocess.DEVNULL if args.no_stdin else None
    try:
        completed = subprocess.run(installer_command(args.platform, script, args.powershell),
                                   env=env, stdin=stdin)
    except OSError as error:
        print("rerun-installer: could not start %s: %s" % (script, error), file=sys.stderr)
        return EXIT_NOT_FOUND
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
