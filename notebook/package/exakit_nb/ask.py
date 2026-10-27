"""Ask a question, inspect the proposed SQL, approve that exact text, then run through the Exasol MCP server.

The archived Governed SQL server is not installed. The kit's own model endpoint can draft SQL from an approved
descriptor; no SQL runs until the person approves it. The MCP process uses only the dedicated read-only user's
credentials from the manifest, never the notebook's admin connection or an admin fallback.
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import queue
import re
import subprocess
import threading
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


def _mcp_settings() -> tuple[list[str], dict[str, str]]:
    manifest = json.loads((home() / "manifest.json").read_text(encoding="utf-8"))
    server = manifest["components"]["mcp_server"]
    connection = manifest["components"]["mcp_server"]["connection"]
    user, password_file = connection["user"], Path(connection["password_file"])
    if (not user or user.upper() == str(manifest["runtime"]["user"]).upper()
            or password_file.name != "mcp_readonly_password" or not password_file.is_file()
            or connection.get("validated") is not True):
        raise RuntimeError("The MCP read-only identity is not ready. Run exakit mcp-setup and exakit mcp-doctor.")
    command, package, version = server.get("command"), server.get("package"), server.get("version")
    if not command or not package or not version:
        raise RuntimeError("The Exasol MCP server is not configured. Run exakit mcp-setup and exakit mcp-doctor.")
    dsn = manifest["runtime"]["dsn"]
    host = dsn.rsplit(":", 1)[0].strip("[]")
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = False
    environment = os.environ.copy()
    environment.update(EXA_DSN=dsn, EXA_USER=user, EXA_PASSWORD=password_file.read_text(encoding="utf-8").strip(),
                       EXA_SSL_CERT_VALIDATION="no" if loopback else "yes")
    if server.get("openssl_armcap_workaround"):
        environment["OPENSSL_armcap"] = "0"
    return [str(command), f"{package}@{version}"], environment


def _execute_mcp(statement: str) -> dict[str, Any]:
    """One stdio MCP session, bounded in time and rows; the server's tool enforces SELECT and the DB user read-only."""
    command, environment = _mcp_settings()
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, encoding="utf-8", env=environment)
    assert process.stdin is not None and process.stdout is not None
    messages: queue.Queue[str] = queue.Queue()

    def read_lines():
        for line in process.stdout:
            messages.put(line)

    threading.Thread(target=read_lines, daemon=True).start()

    def call(request: dict, timeout: int = 30) -> dict:
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        while True:
            try:
                line = messages.get(timeout=timeout)
            except queue.Empty as error:
                raise RuntimeError("The Exasol MCP server did not answer within 30 seconds. Run exakit mcp-doctor.") from error
            try:
                response = json.loads(line)
            except ValueError:
                continue
            if response.get("id") == request.get("id"):
                if "error" in response:
                    raise RuntimeError("Exasol MCP refused the request: " + str(response["error"].get("message", "unknown error")))
                return response.get("result") or {}

    try:
        call({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "exakit-notebook", "version": "0.5"}}})
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        process.stdin.flush()
        result = call({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
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
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdin.close()
        process.stdout.close()


@dataclass
class Proposal:
    dataset: Any
    question: str
    sql: str
    assumptions: list[str] = field(default_factory=list)
    doubts: list[str] = field(default_factory=list)
    _approved_digest: str | None = field(default=None, init=False, repr=False)

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
        print(statement)
        import pandas as pd

        result = _execute_mcp(statement)
        frame = pd.DataFrame(result["rows"], columns=result["columns"])
        if len(frame) == 1000:
            print("Showing at most 1,000 rows. The query may have more; use an aggregate to verify a total.")
        log_event(SQL, sql_digest=self._approved_digest, rows=len(frame), sql=statement, via="mcp")
        log_event(ASK_ANSWER, dataset=self.dataset.id, question=self.question,
                  sql_digest=self._approved_digest, row_count=len(frame), doubts=self.doubts)
        return frame


def ask(dataset: Any, question: str, proposed_sql: str | None = None) -> Proposal:
    """Draft SQL from roles and the user's opted-in model endpoint; ``proposed_sql`` supports manual drafting."""
    dataset.require_approved("ask")
    if not question or not question.strip():
        raise ValueError("Ask a non-empty question.")
    assumptions: list[str] = []
    doubts: list[str] = []
    if proposed_sql is None:
        from . import model_client

        endpoint = model_client()
        if endpoint is None:
            raise RuntimeError("Set EXAKIT_NB_MODEL for SQL drafting, or pass proposed_sql= with SQL you wrote.")
        client, model = endpoint
        roles = {role: column for role, column in dataset.roles()}
        prompt = {"table": dataset.fact_table, "roles": roles, "question": question,
                  "rules": "Return one read-only Exasol SELECT query and JSON keys sql, assumptions, doubts. "
                           "Use only the named table and columns. Do not include row data."}
        answer = client.chat.completions.create(
            model=model, temperature=0,
            messages=[{"role": "system", "content": "Draft Exasol SQL as one JSON object. Never execute SQL."},
                      {"role": "user", "content": json.dumps(prompt)}])
        raw = answer.choices[0].message.content or ""
        try:
            parsed = json.loads(raw)
            proposed_sql = parsed["sql"]
            assumptions = [str(v) for v in parsed.get("assumptions", [])]
            doubts = [str(v) for v in parsed.get("doubts", [])]
        except (ValueError, KeyError, TypeError) as error:
            raise ValueError("The model did not return a SQL proposal JSON object; ask again or write SQL yourself.") from error
    proposal = Proposal(dataset, question.strip(), _read_sql(proposed_sql), assumptions, doubts)
    print("Proposed SQL (review and edit before approval):\n" + proposal.sql)
    if assumptions:
        print("Assumptions: " + "; ".join(assumptions))
    if doubts:
        print("Doubts: " + "; ".join(doubts))
    return proposal
