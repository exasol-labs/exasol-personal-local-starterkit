"""Start services declared by a persona after its add-ons are available."""

from collections.abc import Callable, Iterable
import shutil
from pathlib import Path

from runtime import AddonFailure, KitContext


def command_prefix(cli: Path, host: str | None = None) -> list[str]:
    if cli.suffix.lower() != '.ps1':
        return [str(cli)]
    host = host or shutil.which('pwsh') or shutil.which('powershell.exe')
    if not host:
        raise AddonFailure('PowerShell is unavailable for persona commands')
    return [host, '-NoProfile', '-File', str(cli)]


def start_services(ctx: KitContext, names: Iterable[str],
                   run: Callable[[str, list[str]], bool],
                   ready: Iterable[str] = ()) -> list[tuple[str, str]]:
    available = set(ready)
    available.update(item for item in ('udf-devkit', 'notebook')
                     if ctx.manifest.get(f"components.{item.replace('-', '_')}.ownership") == 'kit')
    failures = []
    for name in names:
        if name != 'mlflow':
            raise AddonFailure(f'Unknown persona service: {name}')
        missing = [item for item in ('udf-devkit', 'notebook') if item not in available]
        if missing:
            print('Skipping MLflow service - missing: ' + ', '.join(missing), flush=True)
        elif not run('mlflow', ['start']):
            failures.append(('MLflow service', 'exakit mlflow start'))
    return failures
