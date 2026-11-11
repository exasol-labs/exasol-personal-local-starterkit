"""External sources from a notebook cell: connect one, and read what a cell was given.

    nb.connect_source("postgresql", "sales", url="postgres://reader@192.168.64.1:5432/shop")   # asks the password
    nb.connect_source("postgresql", "sales", host="192.168.64.1", database="shop", user="reader")
    nb.clean_path("'/Users/me/My Data/orders.csv'")    # a pasted path: quotes, file://, "\\ " and ~ undone

connect_source runs `exakit connect <connector> --name <name> ... --password-stdin --yes --json`. The password is
asked in a hidden box and goes to the command on standard input: never into the cell, the command line or a log.
"""

from __future__ import annotations

import contextlib
import getpass
import json
import os
import re
import socket
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass, field
from typing import Any, Callable
from urllib.parse import unquote, urlsplit, urlunsplit

from ._kit import exakit_command

__all__ = ["SourceProblem", "SourceTest", "clean_path", "clean_text", "connect_source", "read_connection_string",
           "source_engine", "test_source"]

MAC_HOST = "192.168.64.1"           # where the database (in its VM) reaches this Mac
LOOPBACK = ("localhost", "127.0.0.1", "::1", "0.0.0.0")
TIMEOUT = 600
_PASSWORD_PARAM = re.compile(r"(?:^|[&;])password=([^&;]*)", re.I)    # a password in a URL query
_QUOTES = "\"'\u201c\u201d\u2018\u2019`"


class SourceProblem(ValueError):
    """A source cell that cannot go on, said in one short message: no traceback in a notebook."""

    def _render_traceback_(self) -> list[str]:          # IPython's hook for how an exception is shown
        return [str(self)]


def clean_text(value: Any) -> str:
    """A pasted value as typed: surrounding white space and quotes (straight or curly) removed."""
    text = str(value or "").strip()
    while len(text) >= 2 and text[0] in _QUOTES and text[-1] in _QUOTES:
        text = text[1:-1].strip()
    return text


def clean_path(value: Any) -> str:
    """A path pasted into a cell, made usable: quotes and spaces around it, a ``file://`` link, the shell's
    backslash escapes (``My\\ Data``, from a drag into a terminal) and ``~`` are undone. Empty stays empty."""
    text = clean_text(value)
    if not text:
        return ""
    if text.lower().startswith("file://"):
        parts = urlsplit(text)
        text = unquote(parts.path)
        if re.match(r"^/[A-Za-z]:/", text):           # file:///C:/data -> C:/data
            text = text[1:]
    elif os.sep == "/" and "\\" in text:
        text = re.sub(r"\\(.)", r"\1", text)          # the shell's escapes; Windows keeps its backslashes
    return str(Path(text).expanduser())


def _url_parts(url: str) -> tuple[str, str | None, str | None]:
    """(url without its password, the password or None, the host or None)."""
    scheme_url = url[5:] if url.lower().startswith("jdbc:") else url
    try:
        parts = urlsplit(scheme_url)
        password, host = parts.password, parts.hostname
    except ValueError:
        return url, None, None
    query = parts.query
    if password is None:
        found = _PASSWORD_PARAM.search(query)
        if not found:
            return url, None, host
        password = found.group(1)
        query = _PASSWORD_PARAM.sub("", query).lstrip("&;")
        prefix = "jdbc:" if url.lower().startswith("jdbc:") else ""
        return prefix + urlunsplit((parts.scheme, parts.netloc, parts.path, query, parts.fragment)), unquote(password), host
    netloc = parts.netloc.rsplit("@", 1)
    user = (parts.username or "")
    cleaned = urlunsplit((parts.scheme, f"{user}@{netloc[1]}" if len(netloc) == 2 else netloc[0], parts.path,
                          query, parts.fragment))
    return ("jdbc:" if url.lower().startswith("jdbc:") else "") + cleaned, unquote(password), host


def _reachable_host(host: str) -> str:
    """The host as the database must see it: on a Mac, this computer is 192.168.64.1, never its own loopback."""
    if host.strip().lower().strip("[]") in LOOPBACK and sys.platform == "darwin":
        print(f"host={host} would be the database itself; using {MAC_HOST}, where it reaches this Mac. "
              "The source must listen on that address too, not only on loopback.")
        return MAC_HOST
    return host


def _schema_name(name: str) -> str:
    return "VS_" + re.sub(r"[^A-Z0-9_]", "_", name.upper())


def _in_marimo() -> bool:
    try:
        import marimo as mo
    except ImportError:
        return False
    try:
        return bool(mo.running_in_notebook())
    except Exception:
        return False


