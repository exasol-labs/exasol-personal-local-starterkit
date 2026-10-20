"""The UDF dev kit's rules and its database steps, shared by setup/lib/udf-devkit.sh and udf-devkit.ps1 so the two
cannot drift: the launcher version it needs, the launcher's container list, requirements pinning, BucketFS paths, the
smoke UDF that proves a container, and the container build.

    python udf_tool.py atleast <version> <minimum>        exit 0 when version >= minimum
    python udf_tool.py aliases                            the installed aliases in `exasol slc list --json` (stdin)
    python udf_tool.py pinned <requirements.txt>          "name==version" per line, or exit 2 with the reason
    python udf_tool.py relative <path>                    the path inside the bucket, or exit 2 with the reason
    python udf_tool.py smoke <alias> <schema> [pkg ...]   create and run the smoke UDF; "name version" per line,
                                                          exit 3 when a declared package is missing
    python udf_tool.py dbversion                          the database version (for a prebuilt container's check)
    python udf_tool.py build                              build a container (run with the notebook venv's Python)

The database steps connect through pyexasol as the kit's admin user: EXAKIT_PYX_DSN, EXAKIT_PYX_USER and
EXAKIT_PYX_PWFILE (the FILE holding the password - the password itself never reaches a command line). The rules are the
0.3.0 kit's exakit/domain/udf.py.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path, PurePosixPath

_IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
_REQUIREMENT = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*(?:(==|>=|<=|~=|!=|>|<)\s*([^\s;#]+))?\s*(?:;.*)?$")


class Refused(ValueError):
    """Input the kit refuses; the message names what is wrong."""


def _key(version: str) -> list[int]:
    return [int(p) for p in re.findall(r"\d+", version)[:3]] + [0] * 3


def at_least(version: str, minimum: str) -> bool:
    """True when ``version`` is ``minimum`` or later (numeric parts, a leading v ignored)."""
    return bool(version) and _key(version)[:3] >= _key(minimum)[:3]


def identifier(value: str, what: str) -> str:
    """An unquoted SQL identifier, upper-cased; anything else is refused."""
    if not _IDENT.match(value or ""):
        raise Refused(f"{what} '{value}' is not a plain SQL name (a letter, then letters, digits or _).")
    return value.upper()


def installed_aliases(rows: list) -> list[str]:
    """The aliases of the installed containers in the launcher's ``slc list --json`` answer."""
    out: list[str] = []
    for item in rows:
        if isinstance(item, dict) and item.get("installed"):
            out += [str(a) for a in (item.get("aliases") or [item.get("alias")]) if a]
    return out


