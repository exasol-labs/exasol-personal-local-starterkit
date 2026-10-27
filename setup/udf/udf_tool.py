"""The UDF dev kit's rules and its database steps, shared by setup/lib/udf-devkit.sh and udf-devkit.ps1 so the two
cannot drift: the launcher version it needs, the launcher's container list, requirements pinning, BucketFS paths, the
smoke UDF that proves a container, and the container build.

    python udf_tool.py atleast <version> <minimum>        exit 0 when version >= minimum
    python udf_tool.py aliases                            the installed aliases in `exasol slc list --json` (stdin)
    python udf_tool.py pinned <requirements.txt>          "name==version" per line, or exit 2 with the reason
    python udf_tool.py relative <path>                    the path inside the bucket, or exit 2 with the reason
    python udf_tool.py smoke <alias> <schema> [pkg[==version] ...]
                                                          create and run the smoke UDF; "name version" per line,
                                                          exit 3 when a declared package is missing, 7 when one
                                                          pinned ==version is reported with another version
    python udf_tool.py smoke-rust <alias> <schema> </buckets/... .so> <rustc> [sdk]
                                                          create and run the Rust smoke UDF over the library at
                                                          that bucket path; "container RUST", "rustc <version>",
                                                          "sdk <version>" lines; exit 7 when the reported rustc
                                                          (or sdk) is not the pinned one, or the container
                                                          refused the library (F-UDF-CL-RUST-9001), both
                                                          versions named on stderr
    python udf_tool.py dbversion                          the database version (for a prebuilt container's check)
    python udf_tool.py arch <uname -m> <os>               the DATABASE's architecture, x86_64 or aarch64 (EXAKIT_UDF_ARCH
                                                          overrides); exit 2 for a machine it does not know
    python udf_tool.py resolve <versions.json> <language> <arch> <db-version>
                                                          the matching container row as one JSON line, or exit 4
                                                          naming what did not match
    python udf_tool.py pins <versions.json> <language> <arch> [db-version]
                                                          "name version" per line: the row's pinned packages
    python udf_tool.py field <name>                       one field of the JSON row on stdin (strings bare)
    python udf_tool.py verify <file> <sha256> <size>      exit 0 when both match, 4 naming the one that does not
    python udf_tool.py build                              build a container (run with the notebook venv's Python)

The database steps connect through pyexasol as the kit's admin user: EXAKIT_PYX_DSN, EXAKIT_PYX_USER and
EXAKIT_PYX_PWFILE (the FILE holding the password - the password itself never reaches a command line). The rules are the
0.3.0 kit's exakit/domain/udf.py.
"""

from __future__ import annotations

import hashlib
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


_ARCHES = ("x86_64", "aarch64")
_RANGE = re.compile(r"^(>=|<|==)\s*([0-9][0-9.]*)$")


def database_arch(machine: str, system: str, override: str = "") -> str:
    """The architecture of the DATABASE this machine runs, which is what a container must be built for: an aarch64 VM
    on an Apple-silicon Mac, Podman's x86_64 WSL machine on Windows, the host itself on Linux. EXAKIT_UDF_ARCH wins."""
    if override:
        if override not in _ARCHES:
            raise Refused(f"EXAKIT_UDF_ARCH must be x86_64 or aarch64, not '{override}'.")
        return override
    machine, system = (machine or "").lower(), (system or "").lower()
    if system == "darwin":
        return "aarch64" if machine in ("arm64", "aarch64") else "x86_64"
    if system == "windows":
        return "x86_64"
    if system == "linux":
        if machine in ("x86_64", "amd64"):
            return "x86_64"
        if machine in ("arm64", "aarch64"):
            return "aarch64"
        raise Refused(f"No container is built for a {machine} Linux machine (x86_64 and aarch64 are).")
    raise Refused(f"No container is built for a '{system}' machine (macOS, Linux and Windows are).")


