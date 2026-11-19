"""Persona decisions at the installer boundary; platform adapters run the data UI."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from persona_membership import record
from runtime import AddonFailure

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PERSONA = "general"     # what an install sets up when no persona was named: no question is asked
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
    quiet = False
    if phase == "begin" and not requested:
        # No question: the install sets up the kit's default persona (General) and says nothing about personas.
        requested = DEFAULT_PERSONA
        quiet = True
        actions.append(("set", "EXAKIT_PERSONA", requested))
        phase = "selected"
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
                            ("set", "EXAKIT_PERSONA_ACTIVE", "1")])
            if not quiet:
                actions.append(("notice", "Persona: " + " + ".join(doc["title"] for doc in docs), ""))
    if not requested and not env.get("EXAKIT_DATASETS_PRESELECT"):
        defaults = ",".join(personas.bundled_datasets(root, defaults_only=True))
        if defaults:
            actions.append(("set", "EXAKIT_DATASETS_PRESELECT", defaults))
    return [*actions, ("data", "", "")]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--phase", choices=("begin", "selected"), default="begin")
    for flag in ("interactive", "runtime-failed", "exapump-failed"):
        parser.add_argument("--" + flag, action="store_true")
    args = parser.parse_args()
    actions = plan(args.root, dict(os.environ), phase=args.phase, interactive=args.interactive,
                   runtime_failed=args.runtime_failed, exapump_failed=args.exapump_failed)
    for action, key, value in actions:
        if action == "record":
            # The question's answer replaces the record (a re-run with the same answer writes nothing).
            home = Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit")))
            record(home, key, os.environ.get("EXAKIT_PERSONA_SOURCE", "install"))
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
