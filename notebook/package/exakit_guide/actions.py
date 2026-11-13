"""Every thing a guided card does, as the exact notebook code that does it.

An Action is one or more lines of `exakit.nb` code with {placeholders}. The card's button, the code it shows in Code
mode and what it runs are the same text, so they cannot differ:

    code("kit.addon", addon="dash-server")    ->  nb.addon_ready("dash-server")
    run("kit.addon", addon="dash-server")     ->  runs exactly that line in the notebook's namespace, logs it

Placeholders take plain values (rendered as Python literals: strings, numbers, lists, dicts), or Var("name") for a
variable the notebook already has (`ideas[2]`, `chosen_data`). A secret - a password, an API key - is never written
into the code: {secret} renders as nothing in the code shown, and only at run time as `**__secret__`, which binds the
same keyword argument the hidden prompt would have answered (`ask=`, `secret=`).

Adding a capability to the guided view = one entry here (and its cell in the notebook: tests/test_notebook_guide.py
checks every action's call is in its notebook's code section).
"""

from __future__ import annotations

import re
import string
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Var:
    """A variable of the notebook (or an expression over one), written into the code as it is."""

    expr: str


@dataclass(frozen=True)
class Action:
    notebook: str           # the notebook whose code section holds this call (00_quickstart, 01_explore, ...)
    code: str               # the cell text, with {placeholders}
    result: str | None = None   # the variable the code assigns, returned by run()
    changes: bool = True    # False: it only reads (the kit's state, the data)


