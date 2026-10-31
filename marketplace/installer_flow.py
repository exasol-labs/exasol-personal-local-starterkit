"""Persona decisions at the installer boundary; platform adapters run the data UI."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from runtime import AddonFailure, KitContext, Manifest
from persona_services import command_prefix, start_services

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup/lib"))
import persona_service as personas


def plan(root: Path, env: dict[str, str], *, phase: str = "begin", interactive: bool = False,
         runtime_failed: bool = False, exapump_failed: bool = False) -> list[tuple[str, str, str]]:
    if runtime_failed:
        return []
    if exapump_failed:
        return [("data", "", "")]
    requested = env.get("EXAKIT_PERSONA", "")
    actions = []
    if phase == "selected" and requested:
        try:
            docs = personas.picked(root, requested)
            answers = dict(line.split("=", 1) for line in personas.answers(root, requested, env))
        except personas.BadInput as error:
            actions.extend([("warning", f"{error} - carrying on without a persona", ""),
                            ("set", "EXAKIT_PERSONA", "")])
            requested = ""
        else:
            datasets = "none" if answers.get("EXAKIT_LOAD_SAMPLE") == "0" else answers.get("EXAKIT_DATASETS")
            if datasets:
                actions.append(("set", "EXAKIT_DATASETS_PRESELECT", datasets))
            addons = answers.get("EXAKIT_MARKETPLACE_ADDONS")
            if addons and addons != "none":
                actions.append(("set", "EXAKIT_MARKETPLACE_PRESELECT", addons))
            actions.extend([("record", ",".join(doc["id"] for doc in docs), ""),
                            ("set", "EXAKIT_PERSONA_ACTIVE", "1"),
                            ("notice", "Persona: " + " + ".join(doc["title"] for doc in docs), "")])
    elif phase == "begin" and not requested:
        answered = bool((env.get("EXAKIT_DATASETS") or env.get("EXAKIT_LOAD_SAMPLE") in ("0", "1"))
                        and env.get("EXAKIT_MARKETPLACE_ADDONS"))
        if interactive and not answered:
            return [("question", "", "")]
    if not requested and not env.get("EXAKIT_DATASETS_PRESELECT"):
        defaults = ",".join(personas.bundled_datasets(root, defaults_only=True))
        if defaults:
            actions.append(("set", "EXAKIT_DATASETS_PRESELECT", defaults))
    return [*actions, ("data", "", "")]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--phase", choices=("begin", "selected", "services"), default="begin")
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--host")
    for flag in ("interactive", "runtime-failed", "exapump-failed"):
        parser.add_argument("--" + flag, action="store_true")
    args = parser.parse_args()
    if args.phase == "services":
        if not args.cli:
            parser.error("--cli is required for services")
        try:
            prefix = command_prefix(args.cli, args.host)
            failures = start_services(KitContext.from_environment(args.root),
                personas.selected_services(args.root, os.environ.get("EXAKIT_PERSONA", "")),
                lambda command, options: subprocess.run([*prefix, command, *options],
                    stdin=subprocess.DEVNULL, check=False).returncode == 0)
        except (AddonFailure, personas.BadInput, OSError, ValueError) as error:
            print(f"Persona services: {error}", file=sys.stderr)
            return 1
        for name, retry in failures:
            print(f"{name} did not start; retry with: {retry}", file=sys.stderr)
        return int(bool(failures))
    actions = plan(args.root, dict(os.environ), phase=args.phase, interactive=args.interactive,
                   runtime_failed=args.runtime_failed, exapump_failed=args.exapump_failed)
    for action, key, value in actions:
        if action == "record":
            home = Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit")))
            Manifest(home / "manifest.json").set_many({
                "persona.id": key, "persona.source": os.environ.get("EXAKIT_PERSONA_SOURCE", "install"),
                "persona.requested_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        else:
            print("|".join(field.replace("|", "/").replace("\r", " ").replace("\n", " ")
                           for field in (action, key, value)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AddonFailure, personas.BadInput, OSError, ValueError) as error:
        print(f"Persona flow: {error}", file=sys.stderr)
        raise SystemExit(1)
