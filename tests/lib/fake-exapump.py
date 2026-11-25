"""A stand-in for `exapump sql -p <profile> -f json`, backed by a JSON state file.

Simulates exactly the slice of Exasol the preprocessor setup touches: the
SQL_PREPROCESSOR_SCRIPT slot (system and session), the PREPROC/PREPROC_RT
schemas, their scripts, the PREPROC_ADMIN role, who owns the schemas, the rules in PREPROC.CONFIG,
and whether a statement is dispatched to the kit's probe module. One
invocation is one session, as with the real tool.

Like exapump: statements end at ';', a script body runs from its CREATE line
to a lone '/' ended by a bare LF (a CRLF "/\r" is not one), execution stops at the first failing statement with exit 1 and
an "Error: ..." line on stderr, and each SELECT prints one JSON array.

    FAKE_EXAPUMP_STATE=/path/state.json python3 fake-exapump.py sql -p P -f json

state.json keys (all optional): system_slot, schemas, scripts, role, rules,
owners (schema -> owner, default SYS), grants (the GRANT statements that ran),
modules (PREPROC.MODULES provenance rows), refreshes (a count), users (the
database's users, default ["SYS"]), resolution (PREPROC.RESOLUTION as
[user, script] pairs, written by every REFRESH; until the first one it is what a
refresh would build from the rules now), faults (list),
calls (appended: one list of statements per invocation), jvs (JSON Tables
wrapper packages: {helper schema: {"roots": [...], "relationships": [...],
"members": [...]}}, each row a dict of the __JVS_* table's columns, answered
to SYS.EXA_ALL_TABLES and the __JVS_* reads as JSON Tables makes them).
Like exapump's JSON, a NULL value's key is left out of its row.
Faults: fail_on:<substring>, noop_on:<substring> (answers OK, changes nothing), no_dispatch, break_ordinary_when_active,
master_broken (while the dispatcher is the effective slot, every statement but
ALTER SESSION fails, as a broken MASTER does), fail_alter_system, down. Like a local deployment with no script language
container, a PYTHON3 script cannot be created unless state has "python": true.
"""

import json
import os
import re
import sys

DISPATCHER = "PREPROC_RT.MASTER"
PROBE = "PREPROC_RT.EXAKIT_PROBE_V1"


def load(path):
    try:
        with open(path) as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        doc = {}
    doc.setdefault("system_slot", "")
    doc.setdefault("schemas", [])
    doc.setdefault("scripts", [])
    doc.setdefault("role", False)
    doc.setdefault("rules", [])
    doc.setdefault("modules", [])
    doc.setdefault("faults", [])
    doc.setdefault("calls", [])
    return doc


def split(text):
    statements, current, in_script = [], [], False
    # Lines end at "\n" only, and a script body ends at a line holding nothing but
    # "/" (after spaces or tabs), as in exapump 0.14's scanner (src/commands/sql.rs,
    # scan_script_body: '/' at a line start followed by '\n' or the end of input).
    # So a CRLF "/\r" does not end a body: the body runs on to the end of the
    # input, swallowing every statement after it, and exapump still exits 0.
    for line in text.split("\n"):
        stripped = line.strip()
        if in_script:
            if line.lstrip(" \t") == "/":
                statements.append("\n".join(current).strip())
                current, in_script = [], False
            else:
                current.append(line)
            continue
        if not current and (stripped.startswith("--") or not stripped):
            continue
        current.append(line)
        if re.match(r"(?i)^\s*CREATE\s+(OR\s+REPLACE\s+)?(LUA|PYTHON3)\b", "\n".join(current)):
            in_script = True
            continue
        if stripped.endswith(";"):
            statements.append("\n".join(current).strip().rstrip(";").strip())
            current = []
    if current and "\n".join(current).strip():
        statements.append("\n".join(current).strip().rstrip(";").strip())
    return statements


class Fail(Exception):
    pass


