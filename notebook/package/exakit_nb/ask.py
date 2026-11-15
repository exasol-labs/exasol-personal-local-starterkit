"""Ask a question, inspect the proposed SQL, approve that exact text, then run through the Exasol MCP server.

The archived Governed SQL server is not installed. The kit's own model endpoint can draft SQL from an approved
descriptor; no SQL runs until the person approves it. The SQL runs on the launcher's MCP server beside the
database (the sidecar, on loopback), which connects as the dedicated read-only user only - never the notebook's
admin connection or an admin fallback. The notebook sends no password: the sidecar holds the read-only login.
"""

from __future__ import annotations

import hashlib
import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .workflow import ASK_ANSWER, ASK_APPROVE, SQL, home, log_event

_READ_START = re.compile(r"^\s*(?:--[^\n]*\n\s*)*(SELECT|WITH)\b", re.I)


def _read_sql(statement: str) -> str:
    clean = statement.strip()
    if not _READ_START.match(clean) or ";" in clean.rstrip(";"):
        raise ValueError("The proposal must be one SELECT or WITH query. Edit the SQL and approve it again.")
    return clean.rstrip(";").strip()


MCP_TIMEOUT_SECONDS = 30


def _loopback_http(url: str) -> bool:
    """An http:// URL on this machine: the only place the sidecar listens (no host is written into this file)."""
    import ipaddress
    from urllib.parse import urlsplit

    parts = urlsplit(url)
    try:
        return parts.scheme == "http" and ipaddress.ip_address(parts.hostname or "").is_loopback
    except ValueError:
        return False


def _mcp_settings() -> str:
    """The sidecar's loopback URL, once the read-only identity behind it is the validated dedicated user."""
    manifest = json.loads((home() / "manifest.json").read_text(encoding="utf-8"))
    server = manifest["components"]["mcp_server"]
    connection = manifest["components"]["mcp_server"]["connection"]
    user, password_file = connection["user"], Path(connection["password_file"])
    if (not user or user.upper() == str(manifest["runtime"]["user"]).upper()
            or password_file.name != "mcp_readonly_password" or not password_file.is_file()
            or connection.get("validated") is not True):
        raise RuntimeError("The MCP read-only identity is not ready. Run exakit mcp-setup and exakit mcp-doctor.")
    url = str(server.get("url") or "")
    if server.get("backend") != "sidecar" or not _loopback_http(url):
        raise RuntimeError("The Exasol MCP server beside your database is not set up. Run exakit mcp-setup and "
                           "exakit mcp-doctor.")
    return url


def _execute_mcp(statement: str) -> dict[str, Any]:
    """One MCP session over Streamable HTTP, bounded in time and rows; the server's tool enforces SELECT and the DB
    user read-only. Each answer is JSON or an event stream (``data: {...}`` lines), whichever the server chose; the
    session id it hands back on initialize goes with every later request, as the transport requires."""
    url = _mcp_settings()
    session: dict[str, str] = {}

    def post(request: dict) -> dict:
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **session}
        message = urllib.request.Request(url, data=json.dumps(request).encode("utf-8"), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(message, timeout=MCP_TIMEOUT_SECONDS) as response:
                if response.headers.get("mcp-session-id"):
                    session["mcp-session-id"] = response.headers["mcp-session-id"]
                body = response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"Exasol MCP refused the request: HTTP {error.code}. Run exakit mcp-doctor.") from error
        except TimeoutError as error:
            raise RuntimeError(f"The Exasol MCP server did not answer within {MCP_TIMEOUT_SECONDS} seconds. "
                               "Run exakit mcp-doctor.") from error
        except (urllib.error.URLError, OSError) as error:
            raise RuntimeError(f"The Exasol MCP server at {url} did not answer "
                               f"({getattr(error, 'reason', error)}). Run exakit mcp-doctor.") from error
        if "id" not in request:
            return {}
        for chunk in [body] + [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]:
            try:
                response = json.loads(chunk)
            except ValueError:
                continue
            if isinstance(response, dict) and response.get("id") == request["id"]:
                if "error" in response:
                    raise RuntimeError("Exasol MCP refused the request: " + str(response["error"].get("message", "unknown error")))
                return response.get("result") or {}
        raise RuntimeError("Exasol MCP answered something that is not MCP. Run exakit mcp-doctor.")

    try:
        post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "exakit-notebook", "version": "0.5"}}})
        post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        result = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "execute_exasol_query", "arguments": {"query": statement, "row_limit": 1000}}})
        if result.get("isError"):
            text = " ".join(str(item.get("text", "")) for item in result.get("content", []))
            raise RuntimeError("Exasol MCP refused the SQL: " + text[:500])
        data = result.get("structuredContent")
        if data is None:
            for item in result.get("content", []):
                if item.get("type") == "text":
                    try:
                        data = json.loads(item["text"])
                        break
                    except (KeyError, ValueError):
                        pass
        if not isinstance(data, dict) or not isinstance(data.get("columns"), list) or not isinstance(data.get("rows"), list):
            raise RuntimeError("Exasol MCP returned no tabular result; run exakit mcp-doctor.")
        return data
    finally:
        if session:                                       # end the session; a server that has gone already is fine
            try:
                urllib.request.urlopen(urllib.request.Request(url, headers=session, method="DELETE"), timeout=5).close()
            except (urllib.error.URLError, OSError):
                pass


