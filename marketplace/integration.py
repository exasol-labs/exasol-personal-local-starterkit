"""Post-install integration for marketplace add-ons, shared by both launchers."""

from __future__ import annotations

import filecmp
import hashlib
import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from runtime import AddonFailure, KitContext, cmd_file_bytes, cmd_quote


def _skill_owner(path: Path) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        return ""
    for line in lines[1:]:
        if line == "---":
            break
        if line.startswith("addon: "):
            return line[7:].strip()
    return ""


def _skill_roots() -> list[Path]:
    configured = os.environ.get("EXAKIT_SKILL_ROOTS")
    if configured:
        # PowerShell uses ';'. On Unix the previous adapter used whitespace;
        # shlex also lets a caller quote a root containing spaces.
        parts = configured.split(";") if os.name == "nt" else shlex.split(configured)
        return [Path(part).expanduser() for part in parts if part.strip()]
    return [Path.home() / ".claude" / "skills", Path.home() / ".agents" / "skills"]


# Every skill folder the kit places carries this file, holding the skill-set version it came from: the kit's proof
# of ownership. A folder without it is never replaced. Twin of EXAKIT_SKILL_MARK in setup/lib/common.sh.
SKILL_MARK = ".exakit-owned"


def _same_tree(left: Path, right: Path, ignore: tuple[str, ...] = ()) -> bool:
    """Two folders with the same files and the same bytes (the skill already placed, unchanged)."""
    if not (left.is_dir() and right.is_dir()):
        return False
    report = filecmp.dircmp(left, right, ignore=list(ignore))
    if report.left_only or report.right_only or report.funny_files:
        return False
    if any(not filecmp.cmp(left / name, right / name, shallow=False) for name in report.common_files):
        return False
    return all(_same_tree(left / name, right / name) for name in report.common_dirs)


def _earlier_copy(root: Path, name: str, destination: Path) -> bool:
    """An add-on skill an earlier kit placed, unmarked: the folder holds only SKILL.md, and that file (carriage returns
    aside) is one an earlier kit shipped for this skill (marketplace/earlier-skill-copies.txt). The caller vouches
    that the add-on is the kit's. Twin of _exakit_skill_earlier_copy in common.sh."""
    try:
        if sorted(item.name for item in destination.iterdir()) != ["SKILL.md"]:
            return False
        digest = hashlib.sha256((destination / "SKILL.md").read_bytes().replace(b"\r", b"")).hexdigest()
        listed = (root / "marketplace" / "earlier-skill-copies.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    return f"{name} {digest}" in listed


def _kits_folder(source: Path, destination: Path, root: Path | None = None) -> bool:
    """The folder is the kit's to replace: absent, marked, an older kit's unchanged copy (byte for byte), or (with the
    kit root, for an add-on the kit installs) an add-on skill an earlier kit placed."""
    return not destination.exists() or (destination / SKILL_MARK).is_file() or _same_tree(source, destination) \
        or (root is not None and _earlier_copy(root, source.name, destination))


def install_addon_skills(ctx: KitContext, addon_id: str) -> list[str]:
    """Place the add-on's skills in every skill root. A skill already there, byte for byte, is left alone, so a
    second install writes nothing; a folder of that name the kit did not place (no mark) is the user's and is never
    replaced -- the other roots still get the kit's copy."""
    source = ctx.root / "skills"
    if not source.is_dir():
        return []
    roots = _skill_roots()
    recorded = ctx.manifest.get("components.skills.installed", [])
    recorded = set(recorded if isinstance(recorded, list) else [])
    marker = source / ".version"
    if marker.is_file():
        version = marker.read_text(encoding="utf-8").splitlines()[0].strip()
    else:
        doc = ctx.versions_document()
        version = doc.get("components", {}).get("skills", {}).get("version", "unknown")
    copied: list[str] = []
    # An earlier kit's unmarked copy is adopted only for an add-on the kit itself installed.
    kits = ctx.manifest.get(f"components.{addon_id.replace('-', '_')}.ownership") == "kit"
    for folder in sorted(source.iterdir()):
        spec = folder / "SKILL.md"
        if not spec.is_file() or _skill_owner(spec) != addon_id:
            continue
        changed = placed = False
        for root in roots:
            destination = root / folder.name
            if not _kits_folder(folder, destination, ctx.root if kits else None):
                ctx.log_event(f"Keeping user skill {destination}; marketplace did not replace it")
                continue
            placed = True
            if (destination / SKILL_MARK).is_file() and _same_tree(folder, destination, (SKILL_MARK,)):
                continue
            root.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(folder, destination)
            (destination / SKILL_MARK).write_text(version + "\n", encoding="utf-8")
            changed = True
        if changed or (placed and folder.name not in recorded):
            copied.append(folder.name)
        # Recorded by the mark, not by presence: a user's folder of the name is not the kit's to remove.
        if any((root / folder.name / SKILL_MARK).is_file() for root in roots):
            recorded.add(folder.name)
        else:
            recorded.discard(folder.name)
    if copied:
        ctx.manifest.set_many({"components.skills.installed": sorted(recorded),
                               "components.skills.version": version})
    return copied


def _run_quiet(*argv: str) -> bool:
    try:
        return subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              check=False, timeout=15).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _write_if_changed(path: Path, content: bytes) -> bool:
    """Write the login entry only when it differs from what is there: True when it was written."""
    try:
        if path.read_bytes() == content:
            return False
    except OSError:
        pass
    path.write_bytes(content)
    return True


