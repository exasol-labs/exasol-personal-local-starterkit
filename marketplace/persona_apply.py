"""Apply a persona using the existing data and MCP commands as platform services.

Persona decisions, membership and sequencing live here. Database deployment,
data loading and MCP setup keep their existing CLI contracts. Child commands
receive explicit answers and closed stdin, so they cannot unexpectedly ask.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from runtime import AddonFailure, KitContext
from model import CatalogError, load_addons

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "setup" / "lib"))
import persona_service  # noqa: E402


def _ids(root: Path, requested: str, recorded: str) -> tuple[str, str]:
    old = []
    for item in recorded.split(","):
        if not item:
            continue
        try:
            persona_service.picked(root, item)
        except persona_service.BadInput:
            continue
        old.append(item)
    new = persona_service.selectable(root, requested, ",".join(old))
    joined = persona_service.picked(root, ",".join([*old, *(item["id"] for item in new)]))
    return ",".join(item["id"] for item in new), ",".join(item["id"] for item in joined)


def _child(prefix: list[str], command: str, args: list[str], env: dict[str, str]) -> bool:
    try:
        return subprocess.run([*prefix, command, *args], env=env, stdin=subprocess.DEVNULL,
                              check=False).returncode == 0
    except OSError as error:
        print(f"{command} could not start: {error}", file=sys.stderr)
        return False


def _query(prefix: list[str], command: str, args: list[str], env: dict[str, str]) -> dict | None:
    """Read the existing CLI's machine state without treating exit 3 as no data."""
    try:
        result = subprocess.run([*prefix, command, *args], env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, check=False)
        payload = json.loads(result.stdout)
        return payload if isinstance(payload, dict) else None
    except (OSError, ValueError):
        return None


def _requested_datasets(root: Path, value: str) -> list[str]:
    known = set(persona_service.bundled_datasets(root))
    ids = [part.strip() for part in value.split(",") if part.strip()]
    unknown = [item for item in ids if item not in known]
    if unknown:
        raise persona_service.BadInput(f"Unknown dataset id '{unknown[0]}' in EXAKIT_DATASETS")
    return list(dict.fromkeys(ids))


def _dataset_label(root: Path, dataset_id: str) -> str:
    conf = root / "data" / "datasets" / dataset_id / "dataset.conf"
    for line in conf.read_text(encoding="utf-8").splitlines():
        if line.startswith("label="):
            return line.partition("=")[2]
    return dataset_id


def _requested_addons(root: Path, value: str) -> list[str]:
    catalog = load_addons(root)
    visible = [item.id for item in catalog if item.visible]
    known = {item.id for item in catalog}
    if value.strip().lower() in ("", "none"):
        return []
    if value.strip().lower() == "all":
        return visible
    ids = [part.strip().lower() for part in value.split(",") if part.strip()]
    unknown = [item for item in ids if item not in known]
    if unknown:
        raise CatalogError(f"Unknown add-on '{unknown[0]}' in marketplace/catalog.json")
    return list(dict.fromkeys(ids))