def requirements(text: str) -> list[str]:
    """The requirement lines of a requirements.txt; options, URLs and includes are refused by name."""
    out: list[str] = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split(" #", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith(("-", ".", "/")) or "://" in line:
            raise Refused(f"requirements line {number} ('{line}') is not a package: options, URLs and paths are not supported here.")
        if not _REQUIREMENT.match(line):
            raise Refused(f"requirements line {number} ('{line}') is not a package requirement (name, optionally ==version).")
        out.append(line)
    if not out:
        raise Refused("The requirements file names no package.")
    return out


def pinned(lines: list[str]) -> list[tuple[str, str]]:
    """(name, version) for each requirement; a build takes exact pins only (name==version), so it is reproducible."""
    out: list[tuple[str, str]] = []
    for line in lines:
        match = _REQUIREMENT.match(line)
        if not match or match.group(3) != "==":
            raise Refused(f"'{line}' is not pinned: a container build needs name==version for every package.")
        out.append((match.group(1), match.group(4)))
    return out


def bucket_relative(path: str) -> PurePosixPath:
    """A path inside the bucket: relative, no '..', no drive. The kit never writes outside the bucket."""
    text = (path or "").replace("\\", "/").strip("/")
    parts = [p for p in text.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts) or re.match(r"^[A-Za-z]:", text):
        raise Refused(f"'{path}' is not a path inside the bucket (relative, no '..'), for example: models/model.pkl")
    return PurePosixPath(*parts)


def smoke_script(alias: str, schema: str, packages: list[str]) -> str:
    """The CREATE SCRIPT for a UDF that reports each distribution's version, or MISSING, one row each."""
    names = ", ".join(repr(p) for p in packages)
    return (f"CREATE OR REPLACE {identifier(alias, 'The container alias')} SCALAR SCRIPT "
            f"{identifier(schema, 'The schema')}.EXAKIT_SMOKE() EMITS (PACKAGE VARCHAR(200), VERSION VARCHAR(200)) AS\n"
            "import sys\n"
            "from importlib import metadata\n"
            "def run(ctx):\n"
            "    ctx.emit('python', sys.version.split()[0])\n"
            f"    for name in [{names}]:\n"
            "        try:\n"
            "            ctx.emit(name, metadata.version(name))\n"
            "        except Exception:\n"
            "            ctx.emit(name, 'MISSING')\n")


def _connect():
    import ssl

    import pyexasol
    password = Path(os.environ["EXAKIT_PYX_PWFILE"]).read_text(encoding="utf-8").strip()
    kw = dict(dsn=os.environ["EXAKIT_PYX_DSN"], user=os.environ["EXAKIT_PYX_USER"], password=password, fetch_dict=True)
    try:
        return pyexasol.connect(encryption=True, websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, **kw)
    except Exception:
        return pyexasol.connect(encryption=False, **kw)


def smoke(alias: str, schema: str, packages: list[str]) -> int:
    """Create and run the smoke UDF; print "name version" lines; 3 when a declared package is missing."""
    schema = identifier(schema, "The schema")
    conn = _connect()
    try:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        conn.execute(smoke_script(alias, schema, packages))
        rows = conn.execute(f"SELECT {schema}.EXAKIT_SMOKE()").fetchall()
    finally:
        conn.close()
    found = {str(r.get("PACKAGE")): str(r.get("VERSION")) for r in rows}
    for name, version in found.items():
        print(f"{name} {version}")
    missing = [p for p in packages if found.get(p, "MISSING") == "MISSING"]
    if missing:
        print(f"missing: {', '.join(missing)}", file=sys.stderr)
        return 3
    return 0


def db_version() -> str:
    conn = _connect()
    try:
        rows = conn.execute("SELECT PARAM_VALUE FROM SYS.EXA_METADATA WHERE PARAM_NAME = 'databaseProductVersion'").fetchall()
    finally:
        conn.close()
    return str(rows[0]["PARAM_VALUE"]) if rows else ""


def build() -> int:
    """Build a container with the connector's SLC tooling (EXAKIT_UDF_BUILD: work_dir, name, flavor, packages; SCS_FILE,
    SCS_MASTER_PASSWORD: the notebook store). Prints {"tarball": path}."""
    doc = json.loads(os.environ["EXAKIT_UDF_BUILD"])
    os.chdir(doc["work_dir"])
    from exasol.exaslpm.model.package_file_config import PipPackage
    from exasol.nb_connector.secret_store import Secrets
    from exasol.nb_connector.slc.script_language_container import ScriptLanguageContainer
    secrets = Secrets(Path(os.environ["SCS_FILE"]), os.environ["SCS_MASTER_PASSWORD"])
    slc = ScriptLanguageContainer.create_or_open(secrets, name=doc["name"], flavor=doc["flavor"])
    slc.restore_public_package_file()
    slc.append_custom_pip_packages([PipPackage(name=n, version=v) for n, v in doc["packages"]])
    slc.export()
    built = sorted(slc.workspace.export_path.glob("*.tar.gz"), key=lambda p: p.stat().st_mtime)
    if not built:
        print("the export produced no container tarball", file=sys.stderr)
        return 1
    print(json.dumps({"tarball": str(built[-1])}))
    return 0


def main(argv: list[str]) -> int:
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if command == "atleast" and len(args) == 2:
            return 0 if at_least(args[0], args[1]) else 1
        if command == "aliases":
            text = sys.stdin.read()
            start = text.find("[")
            rows = json.loads(text[start:]) if start >= 0 else None
            if not isinstance(rows, list):
                print("the launcher's container list was not JSON", file=sys.stderr)
                return 2
            print("\n".join(installed_aliases(rows)))
            return 0
        if command == "pinned" and len(args) == 1:
            for name, version in pinned(requirements(Path(args[0]).read_text(encoding="utf-8"))):
                print(f"{name}=={version}")
            return 0
        if command == "relative" and len(args) == 1:
            print(bucket_relative(args[0]).as_posix())
            return 0
        if command == "identifier" and len(args) == 1:
            print(identifier(args[0], "The name"))
            return 0
        if command == "smoke" and len(args) >= 2:
            return smoke(args[0], args[1], args[2:])
        if command == "dbversion":
            print(db_version())
            return 0
        if command == "build":
            return build()
    except Refused as err:
        print(str(err), file=sys.stderr)
        return 2
    except OSError as err:
        print(f"{err.__class__.__name__}: {err}", file=sys.stderr)
        return 2
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