_QUOTED = re.compile(r"('(?:[^']|'')*'|\"(?:[^\"]|\"\")*\")")
_CLAUSE = re.compile(r"\s+((?:LEFT |RIGHT |INNER |FULL |CROSS )?(?:OUTER )?JOIN|FROM|WHERE|GROUP BY|HAVING|QUALIFY|ORDER BY|"
                     r"LIMIT|UNION ALL|UNION)\b", re.I)


def readable(sql: str) -> str:
    """The SQL laid out for reading, one clause per line; the text approved and run is never changed. SQL that
    already has line breaks is shown as it is."""
    if "\n" in sql.strip():
        return sql.strip()
    parts = _QUOTED.split(sql.strip())                 # odd items are quoted names and strings: never split inside
    return "".join(part if i % 2 else _CLAUSE.sub(lambda m: "\n" + m.group(1), part) for i, part in enumerate(parts))


@dataclass
class Proposal:
    """A question with the SQL proposed for it. Nothing runs until ``approve()`` accepts that exact text; ``edit()`` replaces
    the SQL and removes the approval; ``run()`` runs the approved text through the kit's read-only service."""

    dataset: Any
    question: str
    sql: str
    assumptions: list[str] = field(default_factory=list)
    doubts: list[str] = field(default_factory=list)
    request: dict[str, Any] | None = None     # the structured request the SQL was compiled from (semantic model only)
    plan: list[str] = field(default_factory=list)   # how the answer is put together, in plain words
    checked: bool | None = None               # True: your data map wrote or checked the SQL; False: the AI wrote it alone
    request_id: Any = None                    # Semantic Views' number for the compile: feedback goes to it
    conn: Any = field(default=None, repr=False, compare=False)
    _approved_digest: str | None = field(default=None, init=False, repr=False)

    def _sections(self) -> list[tuple[str, list[str]]]:
        return [("How it is put together", self.plan), ("What the model assumed", self.assumptions),
                ("Check before you approve", self.doubts)]

    @property
    def checked_line(self) -> str:
        if self.checked is True:
            return "Checked by your data map: it wrote this SQL from its own definitions, and refuses joins that count twice."
        if self.checked is False:
            return ("Not checked by your data map: the AI wrote this SQL from the column map alone. Read the joins and "
                    "the sums before you approve it.")
        return ""

    def __str__(self) -> str:
        state = "approved" if self._approved_digest else "not approved yet: nothing has run"
        lines = [f"Question: {self.question}"] + ([self.checked_line] if self.checked_line else []) + [f"SQL ({state}):", readable(self.sql)]
        for title, items in self._sections():
            if items:
                lines += ["", f"{title}:", *(f"  - {item}" for item in items)]
        return "\n".join(lines)

    def _repr_html_(self) -> str:
        """How Jupyter and Marimo show a proposal: the question, the SQL one clause per line, then what the model
        assumed and what to check, as lists, and the state."""
        from html import escape

        state = ("<b>Approved</b>: run it with <code>proposal.run()</code>." if self._approved_digest
                 else "<b>Not approved yet</b>: nothing has run. Edit with <code>proposal.edit(\"...\")</code> if needed, "
                      "then approve it in the next cell.")
        html = [f"<p><b>Question:</b> {escape(self.question)}</p>"] + ([f"<p><i>{escape(self.checked_line)}</i></p>"] if self.checked_line else []) + [
                f"<pre style=\"white-space: pre-wrap\">{escape(readable(self.sql))}</pre>"]
        for title, items in self._sections():
            if items:
                html.append(f"<p><b>{title}</b></p><ul>" + "".join(f"<li>{escape(item)}</li>" for item in items) + "</ul>")
        html.append(f"<p>{state}</p>")
        return "\n".join(html)

    def _feedback(self, verdict: str, comment: str | None = None, proposed: str | None = None) -> None:
        """What you made of an answer Semantic Views compiled, recorded with it (RECORD_AGENT_FEEDBACK)."""
        if self.request_id is None or self.conn is None:
            return
        try:
            from .semantic import _service

            _service().record_feedback(self.conn, self.request_id, verdict, comment, proposed)
        except Exception:                   # noqa: BLE001 - feedback is extra
            pass

    def edit(self, sql: str) -> "Proposal":
        if self.request_id is not None:
            self._feedback("NEEDS_CHANGE", "A person wrote other SQL for this question.", _read_sql(sql))
            self.request_id = None
        self.sql = _read_sql(sql)
        self._approved_digest = None
        self.request = None                  # your own SQL: it no longer is what the request compiles to
        self.checked, self.plan = None, []
        return self

    def verify(self, conn, name: str | None = None) -> dict[str, Any]:
        """Keep this approved question in the semantic model as a verified question (nb.verify_question): the next
        time it is asked - here or by an AI client over MCP - its request is used, with no new draft. Only a question
        answered from the model can be kept: SQL written or edited by hand has no request to keep."""
        if not self._approved_digest:
            raise RuntimeError("Approve the SQL first: only an approved question can be kept.")
        if not self.request:
            raise RuntimeError("Only a question answered from your data map can be saved as a trusted question "
                               "(this SQL was written or edited by hand, or drafted from the column map).")
        from .semantic import verify_question

        return verify_question(conn, self.request["model"], self.request["object"], name or self.question[:120],
                               self.question, {k: v for k, v in self.request.items() if k not in ("model", "object", "client")})

    def approve(self) -> "Proposal":
        self.dataset.require_approved("ask")
        self.sql = _read_sql(self.sql)
        self._approved_digest = hashlib.sha256(self.sql.encode("utf-8")).hexdigest()
        self._feedback("ACCEPTED", "Approved to run as compiled.")
        log_event(ASK_APPROVE, dataset=self.dataset.id, question=self.question, sql=self.sql,
                  sql_digest=self._approved_digest, descriptor_version=self.dataset.version)
        return self

    def run(self):
        self.dataset.require_approved("ask")
        statement = _read_sql(self.sql)
        if self._approved_digest != hashlib.sha256(statement.encode("utf-8")).hexdigest():
            raise RuntimeError("This SQL has not been approved. Review it, then call proposal.approve() before run().")
        import pandas as pd

        result = _execute_mcp(statement)
        frame = pd.DataFrame(result["rows"], columns=result["columns"])
        if len(frame) == 1000:
            print("Showing at most 1,000 rows. The query may have more; use an aggregate to verify a total.")
        log_event(SQL, sql_digest=self._approved_digest, rows=len(frame), sql=statement, via="mcp")
        log_event(ASK_ANSWER, dataset=self.dataset.id, question=self.question,
                  sql_digest=self._approved_digest, row_count=len(frame), doubts=self.doubts)
        return frame