def version_in_range(version: str, spec: str) -> bool:
    """True when the dotted numeric ``version`` satisfies every comma-separated comparator in ``spec`` (>=, <, ==);
    an empty spec matches everything. ``==`` compares as many parts as it names: ==2026.2 takes 2026.2.5."""
    have = _key(version)
    for part in [p.strip() for p in (spec or "").split(",") if p.strip()]:
        match = _RANGE.match(part)
        if not match:
            raise Refused(f"'{part}' is not a version comparator (>=, < or == a dotted number).")
        op, want_text = match.group(1), match.group(2)
        want = _key(want_text)
        if op == ">=" and not have >= want:
            return False
        if op == "<" and not have < want:
            return False
        if op == "==":
            depth = len(re.findall(r"\d+", want_text)[:3])
            if have[:depth] != want[:depth]:
                return False
    return True


def container_rows(doc: dict) -> list[dict]:
    rows = ((doc.get("components") or {}).get("udf-devkit") or {}).get("containers")
    return [r for r in (rows or []) if isinstance(r, dict)]


def resolve_container(doc: dict, language: str, arch: str, db_version: str) -> dict:
    """The container row for this language, the database's architecture and its version; refused with the thing that
    did not match named, so the user knows whether to wait for a kit update or for a container."""
    for_language = [r for r in container_rows(doc) if r.get("language") == language]
    if not for_language:
        raise Refused(f"no {language} container is published in this kit's versions.json")
    for_arch = [r for r in for_language if r.get("arch") == arch]
    if not for_arch:
        raise Refused(f"no {language} container for {arch}")
    if not db_version:
        raise Refused("the database version is not known (is it running? exakit status)")
    for row in for_arch:
        if version_in_range(db_version, str(row.get("db_versions") or "")):
            return row
    ranges = ", ".join(str(r.get("db_versions") or "any") for r in for_arch)
    raise Refused(f"container needs database {ranges}, this one is {db_version}")


def container_pins(row: dict) -> list[tuple[str, str]]:
    """(name, version) of a row's pinned packages (Python) or crates (Rust)."""
    pinned_set = row.get("packages") or row.get("crates") or {}
    return [(str(n), str(v)) for n, v in pinned_set.items()]


def verify_file(path: str, sha256: str, size: int) -> None:
    """Refused unless the file has exactly this size and digest. Size first: a truncated download is the usual case
    and the message says how far it got, which a resumed download fixes."""
    file = Path(path)
    if not file.is_file():
        raise Refused(f"{path} is not there")
    actual_size = file.stat().st_size
    if actual_size != int(size):
        raise Refused(f"expected {size} bytes, got {actual_size}")
    digest = hashlib.sha256()
    with file.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != str(sha256).lower():
        raise Refused(f"sha256 expected {sha256}, got {actual}")


def split_pins(packages: list[str]) -> list[tuple[str, str]]:
    """"name==version" -> (name, version); a bare name -> (name, "")."""
    out: list[tuple[str, str]] = []
    for item in packages:
        name, _, version = item.partition("==")
        out.append((name.strip(), version.strip()))
    return out


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
    """Create and run the smoke UDF; print "name version" lines; 3 when a declared package is missing, 7 when one
    given as name==version is there with another version (the container is not the one the kit pinned)."""
    schema = identifier(schema, "The schema")
    pins = split_pins(packages)
    names = [name for name, _ in pins]
    conn = _connect()
    try:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        conn.execute(smoke_script(alias, schema, names))
        rows = conn.execute(f"SELECT {schema}.EXAKIT_SMOKE()").fetchall()
    finally:
        conn.close()
    found = {str(r.get("PACKAGE")): str(r.get("VERSION")) for r in rows}
    for name, version in found.items():
        print(f"{name} {version}")
    return smoke_verdict(found, pins)