ACTIONS: dict[str, Action] = {
    # -- the kit: what is there (reads) ------------------------------------------------------------------------------
    "kit.check": Action("00_quickstart", "kit_state = nb.kit_check()", "kit_state", False),
    "kit.components": Action("00_quickstart", "components = nb.components()", "components", False),
    "kit.addons": Action("00_quickstart", "addons = nb.addons()", "addons", False),
    "kit.ai_clients": Action("00_quickstart", "ai_clients = nb.ai_clients()", "ai_clients", False),
    "kit.datasets": Action("00_quickstart", "sample_datasets = nb.sample_datasets()", "sample_datasets", False),
    "kit.loaded_files": Action("00_quickstart", "loaded_files = nb.loaded_files()", "loaded_files", False),
    "kit.notebooks": Action("00_quickstart", "notebooks = nb.notebooks({persona})", "notebooks", False),
    "kit.model": Action("00_quickstart", "model = nb.model_settings()", "model", False),
    "kit.tracing": Action("00_quickstart", "tracing = nb.tracing()", "tracing", False),
    "kit.persona_plan": Action("00_quickstart", "persona_plan = nb.persona_plan()", "persona_plan", False),
    "kit.approved": Action("00_quickstart", "approved = nb.approved_datasets()", "approved", False),
    "kit.workflows": Action("00_quickstart", "workflows = nb.list_workflows()", "workflows", False),
    "kit.workflow_log": Action("00_quickstart", "workflow_events = nb.workflow_log({workflow_id})", "workflow_events", False),
    # -- the kit: what changes it ------------------------------------------------------------------------------------
    "kit.start": Action("00_quickstart", 'nb.exakit("start")'),
    "kit.start_service": Action("00_quickstart", 'nb.exakit("start", {service})'),
    "kit.logs": Action("00_quickstart", 'nb.exakit("logs", {service})', changes=False),
    "kit.addon": Action("00_quickstart", "nb.addon_ready({addon})"),
    "kit.mcp_doctor": Action("00_quickstart", 'nb.exakit("mcp-doctor")', changes=False),
    "kit.data_load": Action("00_quickstart", 'nb.exakit("data-load", {what})'),
    "kit.data_load_into": Action("00_quickstart", 'nb.exakit("data-load", {what}, env={{"EXAKIT_SCHEMA": {schema}}})'),
    "kit.update": Action("00_quickstart", "nb.kit_update()"),
    "kit.update_one": Action("00_quickstart", "nb.kit_update({component})"),
    "model.use": Action("00_quickstart", "nb.use_model({model_id}, {base_url}, remember=True{secret})"),
    "model.providers": Action("00_quickstart", "providers = nb.model_providers()", "providers", False),
    "model.list": Action("00_quickstart", "models = nb.provider_models({provider}, base_url={base_url}{secret})", "models", False),
    "model.use_effort": Action("00_quickstart", "nb.use_model({model_id}, {base_url}, effort={effort}, remember=True{secret})"),
    "model.langfuse": Action("00_quickstart", "nb.use_model(langfuse_base_url={langfuse_url}, remember=True{secret})"),
    "model.forget": Action("00_quickstart", "nb.forget_model(model={model}, langfuse={langfuse})"),
    # -- step 1: access and understand ------------------------------------------------------------------------------
    "data.workflow": Action("00_quickstart", 'workflow_id = nb.workflow("data-scientist-quickstart")', "workflow_id"),
    "data.connect": Action("00_quickstart", "connection = nb.connect()\nnb.check_connection(connection)", "connection"),
    "data.sample": Action("00_quickstart", "sample_data = nb.load_sample(connection, {dataset_id})", "sample_data"),
    "data.own_file": Action("00_quickstart", "own_data = nb.load_own_file({path}, {schema}, conn=connection)", "own_data"),
    "data.table": Action("00_quickstart", "own_data = nb.use_table(connection, {table})", "own_data"),
    "data.approved": Action("00_quickstart", "own_data = nb.dataset(connection, {dataset_id})", "own_data"),
    "data.connect_source": Action("00_quickstart", "connected = nb.connect_source({connector}, {name}{settings}{secret})", "connected"),
    "data.source_tips": Action("00_quickstart", 'source_tips = nb.source_engine("catalog", "--public-ip")["events"]',
                               "source_tips", False),
    "data.read_string": Action("00_quickstart", "source_reading = nb.read_connection_string({connector}, {text}{settings})", "source_reading", False),
    "data.test_source": Action("00_quickstart", "source_test = nb.test_source({connector}, {name}{settings})", "source_test", False),
    "data.connector_form": Action("00_quickstart", "connector_forms[{connector}] = nb.connector_inputs({connector}{settings})",
                                  "connector_forms", False),
    "data.connector_forms": Action("00_quickstart", 'connector_forms = {{c["id"]: nb.connector_inputs(c["id"]) for c in connectors}}',
                                   "connector_forms", False),
    "data.source": Action("00_quickstart", "source_data = nb.load_source(connection, {source})", "source_data"),
    "data.choose": Action("00_quickstart", "chosen_data = {data}", "chosen_data", False),
    # several tables chosen at once: each is kept by its table name, and one of them is the one being worked on
    "data.several": Action("00_quickstart", "chosen_tables = {{}}", "chosen_tables", False),
    "data.keep": Action("00_quickstart", "chosen_tables[{table}] = {data}", "chosen_tables", False),
    "data.switch": Action("00_quickstart", "chosen_data = chosen_tables[{table}]", "chosen_data", False),
    "data.map": Action("00_quickstart", "data_map = nb.data_map(connection)", "data_map", False),
    "data.connectors": Action("00_quickstart", "connectors = nb.connectors()", "connectors", False),
    "semantic.models": Action("00_quickstart", "semantic_models = nb.semantic_models(connection)", "semantic_models", False),
    "semantic.preview": Action("00_quickstart", "semantic = nb.semantic_model(connection, {name}, tables={tables}, "
                               "links={links}, ai={ai}, preview=True)", "semantic", False),
    "semantic.publish": Action("00_quickstart", "semantic = nb.semantic_model(connection, {name}, tables={tables}, "
                               "links={links}, ai={ai}, preview=False)", "semantic"),
    "semantic.links": Action("00_quickstart", "found_links = nb.find_links(connection, {schemas}, ai={ai})", "found_links", False),
    "semantic.preview_schemas": Action("00_quickstart", "semantic = nb.semantic_model(connection, {name}, schemas={schemas}, "
                                       "links={links}, ai={ai}, preview=True)", "semantic", False),
    "semantic.publish_schemas": Action("00_quickstart", "semantic = nb.semantic_model(connection, {name}, schemas={schemas}, "
                                       "links={links}, ai={ai}, preview=False)", "semantic"),
    "semantic.refresh": Action("00_quickstart", "refreshed = nb.refresh_semantic(connection, {name})", "refreshed"),
    "map.review": Action("00_quickstart", "role_review = nb.review_roles(connection, chosen_data)", "role_review"),
    "map.approve": Action("00_quickstart", "role_review.approve({choices}, {slots}, notes={notes})\ndataset = role_review.dataset()", "dataset"),
    "map.ai_check": Action("00_quickstart", "ai_map = nb.fill_column_map(role_review)", "ai_map", False),
    "map.keep": Action("00_quickstart", "dataset = role_review.dataset()", "dataset", False),
    "map.draft": Action("00_quickstart", "draft_dataset = role_review.dataset(draft_ok=True)", "draft_dataset", False),
    "map.leakage": Action("00_quickstart", "leaking = nb.leakage_check(connection, {data})", "leaking", False),
    "map.versions": Action("00_quickstart", "versions = nb.column_map_versions({dataset_id})", "versions", False),
    "map.first_result": Action("00_quickstart", "first_rows = nb.sql(connection, {sql})", "first_rows", False),
    "map.first_overall": Action("00_quickstart", "first_overall = nb.sql(connection, {sql})", "first_overall", False),
    "map.first_note": Action("00_quickstart", "first_note = nb.note_groups(first_rows, dataset, {group}, {count}, {pct}, overall={overall})",
                             "first_note", False),
    # -- step 2: prepare, explore, model ----------------------------------------------------------------------------
    "explore.open": Action("01_explore", 'workflow_id = nb.continue_workflow("explore")\n'
                                          "dataset = nb.dataset(connection, nb.chosen_dataset({dataset_id}))", "dataset"),
    "explore.checks": Action("01_explore", "findings = nb.data_checks(connection, dataset)", "findings", False),
    "explore.schema": Action("01_explore", "schema_map = nb.describe_schema(connection, dataset)\n"
                                            "joined_view_proposal = schema_map.joined_view(dataset)", "joined_view_proposal", False),
    "explore.join": Action("01_explore", "dataset = joined_view_proposal.create(connection)", "dataset"),
    "explore.typed": Action("01_explore", "typed_view_proposal = nb.typed_view(connection, dataset)", "typed_view_proposal", False),
    "explore.clean": Action("01_explore", "dataset = typed_view_proposal.create(connection)", "dataset"),
    "explore.count": Action("01_explore", "row_count = nb.sql(connection, {sql})", "row_count", False),
    "explore.groups": Action("01_explore", "groups = nb.sql(connection, {sql})", "groups", False),
    "explore.overall": Action("01_explore", "overall = nb.sql(connection, {sql})", "overall", False),
    "explore.groups_note": Action("01_explore", "groups_note = nb.note_groups(groups, dataset, {group}, {count}, {pct}, overall={overall})",
                                  "groups_note", False),
    "explore.span": Action("01_explore", "date_span = nb.sql(connection, {sql})", "date_span", False),
    "explore.trend": Action("01_explore", "over_time = nb.sql(connection, {sql})", "over_time", False),
    "explore.trend_note": Action("01_explore", "trend_note = nb.note_trend(over_time, dataset, {period}, {count}, {pct})",
                                 "trend_note", False),
    "explore.lab_data": Action("01_explore", "lab_data = nb.lab_data(connection, dataset)\nkept_features = {{}}", "lab_data", False),
    "explore.lab": Action("01_explore", "lab = nb.model_lab(connection, dataset, {task}, model={model}, target_number={target_number}, "
                                        "data=lab_data, features=kept_features{settings})", "lab"),
    "explore.ideas": Action("01_explore", "ideas = nb.feature_ideas(lab, ai={ai}, conn=connection)", "ideas", False),
    "explore.try": Action("01_explore", "tried = nb.try_feature(lab, ideas[{index}])", "tried"),
    "explore.keep": Action("01_explore", 'kept_features[ideas[{index}].id] = tried["series"]', None),
    "explore.drop": Action("01_explore", "kept_features.pop(ideas[{index}].id, None)", None),
    # -- step 3: ask -----------------------------------------------------------------------------------------------
    "ask.open": Action("02_ask_your_data", 'nb.continue_workflow("questions")\n'
                                             "dataset = nb.dataset(connection, nb.chosen_dataset({dataset_id}))\n"
                                             'dataset.require_approved("ask")', "dataset", False),
    "ask.examples": Action("02_ask_your_data", "examples = nb.example_questions(dataset)", "examples", False),
    "ask.model": Action("02_ask_your_data", "proposal = nb.ask(dataset, {question}, conn=connection)", "proposal"),
    "ask.rules": Action("02_ask_your_data", "proposal = nb.draft_question(connection, dataset, {question})", "proposal"),
    "ask.edit": Action("02_ask_your_data", "proposal.edit({sql})", None),
    "ask.run": Action("02_ask_your_data", "proposal.approve()\nanswer = proposal.run()", "answer"),
    # -- step 4: share and hand off ---------------------------------------------------------------------------------
    "share.open": Action("03_share", 'nb.continue_workflow("share")\n'
                                      "dataset = nb.dataset(connection, nb.chosen_dataset({dataset_id}))\n"
                                      'dataset.require_approved("share")', "dataset", False),
    "share.server": Action("03_share", 'dash_server_state = nb.addon_ready("dash-server")', "dash_server_state"),
    "share.draft": Action("03_share", "dashboard_draft = nb.share(dataset, {sql}, {title}, {name}, measure={measure})",
                          "dashboard_draft", False),
    "share.preview": Action("03_share", "dash_server = nb.dash_tools()\npreview_path = dashboard_draft.preview(dash_server)",
                            "preview_path"),
    "share.publish": Action("03_share", "live_path = dashboard_draft.confirm(dash_server, figures_checked=True)", "live_path"),
    "share.handoff": Action("03_share", "handoff = nb.handoff_bundle(connection, dataset)", "handoff"),
}


