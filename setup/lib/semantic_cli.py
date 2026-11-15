"""exakit semantic / exakit board: the semantic layer and the multi-page dashboard from the command line, for a
person or an AI client, doing exactly what the notebook cards do (the same functions, the same files).

    exakit semantic models                                      every model, and which the kit built
    exakit semantic fields <MODEL>                              its metrics and dimensions, with what each is
    exakit semantic search "<words>" [--model M]                the fields that match, best first
    exakit semantic compile '<request json>' | --request-file F the SQL a structured request compiles to, and how
    exakit semantic verify <MODEL> --object O --name N --question "..." --request '<json>'
    exakit semantic verified <MODEL>                            its verified questions
    exakit semantic fuse <MODEL> --table S.T --same-as S.T [--key COL] [--wins model|other] [--apply]
    exakit semantic fuse <MODEL> --document F [--apply]         a fusion document of your own
    exakit semantic fusion <MODEL>                              its whole fusion layer, exported
    exakit semantic column-maps <MODEL>                         the approved column maps the model carries
    exakit semantic restore-maps <MODEL> [--write]              the kit's store put back from the model
    exakit semantic refresh <MODEL>                             changed in place, or rebuilt when it is gone
    exakit semantic plan <MODEL> --table S.T... [--link S.T.COL=S.T.KEY]...   every statement saving it runs
    exakit semantic run <MODEL> --sql-file F                    your own version of those statements
    exakit semantic adopt <MODEL> <SCHEMA.VIEW> [--dry-run]     a view you already wrote, made a semantic view
    exakit semantic draft --table S.T [--table ...]             your AI drafts the data map (nothing saved)
    exakit semantic validate <MODEL>                            what Semantic Views finds wrong with it
    exakit semantic versions <MODEL>                            every saved version, kept in the model
    exakit semantic restore-version <MODEL> <N>                 save version N again (it becomes the newest)
    exakit semantic totals <MODEL> [--store VIEW --metric M... --dimension D... [--name N] [--max-age "6 HOURS"]]
    exakit semantic totals <MODEL> --refresh N | --off N | --on N   pre-built totals for speed
    exakit semantic freeze <SCHEMA.NAME> --sql "SELECT ... FROM SEMANTIC_X.V ..."   a view for BI tools
    exakit semantic frozen <MODEL> [--sync]                     the frozen views, stale ones retired with --sync
    exakit semantic governance <MODEL> open|governed            report, or refuse, unprotected sources
    exakit semantic composition <MODEL> on|off                  semantic views joined like tables in plain SQL
    exakit semantic logging [on|off] [--session]                Semantic Views' query log
    exakit semantic history [--limit N]                         what was asked, newest first
    exakit semantic suggestions <MODEL> [--all]                 suggested changes waiting for review
    exakit semantic propose <MODEL> --kind K --object-type T [--object O] --change '<json>' --why "..."
    exakit semantic review <ID> certified|rejected --why "..."
    exakit semantic import-databricks <MODEL> --file F [--apply]
    exakit semantic import-osi --file F
    exakit semantic explain <MODEL> <VIEW> <METRIC>             a metric as Semantic Views explains it

    exakit board list | show <NAME>
    exakit board starter [NAME] [--rules '{"GROUPS": 5}']       a page per approved table, from the column maps (default: overview)
    exakit board pin <NAME> --page P --question "..." --sql "SELECT ..." | --sql-file F [--title T] [--kind K]
    exakit board edit <NAME> <TILE> --sql "SELECT ..."          your own SQL for a tile
    exakit board move <NAME> <TILE> <PAGE> | remove <NAME> <TILE> | kind <NAME> <TILE> <kpi|bar|line|table>
    exakit board recheck <NAME> [--update]                      tiles from your data map compiled again: what changed
    exakit board preview <NAME> [--rules '{...}'] [--app-file F] a health-checked preview on Dash Server
    exakit board publish <NAME> --figures-checked [--app-file F]  live, after a person checked the preview's figures

Every command takes --json (one object on stdout). A fusion is a dry run unless --apply; restore-maps writes only
with --write; publish needs --figures-checked. Pinning SQL to a board is the approval of that SQL: show it to the user
and pin it only after their yes. Exit codes: 0 ok; 2 bad arguments or a refusal; 3 not found; 4 not reachable.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
PACKAGE = HERE.parent.parent / "notebook" / "package"
if PACKAGE.is_dir() and str(PACKAGE) not in sys.path:
    sys.path.insert(0, str(PACKAGE))

import describe_service as svc  # noqa: E402

FLAGS = {"--json": "json", "--sync": "sync", "--session": "session", "--all": "all", "--apply": "apply", "--dry-run": "dry_run", "--update": "update", "--write": "write", "--figures-checked": "figures_checked"}
VALUED = {"--model", "--store", "--metric", "--dimension", "--max-age", "--refresh", "--off", "--on", "--limit", "--kind", "--object-type", "--object", "--change", "--why", "--file", "--app-file", "--rules", "--link", "--object", "--name", "--question", "--request", "--request-file", "--table", "--same-as", "--key", "--wins",
          "--document", "--page", "--sql", "--sql-file", "--title", "--kind"}


class Refused(svc.Refused):
    pass


def parse(args: list[str]) -> tuple[list[str], dict[str, Any]]:
    words: list[str] = []
    opts: dict[str, Any] = {}
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in FLAGS:
            opts[FLAGS[arg]] = True
        elif arg in VALUED:
            if i + 1 >= len(args):
                raise Refused(f"{arg} needs a value.")
            key = arg[2:].replace("-", "_")
            opts[key] = f"{opts[key]},{args[i + 1]}" if key in ("table", "link", "metric", "dimension") and opts.get(key) else args[i + 1]
            i += 1
        elif arg.startswith("--"):
            raise Refused(f"Unknown option '{arg}'. See: exakit help {'semantic' if 'semantic' in sys.argv[1:2] else 'board'}")
        else:
            words.append(arg)
        i += 1
    return words, opts


def _need(words: list[str], count: int, usage: str) -> list[str]:
    if len(words) != count:
        raise Refused(f"Usage: {usage}")
    return words


def _json_arg(opts: dict[str, Any], words: list[str] | None = None, name: str = "request") -> dict[str, Any]:
    text = opts.get(name)
    if opts.get(f"{name}_file"):
        text = Path(opts[f"{name}_file"]).expanduser().read_text(encoding="utf-8")
    elif text is None and words:
        text = words[0]
    try:
        found = json.loads(text or "")
    except ValueError as err:
        raise Refused(f"The {name} is not JSON ({err}).") from err
    if not isinstance(found, dict):
        raise Refused(f"The {name} is a JSON object: {{...}}.")
    return found


def _connected(work):
    conn = svc.connect()
    try:
        return work(conn)
    finally:
        conn.close()


# --- exakit semantic -----------------------------------------------------------------------------------------------

def semantic(action: str, words: list[str], opts: dict[str, Any]) -> tuple[Any, str]:
    if action == "models":
        found = _connected(svc.list_models)
        return found, "\n".join(f"{m['model']:<24} {m['published_schema']:<28} {'kit' if m['kit'] else 'not the kit'}  "
                                f"{m['description']}" for m in found) or "No semantic models yet."
    if action == "fields":
        model, = _need(words, 1, "exakit semantic fields <MODEL>")
        found = _connected(lambda c: svc.model_fields(c, model))
        return found, "\n".join(f"{f['object']:<20} {f['kind']:<10} {f['name']:<32} {f['about']}" for f in found) or "No fields."
    if action == "search":
        if not words:
            raise Refused('Usage: exakit semantic search "<words>" [--model M]')
        text = " ".join(words)
        found = _connected(lambda c: svc.search_fields(c, text, opts.get("model")))
        return found, "\n".join(f"{f['model']:<16} {f['object']:<18} {f['kind']:<10} {f['name']:<30} {f['about']}"
                                for f in found) or f"Nothing in your data map matches '{text}'."
    if action == "compile":
        request = _json_arg(opts, words)
        found = _connected(lambda c: svc.compile_request(c, request))
        return found, found["sql"] + "".join(f"\n-- {line}" for line in found.get("explained") or []) if found["status"] == "ok" else (
            f"Refused: {found['error']}" + (f"\nChoices: {json.dumps(found['clarification'])}" if found.get("clarification") else ""))
    if action == "verify":
        model, = _need(words, 1, "exakit semantic verify <MODEL> --object O --name N --question \"...\" --request '<json>'")
        for key in ("object", "name", "question"):
            if not opts.get(key):
                raise Refused(f"--{key} is needed.")
        request = _json_arg(opts)
        found = _connected(lambda c: svc.verify_question(c, model, opts["object"], opts["name"], opts["question"], request))
        return found, f"Kept as a verified question of {model}: {opts['name']}\n{found['sql']}"
    if action == "verified":
        model, = _need(words, 1, "exakit semantic verified <MODEL>")
        found = _connected(lambda c: svc.verified_questions(c, model))
        return found, "\n".join(f"{q['name']}: {q['question']}" for q in found) or "No verified questions yet."
    if action == "fuse":
        model, = _need(words, 1, "exakit semantic fuse <MODEL> --table S.T --same-as S.T [--key COL] [--wins model|other] [--apply]")
        if opts.get("table") and "," in opts["table"]:
            raise Refused("fuse takes one --table: the model's table that the other source copies.")

        def work(conn):
            if opts.get("document"):
                try:
                    document = json.loads(Path(opts["document"]).expanduser().read_text(encoding="utf-8"))
                except ValueError as err:
                    raise Refused(f"The fusion document is not JSON ({err}).") from err
            else:
                if not (opts.get("table") and opts.get("same_as")):
                    raise Refused("Name the model's table (--table) and its copy in another source (--same-as), or give --document.")
                wins = opts.get("wins") or "model"
                if wins not in ("model", "other"):
                    raise Refused("--wins is model (the model's table wins) or other.")
                document = svc.fusion_document(conn, model, opts["table"], opts["same_as"], key=opts.get("key"), wins=wins)
            result = svc.fuse(conn, model, document, dry_run=not opts.get("apply"))
            return dict(result, document=result.get("document") or document)
        found = _connected(work)
        state = ("Applied" if not found["dry_run"] else "Checked, nothing changed") if found["status"] != "error" else "Refused"
        return found, (f"{state}: {found['status']}" + (f" - {found['message']}" if found.get("message") else "")
                       + ("\nApply it with --apply after the user agrees." if found["dry_run"] and found["status"] != "error" else ""))
    if action == "fusion":
        model, = _need(words, 1, "exakit semantic fusion <MODEL>")
        found = _connected(lambda c: svc.fusion(c, model))
        return found, json.dumps(found, indent=2) if found else f"{model} has no fusion."
    if action == "column-maps":
        model, = _need(words, 1, "exakit semantic column-maps <MODEL>")
        found = _connected(lambda c: svc.column_maps_in_model(c, model))
        return found, "\n".join(f"{t}: v{m['version']}" for t, m in sorted(found.items())) or "No column maps in the model."
    if action == "restore-maps":
        model, = _need(words, 1, "exakit semantic restore-maps <MODEL> [--write]")
        found = _connected(lambda c: svc.restore_column_maps(c, model, write=bool(opts.get("write"))))
        return found, "\n".join(f"{r['table']}: v{r['version']} - {r['action']}" for r in found) or "Nothing to restore."
    if action == "plan":
        model, = _need(words, 1, "exakit semantic plan <MODEL> --table S.T [--table ...] [--link S.T.COL=S.T.KEY]")
        tables = [t for t in (opts.get("table") or "").split(",") if t]
        links = [l for l in (opts.get("link") or "").split(",") if l]
        found = _connected(lambda c: svc.semantic_model(c, model, tables, links, dry_run=True))
        return found["sql"], ";\n\n".join(found["sql"]) + ";"
    if action == "run":
        model, = _need(words, 1, "exakit semantic run <MODEL> --sql-file F")
        if not opts.get("sql_file"):
            raise Refused("--sql-file is needed: the statements (as plan printed them, edited), each ending in ;")
        text = Path(opts["sql_file"]).expanduser().read_text(encoding="utf-8")
        statements = [p.strip() for p in text.split(";\n") if p.strip().rstrip(";")]
        found = _connected(lambda c: svc.semantic_model(c, model, [], statements=[p.rstrip(";") for p in statements]))
        return found, f"Ran {len(statements)} statements for {model}."
    if action == "totals":
        model, = _need(words, 1, "exakit semantic totals <MODEL> [--store VIEW --metric M --dimension D] | --refresh N | --off N | --on N")
        listed = lambda key: [x for x in (opts.get(key) or "").split(",") if x]
        if opts.get("store"):
            found = _connected(lambda c: svc.store_totals(c, model, opts["store"], listed("metric"), listed("dimension"),
                                                          name=opts.get("name"), max_age=opts.get("max_age") or "1 DAYS"))
            return found, f"Stored {found['table']} and registered it with {model}; refresh it with --refresh {found['name']}."
        for key, status in (("refresh", None), ("off", "INACTIVE"), ("on", "ACTIVE")):
            if opts.get(key):
                found = _connected(lambda c: svc.refresh_totals(c, model, opts[key]) if status is None
                                   else svc.totals_status(c, model, opts[key], status))
                return found, f"{opts[key]}: {'refreshed' if status is None else status.lower()}."
        found = _connected(lambda c: svc.list_totals(c, model))
        return found, "\n".join(json.dumps(r, default=str) for r in found) or f"{model} has no stored totals."
    if action == "freeze":
        view, = _need(words, 1, "exakit semantic freeze <SCHEMA.NAME> --sql \"SELECT ... FROM SEMANTIC_X.V\"")
        found = _connected(lambda c: svc.freeze_view(c, view, opts.get("sql") or ""))
        return found, f"Frozen: {found['view']} answers for anyone with SELECT on it, no preprocessor needed."
    if action == "frozen":
        model, = _need(words, 1, "exakit semantic frozen <MODEL> [--sync]")
        found = _connected(lambda c: svc.frozen_views(c, model, sync=bool(opts.get("sync"))))
        return found, "\n".join(f"{v['status']:<10} {v['view']} {v['detail']}".rstrip() for v in found) or "No frozen views."
    if action == "governance":
        model, mode = _need(words, 2, "exakit semantic governance <MODEL> open|governed")
        found = _connected(lambda c: svc.governance_mode(c, model, mode))
        return found, f"{model} is {found['mode']}; Semantic Views finds {found['errors']} error(s)." + "".join(
            f"\n{i['severity']} {i['rule']}: {i['message']}" for i in found["issues"])
    if action == "composition":
        model, state = _need(words, 2, "exakit semantic composition <MODEL> on|off")
        if state not in ("on", "off"):
            raise Refused("composition is on or off.")
        found = _connected(lambda c: svc.derived_composition(c, model, state == "on"))
        return found, f"Joining {model}'s semantic views in plain SQL: {state}."
    if action == "logging":
        if len(words) > 1 or (words and words[0] not in ("on", "off")):
            raise Refused("Usage: exakit semantic logging [on|off] [--session]")
        on = None if not words else words[0] == "on"
        found = _connected(lambda c: svc.query_logging(c, on, "SESSION" if opts.get("session") else "DEPLOYMENT"))
        return found, f"Query logging: {found['effective']} (database {found['deployment']}, this session {found['session'] or 'as the database'})."
    if action == "history":
        found = _connected(lambda c: svc.query_history(c, int(opts.get("limit") or 50)))
        return found, "\n".join(json.dumps(r, default=str) for r in found["requests"] + found["statements"]) or "Nothing logged yet."
    if action == "suggestions":
        model, = _need(words, 1, "exakit semantic suggestions <MODEL> [--all]")
        found = _connected(lambda c: svc.suggestions(c, model, not opts.get("all")))
        return found, "\n".join(json.dumps(r, default=str) for r in found) or "No suggestions waiting."
    if action == "propose":
        model, = _need(words, 1, "exakit semantic propose <MODEL> --kind K --object-type T [--object O] --change '<json>' --why \"...\"")
        change = _json_arg(opts, name="change")
        found = _connected(lambda c: svc.propose_change(c, model, opts.get("kind") or "", opts.get("object_type") or "",
                                                        opts.get("object"), change, opts.get("why") or ""))
        return found, f"Suggestion {found['id']} kept for review ({found['status']})."
    if action == "review":
        number, decision = _need(words, 2, "exakit semantic review <ID> certified|rejected --why \"...\"")
        if not number.isdigit():
            raise Refused("The suggestion id is a number, as exakit semantic suggestions lists it.")
        found = _connected(lambda c: svc.review_change(c, int(number), decision, opts.get("why") or ""))
        return found, f"Suggestion {number}: {found['status']}."
    if action == "import-databricks":
        model, = _need(words, 1, "exakit semantic import-databricks <MODEL> --file F [--apply]")
        if not opts.get("file"):
            raise Refused("--file is needed: the metric view's YAML.")
        text = Path(opts["file"]).expanduser().read_text(encoding="utf-8")
        found = _connected(lambda c: svc.import_databricks(c, model, text, apply=bool(opts.get("apply"))))
        return found, (found.get("ddl") or "") + (f"\n{found['error']}" if found.get("error") else "") + (
            "" if found["applied"] else "\nCreate it with --apply after the user agrees.")
    if action == "import-osi":
        if not opts.get("file"):
            raise Refused("--file is needed: the OSI import plan (JSON).")
        try:
            plan = json.loads(Path(opts["file"]).expanduser().read_text(encoding="utf-8"))
        except ValueError as err:
            raise Refused(f"The plan is not JSON ({err}).") from err
        found = _connected(lambda c: svc.import_osi(c, plan))
        return found, "\n".join(f"{r['status']:<10} {r['operation'] or ''} {r['target'] or ''} {r['message']}".rstrip() for r in found)
    if action == "versions":
        model, = _need(words, 1, "exakit semantic versions <MODEL>")
        found = _connected(lambda c: svc.data_map_versions(c, model))
        return found, "\n".join(f"v{v['version']:<4} {v['saved_at'] or '':<22} {v['tables']} tables, {v['links']} links, "
                                f"{v['metrics']} metrics" for v in found) or f"{model} has no saved versions yet."
    if action == "restore-version":
        model, number = _need(words, 2, "exakit semantic restore-version <MODEL> <N>")
        if not number.lstrip("v").isdigit():
            raise Refused("The version is a number, as exakit semantic versions lists it.")
        found = _connected(lambda c: svc.restore_data_map(c, int(number.lstrip("v")), model))
        return found, f"Saved version {number} again as version {found.get('version')}."
    if action == "validate":
        model, = _need(words, 1, "exakit semantic validate <MODEL>")
        found = _connected(lambda c: svc.validate_model(c, model))
        lines = [f"{i['severity']:<12} {i['object_type']} {i['object']} {i['rule']}: {i['message']}" for i in found["issues"]]
        lines += [f"TYPE         {t['object']}.{t['metric']}: declared {t['declared']}, returns {t['compiled']} {t['error']}".rstrip()
                  for t in found["types"]]
        lines += [f"SUGGESTION   {x['type']} {x['object']} ({x['reason']}): {x['proposed']}" for x in found["suggestions"]]
        return found, "\n".join(lines) or f"Semantic Views finds nothing wrong with {found['model']}."
    if action == "explain":
        model, view, metric = _need(words, 3, "exakit semantic explain <MODEL> <VIEW> <METRIC>")
        found = _connected(lambda c: svc.explain_metric(c, model, view, metric))
        return found, "\n".join(f"{r['section']:<14} {r['item']}: {r['detail']}" for r in found) or "Nothing to say."
    if action == "draft":
        tables = [t for t in (opts.get("table") or "").split(",") if t]
        if not tables:
            raise Refused("Name the tables: exakit semantic draft --table S.T --table S.T")
        found = svc.draft_data_map(tables)
        return found, json.dumps(found, indent=2, ensure_ascii=False)
    if action == "adopt":
        model, view = _need(words, 2, "exakit semantic adopt <MODEL> <SCHEMA.VIEW> [--dry-run]")
        found = _connected(lambda c: svc.adopt_view(c, model, view, dry_run=bool(opts.get("dry_run"))))
        if found["status"] == "dry_run":
            return found, (f"{view} as written:\n{found['view_sql']}\n\nAdopting it runs:\n{found['sql']};"
                           "\nRun it again without --dry-run after the user agrees.")
        return found, (f"Adopted {view} into {found['model']} as {found['object']}: {found['dimensions']} dimensions, "
                       f"{found['metrics']} metrics ({found['status']}).\nAsk it: exakit semantic fields {found['model']}")
    if action == "refresh":
        model, = _need(words, 1, "exakit semantic refresh <MODEL>")
        found = _connected(lambda c: svc.refresh_model(c, model))
        return found, f"Refreshed {found['view']} ({found.get('mode', 'rebuilt')})"
    raise Refused(f"Unknown action '{action}' (models, fields, search, compile, verify, verified, fuse, fusion, column-maps, "
                  "restore-maps, refresh, plan, run, adopt, draft, validate, explain, versions, restore-version, totals, freeze, frozen, governance, composition, logging, history, suggestions, propose, review, import-databricks, import-osi).")


# --- exakit board -----------------------------------------------------------------------------------------------------

def _preview_state(name: str) -> Path:
    import importlib

    return importlib.import_module("exakit_nb.board")._folder() / f"{name}.preview.json"


def board(action: str, words: list[str], opts: dict[str, Any]) -> tuple[Any, str]:
    import importlib

    boards = importlib.import_module("exakit_nb.board")
    if action == "list":
        found = boards.boards()
        return found, "\n".join(f"{b['name']:<24} {b['pages']} pages, {b['tiles']} tiles  {b['title']}" for b in found) \
            or "No dashboards yet: exakit board pin <NAME> --page P --question ... --sql ..."
    if action == "starter":
        name = (words or ["overview"])[0]
        from exakit_nb.workflow import continue_workflow

        continue_workflow("board")
        rules = _json_arg(opts, name="rules") if opts.get("rules") else None
        b = _connected(lambda c: boards.starter_board(c, name=name, rules=rules))
        return {"name": b.name, "title": b.title, "pages": b.pages}, f"{b}\nPreview it: exakit board preview {b.name}"
    if action == "show":
        name, = _need(words, 1, "exakit board show <NAME>")
        b = boards.board(name)
        return {"name": b.name, "title": b.title, "pages": b.pages}, str(b)
    if action == "pin":
        name, = _need(words, 1, "exakit board pin <NAME> --page P --question \"...\" --sql \"SELECT ...\"")
        if not opts.get("question") or not (opts.get("sql") or opts.get("sql_file")):
            raise Refused("--question and --sql (or --sql-file) are needed: the SQL the user approved.")
        from exakit_nb.ask import _read_sql

        sql = opts.get("sql") or Path(opts["sql_file"]).expanduser().read_text(encoding="utf-8")
        statement = _read_sql(sql)
        approved = type("Approved", (), {"question": opts["question"], "sql": statement, "request": None, "dataset": None,
                                         "_approved_digest": hashlib.sha256(statement.encode("utf-8")).hexdigest()})()
        answer = None
        try:                                     # its shape, through the read-only service: the tile's kind and filters
            import pandas as pd
            from exakit_nb.ask import _execute_mcp

            ran = _execute_mcp(statement)
            answer = pd.DataFrame(ran["rows"], columns=ran["columns"])
        except Exception:
            answer = None
        from exakit_nb.workflow import continue_workflow

        continue_workflow("board")
        tile = boards.pin(approved, answer, board=name, page=opts.get("page") or "Overview", title=opts.get("title"),
                          kind=opts.get("kind"))
        return tile, f"Pinned to {name} / {opts.get('page') or 'Overview'} as a {tile['kind']} (tile {tile['id']})."
    if action == "recheck":
        name, = _need(words, 1, "exakit board recheck <NAME> [--update]")
        found = _connected(lambda c: boards.board(name).recheck(c, update=bool(opts.get("update"))))
        changed = [f for f in found if f["state"] != "same"]
        text = "\n".join(f"[{f['id']}] {f['page']} / {f['title']}: {f['state']}"
                         + (f"\n{f['sql']}" if f.get("sql") else "") + (f" ({f['reason']})" if f.get("reason") else "")
                         for f in changed)
        if not found:
            text = f"{name} has no tile answered from your data map."
        elif not changed:
            text = f"Every tile of {name} answered from your data map compiles as it was pinned."
        elif not opts.get("update") and any(f["state"] == "changed" for f in changed):
            text += "\nTake the new SQL with --update after the user agrees."
        return found, text
    if action == "edit":
        name, tile = _need(words, 2, "exakit board edit <NAME> <TILE> --sql \"SELECT ...\" | --sql-file F")
        if not (opts.get("sql") or opts.get("sql_file")):
            raise Refused("--sql (or --sql-file) is needed: the tile's new SQL, which the user approved.")
        sql = opts.get("sql") or Path(opts["sql_file"]).expanduser().read_text(encoding="utf-8")
        b = boards.board(name)
        try:
            b.edit(tile, sql, title=opts.get("title"))
        except KeyError as err:
            raise svc.NotFound(str(err).strip("'\"")) from err
        except ValueError as err:
            raise Refused(str(err)) from err
        b.save()
        return {"name": b.name, "pages": b.pages}, str(b)
    if action in ("move", "remove", "kind"):
        usage = {"move": "exakit board move <NAME> <TILE> <PAGE>", "remove": "exakit board remove <NAME> <TILE>",
                 "kind": "exakit board kind <NAME> <TILE> <kpi|bar|line|table>"}[action]
        parts = _need(words, 2 if action == "remove" else 3, usage)
        b = boards.board(parts[0])
        try:
            if action == "move":
                b.move(parts[1], parts[2])
            elif action == "remove":
                b.remove(parts[1])
            else:
                b.show_as(parts[1], parts[2])
        except KeyError as err:
            raise svc.NotFound(str(err).strip("'\"")) from err
        except ValueError as err:
            raise Refused(str(err)) from err
        b.save()
        return {"name": b.name, "pages": b.pages}, str(b)
    if action == "preview":
        name, = _need(words, 1, "exakit board preview <NAME>")
        from exakit_nb.dash_mcp import dash_tools
        from exakit_nb.workflow import continue_workflow

        continue_workflow("board")
        b = boards.board(name)
        if opts.get("rules"):
            b.rules = {**b.rules, **_json_arg(opts, name="rules")}
            b.save()
        app = Path(opts["app_file"]).expanduser().read_text(encoding="utf-8") if opts.get("app_file") else None
        draft = b.share(app=app)
        tools = dash_tools()
        path = draft.preview(tools)
        state = {"name": name, "app": draft.name, "revision": draft.revision_number, "query_digest": draft.query_digest,
                 "workflow_id": draft.workflow_id, "preview": tools.url + path}
        _preview_state(name).write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        return state, f"Preview (healthy): {state['preview']}\nCheck the figures, then: exakit board publish {name} --figures-checked"
    if action == "publish":
        name, = _need(words, 1, "exakit board publish <NAME> --figures-checked")
        if not opts.get("figures_checked"):
            raise Refused("Publish only after a person opened the preview and checked the figures: --figures-checked.")
        try:
            state = json.loads(_preview_state(name).read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            raise Refused(f"Make a preview first: exakit board preview {name}") from err
        from exakit_nb.dash_mcp import dash_tools
        from exakit_nb.workflow import continue_workflow

        continue_workflow("board")
        app = Path(opts["app_file"]).expanduser().read_text(encoding="utf-8") if opts.get("app_file") else None
        draft = boards.board(name).share(app=app)
        if draft.query_digest != state["query_digest"]:
            raise Refused(f"{name} changed since its preview: preview it again (exakit board preview {name}).")
        draft.revision_number, draft.healthy = state["revision"], True     # the preview this person checked
        tools = dash_tools()
        route = draft.confirm(tools, figures_checked=True)
        return {"name": name, "live": tools.url + route}, f"Live: {tools.url + route}"
    raise Refused(f"Unknown action '{action}' (list, starter, show, pin, edit, recheck, move, remove, kind, preview, publish).")


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0 if len(argv) >= 2 else 2
    group, action = argv[0], argv[1]
    try:
        words, opts = parse(argv[2:])
        import contextlib

        # what the functions say on their way (a workflow resumed, a tile pinned) goes to stderr: stdout is the answer
        with contextlib.redirect_stdout(sys.stderr):
            if group == "semantic":
                found, text = semantic(action, words, opts)
            elif group == "board":
                found, text = board(action, words, opts)
            else:
                raise Refused(f"Unknown group '{group}' (semantic, board).")
    except (svc.Refused, svc.NotFound, svc.Unreachable, svc.Conflict) as err:
        print(str(err), file=sys.stderr)
        return getattr(err, "code", 2)
    except (RuntimeError, ValueError, OSError) as err:
        print(str(err).splitlines()[0] if str(err) else type(err).__name__, file=sys.stderr)
        return 1
    print(json.dumps(found, indent=2, ensure_ascii=False, default=str) if opts.get("json") else text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
