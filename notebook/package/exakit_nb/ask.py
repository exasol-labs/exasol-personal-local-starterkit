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
    _approved_digest: str | None = field(default=None, init=False, repr=False)

    def _sections(self) -> list[tuple[str, list[str]]]:
        return [("What the model assumed", self.assumptions), ("Check before you approve", self.doubts)]

    def __str__(self) -> str:
        state = "approved" if self._approved_digest else "not approved yet: nothing has run"
        lines = [f"Question: {self.question}", f"SQL ({state}):", readable(self.sql)]
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
        html = [f"<p><b>Question:</b> {escape(self.question)}</p>",
                f"<pre style=\"white-space: pre-wrap\">{escape(readable(self.sql))}</pre>"]
        for title, items in self._sections():
            if items:
                html.append(f"<p><b>{title}</b></p><ul>" + "".join(f"<li>{escape(item)}</li>" for item in items) + "</ul>")
        html.append(f"<p>{state}</p>")
        return "\n".join(html)

    def edit(self, sql: str) -> "Proposal":
        self.sql = _read_sql(sql)
        self._approved_digest = None
        return self

    def approve(self) -> "Proposal":
        self.dataset.require_approved("ask")
        self.sql = _read_sql(self.sql)
        self._approved_digest = hashlib.sha256(self.sql.encode("utf-8")).hexdigest()
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


def ask(dataset: Any, question: str, proposed_sql: str | None = None, *, table_description: str | None = None,
        request_timeout: float | None = None, max_output_tokens: int | None = None) -> Proposal:
    """Draft SQL from roles and the user's opted-in model endpoint; ``proposed_sql`` supports manual drafting."""
    if request_timeout is not None and request_timeout <= 0:
        raise ValueError("request_timeout must be positive.")
    if max_output_tokens is not None and max_output_tokens <= 0:
        raise ValueError("max_output_tokens must be positive.")
    dataset.require_approved("ask")
    if not question or not question.strip():
        raise ValueError("Ask a non-empty question.")
    assumptions: list[str] = []
    doubts: list[str] = []
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
        prompt = {**described(dataset), "question": question,
                  "rules": "Return one read-only Exasol SELECT query and JSON keys sql, assumptions, doubts. Query the "
                           "table named above with its fully qualified name. Use only its columns listed above (or in "
                           "the supplied schema description); the slots name the ones the question most likely means. "
                           "A flag's evidence gives its values. Do not include row data."}
        if table_description:
            prompt["table_description"] = table_description
        try:
            answer = client.chat.completions.create(
                model=model,
                messages=[{"role": "system", "content": "Return only one JSON object with sql, assumptions (array) and doubts (array). No Markdown. Use fully qualified Exasol table names. Never execute SQL."},
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
    return Proposal(dataset, question.strip(), _read_sql(proposed_sql), assumptions, doubts)
