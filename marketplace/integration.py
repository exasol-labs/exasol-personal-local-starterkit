"""Post-install integration for marketplace add-ons, shared by both launchers."""

from __future__ import annotations

import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from runtime import AddonFailure, KitContext


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


def install_addon_skills(ctx: KitContext, addon_id: str) -> list[str]:
    source = ctx.root / "skills"
    if not source.is_dir():
        return []
    roots = _skill_roots()
    recorded = ctx.manifest.get("components.skills.installed", [])
    recorded = set(recorded if isinstance(recorded, list) else [])
    copied: list[str] = []
    for folder in sorted(source.iterdir()):
        spec = folder / "SKILL.md"
        if not spec.is_file() or _skill_owner(spec) != addon_id:
            continue
        # A skill with this name placed by the user is never claimed or
        # overwritten, even if another root is empty.
        if any((root / folder.name).exists() for root in roots) and folder.name not in recorded:
            ctx.log_event(f"Keeping user skill {folder.name}; marketplace did not replace it")
            continue
        for root in roots:
            root.mkdir(parents=True, exist_ok=True)
            destination = root / folder.name
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(folder, destination)
        recorded.add(folder.name)
        copied.append(folder.name)
    if copied:
        marker = source / ".version"
        if marker.is_file():
            version = marker.read_text(encoding="utf-8").splitlines()[0].strip()
        else:
            doc = json.loads((ctx.root / "versions.json").read_text(encoding="utf-8"))
            version = doc.get("components", {}).get("skills", {}).get("version", "unknown")
        ctx.manifest.set_many({"components.skills.installed": sorted(recorded),
                               "components.skills.version": version})
    return copied


def _run_quiet(*argv: str) -> bool:
    try:
        return subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              check=False, timeout=15).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def register_autostart(ctx: KitContext, addon_id: str, module: object) -> bool:
    command_fn = getattr(module, "autostart_command", None)
    if ctx.manifest.get("autostart.enabled") is not True or not callable(command_fn):
        return False
    argv = command_fn(ctx)
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
        path.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": argv,
                                        "RunAtLoad": True, "StandardOutPath": str(log),
                                        "StandardErrorPath": str(log)}))
        _run_quiet("launchctl", "unload", str(path))
        if not _run_quiet("launchctl", "load", str(path)):
            raise AddonFailure(f"{addon_id}: launchd refused the login entry; retry with exakit autostart")
    elif os.name == "nt":
        base = os.environ.get("EXAKIT_STARTUP_DIR") or str(Path(os.environ.get("APPDATA", str(Path.home() / "AppData/Roaming"))) /
                                                            "Microsoft/Windows/Start Menu/Programs/Startup")
        root = Path(base)
        root.mkdir(parents=True, exist_ok=True)
        # Windows cmd quoting is delegated to subprocess.list2cmdline.
        line = subprocess.list2cmdline(argv)
        (root / f"{label}.cmd").write_text("@echo off\r\nstart \"\" /min " + line + "\r\n", encoding="ascii")
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
        path.write_text(f"[Unit]\nDescription=Exasol Starter Kit: {addon_id}\n\n"
                        f"[Service]\n{service}\nExecStart={command}\n\n"
                        "[Install]\nWantedBy=default.target\n", encoding="utf-8")
        if not (_run_quiet("systemctl", "--user", "daemon-reload") and
                _run_quiet("systemctl", "--user", "enable", path.name)):
            raise AddonFailure(f"{addon_id}: systemd could not enable the login entry")
    ctx.log_event(f"Registered autostart: {addon_id}")
    return True
