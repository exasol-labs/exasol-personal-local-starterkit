"""Refuse uploading generated artifacts containing this kit's connection values or configured secrets.

Prints file paths and field names only, never the matched value. Service URLs
on other ports and Python's sys module are not database connection disclosures.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re

CREDENTIAL_FIELD = re.compile(r"(?:^|_)(?:password|secret_key|api_key|token)$", re.I)


def credential_values(home: Path) -> dict[str, str]:
    manifest = json.loads((home / "manifest.json").read_text())
    runtime = manifest.get("runtime", {})
    dsn = runtime.get("dsn", "")
    host = dsn.rsplit(":", 1)[0].strip("[]") if ":" in dsn else dsn
    mcp = manifest.get("components", {}).get("mcp_server", {}).get("connection", {})
    values = {"database_dsn": dsn, "database_host": host, "database_user": runtime.get("user", ""),
              "database_user_mcp": mcp.get("user", "")}
    sources = [runtime.get("password_file"), manifest.get("components", {}).get("mcp_server", {}).get("connection", {}).get("password_file")]
    for index, source in enumerate(sources):
        if source and Path(source).is_file():
            values[f"database_password_{index}"] = Path(source).read_text().strip()
    for key, value in os.environ.items():
        if CREDENTIAL_FIELD.search(key) and value:
            values[key] = value
    config = home / "credentials/langfuse.json"
    if config.is_file():
        doc = json.loads(config.read_text())
        if doc.get("LANGFUSE_SECRET_KEY"):
            values["LANGFUSE_SECRET_KEY"] = doc["LANGFUSE_SECRET_KEY"]
    return {k:v for k,v in values.items() if isinstance(v,str) and v}


def inspect_text(text: str, values: dict[str, str]) -> list[str]:
    found = set()
    def inspect_json(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if CREDENTIAL_FIELD.search(key) and isinstance(item, str) and item:
                    found.add("credential_field")
                inspect_json(item)
        elif isinstance(value, list):
            for item in value: inspect_json(item)
        elif isinstance(value, str):
            fragments.append(value)
            if value.lstrip().startswith(("{", "[")):
                try: inspect_json(json.loads(value))
                except (ValueError, TypeError): pass
    fragments = [text]
    try: inspect_json(json.loads(text))
    except (ValueError, TypeError): pass
    decoded = "\n".join(fragments)
    for key, value in values.items():
        if key == "database_host":
            # Bare host/diagnostic values disclose the DB identity. A URL on a
            # different explicit port is a service address, screened separately
            # by the exact database_dsn check.
            pattern = r"(?<![A-Za-z0-9_.-])" + re.escape(value) + r"(?![A-Za-z0-9_.-]|:\d)"
            if re.search(pattern, decoded): found.add(key)
        elif key.startswith("database_user"):
            # Quoted literals and connection diagnostics; avoid matching import sys.
            pattern = r"(?:[\"']" + re.escape(value) + r"[\"']|\b(?:user(?:name)?|EXA_USER)\s*(?:=>|:|=)\s*[\"']?" + re.escape(value) + r"\b)"
            diagnostic = r"\b(?:user(?:name)?|EXA_USER)\s*(?:=>|:|=)\s*[\"']?" + re.escape(value) + r"\b"
            if re.search(pattern, decoded) or re.search(diagnostic, decoded, re.I): found.add(key)
        elif re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(value) + r"(?![A-Za-z0-9_.-])", decoded):
            found.add(key)
    return sorted(found)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--kit-home", type=Path, default=Path(os.environ.get("EXAKIT_HOME") or Path.home()/".exasol-starter-kit"))
    args = parser.parse_args(argv)
    try: values = credential_values(args.kit_home)
    except (OSError, ValueError): parser.error("Cannot read the kit manifest; a scan without its connection values is not verification")
    violations=[]
    scanned=0
    for entry in args.paths:
        for path in ([entry] if entry.is_file() else sorted(entry.rglob("*"))):
            if not path.is_file(): continue
            try: text=path.read_text()
            except (OSError, UnicodeError):
                violations.append({"file":str(path),"field":"unreadable_text"})
                continue
            scanned+=1
            for field in inspect_text(text,values): violations.append({"file":str(path),"field":field})
    print(json.dumps({"safe":bool(scanned) and not violations,"files_scanned":scanned,"violations":violations}))
    return 1 if violations else (0 if scanned else 2)


if __name__ == "__main__": raise SystemExit(main())