def register_autostart(ctx: KitContext, addon_id: str, module: object) -> bool:
    """Register the add-on's service to start at login. Idempotent: an entry already there with the same command
    is neither rewritten nor reloaded (a reload would restart a running service), so a second run changes nothing.
    Returns True when an entry is in place."""
    command_fn = getattr(module, "autostart_command", None)
    if ctx.manifest.get("autostart.enabled") is not True or not callable(command_fn):
        return False
    argv = command_fn(ctx)
    if argv is None:
        return False                    # nothing to start at login: the service follows the database (a sidecar)
    if not isinstance(argv, list) or not argv or not all(isinstance(item, str) and item for item in argv):
        raise AddonFailure(f"{addon_id}: invalid autostart command")
    label = f"com.exasol.exakit.{addon_id}"
    logs = ctx.home / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        root = Path(os.environ.get("EXAKIT_LAUNCHAGENT_DIR", str(Path.home() / "Library/LaunchAgents")))
        root.mkdir(parents=True, exist_ok=True)
        path = root / f"{label}.plist"
        log = logs / f"autostart-{addon_id}.log"
        with log.open("a", encoding="utf-8"):
            pass
        log.chmod(0o600)
        content = plistlib.dumps({"Label": label, "ProgramArguments": argv, "RunAtLoad": True,
                                  "StandardOutPath": str(log), "StandardErrorPath": str(log)})
        if not _write_if_changed(path, content) and _run_quiet("launchctl", "list", label):
            ctx.log_event(f"Autostart unchanged: {addon_id}")
            return True
        _run_quiet("launchctl", "unload", str(path))
        if not _run_quiet("launchctl", "load", str(path)):
            raise AddonFailure(f"{addon_id}: launchd refused the login entry; retry with exakit autostart")
    elif os.name == "nt":
        base = os.environ.get("EXAKIT_STARTUP_DIR") or str(Path(os.environ.get("APPDATA", str(Path.home() / "AppData/Roaming"))) /
                                                            "Microsoft/Windows/Start Menu/Programs/Startup")
        root = Path(base)
        root.mkdir(parents=True, exist_ok=True)
        line = " ".join(cmd_quote(item) for item in argv)
        content = cmd_file_bytes("@echo off\r\nstart \"\" /min " + line + "\r\n")
        if not _write_if_changed(root / f"{label}.cmd", content):
            ctx.log_event(f"Autostart unchanged: {addon_id}")
            return True
    else:
        root = Path(os.environ.get("EXAKIT_SYSTEMD_USER_DIR", str(Path.home() / ".config/systemd/user")))
        if not _run_quiet("systemctl", "--user", "show-environment"):
            raise AddonFailure(f"{addon_id}: no systemd --user session; start it after login with exakit start")
        root.mkdir(parents=True, exist_ok=True)
        kind_fn = getattr(module, "autostart_kind", None)
        kind = kind_fn(ctx) if callable(kind_fn) else "longrunning"
        service = ("Type=oneshot\nRemainAfterExit=yes" if kind == "handoff" else
                   "Type=simple\nRestart=on-failure\nRestartSec=5")
        # systemd's command line uses its own quoted argument syntax.
        command = " ".join('"' + arg.replace('\\', '\\\\').replace('"', '\\"') + '"' for arg in argv)
        path = root / f"{label}.service"
        content = (f"[Unit]\nDescription=Exasol Starter Kit: {addon_id}\n\n"
                   f"[Service]\n{service}\nExecStart={command}\n\n"
                   "[Install]\nWantedBy=default.target\n").encode("utf-8")
        if not _write_if_changed(path, content) and _run_quiet("systemctl", "--user", "is-enabled", path.name):
            ctx.log_event(f"Autostart unchanged: {addon_id}")
            return True
        if not (_run_quiet("systemctl", "--user", "daemon-reload") and
                _run_quiet("systemctl", "--user", "enable", path.name)):
            raise AddonFailure(f"{addon_id}: systemd could not enable the login entry")
    ctx.log_event(f"Registered autostart: {addon_id}")
    return True


