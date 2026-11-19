"""Core-task bookkeeping for the installer and `exakit update`.

    manage.py tasks    --tasks FILE [--scope SCOPE]
        Every task name, one per line, in tasks.json order: the work the
        installer's steps run and verify on every pass.
    manage.py pending  --tasks FILE --manifest FILE [--scope SCOPE]
        Pending task names, one per line, in tasks.json order. Nothing printed
        means nothing is pending.
    manage.py status   --tasks FILE --manifest FILE
        One JSON object: every task with its scope and whether it completed,
        and the pending names.
    manage.py complete --tasks FILE --manifest FILE NAME
        Record NAME as completed. The installer calls this only after the
        task's own setup checks passed. NAME must be a task in tasks.json.

Exit codes: 0 done, 2 bad arguments or tasks file, 3 no manifest, 4 manifest
unreadable, 5 manifest not writable. The message goes to stderr.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import state  # noqa: E402  (path set above)


def _parser():
    parser = argparse.ArgumentParser(prog="manage.py", description="Core-task bookkeeping.")
    sub = parser.add_subparsers(dest="command")
    for name in ("tasks", "pending", "status", "complete"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--tasks", required=True)
        if name != "tasks":
            cmd.add_argument("--manifest", required=True)
        if name in ("tasks", "pending"):
            cmd.add_argument("--scope", choices=state.SCOPES)
        if name == "complete":
            cmd.add_argument("name")
    return parser


def main(argv=None):
    parser = _parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_usage(sys.stderr)
        return state.EXIT_USAGE
    try:
        tasks = state.load_tasks(args.tasks)
        if args.command == "tasks":
            for task in tasks:
                if args.scope is None or task["scope"] == args.scope:
                    print(task["name"])
            return 0
        if args.command == "complete":
            if args.name not in [task["name"] for task in tasks]:
                raise state.StateError("%s is not a task in %s" % (args.name, args.tasks),
                                       state.EXIT_USAGE)
            state.mark_completed(args.manifest, args.name)
            return 0
        doc = state.read_manifest(args.manifest)
        if args.command == "pending":
            for name in state.pending(tasks, doc, args.scope):
                print(name)
            return 0
        done = set(state.completed(doc))
        print(json.dumps({
            "tasks": [dict(task, completed=task["name"] in done) for task in tasks],
            "pending": state.pending(tasks, doc),
        }, indent=2))
        return 0
    except state.StateError as error:
        print("core tasks: %s" % error, file=sys.stderr)
        return error.code


if __name__ == "__main__":
    sys.exit(main())