def described(dataset: Any) -> dict[str, Any]:
    """What the model is told about the data: the approved descriptor - the table, what one row is, the version, the
    slots, and every column with its role, the evidence that chose it and its note. A sensitive column is named with
    its role only, and the model is told never to select its values. The same approved version the schema's
    Exasol Semantic Views model is built from, so the notebook and the AI clients over MCP answer from one meaning."""
    descriptor = getattr(dataset, "descriptor", None)
    about: dict[str, Any] = {"table": dataset.fact_table,
                             "descriptor": f"{dataset.id} v{dataset.version} (approved)",
                             "slots": {role: column for role, column in dataset.roles()}}
    grain = getattr(descriptor, "grain", None)
    if grain:
        about["grain"] = grain
    columns = {}
    for name, entry in (getattr(descriptor, "columns", None) or {}).items():
        if entry.get("sensitive"):
            columns[name] = {"role": entry.get("role"), "sensitive": "personal data: never select, group or filter its values"}
        else:
            columns[name] = {key: entry[key] for key in ("role", "evidence", "note") if entry.get(key)}
    if columns:
        about["columns"] = columns
    return about


MARK = "[built by exakit]"      # in the description of a semantic model the kit built

ASK_RULES: dict[str, Any] = {
    "ORDER": ["trusted", "data_map_request", "data_map_sql", "column_map"],
    "REQUEST_LIMIT": 1000,
    "SEARCH_ABOVE": 30,
    "SEARCH_WORDS": 4,
    "REQUEST_SYSTEM": "Return only one JSON object with metrics, dimensions, filters, order_by, limit, assumptions (array) "
                      "and doubts (array). No Markdown.",
    "REQUEST_PROMPT": "Answer with a structured request: metrics (names from the list), dimensions (names from the list, "
                      "to group by), filters [{field, op, value}] on dimensions (op one of = != > >= < <= LIKE IN BETWEEN), "
                      "order_by [{field, direction}], limit. Use only the names listed (the glossary, when given, is Semantic "
                      "Views' own description of them), and follow the model's instructions "
                      "(a SAFETY one is never broken). If the question cannot be answered from them, return an empty "
                      "metrics list and say why in doubts.",
    "DATA_MAP_SQL_SYSTEM": "Return only one JSON object with sql, assumptions (array) and doubts (array). No Markdown. "
                           "Never execute SQL.",
    "DATA_MAP_SQL_PROMPT": "Answer with Semantic SQL over the semantic view: SELECT <dimension names>, <metric names> FROM "
                           "<semantic_view> [WHERE <dimension> = '<value>'] GROUP BY <the dimension names>. Use only the "
                           "names listed (the glossary, when given, is Semantic Views' own description of them). No joins, no "
                           "aggregate functions, no other tables: the metrics already aggregate. "
                           "If the question cannot be answered from these metrics and dimensions, return sql as an empty "
                           "string and say why in doubts.",
    "COLUMN_MAP_SYSTEM": "Return only one JSON object with sql, assumptions (array) and doubts (array). No Markdown. Use "
                         "fully qualified Exasol table names. Never execute SQL.",
    "COLUMN_MAP_PROMPT": "Return one read-only Exasol SELECT query and JSON keys sql, assumptions, doubts. Query the table "
                         "named above with its fully qualified name. Use only its columns listed above (or in the supplied "
                         "schema description); the slots name the ones the question most likely means. A flag's evidence "
                         "gives its values. Do not include row data.",
}
STEPS = ("trusted", "data_map_request", "data_map_sql", "column_map")