def smoke_verdict(found: dict, pins: list[tuple[str, str]]) -> int:
    """0, or 3 (a package missing) before 7 (a pinned version not the reported one), the reasons on stderr."""
    missing = [name for name, _ in pins if found.get(name, "MISSING") == "MISSING"]
    if missing:
        print(f"missing: {', '.join(missing)}", file=sys.stderr)
        return 3
    differs = [(name, found[name], want) for name, want in pins if want and found[name] != want]
    for name, got, want in differs:
        print(f"{name} reported {got}, pinned {want}", file=sys.stderr)
    return 7 if differs else 0


# --- the Rust smoke UDF (design 5, AC-ML1.5) ------------------------------------------------------------------------
#
# udf/rust-smoke is one scalar UDF, EXAKIT_SMOKE(x BIGINT) RETURNS VARCHAR(2000), built by CI for each architecture
# and copied into the bucket by the kit; it answers {"container": "RUST", "rustc": "rustc 1.98.1 (...)", "sdk":
# "0.33.0", "x": 1}. The database checks the library's ABI fingerprint (SDK_VERSION:RUSTC_VERSION) when it loads it
# and refuses another build with F-UDF-CL-RUST-9001; the kit maps that to step smoke, exit 7, naming both sides.

_BUCKET_SO = re.compile(r"^/buckets/[A-Za-z0-9_][A-Za-z0-9_./-]*\.so$")
_SEMVER = re.compile(r"\d+\.\d+\.\d+")
RUST_LOAD_ERROR = "F-UDF-CL-RUST-9001"
RUST_SMOKE_NAME = "EXAKIT_SMOKE"


def rust_smoke_script(alias: str, schema: str, udf_path: str) -> str:
    """The CREATE SCRIPT for the Rust smoke UDF over the library at ``udf_path`` (a /buckets/... .so path, nothing
    else reaches the SQL)."""
    if not _BUCKET_SO.match(udf_path or ""):
        raise Refused(f"'{udf_path}' is not a /buckets/... path to a .so file.")
    return (f"CREATE OR REPLACE {identifier(alias, 'The container alias')} SCALAR SCRIPT "
            f"{identifier(schema, 'The schema')}.{RUST_SMOKE_NAME}(x BIGINT) RETURNS VARCHAR(2000) AS\n"
            f"%udf_object {udf_path};\n")


def rustc_semver(text: str) -> str:
    """"rustc 1.98.1 (48a229cea 2026-09-01)" -> "1.98.1"; a bare version passes through; "" when none."""
    match = _SEMVER.search(text or "")
    return match.group(0) if match else ""


def rust_smoke_report(text: str) -> dict:
    """The UDF's answer as a dict; refused when it is not the JSON object the kit's library returns."""
    try:
        report = json.loads(text or "")
    except ValueError:
        raise Refused(f"the smoke UDF answered '{text}', not a JSON object") from None
    if not isinstance(report, dict) or "rustc" not in report:
        raise Refused(f"the smoke UDF answered '{text}', not {{container, rustc, sdk}}")
    return report


def rust_smoke_verdict(report: dict, rustc_pin: str, sdk_pin: str = "") -> tuple[list[str], int]:
    """("name version" lines, 0 or 7): the lines the kit prints (container, rustc as x.y.z, sdk, rustc_full) and 7
    when the reported rustc (or the sdk, when pinned) is not the pinned one, the two versions on stderr."""
    rustc_full = str(report.get("rustc") or "")
    rustc = rustc_semver(rustc_full) or rustc_full
    sdk = str(report.get("sdk") or "")
    lines = [f"container {report.get('container') or 'RUST'}", f"rustc {rustc or 'unknown'}", f"sdk {sdk or 'unknown'}"]
    if rustc_full and rustc_full != rustc:
        lines.append(f"rustc_full {rustc_full}")
    code = 0
    if rustc_semver(rustc_pin) and rustc != rustc_semver(rustc_pin):
        print(f"rustc reported {rustc or 'nothing'}, pinned {rustc_semver(rustc_pin)}", file=sys.stderr)
        code = 7
    if sdk_pin and sdk != sdk_pin:
        print(f"exasol-udf-sdk reported {sdk or 'nothing'}, pinned {sdk_pin}", file=sys.stderr)
        code = 7
    return lines, code


