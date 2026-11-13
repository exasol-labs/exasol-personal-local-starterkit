"""The notebooks' documentation, opened from a cell: ``nb.docs()``.

    nb.docs()                   # the documentation (this notebook's persona section), shown under the cell
    nb.docs("descriptor")       # search it for a word
    nb.docs(nb.describe)        # one command's page (or nb.docs("describe"))
    nb.docs("dash-server")      # an add-on's entry; nb.docs("data-load"): a kit command
    nb.docs("explore")              # one page, by its address
    nb.docs(browser=True)       # in a browser tab instead

The documentation is a site of plain files the kit ships (``notebook/docs/site`` in the kit copy): pages, styles and
a search index, built ahead of time. This module serves that folder from this Python on this computer only
(the loopback address, a free port) and shows it in a frame under the cell, so reading and searching need no internet, no Node
and no second install. The server starts on the first call and stops with the kernel.

A command's page is found in the site's own list (``commands.json``, written from ``exakit.nb``'s ``__all__`` when the
site is built), so every public helper has one. Anything else is handed to the site's search.
"""

from __future__ import annotations

import html
import json
import os
import mimetypes
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlsplit

from ._kit import setting

__all__ = ["Docs", "docs"]

PREFIX = "/docs"                       # the site is built to live under this path (notebook/docs/next.config.mjs)
BIND, SHOWN = "127.0.0.1", "localhost"   # served on the loopback address only: no other computer reaches it
# The ports the documentation tries, in order. One fixed address means a Docs link saved in a notebook still opens
# after the kernel restarts (another kernel, or this one again, serves the same address); a port another program
# holds is skipped, and when every one is taken the system picks a free one. EXAKIT_DOCS_PORT puts one first.
PORTS = tuple(range(8790, 8810))
_TEXT = {".html", ".txt", ".md", ".json", ".js", ".css", ".svg", ".xml"}
_lock = threading.Lock()
_server: ThreadingHTTPServer | None = None
_served: Path | None = None


def site_dir() -> Path | None:
    """The built documentation site: in the kit copy this Python belongs to, else in the checkout this package sits
    in; None when neither has one."""
    candidates = []
    kit = setting("EXAKIT_NB_KIT")
    if kit:
        candidates.append(Path(kit) / "notebook" / "docs" / "site")
    candidates.append(Path(__file__).resolve().parents[2] / "docs" / "site")
    for path in candidates:
        if (path / "index.html").is_file():
            return path
    return None


def _file_for(root: Path, path: str) -> Path | None:
    """The file a request path names: the path itself, the page of that name, or a folder's index. Never a file
    outside the site."""
    if path != PREFIX and not path.startswith(PREFIX + "/"):
        return None
    relative = unquote(path[len(PREFIX):]).strip("/")
    for candidate in ([relative, f"{relative}.html", f"{relative}/index.html"] if relative else ["index.html"]):
        target = (root / candidate).resolve()
        if target.is_file() and root in target.parents:
            return target
    return None


class _Handler(BaseHTTPRequestHandler):
    server_version = "exakit-docs"
    root: Path
    stamp = ""

    def log_message(self, *args: Any) -> None:       # a notebook's output is not an access log
        pass

    def _answer(self, body: bool) -> None:
        path = urlsplit(self.path).path
        if path in ("", "/"):
            self.send_response(302)
            self.send_header("Location", PREFIX)
            self.end_headers()
            return
        target, status = _file_for(self.root, path), 200
        if target is None:
            target, status = self.root / "404.html", 404
            if not target.is_file():
                self.send_error(404)
                return
        data = target.read_bytes()
        kind = mimetypes.guess_type(target.name)[0] or ("application/json" if target.parent.name == "api" else "application/octet-stream")
        if target.suffix in _TEXT or kind == "application/json":
            kind += "; charset=utf-8"
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Exakit-Docs-Site", self.stamp)       # which site this is: another kernel may reuse it
        # Built files under _next/static carry their content's hash in their name; a page must be read again.
        self.send_header("Cache-Control", "public, max-age=31536000, immutable" if "/_next/static/" in path else "no-cache")
        self.end_headers()
        if body:
            self.wfile.write(data)

    def do_GET(self) -> None:
        self._answer(True)

    def do_HEAD(self) -> None:
        self._answer(False)


def _stamp(root: Path) -> str:
    """One word that names a built site: its folder and the build it holds (two kits never share an address)."""
    import hashlib

    build = root / "BUILD.json"
    marker = build.read_bytes() if build.is_file() else str((root / "index.html").stat().st_mtime_ns).encode()
    return hashlib.sha256(str(root.resolve()).encode() + b"\0" + marker).hexdigest()[:16]