def _literal(value: Any) -> str:
    """A value as the notebook's cells write it: strings in double quotes, lists and dicts element by element."""
    import json

    if isinstance(value, Var):
        return value.expr
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        inner = ", ".join(_literal(v) for v in value)
        return f"[{inner}]" if isinstance(value, list) else f"({inner}{',' if len(value) == 1 else ''})"
    if isinstance(value, dict):
        return "{" + ", ".join(f"{_literal(k)}: {_literal(v)}" for k, v in value.items()) + "}"
    return repr(value)


class _Values(dict):
    def __missing__(self, key: str) -> str:
        raise KeyError(f"The action needs a value for {{{key}}}.")


def _render(action_id: str, values: dict[str, Any], *, for_run: bool) -> str:
    action = ACTIONS[action_id]
    fields = {name for _, name, _, _ in string.Formatter().parse(action.code) if name}
    rendered = _Values({k: _literal(v) for k, v in values.items() if k in fields and k not in ("secret", "settings")})
    if "secret" in fields:
        rendered["secret"] = ", **__secret__" if for_run and values.get("secret") else ""
    if "settings" in fields:
        rendered["settings"] = "".join(f", {k}={_literal(v)}" for k, v in (values.get("settings") or {}).items()
                                       if v not in (None, ""))
    return action.code.format_map(rendered)