def rust_load_reason(error: str, rustc_pin: str, sdk_pin: str) -> str:
    """One line for a database error while creating or running the smoke UDF: an ABI refusal (F-UDF-CL-RUST-9001)
    is named as such, with the fingerprint the container expects (sdk:rustc), so the user knows the library and the
    container disagree rather than the database being broken."""
    text = " ".join(str(error or "").split())
    if RUST_LOAD_ERROR in text:
        return (f"the RUST container refused to load the smoke library ({RUST_LOAD_ERROR}: ABI fingerprint mismatch): "
                f"the library was built for another exasol-udf-sdk or rustc than the container's "
                f"{sdk_pin or '?'}:rustc_{rustc_semver(rustc_pin) or '?'} - {text}")
    return f"the smoke UDF did not run: {text}"


def smoke_rust(alias: str, schema: str, udf_path: str, rustc_pin: str, sdk_pin: str = "") -> int:
    """Create the Rust smoke UDF over the library in the bucket, run it once, print the "name version" lines; 7 with
    both versions on stderr when the reported rustc or sdk is not the pinned one or the container refused the
    library."""
    script = rust_smoke_script(alias, schema, udf_path)
    schema = identifier(schema, "The schema")
    conn = _connect()
    try:
        try:
            conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
            conn.execute(script)
            rows = conn.execute(f"SELECT {schema}.{RUST_SMOKE_NAME}(1) AS ANSWER").fetchall()
        except Exception as err:  # the driver's error carries the database's message
            print(rust_load_reason(str(err), rustc_pin, sdk_pin), file=sys.stderr)
            return 7
    finally:
        conn.close()
    answer = str(rows[0]["ANSWER"]) if rows else ""
    try:
        report = rust_smoke_report(answer)
    except Refused as err:
        print(str(err), file=sys.stderr)
        return 7
    lines, code = rust_smoke_verdict(report, rustc_pin, sdk_pin)
    print("\n".join(lines))
    return code


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


def _load_json(path: str) -> dict:
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        raise Refused(f"{path} is not a JSON object")
    return doc


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
        if command == "smoke-rust" and len(args) in (4, 5):
            return smoke_rust(args[0], args[1], args[2], args[3], args[4] if len(args) == 5 else "")
        if command == "dbversion":
            print(db_version())
            return 0
        if command == "arch" and len(args) == 2:
            print(database_arch(args[0], args[1], os.environ.get("EXAKIT_UDF_ARCH", "")))
            return 0
        if command == "resolve" and len(args) == 4:
            try:
                print(json.dumps(resolve_container(_load_json(args[0]), args[1], args[2], args[3])))
            except Refused as err:
                print(str(err), file=sys.stderr)
                return 4
            return 0
        if command == "pins" and len(args) in (3, 4):
            doc = _load_json(args[0])
            rows = [r for r in container_rows(doc) if r.get("language") == args[1] and r.get("arch") == args[2]]
            if len(args) == 4:
                rows = [r for r in rows if version_in_range(args[3], str(r.get("db_versions") or ""))]
            if not rows:
                print(f"no {args[1]} container for {args[2]}", file=sys.stderr)
                return 4
            for name, version in container_pins(rows[0]):
                print(f"{name} {version}")
            return 0
        if command == "field" and len(args) == 1:
            row = json.loads(sys.stdin.read() or "{}")
            value = row.get(args[0]) if isinstance(row, dict) else None
            if value is None:
                return 1
            print(value if isinstance(value, str) else json.dumps(value))
            return 0
        if command == "verify" and len(args) == 3:
            try:
                verify_file(args[0], args[1], int(args[2]))
            except Refused as err:
                print(str(err), file=sys.stderr)
                return 4
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