# --- an add-on's MCP endpoint in the AI clients ------------------------------------------------------------------
# An add-on whose service is an MCP server declares the client entry it is registered under (MCP_SERVER in its
# module: dash-server's control plane). Installing it puts that entry into every AI client already connected;
# removing it takes out that one entry, so the exasol entry and any other stay. Both go through the kit's MCP
# subsystem (python -m mcp), which owns the client config files and records each entry in manifest.json. Until 0.2.5
# the shell add-on modules did this; when they moved here nothing did any more (audit MKT-01).
#
# That subsystem rewrites manifest.json without the kit's lock, so it runs under Manifest.locked(): an add-on
# installing beside this one, or the installer in the foreground, writes its own record before or after it, and
# neither is lost under the other.
MCP_TIMEOUT = 120


def _mcp(ctx: KitContext, *argv: str) -> tuple[int, dict]:
    """Run one `python -m mcp` command against this kit home: (its exit code, its JSON answer or {})."""
    env = dict(os.environ)
    env["PYTHONPATH"] = str(ctx.root) + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    command = [sys.executable, "-m", "mcp", *argv, "--runtime-root", str(ctx.home)]
    try:
        with ctx.manifest.locked():
            result = subprocess.run(command, cwd=ctx.root, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                                    text=True, check=False, timeout=MCP_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as error:
        ctx.log_event(f"python -m mcp {argv[0]} did not run: {error}")
        return 1, {}
    for line in result.stderr.splitlines()[-3:]:
        ctx.log_event(f"python -m mcp {argv[0]}: {line}")
    try:
        answer = json.loads(result.stdout or "{}")
    except ValueError:
        answer = {}
    return result.returncode, answer if isinstance(answer, dict) else {}


def register_mcp_endpoint(ctx: KitContext, addon_id: str, module: object) -> str:
    """Put the add-on's MCP endpoint into the AI clients already connected (never a client the user did not connect).
    Answers the warning to show, or "" when it is done or there is nothing to do."""
    server = getattr(module, "MCP_SERVER", "")
    if not server:
        return ""
    code, answer = _mcp(ctx, "register-addon-servers", "--connected")
    # The MCP subsystem knows one add-on endpoint, Dash Server's, and answers for it under this key.
    entry = answer.get("dash_server") if isinstance(answer.get("dash_server"), dict) else {}
    configured = [str(client) for client in entry.get("configured_clients") or []]
    if configured:
        ctx.log_event(f"{server} MCP endpoint registered with: {', '.join(configured)}")
        return ""
    if entry.get("skipped_clients"):
        # Every connected client was skipped: one that cannot express a remote MCP server (Claude Desktop's config
        # file) is a fact about that client, not a failed install.
        ctx.log_event(f"No connected AI client can take a remote MCP endpoint; drive {addon_id} with: "
                      f"exakit help {addon_id}")
        return ""
    if code != 0:
        return "its MCP endpoint was not registered with your AI clients; register it with: exakit mcp-setup"
    ctx.log_event(f"No AI client is connected yet; exakit mcp-setup registers {server} with the one you connect")
    return ""


def unregister_mcp_endpoint(ctx: KitContext, addon_id: str, module: object) -> str:
    """Take the add-on's MCP entry out of every AI client that has it. Answers the warning to show, or ""."""
    server = getattr(module, "MCP_SERVER", "")
    if not server:
        return ""
    code, answer = _mcp(ctx, "run-runtime-operation", "uninstall", "--servers", server)
    # A client file the kit could not parse is left untouched, its entry still in it: name the file.
    untouched = [finding.get("scope") or {} for finding in answer.get("findings") or []
                 if isinstance(finding, dict) and finding.get("code") == "client_config_left_untouched"]
    if untouched:
        where = "; ".join(f"'{scope.get('entry', server)}' in {scope.get('path')}" for scope in untouched)
        return (f"the kit could not parse a client config, so it left it as it was; delete the MCP entry "
                f"by hand: {where}")
    if code != 0:
        return f"the {server} MCP entry may still be in your AI client configs; check with: exakit mcp-status"
    ctx.log_event(f"{server} MCP entry removed from the AI clients")
    return ""