def code(action_id: str, **values: Any) -> str:
    """The exact notebook code of an action with these values (no secret ever appears in it)."""
    return _render(action_id, values, for_run=False)


CELL = "<exakit.guide:cell>"
SHOWN = 6000        # characters of a cell's output a card shows


def _shown(value: Any) -> str:
    """A cell's last value as text, the way a notebook shows it: a table as its first rows, anything else its repr."""
    if value is None:
        return ""
    try:
        if type(value).__name__ in ("DataFrame", "Series") and hasattr(value, "to_string"):
            rows = len(value)
            text = value.head(20).to_string(max_cols=12) if hasattr(value, "head") else value.to_string()
            return text + (f"\n... {rows:,} rows, the first 20 shown" if rows > 20 else "")
    except Exception:
        pass
    return repr(value)


def run_text(text: str, session=None) -> dict[str, Any]:
    """Run code typed into a card's Code view the way a notebook cell runs it: in the notebook's own namespace
    (``nb``, ``connection``, ``dataset`` ... as the cards left them), every line executed, the last expression's value
    kept. A cell that holds a query (SELECT or WITH) runs it with nb.sql on the notebook's connection. Returns
    {ok, text, value}: ``text`` is what it printed and the value's display, or the error in one line
    with the line it happened on. What ran is logged like every card action; an error does not raise."""
    import ast
    import textwrap
    import traceback

    from .session import SESSION, quiet

    session = session or SESSION
    source = textwrap.dedent(str(text or "")).strip()
    if not source:
        raise ValueError("Nothing to run: the cell is empty.")
    namespace = session.namespace()
    # A card also shows queries (the dashboard's SQL, a question's SQL). A cell holding one runs it as the notebook
    # would, nb.sql(connection, ...): a read only, shown before its result like every query of the kit.
    query = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#")).strip()
    if re.match(r"(?is)^(select|with)\b", query):
        source = f"nb.sql(connection, {query!r})" if "\n" not in query else f'nb.sql(connection, """\n{query}\n""")'
    tree = ast.parse(source, CELL, "exec")                 # a syntax error is the reader's to fix: raised as it is
    # The notebook's `connection`, when the cell uses it without making its own.
    if re.search(r"\bconnection\b", source) and not re.search(r"(?m)^\s*connection\s*=", source):
        session.connection()
    value, error = None, ""
    with quiet() as out:
        try:
            if tree.body and isinstance(tree.body[-1], ast.Expr):
                last = tree.body.pop()
                exec(compile(tree, CELL, "exec"), namespace)
                value = eval(compile(ast.Expression(last.value), CELL, "eval"), namespace)
            else:
                exec(compile(tree, CELL, "exec"), namespace)
        except Exception as exc:
            line = next((frame.lineno for frame in reversed(traceback.extract_tb(exc.__traceback__)) if frame.filename == CELL), None)
            error = "".join(traceback.format_exception_only(type(exc), exc)).strip() + (f"  (line {line})" if line else "")
    printed = getattr(out, "text", "")
    session.said = printed
    session.log(source)                                    # what ran, worked or not: the Code view and the workflow log
    shown = "\n".join(part for part in (printed, error or _shown(value)) if part)
    if len(shown) > SHOWN:
        shown = shown[:SHOWN] + "\n... (cut: the rest is not shown here)"
    return {"ok": not error, "text": shown, "value": value}