def _ours(port: int, stamp: str) -> bool:
    """True when the documentation of this very site already answers on port (another kernel's server)."""
    import http.client

    try:
        connection = http.client.HTTPConnection(BIND, port, timeout=1)
        connection.request("HEAD", PREFIX)
        answer = connection.getresponse()
        same = answer.getheader("Server", "").startswith("exakit-docs") and answer.getheader("X-Exakit-Docs-Site") == stamp
        connection.close()
        return same
    except OSError:
        return False


def _ports() -> list[int]:
    wanted = os.environ.get("EXAKIT_DOCS_PORT", "").strip()
    first = [int(wanted)] if wanted.isdigit() and 0 < int(wanted) < 65536 else []
    return first + [port for port in PORTS if port not in first]


def _serve(root: Path) -> str:
    """The address the site is served at: this kernel's server, another kernel's serving the same site, or a new
    one on the first free port of PORTS (any free port when all are taken). A port held by another program is
    never touched."""
    global _server, _served
    with _lock:
        if _server is not None and _served == root:
            return f"http://{SHOWN}:{_server.server_address[1]}"
        if _server is not None:
            _server.shutdown()
            _server.server_close()
            _server = None
        stamp = _stamp(root)
        handler = type("_SiteHandler", (_Handler,), {"root": root.resolve(), "stamp": stamp})
        for port in _ports() + [0]:
            if port and _ours(port, stamp):
                _served = root
                return f"http://{SHOWN}:{port}"
            try:
                server = ThreadingHTTPServer((BIND, port), handler)
            except OSError:                        # taken by another program: the next one
                continue
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, name="exakit-docs", daemon=True).start()
            _server, _served = server, root
            return f"http://{SHOWN}:{server.server_address[1]}"
        raise RuntimeError("No free port on this computer for the documentation.")