def connect_source(connector: str, name: str, url: str | None = None, *, password: Any = None,
                   password_file: str | Path | None = None,
                   ask_password: bool = True, dry_run: bool = False, show: bool = True,
                   secret: Callable[[str], str] | None = None, storage_secret: Any = None,
                   storage_secret_file: str | Path | None = None, **settings: Any) -> str | None:
    """Connect an external source as a virtual schema, from a notebook cell. ``connector`` is the kit's id or alias
    (``postgresql``, ``pg``, ``mysql``, ``snowflake`` ...; ``exakit help connect`` lists them), ``name`` becomes the
    schema ``VS_<NAME>``. Give the source's connection string as ``url`` (a JDBC URL, ``postgres://...``), or each
    input as a keyword (``host=``, ``database=``, ``schema=``, ``user=`` ...; the connector's skill lists them).
    The password is asked in a hidden box (Enter: none), or read from ``password_file``; a password inside ``url`` is
    taken out of it and used, never shown. Marimo has no hidden prompt: pass a password field as ``password``
    (``mo.ui.text(kind="password")``, its value is read) or a ``password_file``. ``dry_run`` checks the inputs and
    connects nothing. A connector with several kinds of source in one takes its settings as keywords too
    (``catalog="unity", files="s3"`` for a Lakehouse; nb.connector_inputs lists them). A source with a second secret
    (a Lakehouse catalog login plus storage keys) takes it as ``storage_secret_file``, or as ``storage_secret`` (the
    text, a Marimo password field, or a function that asks for it): it reaches the kit in a file only this user can
    read, removed as soon as the kit has read it. Returns the schema name (``VS_SALES``) when connected, None for a dry run; raises SourceProblem with the kit's reason otherwise."""
    command = exakit_command()
    if command is None:
        raise SourceProblem("The kit's command line (exakit) is not on PATH. In a terminal: exakit connect")
    connector, name = clean_text(connector), clean_text(name)
    if not connector or not name:
        raise SourceProblem("Name the connector and the source, e.g. nb.connect_source(\"postgresql\", \"sales\", url=...).")
    args = [connector, "--name", name]
    given = getattr(password, "value", password)              # a marimo password field, or the text itself
    password = str(given) if given else None
    if url:
        url, in_url, host = _url_parts(clean_text(url))
        password = password or in_url
        if host and _reachable_host(host) != host:
            url = url.replace(host, MAC_HOST, 1)
        args += ["--url", url]
    for key, value in settings.items():
        if value is None or str(value).strip() == "":
            continue
        value = clean_text(value)
        if key == "host":
            value = _reachable_host(value)
        elif key in ("ca", "key_file", "keyfile"):
            value = clean_path(value)
        args += ["--set", f"{key}={value}"]
    if password_file:
        file = Path(clean_path(password_file))
        if not file.is_file():
            raise SourceProblem(f"No password file at {file}.")
        args += ["--password-file", str(file)]
    elif not dry_run:
        if password is None and ask_password:
            if secret is None and _in_marimo():
                raise SourceProblem('Marimo cannot ask for a password in a hidden box. In a cell: PW = '
                                    'mo.ui.text(kind="password"); PW  - type it there, then pass PW as the password argument.')
            try:
                password = (secret or getpass.getpass)(f"Password for {name} (hidden; Enter for none): ")
            except Exception as err:                       # a front end without prompts
                raise SourceProblem(f"Could not ask for the password here ({type(err).__name__}). Put it in a file "
                                    "and pass password_file=\"~/.config/exakit/<name>.pw\".") from None
        if password:
            args.append("--password-stdin")
    held: str | None = None                                # the storage secret's file, when this call wrote it
    if storage_secret_file:
        file = Path(clean_path(storage_secret_file))
        if not file.is_file():
            raise SourceProblem(f"No storage secret file at {file}.")
        args += ["--storage-secret-file", str(file)]
    elif storage_secret is not None and not dry_run:
        typed = storage_secret(f"Storage secret for {name} (hidden): ") if callable(storage_secret) else getattr(storage_secret, "value", storage_secret)
        if typed:
            import tempfile

            handle, held = tempfile.mkstemp(prefix="exakit-", suffix=".secret")      # 0600, this user only
            with os.fdopen(handle, "w", encoding="utf-8") as out:
                out.write(str(typed))
            args += ["--storage-secret-file", held]
    args += ["--dry-run"] if dry_run else ["--yes"]
    args.append("--json")
    if show:
        print(f"exakit connect {' '.join(_shown(args))}")
    try:
        done = subprocess.run([*command, "connect", *args], input=(password or "") if "--password-stdin" in args else None,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                              errors="replace", timeout=TIMEOUT, stdin=None if "--password-stdin" in args else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise SourceProblem(f"exakit connect took over {TIMEOUT // 60} minutes and was stopped. "
                            f"In a terminal: exakit source check {name}") from None
    finally:
        if held:
            with contextlib.suppress(OSError):
                os.unlink(held)
    answer = _last_json(done.stdout)
    if done.returncode != 0 or not answer.get("ok", False):
        reason = answer.get("error") or (done.stderr or done.stdout).strip().splitlines()[-1:] or [f"exit {done.returncode}"]
        reason = reason if isinstance(reason, str) else reason[0]
        remedy = answer.get("remedy")
        raise SourceProblem(f"{name} was not connected: {reason}" + (f"\nFix: {remedy}" if remedy else ""))
    if dry_run:
        print(f"The inputs are complete. Run it again without dry_run=True to connect {name}.")
        return None
    schema = str(answer.get("schema") or _schema_name(name))
    print(f"Connected: {schema}. Set SOURCE = \"{schema}.<TABLE>\"; nb.load_source(connection, \"{schema}\") lists its tables.")
    return schema


def source_engine(*words: str, text: str | None = None) -> dict[str, Any]:
    """Ask the kit's own source engine (setup/virtual-schemas/engine/cli.py, the coordinator behind `exakit connect`
    and `exakit source`) one of the questions its connect form asks, and return its --json answer:

        source_engine("catalog")                      the connectors, as the connect menu lists them
        source_engine("inputs", "postgresql")         what the form asks for one, in order
        source_engine("field", "postgresql", "port", text="5433")    is this answer right? (the value on stdin)
        source_engine("paste", "postgresql", text=...)               a connection string, read into inputs

    Run as the kit's shell runs it: the kit's Python where it is installed, isolated (-I), with this installation's
    definitions and home. None of these four touches the database. A refusal is a SourceProblem in the engine's
    words, with its remedy."""
    from ._kit import _home
    from .kit_facts import _kit_root

    root = _kit_root()
    defs = root / "setup" / "virtual-schemas" if root else None
    if defs is None or not (defs / "engine" / "cli.py").is_file():
        raise SourceProblem("This kit copy has no setup/virtual-schemas. Update it: exakit update")
    home = _home()
    kit_python = (home / "pyexasol-venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")) if home else None
    python = str(kit_python) if kit_python and kit_python.is_file() else sys.executable
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONEXECUTABLE", "__PYVENV_LAUNCHER__")}
    scratch = None
    if home is None:                    # a checkout with no installed kit (tests): the engine still wants a home
        import tempfile

        scratch = tempfile.TemporaryDirectory()
    try:
        done = subprocess.run([python, "-I", str(defs / "engine" / "cli.py"), "--defs", str(defs),
                               "--kit-home", str(home or scratch.name), "--json", *words],
                              input=text if text is not None else "", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, encoding="utf-8", errors="replace", timeout=60, env=env)
    except subprocess.TimeoutExpired:
        raise SourceProblem("The kit's source engine did not answer within a minute.") from None
    finally:
        if scratch is not None:
            scratch.cleanup()
    answer = _last_json(done.stdout)
    if not answer:
        raise SourceProblem("The kit's source engine did not answer: "
                            + ((done.stderr or done.stdout).strip().splitlines() or ["no output"])[-1])
    if not answer.get("ok", False):
        remedy = answer.get("remedy")
        generic = "correct what the error names"
        raise SourceProblem(str(answer.get("error")) + (f"\nFix: {remedy}" if remedy and generic not in remedy else ""))
    answer["events"] = [line for line in (done.stderr or "").splitlines() if line[:5] in ("INFO ", "WARN ", "OK   ")
                        or line.startswith("OK ")]
    return answer