def run(action_id: str, session=None, **values: Any) -> Any:
    """Run the action's code in the notebook's namespace - that very text, nothing else - and log it. Returns the
    variable the code assigns (Action.result). A secret is a dict of keyword arguments ({"ask": ...})."""
    from .session import SESSION, quiet

    session = session or SESSION
    action = ACTIONS[action_id]
    text = _render(action_id, values, for_run=True)
    namespace = session.namespace()
    # The notebook's `connection` variable, as a whole word: nb.read_connection_string needs no database.
    if re.search(r"\bconnection\b", text) and action_id != "data.connect":
        session.connection()
    secret = values.get("secret")
    if secret:
        namespace["__secret__"] = dict(secret)
    value = None
    try:
        with quiet() as out:
            try:  # one expression (nb.exakit(...)): its value says how it ended, as it would in a cell
                compiled, single = compile(text, f"<exakit.guide:{action_id}>", "eval"), True
            except SyntaxError:
                compiled, single = compile(text, f"<exakit.guide:{action_id}>", "exec"), False
            if single:
                value = eval(compiled, namespace)
            else:
                exec(compiled, namespace)
    finally:
        namespace.pop("__secret__", None)
        session.said = getattr(out, "text", "") if "out" in locals() else ""
        session.log(code(action_id, **values))      # what ran, worked or not: the card's Code view and the workflow log
    if action.result:
        return namespace.get(action.result)
    if type(value).__name__ == "KitRun" and not value.ok:
        # A kit command that failed (nb.exakit's KitRun): the card says so, with the command's own last words.
        lines = [line.strip() for line in str(getattr(value, "output", "") or "").splitlines() if line.strip()]
        reason = [line for line in lines if not line.startswith("|")]        # "| Log: ..." follows the reason
        said = (reason or lines or [f"{value} did not finish"])[-1]
        for mark in ("[x]", "✗", "Error:", "error:"):
            if said.startswith(mark):
                said = said[len(mark):].strip()
        raise RuntimeError(said + (f" ({lines[-1].lstrip('| ').strip()})" if lines and lines[-1].startswith("|") else ""))
    return value