def _commands(root: Path) -> dict[str, str]:
    try:
        return json.loads((root / "commands.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _sections(root: Path) -> list[str]:
    """The site's sections, one per persona (a folder with a page of its own name), this notebook's first: a
    notebook sits in a folder named after its persona, as the kit copies them."""
    found = sorted(path.name for path in root.iterdir() if path.is_dir() and (root / f"{path.name}.html").is_file())
    here = Path.cwd().name
    return ([here] if here in found else []) + [name for name in found if name != here]


def _kit_root() -> Path:
    kit = setting("EXAKIT_NB_KIT")
    return Path(kit) if kit else Path(__file__).resolve().parents[3]


def _kit_names() -> tuple[set[str], set[str]]:
    """(the marketplace's add-on ids, the kit's commands), from the kit copy's own catalog and help."""
    addons: set[str] = set()
    commands: set[str] = set()
    try:
        catalog = json.loads((_kit_root() / "marketplace" / "catalog.json").read_text(encoding="utf-8"))
        addons = {str(a["id"]) for a in catalog.get("addons") or [] if isinstance(a, dict) and a.get("id")}
    except (OSError, ValueError):
        pass
    try:
        helped = json.loads((_kit_root() / "setup" / "help" / "exakit.json").read_text(encoding="utf-8"))
        commands = {str(c["command"]) for c in helped.get("commands") or [] if isinstance(c, dict) and c.get("command")}
    except (OSError, ValueError):
        pass
    return addons, commands


def _kit_page(root: Path, word: str) -> str | None:
    """The page for an add-on's id (its entry on the add-ons page) or a kit command (the command table)."""
    addons, commands = _kit_names()
    name = word.strip().lower()
    if name.startswith("exakit "):
        name = name[len("exakit "):].strip()
    if name in addons and _file_for(root, f"{PREFIX}/kit/tools/add-ons") is not None:
        return f"{PREFIX}/kit/tools/add-ons#{name}"
    if name in commands and _file_for(root, f"{PREFIX}/kit/reference/commands") is not None:
        return f"{PREFIX}/kit/reference/commands?q={quote('exakit ' + name)}"
    return None


def _path_for(root: Path, what: Any) -> str:
    """The site path for what was asked: this notebook's persona section, a command's page, a page by its address
    (in any section, this persona's first), else a search."""
    sections = _sections(root)
    if what is None:
        return f"{PREFIX}/{sections[0]}" if sections and sections[0] == Path.cwd().name else PREFIX
    commands = _commands(root)
    if not isinstance(what, str):
        name = getattr(what, "__name__", None) or type(what).__name__
        if name in commands:
            return PREFIX + commands[name]
        what = name
    text = what.strip()
    name = text[3:] if text.startswith("nb.") else text
    name = name[:-2] if name.endswith("()") else name
    if name in commands:
        return PREFIX + commands[name]
    kit_page = _kit_page(root, text)
    if kit_page:
        return kit_page
    page = text.strip("/")
    for address in ([page] + [f"{section}/{page}" for section in sections] if page else []):
        if _file_for(root, f"{PREFIX}/{address}") is not None:
            return f"{PREFIX}/{address}"
    return f"{PREFIX}?q={quote(text)}" if text else PREFIX


class Docs:
    """What ``nb.docs()`` returns: the documentation at ``url``. A notebook shows it in a frame under the cell;
    ``open()`` opens it in a browser tab."""

    def __init__(self, url: str, height: int = 640):
        self.url = url
        self.height = height

    def open(self) -> "Docs":
        """Open the page in the default browser."""
        import webbrowser

        webbrowser.open(self.url)
        return self

    def __repr__(self) -> str:
        return f"Documentation: {self.url}"

    def _repr_html_(self) -> str:
        url = html.escape(self.url, quote=True)
        return (f'<div style="font:13px/1.4 system-ui,sans-serif;margin:2px 0 6px">'
                f'<a href="{url}" target="_blank" rel="noopener">Open the documentation in a new tab</a></div>'
                f'<iframe src="{url}" title="Starter Kit documentation" loading="lazy" '
                f'style="width:100%;height:{int(self.height)}px;border:1px solid #d0d7de;border-radius:4px"></iframe>')

    def _mime_(self) -> tuple[str, str]:             # Marimo's display hook
        return "text/html", self._repr_html_()


def docs(what: Any = None, *, height: int = 640, browser: bool = False) -> Docs:
    """Open the notebooks' documentation: all of it, one command's page, one page, or a search.

    ``what`` is nothing (the section of the persona whose notebook this is, else the start page), a helper or its name (``nb.describe``, ``"describe"``: that command's page),
    a page's address (``"explore"``, ``"set-up/ai-and-langfuse"``), or any other words (searched, typos forgiven). The result shows
    under the cell in a frame ``height`` pixels tall; ``browser=True`` opens a browser tab too. Served from this
    computer only, from files the kit ships: nothing is fetched from the internet."""
    root = site_dir()
    if root is None:
        raise RuntimeError("The documentation site is not in this kit copy (notebook/docs/site). "
                           "Fix: exakit update notebook")
    page = Docs(_serve(root) + _path_for(root, what), height)
    if browser:
        page.open()
    return page


def main(argv: list[str]) -> int:
    """``exakit docs [<add-on | command | page | words>] [--print] [--json]``: open the kit's documentation in the
    browser - all of it, an add-on's entry, a kit command, a page by its address, or a search for any other
    words - served from this computer. With no server of the kit's running yet, this one serves until Ctrl+C.
    ``--print`` and ``--json`` only say the address (and whether it is being served) and open nothing."""
    words = [a for a in argv if not a.startswith("-")]
    flags = {a for a in argv if a.startswith("-")}
    unknown = flags - {"--print", "--json", "-j", "--help", "-h"}
    if unknown:
        print(f"Unknown option '{sorted(unknown)[0]}' for docs (supported: --print, --json).", file=sys.stderr)
        return 2
    if flags & {"--help", "-h"}:
        print("Use: exakit docs [<add-on | command | page | words to search>] [--print] [--json]")
        return 0
    root = site_dir()
    if root is None:
        print("The documentation site is not in this kit copy (notebook/docs/site). Fix: exakit update notebook", file=sys.stderr)
        return 1
    what = " ".join(words) or None
    # from the terminal a kit command or an add-on comes first (`exakit docs describe` is the command, not the
    # notebook helper of the same name); then a helper, a page, a search
    path = (_kit_page(root, what) or _path_for(root, what)) if what else PREFIX
    stamp = _stamp(root)
    running = next((port for port in _ports() if _ours(port, stamp)), None)
    only_say = bool(flags & {"--print", "--json", "-j"})
    if only_say:
        port = running or _ports()[0]
        url = f"http://{SHOWN}:{port}{path}"
        if flags & {"--json", "-j"}:
            print(json.dumps({"url": url, "serving": running is not None, "start": None if running else "exakit docs"}))
        else:
            print(url if running else f"{url}  (not served yet: run exakit docs to serve and open it)")
        return 0
    url = _serve(root) + path
    import webbrowser

    webbrowser.open(url)
    if running is not None:
        print(f"Opened {url}")
        return 0
    print(f"Serving the kit's documentation at {url}\nPress Ctrl+C to stop.", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        print()
    return 0