def resolve(doc):
    """PREPROC.RESOLUTION as a REFRESH builds it: a ROLE PUBLIC rule reaches every
    user, a USER rule its user, any other role (DBA) the first user, the admin."""
    users = doc.get("users") or ["SYS"]
    pairs = []
    for rule in doc["rules"]:
        if not rule.get("enabled", True):
            continue
        scope = (rule.get("scope_type", "ROLE"), rule.get("scope_value", "DBA"))
        if scope == ("ROLE", "PUBLIC"):
            pairs += [[user, rule["script"]] for user in users]
        elif scope[0] == "USER":
            pairs.append([str(scope[1]).upper(), rule["script"]])
        else:
            pairs.append([users[0], rule["script"]])
    return pairs


def resolution(doc):
    return doc["resolution"] if "resolution" in doc else resolve(doc)


def literals(args):
    """The arguments of an EXECUTE SCRIPT call: 'text' (quotes doubled), numbers, NULL, TRUE/FALSE."""
    values = []
    for match in re.finditer(r"'((?:[^']|'')*)'|(-?\d+)|(NULL|TRUE|FALSE)", args, re.I):
        if match.group(1) is not None:
            values.append(match.group(1).replace("''", "'"))
        elif match.group(2) is not None:
            values.append(int(match.group(2)))
        else:
            values.append({"NULL": None, "TRUE": True, "FALSE": False}[match.group(3).upper()])
    return values


def norm(value):
    value = (value or "").strip().strip("'").replace('"', "").upper()
    return "" if value in ("", "NULL") else value


