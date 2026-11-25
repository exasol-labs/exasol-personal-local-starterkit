"""A stand-in for the kit's database in the uninstall tests (never a real one): marketplace/kit_logins.py loads it
through EXAKIT_KIT_LOGINS_FAKE_DB and calls connect(dsn=, user=). It answers from a JSON state file, keeps that file
up to date as statements change things, and writes every statement it is handed to a log.

    EXAKIT_FAKE_DB_STATE  {"down": false,                                   connect refuses, as a stopped database
                           "users": ["MCP_READONLY"],                       EXA_DBA_USERS
                           "sessions": {"MCP_READONLY": [11, 12]},          EXA_DBA_SESSIONS
                           "roles": {"SEMANTIC_USER": ["MCP_READONLY"]},    EXA_DBA_ROLES and their grantees
                           "owners": {"PREPROC": "PREPROC_ADMIN"},          EXA_SCHEMAS.SCHEMA_OWNER
                           "connections": ["EXAKIT_SRC_SALES"],             EXA_DBA_CONNECTIONS
                           "schemas": ["VS_SALES"],                         more of EXA_SCHEMAS
                           "slot": "PREPROC_RT.MASTER",                     SQL_PREPROCESSOR_SCRIPT
                           "refuse": {"DROP USER \"X\"": "why"}}            a statement that fails, by its start
    EXAKIT_FAKE_DB_LOG    every statement, one per line

As Exasol does, a DROP USER or DROP ROLE without CASCADE is refused while the user or role still owns a schema
("CASCADE must be specified to drop ..."), so a test sees the owner change come first or the drop fail.
"""

import json
import os
import re


def _load():
    with open(os.environ["EXAKIT_FAKE_DB_STATE"], encoding="utf-8") as handle:
        return json.load(handle)


class _Db(object):
    def __init__(self, state):
        self.state = state

    def _save(self):
        with open(os.environ["EXAKIT_FAKE_DB_STATE"], "w", encoding="utf-8") as handle:
            json.dump(self.state, handle)

    def _log(self, sql):
        with open(os.environ["EXAKIT_FAKE_DB_LOG"], "a", encoding="utf-8") as handle:
            handle.write(sql + "\n")
        for start, why in (self.state.get("refuse") or {}).items():
            if sql.startswith(start):
                raise RuntimeError(why)

    def query(self, sql):
        self._log(sql)
        names = re.findall(r"'([^']*)'", sql)
        owners = self.state.get("owners", {})
        if "FROM SYS.EXA_DBA_USERS" in sql:
            return [(name,) for name in names if name in self.state.get("users", [])]
        if "FROM SYS.EXA_DBA_SESSIONS" in sql:
            return [(sid,) for sid in self.state.get("sessions", {}).get(names[0], [])]
        if "FROM SYS.EXA_DBA_ROLES" in sql:
            return [(name,) for name in names if name in self.state.get("roles", {})]
        if "FROM SYS.EXA_DBA_ROLE_PRIVS" in sql:
            return [(grantee,) for grantee in self.state.get("roles", {}).get(names[0], [])]
        if "FROM SYS.EXA_DBA_CONNECTIONS" in sql:
            return [(name,) for name in self.state.get("connections", [])]
        if "FROM SYS.EXA_SCHEMAS" in sql and "SCHEMA_OWNER =" in sql:
            return [(schema, False) for schema, owner in sorted(owners.items()) if owner == names[0]]
        if "FROM SYS.EXA_SCHEMAS" in sql:
            return [(name,) for name in names if name in self.state.get("schemas", []) or name in owners]
        if "FROM SYS.EXA_PARAMETERS" in sql:
            return [(self.state.get("slot", ""),)]
        return []

    def execute(self, sql):
        self._log(sql)
        owners = self.state.setdefault("owners", {})
        moved = re.match(r'ALTER (?:VIRTUAL )?SCHEMA "([^"]+)" CHANGE OWNER (\w+)$', sql)
        if moved:
            owners[moved.group(1)] = moved.group(2)
            self._save()
            return
        dropped = re.match(r'DROP (USER|ROLE) "([A-Z0-9_]+)"( CASCADE)?$', sql)
        if not dropped:
            return
        kind, name = dropped.group(1), dropped.group(2)
        if not dropped.group(3) and name in owners.values():
            raise RuntimeError("CASCADE must be specified to drop %s %s" % (kind.lower(), name))
        if kind == "USER" and name in self.state.get("users", []):
            self.state["users"].remove(name)
            for grantees in self.state.get("roles", {}).values():
                if name in grantees:
                    grantees.remove(name)
        if kind == "ROLE":
            self.state.get("roles", {}).pop(name, None)
        self._save()

    def close(self):
        pass


def connect(dsn, user):
    state = _load()
    if state.get("down"):
        raise ConnectionRefusedError(61, "Connection refused")
    return _Db(state)
