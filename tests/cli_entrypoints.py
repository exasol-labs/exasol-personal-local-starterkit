"""Installed shell entry points usable on the current test host."""

import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def entrypoints(root: Path = ROOT) -> list[list[str]]:
    """The kit's command at ``root`` (a test's own kit copy, or this checkout) on every shell this host has."""
    commands = []
    if os.name != "nt" and shutil.which("bash"):
        commands.append(["bash", str(root / "setup/exakit")])
    for shell in (("powershell", "pwsh") if os.name == "nt" else ("pwsh",)):
        if shutil.which(shell):
            commands.append([shell, "-NoProfile", "-File", str(root / "setup/exakit.ps1")])
    return commands