def run(doc, sql, out):
    up = sql.upper()
    session = doc["_session"]
    effective = session if session is not None else doc["system_slot"]
    active = effective == DISPATCHER and DISPATCHER in doc["scripts"]
    for fault in doc["faults"]:
        if fault.startswith("fail_on:") and fault[len("fail_on:"):] in sql:
            raise Fail("injected failure on %s" % fault[len("fail_on:"):])
        if fault.startswith("noop_on:") and fault[len("noop_on:"):] in sql:
            return                              # answers OK and changes nothing
    if active and "master_broken" in doc["faults"] and not up.startswith("ALTER SESSION"):
        raise Fail("preprocessor script PREPROC_RT.MASTER failed: attempt to index a nil value")
    m = re.match(r"(?is)^ALTER\s+(SESSION|SYSTEM)\s+SET\s+sql_preprocessor_script\s*=\s*(.*)$", sql)
    if m:
        value = norm(m.group(2))
        if m.group(1).upper() == "SYSTEM":
            if "fail_alter_system" in doc["faults"]:
                raise Fail("insufficient privileges for ALTER SYSTEM")
            doc["system_slot"] = value
        else:
            doc["_session"] = value
        return
    if up.startswith("SELECT 'EXAKIT_PP_ORDINARY'"):
        if active and "break_ordinary_when_active" in doc["faults"]:
            raise Fail("preprocessor error: ordinary statement rewritten badly")
        out.append([{"R": "EXAKIT_PP_ORDINARY"}])
        return
    if up.startswith("SELECT 'EXAKIT_PP_PROBE_IN'"):
        dispatched = (active and "no_dispatch" not in doc["faults"] and PROBE in doc["scripts"]
                      and any(rule["script"] == PROBE for rule in doc["rules"]))
        out.append([{"R": "EXAKIT_PP_PROBE_OUT" if dispatched else "EXAKIT_PP_PROBE_IN"}])
        return
    if "__JVS_" in up:
        jvs = doc.get("jvs") or {}
        if "FROM SYS.EXA_ALL_TABLES" in up:
            out.append([{"TABLE_SCHEMA": name} for name in sorted(jvs)])
            return
        m = re.search(r'FROM\s+"?(\w+)"?\."?(__JVS_\w+)"?', sql, re.I)
        package = jvs.get(m.group(1).upper()) if m else None
        if package is None:
            raise Fail("object %s not found" % (m.group(0) if m else "__JVS_*"))
        key = {"__JVS_ROOTS": "roots", "__JVS_RELATIONSHIPS": "relationships",
               "__JVS_COLUMN_MEMBERS": "members"}[m.group(2).upper()]
        out.append([{k: v for k, v in row.items() if v is not None} for row in package.get(key, [])])
        return
    if "FROM EXA_DBA_USERS" in up:                 # users a ROLE PUBLIC rule reaches with no RESOLUTION row
        public = any(r.get("enabled", True) and (r.get("scope_type", "ROLE"), r.get("scope_value", "DBA"))
                     == ("ROLE", "PUBLIC") for r in doc["rules"])
        resolved = set(user for user, _ in resolution(doc))
        out.append([{"N": len([u for u in (doc.get("users") or ["SYS"]) if u not in resolved]) if public else 0}])
        return
    if "FROM PREPROC.RESOLUTION" in up:
        if "PREPROC" not in doc["schemas"]:
            raise Fail("object PREPROC.RESOLUTION not found")
        out.append([{"S": name} for name in sorted(set(script for _, script in resolution(doc)))])
        return
    if "FROM EXA_PARAMETERS" in up:
        out.append([{"S": doc["system_slot"]}] if doc["system_slot"] else [{}])
        return
    if "FROM EXA_SCHEMAS" in up:
        m = re.search(r"SCHEMA_NAME\s+IN\s*\(([^)]*)\)", sql, re.I)
        wanted = set(literals(m.group(1))) if m else None
        if "SCHEMA_OWNER" in up:
            out.append([{"N": name, "O": doc.get("owners", {}).get(name, "SYS")} for name in doc["schemas"]
                        if wanted is None or name in wanted])
            return
        out.append([{"N": name} for name in doc["schemas"] if wanted is None or name in wanted])
        return
    if "FROM EXA_ALL_SCRIPTS" in up:
        out.append([{"N": name} for name in doc["scripts"]])
        return
    if "FROM EXA_DBA_TABLES" in up:                 # PREPROC.CONFIG exists once its schema does
        out.append([{"N": "CONFIG"}] if "PREPROC" in doc["schemas"] else [])
        return
    if "FROM EXA_DBA_ROLES" in up:
        out.append([{"N": "PREPROC_ADMIN"}] if doc["role"] else [])
        return
    if "FROM PREPROC.CONFIG" in up:
        if "PREPROC" not in doc["schemas"]:
            raise Fail("object PREPROC.CONFIG not found")
        if "SCOPE_TYPE AS ST" in up:
            out.append([{"ID": r["id"], "ST": r.get("scope_type", "ROLE"), "SV": r.get("scope_value", "DBA"),
                         "PH": r.get("phase", "EXPAND"), "S": r["script"], "F": r.get("function", "expand"),
                         "E": r.get("enabled", True)} for r in doc["rules"]])
        elif "DISTINCT SCRIPT_NAME" in up:
            out.append([{"N": name} for name in sorted(set(r["script"] for r in doc["rules"]))])
        else:
            wanted = re.search(r"SCRIPT_NAME\s*=\s*'([^']*)'", sql).group(1)
            out.append([{"ID": r["id"]} for r in doc["rules"] if r["script"] == wanted])
        return
    if "FROM PREPROC.MODULES" in up:
        if "PREPROC" not in doc["schemas"]:
            raise Fail("object PREPROC.MODULES not found")
        wanted = re.search(r"NAME\s*=\s*'([^']*)'", sql).group(1)
        out.append([{"V": m["version"], "ST": m["status"], "H": m["sha256"]}
                    for m in doc["modules"] if m["name"] == wanted])
        return
    if "FROM PREPROC_RT.MY_PIPELINE" in up:
        if "PREPROC_RT" not in doc["schemas"]:
            raise Fail("object PREPROC_RT.MY_PIPELINE not found")
        out.append([{"N": 0}])
        return
    if up.startswith("CREATE ROLE"):
        if doc["role"]:
            raise Fail("role PREPROC_ADMIN already exists")
        doc["role"] = True
        return
    m = re.match(r"(?i)^ALTER SCHEMA (\w+) CHANGE OWNER (\w+)$", sql)
    if m:
        if m.group(2).upper() != "SYS" and not doc["role"]:
            raise Fail("user or role %s does not exist" % m.group(2).upper())
        doc.setdefault("owners", {})[m.group(1).upper()] = m.group(2).upper()
        return
    if up.startswith("GRANT "):
        if up.endswith(" TO PREPROC_ADMIN") and not doc["role"]:
            raise Fail("user or role PREPROC_ADMIN does not exist")
        if up not in doc.setdefault("grants", []):
            doc["grants"].append(up)
        return
    m = re.match(r"(?i)^CREATE SCHEMA (IF NOT EXISTS )?(\w+)", sql)
    if m:
        if m.group(2).upper() not in doc["schemas"]:
            doc["schemas"].append(m.group(2).upper())
        return
    m = re.match(r"(?is)^CREATE\s+(OR\s+REPLACE\s+)?(LUA|PYTHON3)[\w\s]*?SCRIPT\s+([\w.]+)", sql)
    if m and m.group(2).upper() == "PYTHON3" and not doc.get("python"):
        raise Fail("No usable script language container is installed for the requested language.")
    if m:
        name = m.group(3).upper()
        if name.split(".")[0] not in doc["schemas"]:
            raise Fail("schema %s not found" % name.split(".")[0])
        if name not in doc["scripts"]:
            doc["scripts"].append(name)
        return
    if up.startswith("INSERT INTO PREPROC.CONFIG"):
        doc["rules"].append({"id": len(doc["rules"]) + 1, "script": "PREPROC_RT.CONTROL_SUGAR_V1"})
        return
    m = re.match(r"(?is)^EXECUTE SCRIPT PREPROC.RULE_ENSURE\((.*)\)$", sql)
    if m:
        scope_type, scope_value, phase, script, function = literals(m.group(1))[:5]
        script = script.upper()
        if script not in doc["scripts"]:
            raise Fail("script %s does not exist" % script)
        key = {"scope_type": scope_type, "scope_value": scope_value, "phase": phase, "script": script,
               "function": function}
        existing = [r for r in doc["rules"] if all(r.get(k, key[k]) == key[k] for k in key)
                    and r.get("enabled", True)]
        if not existing:
            existing = [dict(key, id=max([r["id"] for r in doc["rules"]] or [0]) + 1, enabled=True)]
            doc["rules"].append(existing[0])
        if literals(m.group(1))[-1] is False:   # norefresh FALSE: the framework refreshes
            doc["resolution"] = resolve(doc)
        out.append([{"RULE_ID": existing[0]["id"]}])
        return
    m = re.match(r"(?is)^EXECUTE SCRIPT PREPROC.MODULE_REGISTER\((.*)\)$", sql)
    if m:
        values = literals(m.group(1))
        name, version, sha, script = values[0], values[1], values[4], values[5]
        if script.upper() not in doc["scripts"]:
            raise Fail("script %s does not exist" % script)
        row = {"name": name, "version": version, "source": values[2], "ref": values[3], "sha256": sha,
               "script": script, "function": values[6], "phase": values[7], "deploy_mode": values[8],
               "library_version": values[10], "objects": values[11], "status": "deployed"}
        doc["modules"] = [r for r in doc["modules"] if not (r["name"] == name and r["version"] == version)]
        doc["modules"].append(row)
        out.append([{"NAME": name, "VERSION": version, "STATUS": "deployed"}])
        return
    m = re.match(r"(?is)^EXECUTE SCRIPT PREPROC.MODULE_RETIRE\((.*)\)$", sql)
    if m:
        name, version = literals(m.group(1))[:2]
        rows = [r for r in doc["modules"] if r["name"] == name and r["version"] == version]
        if not rows:
            raise Fail("PREPROC.MODULE_RETIRE: no provenance row for (%s, %s)" % (name, version))
        rows[0]["status"] = "retired"
        out.append([{"NAME": name, "VERSION": version, "STATUS": "retired"}])
        return
    m = re.match(r"(?is)^EXECUTE SCRIPT PREPROC.MODULE_RECLAIM\((.*)\)$", sql)
    if m:
        name, version = literals(m.group(1))[:2]
        rows = [r for r in doc["modules"] if r["name"] == name and r["version"] == version]
        if not rows or rows[0]["status"] != "retired":
            out.append([{"STATUS": "not_retired"}])
            return
        names = [line.split("|", 1)[1] for line in (rows[0]["objects"] or rows[0]["script"]).split("\n")]
        if any(r["script"] in names and r.get("enabled", True) for r in doc["rules"]):
            out.append([{"STATUS": "blocked_by_rule"}])
            return
        doc["scripts"] = [s for s in doc["scripts"] if s not in names]
        doc["modules"].remove(rows[0])
        out.append([{"STATUS": "reclaimed"}])
        return
    m = re.match(r"(?i)^EXECUTE SCRIPT PREPROC.RULE_DROP\((\d+)", sql)
    if m:
        doc["rules"] = [r for r in doc["rules"] if r["id"] != int(m.group(1))]
        out.append([{"DROPPED": 1}])
        return
    m = re.match(r"(?i)^DROP SCRIPT (IF EXISTS )?([\w.]+)", sql)
    if m:
        doc["scripts"] = [s for s in doc["scripts"] if s != m.group(2).upper()]
        return
    m = re.match(r"(?i)^DROP SCHEMA (IF EXISTS )?(\w+)", sql)
    if m:
        schema = m.group(2).upper()
        doc["schemas"] = [s for s in doc["schemas"] if s != schema]
        doc["scripts"] = [s for s in doc["scripts"] if not s.startswith(schema + ".")]
        if schema == "PREPROC":
            doc["rules"] = []
        return
    if up.startswith("DROP ROLE"):
        doc["role"] = False
        return
    if up.startswith("EXECUTE SCRIPT PREPROC.STATUS"):
        stale = bool(doc.get("stale"))
        out.append([{"IS_STALE": stale, "VERDICT": "STALE" if stale else "CURRENT", "LAST_REFRESH": "2026-10-27 21:21:09"}])
        return
    if up.startswith("EXECUTE SCRIPT PREPROC.REFRESH"):
        doc["stale"] = False
        doc["resolution"] = resolve(doc)
        doc["refreshes"] = doc.get("refreshes", 0) + 1
        out.append([{"REFRESHED": True}])
        return
    if up.startswith("EXECUTE SCRIPT"):
        out.append([])
        return
    # Anything else (GRANT, ALTER SCHEMA, CREATE TABLE, SELECT 1 ...) succeeds.
    if up.startswith("SELECT"):
        out.append([{"X": 1}])


