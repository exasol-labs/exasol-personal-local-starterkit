"""(run: python3 tests/test_notebook_docs.py) The notebooks' documentation site (notebook/docs) and nb.docs().

The command reference is generated from the code and current; every public helper of exakit.nb has an entry; every
page has a title and a description, is listed in its folder's meta.json and links only to pages and anchors that
exist; the shipped site was built from the sources in the repository; and nb.docs() serves a site from this
computer only, finds a command's page, a page by its address, or falls back to the site's search."""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

DOCS = ROOT / "notebook" / "docs"
CONTENT = DOCS / "content" / "docs"

_spec = importlib.util.spec_from_file_location("nb_docs_tool", ROOT / "tools" / "nb_docs.py")
tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tool)

from exakit_nb import docs as nb_docs  # noqa: E402

docs_module = sys.modules["exakit_nb.docs"]


def pages() -> list[Path]:
    return sorted(CONTENT.rglob("*.mdx"))


def route(path: Path) -> str:
    relative = path.relative_to(CONTENT).with_suffix("").as_posix()
    if relative == "index":
        return "/"
    return "/" + (relative[: -len("/index")] if relative.endswith("/index") else relative)


def anchors(path: Path) -> set[str]:
    """The ids a page's headings get: an explicit [#id], else the heading's words as a slug."""
    found = set()
    for heading in re.findall(r"^#{2,6}\s+(.+)$", path.read_text(encoding="utf-8"), re.M):
        explicit = re.search(r"\[#([^\]]+)\]\s*$", heading)
        found.add(explicit.group(1) if explicit else re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-"))
    return found


class GeneratedReferenceTest(unittest.TestCase):
    def test_the_generated_pages_are_current(self):
        for path, text in tool.build().items():
            with self.subTest(path=path.relative_to(ROOT).as_posix()):
                self.assertTrue(path.is_file(), "run: python3 tools/nb_docs.py")
                self.assertEqual(path.read_text(encoding="utf-8"), text, "run: python3 tools/nb_docs.py")

    def test_nothing_else_sits_in_the_generated_folder(self):
        expected = {path.name for path in tool.build() if path.parent == tool.REFERENCE}
        self.assertEqual({path.name for path in tool.REFERENCE.iterdir()}, expected)

    def test_every_public_helper_has_an_entry(self):
        commands = json.loads(tool.COMMANDS.read_text(encoding="utf-8"))
        names = [name for name, _, _ in tool.exported()]
        self.assertGreater(len(names), 100)
        self.assertEqual(sorted(commands), sorted(names))
        for name, target in commands.items():
            page, _, anchor = target.partition("#")
            path = CONTENT / f"{page.strip('/')}.mdx"
            with self.subTest(name=name):
                self.assertTrue(path.is_file(), target)
                self.assertEqual(anchor, name)
                self.assertIn(name, anchors(path))

    def test_every_helper_says_what_it_does(self):
        for name, module, original in tool.exported():
            node = tool._definition(tool._tree(module), original)
            with self.subTest(name=name):
                self.assertTrue(tool._summary(tool.ast.get_docstring(node)), f"nb.{name} has no docstring")

    def test_a_docstring_becomes_safe_mdx(self):
        text = tool.to_mdx("Reads ``{id}`` from <SCHEMA>.<TABLE> and __all__.\n\n    ds = nb.dataset(conn, \"x\")   # {kept}\n\nDone.")
        self.assertIn("`{id}`", text)                        # inside backticks: as written
        self.assertIn("\\<SCHEMA\\>", text)
        self.assertIn("\\_\\_all\\_\\_", text)
        self.assertIn("```python\nds = nb.dataset(conn, \"x\")   # {kept}\n```", text)


class PagesTest(unittest.TestCase):
    def test_every_page_has_a_title_and_a_description(self):
        for path in pages():
            head = re.match(r"---\n(.*?)\n---\n", path.read_text(encoding="utf-8"), re.S)
            with self.subTest(page=route(path)):
                self.assertIsNotNone(head, "no frontmatter")
                self.assertRegex(head.group(1), r"(?m)^title: \S")
                self.assertRegex(head.group(1), r"(?m)^description: \S")

    def test_every_page_is_in_the_sidebar_and_the_sidebar_names_only_pages(self):
        for meta in sorted(CONTENT.rglob("meta.json")):
            folder = meta.parent
            listed = json.loads(meta.read_text(encoding="utf-8"))["pages"]
            here = {path.stem for path in folder.glob("*.mdx")} | {path.name for path in folder.iterdir() if path.is_dir()}
            with self.subTest(folder=folder.relative_to(CONTENT).as_posix() or "."):
                self.assertEqual(sorted(listed), sorted(here))

    def test_every_link_leads_somewhere(self):
        routes = {route(path): path for path in pages()}
        for path in pages():
            text = path.read_text(encoding="utf-8")
            for target in re.findall(r"\]\((/[^)\s]*)\)", text) + re.findall(r'href="(/[^"]*)"', text):
                page, _, anchor = target.partition("#")
                with self.subTest(page=route(path), link=target):
                    self.assertIn(page.rstrip("/") or "/", routes)
                    if anchor:
                        self.assertIn(anchor, anchors(routes[page.rstrip("/") or "/"]))
            for target in re.findall(r"\]\(([^)\s]+\.mdx[^)\s]*)\)", text):
                self.fail(f"{route(path)} links to a file ({target}); link to the page's address instead")

    def test_every_notebooks_docs_button_opens_a_page_that_exists(self):
        """The first card of each guided notebook has a Docs button; the page it names is one of these."""
        named = []
        for path in sorted((ROOT / "notebook" / "package" / "exakit_guide").rglob("*.py")):
            named += re.findall(r'\bdocs="([^"]+)"', path.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(named), 5, "start, understand, explore, ask and share each name their page")
        for page in named:
            with self.subTest(page=page):
                self.assertTrue((CONTENT / tool.SECTION / f"{page}.mdx").is_file())

    def test_no_page_shows_a_password_or_a_key(self):
        for path in pages():
            with self.subTest(page=route(path)):
                self.assertNotRegex(path.read_text(encoding="utf-8"), r"(?i)(sk-[a-z0-9]{12,}|password\s*=\s*['\"][^'\"]+['\"])")


class ShippedSiteTest(unittest.TestCase):
    def test_the_shipped_site_was_built_from_these_sources(self):
        stamp = tool.SITE / tool.STAMP
        self.assertTrue(stamp.is_file(), "build the site (npm run build in notebook/docs), then: python3 tools/nb_docs.py --publish")
        self.assertEqual(json.loads(stamp.read_text(encoding="utf-8"))["sources"], tool.sources_digest(),
                         "the pages changed since the site was built: npm run build in notebook/docs, then "
                         "python3 tools/nb_docs.py --publish")

    def test_the_shipped_site_has_every_page_the_search_index_and_the_command_list(self):
        for path in pages():
            relative = route(path).strip("/")
            with self.subTest(page=route(path)):
                self.assertTrue((tool.SITE / (f"{relative}.html" if relative else "index.html")).is_file())
        self.assertTrue((tool.SITE / "api" / "search").is_file())
        self.assertEqual(json.loads((tool.SITE / "commands.json").read_text(encoding="utf-8")),
                         json.loads(tool.COMMANDS.read_text(encoding="utf-8")))

    def test_the_shipped_site_loads_nothing_from_the_internet(self):
        for path in tool.SITE.rglob("*.html"):
            for source in re.findall(r'<(?:script|link)[^>]+(?:src|href)="(https?://[^"]+)"', path.read_text(encoding="utf-8")):
                self.fail(f"{path.relative_to(tool.SITE)} loads {source}")


class ServedDocsTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.site = Path(self.folder.name).resolve() / "site"
        (self.site / "concepts").mkdir(parents=True)
        (self.site / "reference").mkdir()
        (self.site / "index.html").write_text("<h1>start</h1>", encoding="utf-8")
        (self.site / "404.html").write_text("<h1>not here</h1>", encoding="utf-8")
        (self.site / "concepts" / "descriptor.html").write_text("<h1>descriptor</h1>", encoding="utf-8")
        (self.site / "reference" / "describe.html").write_text("<h1>describe</h1>", encoding="utf-8")
        (self.site / "commands.json").write_text(json.dumps({"describe": "/reference/describe#describe"}), encoding="utf-8")
        (Path(self.folder.name) / "secret.txt").write_text("outside the site", encoding="utf-8")
        self.addCleanup(self.folder.cleanup)
        self.addCleanup(self.stop)
        self.original = docs_module.site_dir
        docs_module.site_dir = lambda: self.site
        self.addCleanup(lambda: setattr(docs_module, "site_dir", self.original))

    def stop(self):
        if docs_module._server is not None:
            docs_module._server.shutdown()
            docs_module._server.server_close()
            docs_module._server = None
            docs_module._served = None

    def get(self, url: str, method: str = "GET"):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=5) as answer:
                return answer.status, answer.read().decode(), answer.headers
        except urllib.error.HTTPError as problem:
            return problem.code, problem.read().decode(), problem.headers

    def test_the_start_page_a_command_a_page_and_a_search(self):
        base = nb_docs().url
        self.assertRegex(base, r"^http://localhost:\d+/docs$")
        self.assertTrue(nb_docs("describe").url.endswith("/docs/reference/describe#describe"))
        self.assertTrue(nb_docs("nb.describe()").url.endswith("/docs/reference/describe#describe"))

        def describe():
            pass

        self.assertTrue(nb_docs(describe).url.endswith("/docs/reference/describe#describe"))
        self.assertTrue(nb_docs("concepts/descriptor").url.endswith("/docs/concepts/descriptor"))
        self.assertTrue(nb_docs("role of a column").url.endswith("/docs?q=role%20of%20a%20column"))

    def test_a_personas_notebook_opens_its_own_section_and_finds_its_pages(self):
        """The site has a section per persona. A notebook in that persona's folder opens there, and a page's address
        need not name the section."""
        import os

        (self.site / "data-scientist" / "concepts").mkdir(parents=True)
        (self.site / "data-scientist.html").write_text("<h1>ds</h1>", encoding="utf-8")
        (self.site / "data-scientist" / "concepts" / "workflow.html").write_text("<h1>workflow</h1>", encoding="utf-8")
        self.assertTrue(nb_docs().url.endswith("/docs"))                       # not in a persona's folder: the start page
        folder = Path(self.folder.name) / "data-scientist"
        folder.mkdir()
        before = os.getcwd()
        os.chdir(folder)
        self.addCleanup(os.chdir, before)
        self.assertTrue(nb_docs().url.endswith("/docs/data-scientist"))
        self.assertTrue(nb_docs("concepts/workflow").url.endswith("/docs/data-scientist/concepts/workflow"))
        self.assertTrue(nb_docs("concepts/descriptor").url.endswith("/docs/concepts/descriptor"))   # an exact address wins

    def test_it_serves_pages_and_only_the_site(self):
        base = nb_docs().url
        root = base[: -len("/docs")]
        self.assertEqual(self.get(base)[:2], (200, "<h1>start</h1>"))
        self.assertEqual(self.get(base + "/concepts/descriptor")[:2], (200, "<h1>descriptor</h1>"))
        status, body, headers = self.get(base + "/concepts/descriptor", "HEAD")
        self.assertEqual((status, body), (200, ""))
        self.assertIn("text/html", headers["Content-Type"])
        self.assertEqual(self.get(base + "/missing")[:2], (404, "<h1>not here</h1>"))
        self.assertEqual(self.get(base + "/..%2Fsecret.txt")[0], 404)
        self.assertEqual(self.get(root + "/secret.txt")[0], 404)
        self.assertEqual(docs_module._server.server_address[0], "127.0.0.1")

    def test_one_server_for_the_kernel_and_a_frame_under_the_cell(self):
        first, second = nb_docs(), nb_docs("describe")
        self.assertEqual(first.url.split("/docs")[0], second.url.split("/docs")[0])
        shown = second._repr_html_()
        self.assertIn("<iframe", shown)
        self.assertIn(second.url.replace("#", "#"), shown)
        self.assertEqual(second._mime_()[0], "text/html")

    def test_a_fixed_port_a_busy_one_skipped_and_another_kernels_server_reused(self):
        """The docs live at one of a few fixed ports, so a Docs link saved in a notebook still opens after a restart.
        A port another program holds is skipped (never taken over); a port where this very site is already served by
        another kernel is reused, not doubled; and with every fixed port taken any free port is used."""
        import socket

        free = []
        for _ in range(3):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                free.append(probe.getsockname()[1])
        busy = socket.socket()
        busy.bind(("127.0.0.1", free[0]))
        busy.listen(1)
        self.addCleanup(busy.close)
        original = docs_module.PORTS
        docs_module.PORTS = (free[0], free[1])
        self.addCleanup(setattr, docs_module, "PORTS", original)
        first = nb_docs().url
        self.assertTrue(first.startswith(f"http://localhost:{free[1]}/"), first)            # the busy one skipped
        self.assertEqual(200, self.get(first)[0])
        held = docs_module._server
        docs_module._server, docs_module._served = None, None                             # another kernel, same site
        again = nb_docs().url
        self.assertEqual(first, again)
        self.assertIsNone(docs_module._server, "it reused the running server instead of starting a second")
        docs_module._server = held
        self.stop()
        docs_module.PORTS = (free[0],)                                                    # every fixed port taken
        last = nb_docs().url
        self.assertNotIn(f":{free[0]}/", last)
        self.assertEqual(200, self.get(last)[0])

    def test_a_kit_without_the_site_says_how_to_get_it(self):
        docs_module.site_dir = lambda: None
        with self.assertRaisesRegex(RuntimeError, "exakit update notebook"):
            nb_docs()


if __name__ == "__main__":
    unittest.main()