def apply(ctx: KitContext, requested: str, prefix: list[str], *, live: bool = False) -> int:
    ctx.manifest.read()
    old = str(ctx.manifest.get("persona.id") or "")
    new_ids, all_ids = _ids(ctx.root, requested, old)
    environment = {**os.environ, "EXAKIT_HOME": str(ctx.home)}
    for line in persona_service.answers(ctx.root, all_ids, environment):
        name, value = line.split("=", 1)
        environment[name] = value
    environment["EXAKIT_PERSONA_SOURCE"] = "add"
    datasets = (_requested_datasets(ctx.root, environment.get("EXAKIT_DATASETS", ""))
                if environment.get("EXAKIT_LOAD_SAMPLE") != "0" else [])
    addons = _requested_addons(ctx.root, environment.get("EXAKIT_MARKETPLACE_ADDONS", ""))
    status = _query(prefix, "status", ["--json"], environment) if datasets else None
    if status is not None and isinstance(status.get("datasets_loaded"), list):
        loaded = set(status["datasets_loaded"])
    else:
        loaded = {item for item in datasets if ctx.manifest.get(f"data.datasets.{item}.loaded") is True}
    marketplace = _query(prefix, "marketplace", ["--list", "--json"], environment) if addons else None
    rows = (marketplace.get("addons", []) if marketplace is not None
            and isinstance(marketplace.get("addons"), list) else [])
    installed = {row.get("id") for row in rows if isinstance(row, dict) and row.get("installed")}
    external = {row.get("id") for row in rows if isinstance(row, dict)
                and row.get("status") == "managed outside the kit"}
    for item in addons:
        owner = ctx.manifest.get(f"components.{item.replace('-', '_')}.ownership")
        if owner in ("user", "unknown"):
            external.add(item)
    disabled = [item.id for item in load_addons(ctx.root)
                if item.id in addons and not item.visible and item.id not in installed and item.id not in external]
    if disabled:
        raise CatalogError(f"Add-on '{disabled[0]}' is disabled in marketplace/catalog.json")
    ctx.manifest.set_many({"persona.id": all_ids, "persona.source": "add",
                           "persona.requested_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
    title = " + ".join(item["title"] for item in persona_service.picked(ctx.root, new_ids))
    all_title = " + ".join(item["title"] for item in persona_service.picked(ctx.root, all_ids))
    print(f"\nAdding persona: {title}" + (f" (now {all_title})" if all_ids != new_ids else ""), flush=True)
    failures: list[tuple[str, str]] = []

    print("Step 1/3  Sample data", flush=True)
    have = [item for item in datasets if item in loaded]
    pending = [item for item in datasets if item not in loaded]
    if have:
        print("Already loaded: " + ", ".join(_dataset_label(ctx.root, item) for item in have), flush=True)
    if pending:
        child_env = dict(environment)
        child_env.pop("EXAKIT_DATA_FILE", None)
        child_env.pop("EXAKIT_LOAD_SAMPLE", None)
        if live:
            child_env.pop("EXAKIT_DATASETS", None)
            child_env.update({"EXAKIT_PERSONA_ACTIVE": "1", "EXAKIT_DATASETS_PRESELECT": ",".join(pending),
                              "UI_TABLE_AUTO": "1"})
        else:
            child_env["EXAKIT_DATASETS"] = ",".join(pending)
        if not _child(prefix, "data-load", [], child_env):
            failures.append(("Sample data", f"EXAKIT_DATASETS={','.join(pending)} exakit data-load"))
    elif not have:
        print("No sample data for these personas", flush=True)

    print("Step 2/3  AI clients", flush=True)
    clients = environment.get("EXAKIT_MCP_CLIENTS", "")
    if environment.get("EXAKIT_SKIP_MCP") == "1":
        print("Skipping the AI clients (EXAKIT_SKIP_MCP=1) - connect them any time with: exakit mcp-setup", flush=True)
    elif clients.lower() in ("", "skip", "none"):
        print("No AI clients for these personas", flush=True)
    else:
        child_env = dict(environment)
        if live:
            child_env.pop("EXAKIT_MCP_CLIENTS", None)
            child_env.update({"EXAKIT_MCP_PRESELECT": clients, "UI_TABLE_AUTO": "1"})
        if not _child(prefix, "mcp-setup", [], child_env):
            failures.append(("AI clients", "exakit mcp-setup"))

    print("Step 3/3  Add-ons", flush=True)
    have_addons = [item for item in addons if item in installed]
    external_addons = [item for item in addons if item in external and item not in installed]
    pending_addons = [item for item in addons if item not in installed and item not in external]
    if have_addons:
        print("Already installed: " + ", ".join(have_addons), flush=True)
    if external_addons:
        print("Already available outside the kit: " + ", ".join(external_addons), flush=True)
    if not pending_addons and not have_addons and not external_addons:
        print("No add-ons for these personas", flush=True)
    elif pending_addons:
        child_env = dict(environment)
        if live:
            child_env.pop("EXAKIT_MARKETPLACE_ADDONS", None)
            child_env["EXAKIT_MARKETPLACE_ONLY"] = ",".join(pending_addons)
            child_env["UI_TABLE_AUTO"] = "1"
        else:
            child_env["EXAKIT_MARKETPLACE_ADDONS"] = ",".join(pending_addons)
        if not _child(prefix, "marketplace", [], child_env):
            failures.append(("Add-ons", "exakit marketplace " + " ".join(pending_addons)))

    for name in persona_service.selected_services(ctx.root, new_ids):
        ready_addons = set(installed)
        ready_addons.update(item for item in ("udf-devkit", "notebook")
                            if ctx.manifest.get(f"components.{item.replace('-', '_')}.ownership") == "kit")
        if not any(part == "Add-ons" for part, _ in failures):
            ready_addons.update(pending_addons)
        missing = [item for item in ("udf-devkit", "notebook") if item not in ready_addons]
        if name == "mlflow" and missing:
            print("Skipping MLflow service - missing: " + ", ".join(missing), flush=True)
            continue
        if name == "mlflow" and not _child(prefix, "mlflow", ["start"], environment):
            failures.append(("MLflow service", "exakit mlflow start"))
    if failures:
        print(f"\nPersona added: {all_title} - not everything finished", flush=True)
        for part, retry in failures:
            print(f"{part} did not finish - retry with: {retry}", file=sys.stderr)
        return 1
    print(f"\nPersona added: {all_title}", flush=True)
    return 0


def main() -> int:
    class PersonaParser(argparse.ArgumentParser):
        def error(self, message: str) -> None:
            self.exit(1, f"persona: {message}\n")

    parser = PersonaParser(description=__doc__)
    parser.add_argument("action", choices=("add", "apply"))
    parser.add_argument("ids")
    parser.add_argument("--yes", "-y", action="store_true", help="accepted for compatibility; the command is unattended")
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--host")
    args = parser.parse_args()
    if args.cli.suffix.lower() == ".ps1":
        host = args.host or shutil.which("pwsh") or shutil.which("powershell.exe")
        if not host:
            print("PowerShell is unavailable for persona commands", file=sys.stderr)
            return 1
        prefix = [host, "-NoProfile", "-File", str(args.cli)]
    else:
        prefix = [str(args.cli)]
    try:
        return apply(KitContext.from_environment(ROOT), args.ids, prefix,
                     live=sys.stdout.isatty() and os.environ.get("EXAKIT_NO_FANCY") != "1")
    except (persona_service.BadInput, AddonFailure, CatalogError, OSError, ValueError) as error:
        print(f"persona: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
