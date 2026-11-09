"""``python -m exasol_mlflow replay|status [--json]`` - the stable command line ``exakit mlflow replay`` wraps.

    python -m exasol_mlflow replay [--json] [--tracking-uri URI] [--tracking-dir DIR]
    python -m exasol_mlflow status [--json]

Exit codes: 0 done (also when nothing was pending); 1 a record could not be logged (it stays in the spool; the ones
before it were logged and removed); 2 bad arguments; 3 the tracking server does not answer (nothing was removed).
JSON: ``{"ok": true, "replayed": ["<run id>", ...], "pending": [{run_key, experiment, written_at, path}, ...]}`` -
on a failure ``{"ok": false, "error": "...", "replayed": [...], "pending": [...]}``.
"""

from __future__ import annotations

import argparse
import json
import sys

from . import __version__, records, tracking


def _print(doc: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(doc, indent=2))
        return
    if doc.get("error"):
        print(f"exasol-mlflow: {doc['error']}", file=sys.stderr)
    for run_id in doc.get("replayed", []):
        print(f"replayed run {run_id}")
    pending = doc.get("pending", [])
    if pending:
        print(f"{len(pending)} pending record(s) in {records.spool_dir()}:")
        for row in pending:
            print(f"  {row['run_key']}  {row.get('experiment') or '-'}  {row.get('written_at') or '-'}"
                  + (f"  ({row['error']})" if row.get("error") else ""))
    elif not doc.get("replayed"):
        print(f"nothing pending in {records.spool_dir()}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m exasol_mlflow", description=__doc__.split("\n\n")[0])
    parser.add_argument("--version", action="version", version=f"exasol-mlflow {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)
    replay = commands.add_parser("replay", help="log every pending spool record to MLflow and remove it")
    replay.add_argument("--json", action="store_true", help="print the result as JSON")
    replay.add_argument("--tracking-uri", help="log to this server instead of the resolved one (MLFLOW_TRACKING_URI, the kit's server)")
    replay.add_argument("--tracking-dir", help="log to a local store in this folder")
    replay.add_argument("--timeout", type=float, default=3.0, help="seconds for the health check (default 3)")
    show = commands.add_parser("status", help="list the records waiting for a replay")
    show.add_argument("--json", action="store_true", help="print the result as JSON")
    args = parser.parse_args(argv)
    if args.command == "status":
        _print({"ok": True, "replayed": [], "pending": records.status()}, args.json)
        return 0
    done: list[str] = []
    try:
        done = records.replay(tracking_uri=args.tracking_uri, tracking_dir=args.tracking_dir, timeout=args.timeout)
    except tracking.TrackingUnavailable as err:
        _print({"ok": False, "error": str(err), "replayed": [], "pending": records.status()}, args.json)
        return 3
    except Exception as err:  # noqa: BLE001 - one record failed; say which stays
        _print({"ok": False, "error": f"{type(err).__name__}: {err}", "replayed": done, "pending": records.status()}, args.json)
        return 1
    _print({"ok": True, "replayed": done, "pending": records.status()}, args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