def read_connection_string(connector: str, text: str, **settings: Any) -> dict[str, Any]:
    """Read a source's connection string exactly as `exakit connect --url` does: it is handed to the kit's engine
    (its ``paste`` command, on standard input, never as an argument). Returns {connector, values, notes, dropped,
    masked, credential_in_string, secret_input, missing}: ``values`` by input name, each checked as if typed;
    ``masked`` the string with every credential as ****; ``missing`` the connector's required inputs the string does
    not give (and no default covers). The string's password is used by nb.connect_source(url=...) and is never
    returned, printed or logged here. For a connector with settings (a Lakehouse's ``catalog=``, ``files=``) give the
    ones already chosen: a setting the string itself shows (an s3:// path
    is a folder with no catalog) comes back in ``values``, and ``missing`` is what that combination still needs."""
    import tempfile

    from .kit_facts import connector_inputs

    chosen = {key: str(value) for key, value in settings.items() if value not in (None, "")}
    form = connector_inputs(connector, **chosen)
    # The engine writes the string's credential to this owner-only file (its --secret-out), which tells it the
    # credential is the connector's own; the file is removed unread.
    fd, secret_out = tempfile.mkstemp(prefix="exakit-paste-")
    os.close(fd)
    try:
        answer = source_engine("paste", form["id"], "--secret-out", secret_out, text=clean_text(text))
        has_secret = os.path.getsize(secret_out) > 0
    finally:
        try:
            os.unlink(secret_out)
        except OSError:
            pass
    values = {k: str(v) for k, v in answer.get("values", {}).items()}
    names = {i["name"] for i in form["setting_inputs"]}
    shown = {k: v for k, v in values.items() if k in names and k not in chosen}
    if shown:                                   # the string decided a setting: what that combination asks
        form = connector_inputs(connector, **chosen, **shown)
    secret_input = next((i["name"] for i in form["inputs"] if i["kind"] == "secret"), None)
    missing = [i["name"] for i in form["inputs"]
               if i["required"] and i["name"] not in values and not i["default"]
               and not (i["kind"] == "secret" and has_secret)]
    # The notes as the connect form shows them (it drops the command-line remark: nothing was on one here).
    notes = [n for n in answer.get("notes", []) if not n.startswith("The password from the command line")]
    return {"connector": form["id"], "values": values, "notes": notes, "dropped": list(answer.get("dropped", [])),
            "masked": answer.get("masked", ""), "credential_in_string": has_secret, "secret_input": secret_input,
            "missing": missing}