def ask_rules() -> dict[str, Any]:
    """How a question is drafted, as values to copy, change and pass (nb.ask(..., rules={...})):

    ORDER                 the ways tried, first to last: trusted (a trusted question, no AI), data_map_request (the
                          AI picks names, the data map writes the SQL), data_map_sql (the AI writes Semantic SQL),
                          column_map (the AI writes SQL from the column map). Leave one out to skip it.
    REQUEST_LIMIT         the most rows a request may ask for
    SEARCH_ABOVE          with more fields than this, the data map is searched for the question's words first and the
                          AI is shown the fields that match (all of them when none matches)
    SEARCH_WORDS          how many of the question's words are looked up
    *_SYSTEM, *_PROMPT    every instruction each way gives the AI, word for word
    Also the no-AI drafter's rules (nb.draft_question) and the insights' rules: see nb.draft_rules() and
    nb.insight_rules()."""
    return {k: list(v) if isinstance(v, list) else v for k, v in ASK_RULES.items()}


def _ask_rules(given: dict[str, Any] | None) -> dict[str, Any]:
    found = ask_rules()
    for key, value in (given or {}).items():
        if key not in found:
            raise ValueError(f"{key} is not an ask rule: the rules are {', '.join(found)}")
        if key == "ORDER":
            wrong = [v for v in value if v not in STEPS] if isinstance(value, (list, tuple)) else [value]
            if wrong:
                raise ValueError(f"ORDER lists ways from {', '.join(STEPS)}, not {wrong}")
            value = list(value)
        elif key in ("REQUEST_LIMIT", "SEARCH_ABOVE", "SEARCH_WORDS"):
            if isinstance(value, bool) or not isinstance(value, int) or value < (0 if key == "SEARCH_ABOVE" else 1):
                raise ValueError(f"{key} is a whole number, not {value!r}")
        elif not isinstance(value, str) or not value.strip():
            raise ValueError(f"{key} is the text the AI is given, not {value!r}")
        found[key] = value
    return found


_STOP = {"the", "and", "for", "per", "what", "which", "how", "many", "much", "show", "give", "list", "with", "from",
         "that", "this", "are", "was", "were", "has", "have", "each", "all", "our", "their", "by", "of", "in", "on", "to",
         "is", "me", "a", "an", "top", "most", "least", "by", "over", "between", "last", "first"}


def _glossary(semantic: dict[str, Any], mode: str) -> str:
    """Semantic Views' own glossary of the semantic view (GET_BUSINESS_GLOSSARY): what each field means and the
    model's instructions, written by the product for an AI. "" when it cannot be read; the field list stands."""
    if not semantic.get("conn"):
        return ""
    try:
        from .semantic import _service

        return _service().glossary(semantic["conn"], semantic["model"], semantic["object"], mode)[:12000]
    except Exception:                       # noqa: BLE001
        return ""


