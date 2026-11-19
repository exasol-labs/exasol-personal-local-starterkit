"""The command a persona step runs the kit's own CLI through, on every platform."""

import shutil
from pathlib import Path

from runtime import AddonFailure


def command_prefix(cli: Path, host: str | None = None) -> list[str]:
    if cli.suffix.lower() != '.ps1':
        return [str(cli)]
    host = host or shutil.which('pwsh') or shutil.which('powershell.exe')
    if not host:
        raise AddonFailure('PowerShell is unavailable for persona commands')
    return [host, '-NoProfile', '-File', str(cli)]