@dataclass
class SourceTest:
    """What test_source found, one check per line: (what was checked, passed, what it said)."""

    connector: str
    name: str
    checks: list[tuple[str, bool, str]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.checks) and all(passed for _, passed, _ in self.checks)

    def __bool__(self) -> bool:
        return self.ok

    def __str__(self) -> str:
        lines = [f"{'ok  ' if passed else 'FAIL'}  {what}: {said}" for what, passed, said in self.checks]
        verdict = (f"Ready: nb.connect_source({self.connector!r}, {self.name!r}, ...) connects it." if self.ok
                   else "Not ready: fix the line marked FAIL, then test again.")
        return "\n".join(lines + [verdict])

    def _repr_html_(self) -> str:
        import html

        rows = "".join(f"<tr><td>{'✓' if passed else '✗'}</td><td>{html.escape(what)}</td><td>{html.escape(said)}</td></tr>"
                       for what, passed, said in self.checks)
        return f"<table>{rows}</table><p>{html.escape(str(self).splitlines()[-1])}</p>"


def test_source(connector: str, name: str, url: str | None = None, *, password_file: str | Path | None = None,
                timeout: float = 5, **settings: Any) -> SourceTest:
    """Test a source before connecting it, changing nothing: first the kit's own check of every input
    (`exakit connect ... --dry-run`), then whether this computer reaches the source's host and port. No password is
    needed or sent. The sign-in itself is checked by nb.connect_source, from the database (exakit source check)."""
    result = SourceTest(str(connector), str(name))
    try:
        connect_source(connector, name, url, password_file=password_file, dry_run=True, show=False, **settings)
        result.checks.append(("the kit's check of the inputs", True, "every input is complete and well formed"))
    except SourceProblem as problem:
        result.checks.append(("the kit's check of the inputs", False, str(problem).replace(f"{name} was not connected: ", "")))
        print(result)
        return result
    host = clean_text(settings.get("host") or "")
    port = str(settings.get("port") or "").strip()
    if url and not host:
        try:
            parts = urlsplit(clean_text(url)[5:] if clean_text(url).lower().startswith("jdbc:") else clean_text(url))
            host, port = parts.hostname or "", str(parts.port or port or "")
        except ValueError:
            host = ""
    if host and not port:
        from .kit_facts import connector_inputs

        try:
            port = next((i["default"] for i in connector_inputs(connector)["inputs"] if i["name"] == "port"), "")
        except (OSError, ValueError):
            port = ""
    if host and port.isdigit():
        target = MAC_HOST if host.strip().lower().strip("[]") in LOOPBACK else host
        try:
            with socket.create_connection((target, int(port)), timeout=timeout):
                result.checks.append((f"this computer reaches {target}:{port}", True, "the port answered"))
        except OSError as error:
            reason = getattr(error, "strerror", None) or type(error).__name__
            result.checks.append((f"this computer reaches {target}:{port}", False,
                                  f"{reason}: check the address, the port, and that the source allows this computer"))
    else:
        result.checks.append(("network", True, "no host and port to try here (a cloud service): connecting checks it"))
    print(result)
    return result


def _shown(args: list[str]) -> list[str]:
    """The arguments as printed (the URL has no password left in it), quoted where they hold a space."""
    return [a if " " not in a else repr(a) for a in args]


def _last_json(text: str) -> dict[str, Any]:
    """The last JSON object printed (the --json answer), {} when there is none."""
    decoder, found, start = json.JSONDecoder(), {}, text.find("{")
    while start != -1:
        try:
            value, end = decoder.raw_decode(text, start)
        except json.JSONDecodeError:
            start = text.find("{", start + 1)
            continue
        if isinstance(value, dict):
            found = value
        start = text.find("{", end)
    return found