def _narrowed(semantic: dict[str, Any], question: str, rules: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    """The fields the AI is shown. A small data map is shown whole. A large one (more than SEARCH_ABOVE fields) is
    searched first (SEARCH_SEMANTIC_OBJECTS, one word at a time: the question's SEARCH_WORDS longest words) and only
    the matching metrics and dimensions of this view are shown; a kind with no match is shown whole, so a question
    the search misses still has every name. (semantic, a line saying what was looked up, or None)."""
    every = len(semantic["dimensions"]) + len(semantic["metrics"])
    if every <= int(rules.get("SEARCH_ABOVE", 30)) or not semantic.get("conn"):
        return semantic, None
    from .semantic import _service

    words = sorted({w for w in _words(question) if len(w) > 2 and w not in _STOP}, key=lambda w: (-len(w), w))
    hits: dict[str, float] = {}
    try:
        for word in words[:int(rules.get("SEARCH_WORDS", 4))]:
            for f in _service().search_fields(semantic["conn"], word, semantic["model"]):
                if f["object"].upper() == semantic["object"].upper():
                    hits[f["name"].lower()] = max(hits.get(f["name"].lower(), 0.0), f["score"])
    except Exception:                       # noqa: BLE001 - no search: every field is shown, as before
        return semantic, None
    if not hits:
        return semantic, None
    rank = lambda items: sorted([i for i in items if i["name"].lower() in hits], key=lambda i: -hits[i["name"].lower()])
    metrics, dimensions = rank(semantic["metrics"]), rank(semantic["dimensions"])
    narrowed = dict(semantic, metrics=metrics or semantic["metrics"], dimensions=dimensions or semantic["dimensions"])
    shown = len(narrowed["metrics"]) + len(narrowed["dimensions"])
    return narrowed, f"Your data map was searched for this question: {shown} of its {every} fields were shown to the AI."


def _ask_semantic(client, model: str, options: dict, semantic: dict[str, Any], question: str,
                  rules: dict[str, Any] | None = None):
    """(Semantic SQL, the plain SQL it compiles to, assumptions, doubts) for a question, or None when the model says
    the question cannot be answered from these metrics and dimensions."""
    rules = rules or ASK_RULES
    semantic, _looked = _narrowed(semantic, question, rules)
    prompt = {"semantic_view": semantic["view"], "dimensions": semantic["dimensions"], "metrics": semantic["metrics"],
              "instructions": semantic.get("instructions") or [], "question": question}
    said_by_product = None if _looked else _glossary(semantic, "SEMANTIC_SQL")
    if said_by_product:
        prompt["glossary"] = said_by_product
    prompt["rules"] = rules["DATA_MAP_SQL_PROMPT"]
    answer = client.chat.completions.create(
        model=model,
        messages=[{"role": "system", "content": rules["DATA_MAP_SQL_SYSTEM"]},
                  {"role": "user", "content": json.dumps(prompt)}], **options)
    raw = answer.choices[0].message.content or ""
    fences = re.findall(r"```(?:json)?\s*(.*?)```", raw, flags=re.S | re.I)
    parsed = json.loads(fences[0] if len(fences) == 1 else raw)
    semantic_sql = str(parsed.get("sql") or "").strip().rstrip(";")
    if not semantic_sql:
        raise ValueError("; ".join(str(d) for d in parsed.get("doubts") or []) or "the question is outside the model")
    semantic_sql = _read_sql(semantic_sql)
    if semantic["view"].upper() not in semantic_sql.upper():
        raise ValueError("the draft does not query the semantic view")
    plain, plan, request_id = _compiled_semantic(semantic["conn"], semantic_sql)
    said = ([_looked] if _looked else []) + [str(v) for v in parsed.get("assumptions") or []]
    return (semantic_sql, plain, said, [str(v) for v in parsed.get("doubts") or []],
            _plan_of(plain, plan, semantic["conn"], request_id), request_id)


def _words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", str(text).lower())


def _verified_answer(conn, semantic: dict[str, Any], question: str, dataset: Any) -> "Proposal | None":
    """The model's verified question that is this question (the same words, in any order and case), compiled now:
    a reviewed request answers it with no model call. None when there is none, or it no longer compiles."""
    from .semantic import _service

    try:
        service = _service()
        asked = sorted(set(_words(question)))
        for known in service.verified_questions(conn, semantic["model"]):
            if sorted(set(_words(known.get("question") or ""))) != asked:
                continue
            request = dict(known.get("request") or {}, model=semantic["model"],
                           object=known.get("object") or (known.get("request") or {}).get("object") or semantic["object"])
            compiled = service.compile_request(conn, request)
            if compiled["status"] != "ok":
                return None
            return Proposal(dataset, question.strip(), _read_sql(compiled["sql"]),
                            [f"A trusted question, checked before: \"{known['name']}\". It is answered the way it was approved; "
                             "no AI was asked."],
                            [], request=request, plan=compiled.get("explained") or [], checked=True,
                            request_id=compiled.get("request_id"), conn=conn)
    except Exception:                       # noqa: BLE001 - no verified questions: drafted as usual
        return None
    return None


def _instructions(rows, model: str, lit) -> list[str]:
    """The model's instructions for agents (SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT): what a column means when it is
    no field, which columns are personal data, which tables are read live. [] when the view cannot be read."""
    try:
        found = rows(f"SELECT * FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT WHERE MODEL_NAME = {lit(model)}")
    except Exception:
        return []
    out = []
    for r in found:
        text = next((str(v) for k, v in r.items() if "TEXT" in str(k).upper() and v), "")
        kind = next((str(v) for k, v in r.items() if "KIND" in str(k).upper() and v), "")
        if text:
            out.append(f"{kind}: {text}" if kind else text)
    return out[:60]


def _ask_request(client, model: str, options: dict, semantic: dict[str, Any], question: str,
                 rules: dict[str, Any] | None = None):
    """(the structured request, the SQL the semantic layer compiles it to, assumptions, doubts), or None when the
    model says the question is outside the model. The model only picks metric and dimension names, filters and an
    order; Exasol Semantic Views (COMPILE_REQUEST_JSON) writes the SQL. An ambiguous request comes back with the
    product's choices, named in the doubts."""
    from .semantic import _service

    rules = rules or ASK_RULES
    semantic, looked = _narrowed(semantic, question, rules)
    prompt = {"model": semantic["model"], "object": semantic["object"], "dimensions": semantic["dimensions"],
              "metrics": semantic["metrics"], "instructions": semantic.get("instructions") or [], "question": question}
    said_by_product = None if looked else _glossary(semantic, "STRUCTURED_REQUEST")
    if said_by_product:
        prompt["glossary"] = said_by_product
    prompt["rules"] = rules["REQUEST_PROMPT"]
    answer = client.chat.completions.create(
        model=model,
        messages=[{"role": "system", "content": rules["REQUEST_SYSTEM"]},
                  {"role": "user", "content": json.dumps(prompt)}], **options)
    raw = answer.choices[0].message.content or ""
    fences = re.findall(r"```(?:json)?\s*(.*?)```", raw, flags=re.S | re.I)
    parsed = json.loads(fences[0] if len(fences) == 1 else raw)
    if not isinstance(parsed, dict) or not parsed.get("metrics"):
        raise ValueError("; ".join(str(d) for d in (parsed or {}).get("doubts") or []) or "the question is outside the model")
    request = {"model": semantic["model"], "object": semantic["object"]}
    for key in ("metrics", "dimensions", "filters", "having", "order_by"):
        if isinstance(parsed.get(key), list) and parsed[key]:
            request[key] = parsed[key]
    if isinstance(parsed.get("limit"), int) and parsed["limit"] > 0:
        request["limit"] = min(int(parsed["limit"]), int(rules["REQUEST_LIMIT"]))
    compiled = _service().compile_request(semantic["conn"], request)
    doubts = [str(v) for v in parsed.get("doubts") or []]
    if compiled["status"] != "ok":
        choices = compiled.get("clarification")
        raise ValueError(compiled["error"] + (f"; the model asks which is meant: {json.dumps(choices)[:300]}" if choices else ""))
    said = ([looked] if looked else []) + [str(v) for v in parsed.get("assumptions") or []]
    return request, compiled["sql"], said, doubts, compiled.get("explained") or [], compiled.get("request_id")


def semantic_context(conn, table: str) -> dict[str, Any] | None:
    """What the semantic layer says about ``table`` (SCHEMA.TABLE): the published view rooted at it in a model the
    kit built, with that view's dimensions and metrics by name, business name and description. None when no model
    has it, or Exasol Semantic Views is not installed. Reads the catalog only."""
    schema, _, name = str(table).partition(".")
    lit = lambda text: "'" + str(text).replace("'", "''") + "'"

    def rows(sql: str) -> list[dict[str, Any]]:
        done = conn.execute(sql)
        names = [str(c) for c in done.column_names()] if hasattr(done, "column_names") else []
        return [r if isinstance(r, dict) else dict(zip(names, r)) for r in done.fetchall()]

    try:
        views = rows("SELECT M.MODEL_NAME, M.PUBLISHED_SCHEMA, M.DESCRIPTION, O.OBJECT_NAME FROM SEMANTIC_CATALOG.ENTITIES E "
                     "JOIN SEMANTIC_CATALOG.MODELS M ON M.MODEL_ID = E.MODEL_ID "
                     "JOIN SEMANTIC_CATALOG.SEMANTIC_OBJECTS O ON O.MODEL_ID = E.MODEL_ID AND O.ROOT_ENTITY_NAME = E.ENTITY_NAME "
                     f"WHERE E.SOURCE_SCHEMA = {lit(schema.upper())} AND E.SOURCE_OBJECT = {lit(name.upper())} "
                     "AND E.STATUS = 'ACTIVE' AND O.STATUS = 'ACTIVE' AND M.STATUS = 'PUBLISHED' ORDER BY M.MODEL_NAME")
        views = [v for v in views if MARK in str(v.get("DESCRIPTION") or "")]
        if not views:
            return None
        # the view with the most to say first: a multi-source model has the joined tables' dimensions too. One read of
        # the product's agent surface (role-filtered) for every candidate model; the catalog tables only without it.
        models = sorted({str(v["MODEL_NAME"]) for v in views})
        try:
            every = rows("SELECT MODEL_NAME, OBJECT_NAME, FIELD_KIND, FIELD_NAME, DISPLAY_NAME, DESCRIPTION "
                         "FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE MODEL_NAME IN (" + ", ".join(lit(m) for m in models) + ")")
        except Exception:
            every = None
        if every is not None:
            by_view: dict[tuple[str, str], list[dict[str, Any]]] = {}
            for r in every:
                by_view.setdefault((str(r["MODEL_NAME"]), str(r["OBJECT_NAME"]).upper()), []).append(r)
            view = max(views, key=lambda v: len(by_view.get((str(v["MODEL_NAME"]), str(v["OBJECT_NAME"]).upper()), [])))
            mine = by_view.get((str(view["MODEL_NAME"]), str(view["OBJECT_NAME"]).upper()), [])
            item = lambda r: {"name": str(r["FIELD_NAME"]), "business_name": str(r.get("DISPLAY_NAME") or ""),
                              "about": str(r.get("DESCRIPTION") or "")}
            found = {"model": str(view["MODEL_NAME"]), "object": str(view["OBJECT_NAME"]),
                     "view": f"{view['PUBLISHED_SCHEMA']}.{view['OBJECT_NAME']}",
                     "dimensions": [item(r) for r in mine if str(r["FIELD_KIND"]).upper() == "DIMENSION"],
                     "metrics": [item(r) for r in mine if str(r["FIELD_KIND"]).upper() == "METRIC"],
                     "instructions": _instructions(rows, str(view["MODEL_NAME"]), lit)}
            return found if found["metrics"] else None
        best, fields = None, None
        for view in views:
            view_name = f"{view['PUBLISHED_SCHEMA']}.{view['OBJECT_NAME']}"
            columns = {str(r["COLUMN_NAME"]).lower() for r in rows(
                "SELECT COLUMN_NAME FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = "
                f"{lit(view['PUBLISHED_SCHEMA'])} AND COLUMN_TABLE = {lit(view['OBJECT_NAME'])}")}
            if fields is None or len(columns) > len(fields):
                best, fields = (view, view_name), columns
        view, view_name = best
        model = lit(view["MODEL_NAME"])
        dims = rows("SELECT DIMENSION_NAME, DISPLAY_NAME, DESCRIPTION, DATA_TYPE FROM SEMANTIC_CATALOG.DIMENSIONS "
                    f"WHERE MODEL_NAME = {model} AND STATUS = 'ACTIVE'")
        metrics = rows("SELECT METRIC_NAME, DISPLAY_NAME, DESCRIPTION FROM SEMANTIC_CATALOG.METRICS "
                       f"WHERE MODEL_NAME = {model} AND STATUS = 'ACTIVE'")
    except Exception:
        return None
    pick = lambda items, key: [{"name": str(i[key]), "business_name": str(i.get("DISPLAY_NAME") or ""),
                                "about": str(i.get("DESCRIPTION") or "")} for i in items if str(i[key]).lower() in fields]
    found = {"model": str(view["MODEL_NAME"]), "object": str(view["OBJECT_NAME"]), "view": view_name,
             "dimensions": pick(dims, "DIMENSION_NAME"), "metrics": pick(metrics, "METRIC_NAME")}
    return found if found["metrics"] else None


def _plan_of(sql: str, plan: Any = None, conn=None, request_id: Any = None) -> list[str]:
    """How the answer is put together: Semantic Views' own explanation first (EXPLAIN_COMPILED_SQL, when it compiled
    it), then the tables and joins read from the SQL. Nothing when this Python has no kit beside it."""
    try:
        from .semantic import _service

        service = _service()
        own = service.governance_lines(service.explain_request(conn, request_id)) if conn is not None and request_id is not None else []
        return own + service.plan_lines(sql, plan)
    except Exception:                       # noqa: BLE001 - the plan is shown when it can be worked out
        return []


def compile_semantic(conn, semantic_sql: str) -> str:
    """The plain SQL Exasol Semantic Views compiles a Semantic SQL query into (SEMANTIC_ADMIN.COMPILE_SQL): the joins
    and aggregates the model defines. Nothing of the user's data is read. ValueError with the product's reason when
    the query names something the model does not have."""
    return _compiled_semantic(conn, semantic_sql)[0]


def _compiled_semantic(conn, semantic_sql: str) -> tuple[str, Any, Any]:
    """(the plain SQL, the plan the product returned with it, parsed when it is JSON, its request number)."""
    done = conn.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL('" + semantic_sql.replace("'", "''") + "')")
    names = [str(c) for c in done.column_names()] if hasattr(done, "column_names") else []
    row = done.fetchall()[0]
    row = row if isinstance(row, dict) else dict(zip(names, row))
    generated = next((v for k, v in row.items() if "GENERATED" in str(k).upper() and v), None)
    if str(row.get("STATUS") or "").upper() != "OK" or not generated:
        reason = next((str(v) for k, v in row.items() if "ERROR" in str(k).upper() or "MESSAGE" in str(k).upper() and v), "")
        raise ValueError(f"The semantic model refused the query: {reason or row.get('STATUS')}")
    plan = next((v for k, v in row.items() if str(k).upper() == "PLAN_JSON" and v), None)
    try:
        plan = json.loads(plan) if isinstance(plan, str) else plan
    except ValueError:
        pass
    request_id = next((v for k, v in row.items() if str(k).upper() == "AGENT_REQUEST_ID"), None)
    return " ".join(str(generated).split()), plan, request_id


def ask(dataset: Any, question: str, proposed_sql: str | None = None, *, table_description: str | None = None,
        request_timeout: float | None = None, max_output_tokens: int | None = None, conn=None,
        rules: dict[str, Any] | None = None) -> Proposal:
    """Draft SQL from the user's opted-in model endpoint; ``proposed_sql`` supports manual drafting.

    With ``conn`` (the notebook's connection) and a semantic model the kit built over this data, the model answers
    from the semantic layer: it is shown the model's metrics and dimensions, writes Semantic SQL over the published
    view, and Exasol Semantic Views compiles that into the plain SQL you read and approve - the same definitions an
    AI client over MCP uses, so both give the same number. Without a model over the data, or when the question
    cannot be put in its terms, the SQL is drafted from the approved column map as before, and the proposal says so.
    ``rules`` changes the order of the ways tried, and every word the AI is given (nb.ask_rules() lists them)."""
    rules = _ask_rules(rules)
    order = rules["ORDER"]
    if request_timeout is not None and request_timeout <= 0:
        raise ValueError("request_timeout must be positive.")
    if max_output_tokens is not None and max_output_tokens <= 0:
        raise ValueError("max_output_tokens must be positive.")
    dataset.require_approved("ask")
    if not question or not question.strip():
        raise ValueError("Ask a non-empty question.")
    assumptions: list[str] = []
    doubts: list[str] = []
    semantic = None
    if proposed_sql is None and conn is not None:
        semantic = semantic_context(conn, dataset.fact_table)
        known = _verified_answer(conn, semantic, question, dataset) if semantic and "trusted" in order else None
        if known:                          # asked before and reviewed: its request, compiled now - no model call
            return known
    if proposed_sql is None and not any(step in order for step in ("data_map_request", "data_map_sql", "column_map")):
        raise ValueError("No way left to draft this question: ORDER has none that asks the AI, and no trusted question "
                         "matched. Write the SQL yourself (proposed_sql=) or put a way back in ORDER.")
    if proposed_sql is None:
        from . import model_client

        endpoint = model_client()
        if endpoint is None:
            raise RuntimeError("Set EXAKIT_MODEL_ID for SQL drafting, or pass proposed_sql= with SQL you wrote.")
        client, model = endpoint
        if request_timeout is not None:
            client = client.with_options(timeout=request_timeout, max_retries=0)
        from .model_config import sampling

        options = dict(sampling())  # no temperature unless EXAKIT_MODEL_TEMPERATURE asks for one
        if max_output_tokens is not None:
            options["max_tokens"] = max_output_tokens
        if semantic:
            semantic["conn"] = conn
            try:
                asked = _ask_request(client, model, options, semantic, question, rules) if "data_map_request" in order else None
            except Exception as error:       # noqa: BLE001 - Semantic SQL, then the column map, still answer
                asked = None
                doubts.append(f"The structured request was not used ({str(error).splitlines()[0][:160] if str(error) else type(error).__name__}).")
            if asked:
                client.close()
                request, plain, said, unsure, plan, request_id = asked
                return Proposal(dataset, question.strip(), _read_sql(plain),
                                [f"Answered from your data map ({semantic['model']}): the same meanings your dashboards and "
                                 "AI tools use, so the numbers match.",
                                 "Request: " + json.dumps({k: v for k, v in request.items() if k not in ("model", "object", "client")}),
                                 *said], unsure, request=request, plan=plan, checked=True, request_id=request_id, conn=conn)
            try:
                drafted = _ask_semantic(client, model, options, semantic, question, rules) if "data_map_sql" in order else None
            except Exception as error:       # noqa: BLE001 - the column map still answers; the proposal says why
                drafted = None
                doubts.append(f"Not answered from your data map ({semantic['model']}) "
                              f"({str(error).splitlines()[0][:160] if str(error) else type(error).__name__}); "
                              "drafted from the column map instead.")
            if drafted:
                client.close()
                semantic_sql, plain, said, unsure, plan, request_id = drafted
                return Proposal(dataset, question.strip(), _read_sql(plain),
                                [f"Answered from your data map ({semantic['model']}): the same meanings your dashboards and "
                                 "AI tools use, so the numbers match.",
                                 f"Semantic SQL: {semantic_sql}", *said], unsure, plan=plan, checked=True,
                                request_id=request_id, conn=conn)
        if "column_map" not in order:
            client.close()
            raise ValueError("Not answered: the ways in ORDER found no answer, and column_map is not in it. "
                             + " ".join(doubts))
        prompt = {**described(dataset), "question": question, "rules": rules["COLUMN_MAP_PROMPT"]}
        if table_description:
            prompt["table_description"] = table_description
        try:
            answer = client.chat.completions.create(
                model=model,
                messages=[{"role": "system", "content": rules["COLUMN_MAP_SYSTEM"]},
                          {"role": "user", "content": json.dumps(prompt)}], **options)
        finally:
            client.close()
        raw = answer.choices[0].message.content or ""
        try:
            fences = re.findall(r"```(?:json)?\s*(.*?)```", raw, flags=re.S | re.I)
            parsed = json.loads(fences[0] if len(fences) == 1 else raw)
            if (not isinstance(parsed, dict) or not isinstance(parsed.get("sql"), str)
                    or any(not isinstance(parsed.get(key, []), list)
                           or any(not isinstance(v, str) for v in parsed.get(key, []))
                           for key in ("assumptions", "doubts"))):
                raise ValueError("Invalid proposal fields")
            proposed_sql = parsed["sql"]
            assumptions = [str(v) for v in parsed.get("assumptions", [])]
            doubts = [str(v) for v in parsed.get("doubts", [])]
        except (ValueError, KeyError, TypeError) as error:
            raise ValueError("The model did not return a SQL proposal JSON object; ask again or write SQL yourself.") from error
        drafted_sql = _read_sql(proposed_sql)
        return Proposal(dataset, question.strip(), drafted_sql, assumptions, doubts,
                        plan=_plan_of(drafted_sql)[:1], checked=False)
    return Proposal(dataset, question.strip(), _read_sql(proposed_sql), assumptions, doubts)
