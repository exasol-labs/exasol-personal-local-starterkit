"""A stand-in for Exasol Semantic Views in a test database: the catalog reads the kit makes (PRODUCT_VERSION, MODELS,
ENTITIES) and the admin scripts it runs (CREATE_MODEL, ADD_ENTITY, DROP_MODEL_IF_EXISTS, ...), kept as models.

    sv = SemanticViews()                 # installed; SemanticViews(installed=False) until install() is called
    sv.answer(sql) -> rows | None        # a catalog read, or None when the statement is not one
    sv.apply(sql) -> bool                # an admin script, recorded; False when the statement is not one
    sv.models["support"]                 # {"description", "published_schema", "entities": [(SCHEMA, TABLE)], "scripts"}
"""

from __future__ import annotations

import re


def _args(sql: str) -> list[str | None]:
    """The arguments of EXECUTE SCRIPT X(...): string literals unquoted, NULL as None, other words as written."""
    inner = sql[sql.index("(") + 1:sql.rindex(")")]
    found, i = [], 0
    while i < len(inner):
        if inner[i] == "'":
            j, text = i + 1, []
            while j < len(inner):
                if inner[j] == "'" and inner[j + 1:j + 2] == "'":
                    text.append("'")
                    j += 2
                elif inner[j] == "'":
                    break
                else:
                    text.append(inner[j])
                    j += 1
            found.append("".join(text))
            i = j + 1
        elif inner[i].isalnum():
            j = i
            while j < len(inner) and (inner[j].isalnum() or inner[j] == "_"):
                j += 1
            word = inner[i:j]
            found.append(None if word == "NULL" else word)
            i = j
        else:
            i += 1
    return found


class SemanticViews:
    def __init__(self, installed: bool = True, version: str = "0.6.1"):
        self.installed, self.version = installed, version
        self.models: dict[str, dict] = {}
        self.scripts: list[str] = []
        self.refuse: str | None = None          # a script name the product refuses (to test a rollback)

    def install(self) -> bool:
        self.installed = True
        return True

    def answer(self, sql: str) -> list[dict] | None:
        if "SEMANTIC_CATALOG." not in sql:
            return None
        if not self.installed:
            raise RuntimeError("object SEMANTIC_CATALOG.PRODUCT_VERSION not found")
        if "PRODUCT_VERSION" in sql:
            return [{"DISPLAY_VERSION": self.version}]
        if "SEMANTIC_CATALOG.ENTITIES E" in sql:
            schema = re.search(r"SOURCE_SCHEMA = '([^']*)'", sql)
            table = re.search(r"SOURCE_OBJECT = '([^']*)'", sql)
            return [{"MODEL_NAME": name, "PUBLISHED_SCHEMA": m["published_schema"], "DESCRIPTION": m["description"]}
                    for name, m in self.models.items()
                    if schema and table and (schema.group(1), table.group(1)) in m["entities"]]
        if "SEMANTIC_CATALOG.MODELS" in sql:
            wanted = re.search(r"UPPER\('([^']*)'\)", sql)
            return [{"MODEL_NAME": name, "DESCRIPTION": m["description"], "PUBLISHED_SCHEMA": m["published_schema"],
                     "STATUS": "PUBLISHED" if m.get("published") else "DRAFT"}
                    for name, m in sorted(self.models.items()) if not wanted or name.upper() == wanted.group(1).upper()]
        return []

    def apply(self, sql: str) -> bool:
        match = re.match(r"EXECUTE SCRIPT SEMANTIC_ADMIN\.([A-Z_]+)\(", sql)
        if not match:
            return False
        if not self.installed:
            raise RuntimeError("script SEMANTIC_ADMIN.%s not found" % match.group(1))
        name, args = match.group(1), _args(sql)
        self.scripts.append(name)
        if name == self.refuse:
            raise RuntimeError(f"SEMANTIC_MODEL_030: {name} refused")
        if name == "CREATE_MODEL":
            if args[0] in self.models:
                raise RuntimeError(f"SEMANTIC_ADMIN_010: model exists: {args[0]}")
            self.models[args[0]] = {"published_schema": args[1], "description": args[2] or "", "entities": [],
                                    "definitions": [], "published": False}
        elif name == "DROP_MODEL_IF_EXISTS":
            self.models.pop(args[0], None)
        elif name == "ADD_ENTITY":
            self.models[args[0]]["entities"].append((args[2], args[3]))
        elif name in ("APPLY_SEMANTIC_DEFINITION_OR_FAIL",):
            model = re.search(r"ALTER SEMANTIC VIEW ([a-z0-9_]+)\.", args[0]).group(1)
            self.models[model]["definitions"].append(args[0])
        elif name == "PUBLISH_MODEL":
            self.models[args[0]]["published"] = True
        return True