def main():
    path = os.environ["FAKE_EXAPUMP_STATE"]
    doc = load(path)
    args = sys.argv[1:]
    sql = args[-1] if args and args[0] == "sql" and not args[-1].startswith("-") and args[-1] != "json" else None
    # The bytes exapump is handed, undecoded by any newline translation (Windows'
    # text-mode stdin would turn CRLF into LF and hide what exapump really sees).
    text = sql if sql is not None else sys.stdin.buffer.read().decode("utf-8")
    statements = split(text)
    doc["calls"].append(statements)
    if "down" in doc["faults"]:
        with open(path, "w") as handle:
            json.dump(doc, handle, indent=1)
        sys.stderr.write("Error: Connection refused\n")
        return 1
    doc["_session"] = None
    out, rc = [], 0
    for index, statement in enumerate(statements, 1):
        sys.stderr.write("[%d/%d] %s\n" % (index, len(statements), statement[:60].replace("\n", " ")))
        try:
            run(doc, statement, out)
        except Fail as error:
            sys.stderr.write("Error in statement %d:\n  %s\n\n  Query execution failed: %s\n" % (index, statement[:60], error))
            sys.stderr.write("Error: Query execution failed: %s (Session: 1)\n" % error)
            rc = 1
            break
    doc.pop("_session", None)
    with open(path, "w") as handle:
        json.dump(doc, handle, indent=1)
    sys.stdout.write("\n".join(json.dumps(result) for result in out))
    return rc


if __name__ == "__main__":
    sys.exit(main())
