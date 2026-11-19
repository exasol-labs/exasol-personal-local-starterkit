"""tools/bump_checks.py and the workflows around it: what CI runs when a pinned version or a Federation artifact
changes, and the branch a version bump leaves behind (audit QAT-02, the version-bump workflow).

Offline: every download is a stand-in that writes known bytes, so no test reaches the network.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import struct
import sys
import tarfile
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import bump_checks  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
VERSIONS = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def elf_with_versions(*names: str) -> bytes:
    """A minimal 64-bit little-endian ELF whose .gnu.version_r references `names` from libc.so.6."""
    dynstr = b"\0libc.so.6\0"
    offsets = []
    for name in names:
        offsets.append(len(dynstr))
        dynstr += name.encode() + b"\0"
    header_size = 64
    dynstr_off = header_size
    verneed_off = dynstr_off + len(dynstr)
    verneed_off += (-verneed_off) % 8
    verneed = struct.pack("<HHIII", 1, len(names), 1, 16, 0)
    for index, offset in enumerate(offsets):
        last = index == len(names) - 1
        verneed += struct.pack("<IHHII", 0, 0, index + 2, offset, 0 if last else 16)
    shoff = verneed_off + len(verneed)
    shoff += (-shoff) % 8

    def section(kind, offset, size, link=0, info=0):
        return struct.pack("<IIQQQQIIQQ", 0, kind, 0, 0, offset, size, link, info, 1, 0)

    sections = section(0, 0, 0) + section(3, dynstr_off, len(dynstr)) + \
        section(0x6ffffffe, verneed_off, len(verneed), link=1, info=1)
    ident = b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9
    header = ident + struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 0, shoff, 0, 64, 0, 0, 64, 3, 0)
    blob = bytearray(header)
    blob += b"\0" * (dynstr_off - len(blob)) + dynstr
    blob += b"\0" * (verneed_off - len(blob)) + verneed
    blob += b"\0" * (shoff - len(blob)) + sections
    return bytes(blob)


def tar_gz(members: dict) -> bytes:
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as archive:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return out.getvalue()


class FakeNet(object):
    """Stands in for bump_checks.download: serves bytes by URL and records what was asked for."""

    def __init__(self, files: dict):
        self.files = files
        self.asked = []

    def __call__(self, url, dest):
        self.asked.append(url)
        if url not in self.files:
            raise bump_checks.CheckFailure("could not download %s: HTTP 404" % url)
        Path(dest).write_bytes(self.files[url])


class ChangedComponentsTest(unittest.TestCase):
    def test_only_the_blocks_that_differ(self):
        base = json.loads(json.dumps(VERSIONS))
        head = json.loads(json.dumps(VERSIONS))
        head["components"]["exapump"]["version"] = "9.9.9"
        head["components"]["skills"]["version"] = "9.9.9"
        self.assertEqual(["exapump", "skills"], bump_checks.changed_components(base, head))
        self.assertEqual([], bump_checks.changed_components(base, base))

    def test_no_base_means_every_component(self):
        self.assertEqual(sorted(VERSIONS["components"]), bump_checks.changed_components(None, VERSIONS))

    def test_runnable_leaves_out_what_another_job_covers(self):
        self.assertFalse(bump_checks.runnable("skills"))
        self.assertFalse(bump_checks.runnable("preprocessor"))
        for key in ("personal", "exapump", "uv", "pyexasol", "dbt-exasol", "dash-server", "exasol-scheduler",
                    "json-tables", "exasol-vscode", "semantic-views", "mcp"):
            self.assertTrue(bump_checks.runnable(key), key)
        # Every component the manifest pins is either smoked or named as covered elsewhere.
        for key in VERSIONS["components"]:
            self.assertTrue(bump_checks.runnable(key) or key in bump_checks.COVERED_ELSEWHERE, key)


class FetchVerifiedTest(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work, True)

    def test_a_wrong_digest_or_size_is_refused(self):
        net = FakeNet({"https://example.test/a": b"hello"})
        with patch.object(bump_checks, "download", net):
            bump_checks.fetch_verified("https://example.test/a", sha(b"hello"), self.work / "a", 5)
            with self.assertRaisesRegex(bump_checks.CheckFailure, "does not match its pin"):
                bump_checks.fetch_verified("https://example.test/a", sha(b"other"), self.work / "a")
            with self.assertRaisesRegex(bump_checks.CheckFailure, "is 5 bytes, the pin says 6"):
                bump_checks.fetch_verified("https://example.test/a", sha(b"hello"), self.work / "a", 6)

    def test_plain_http_is_never_fetched(self):
        with self.assertRaisesRegex(bump_checks.CheckFailure, "non-HTTPS"):
            bump_checks.download("http://example.test/a", self.work / "a")


class GlibcFloorTest(unittest.TestCase):
    def test_the_highest_glibc_version_reference_wins(self):
        self.assertEqual("2.38", bump_checks.glibc_floor(elf_with_versions("GLIBC_2.17", "GLIBC_2.38",
                                                                            "GLIBC_PRIVATE", "GLIBC_2.2.5")))
        self.assertEqual("2.34", bump_checks.glibc_floor(elf_with_versions("GLIBC_2.34")))

    def test_not_an_elf_or_no_glibc_reference(self):
        self.assertIsNone(bump_checks.glibc_floor(b"#!/bin/sh\necho hi\n"))
        self.assertIsNone(bump_checks.glibc_floor(elf_with_versions("GCC_3.0")))

    def test_inside_an_archive(self):
        payload = tar_gz({"target/x/release/exasol_scheduler": elf_with_versions("GLIBC_2.39"), "README.md": b"x"})
        self.assertEqual("2.39", bump_checks.glibc_floor_in_archive(payload, "exasol_scheduler"))
        self.assertIsNone(bump_checks.glibc_floor_in_archive(b"not a tarball", "exasol_scheduler"))

    def test_a_stale_floor_fails_and_names_the_fix(self):
        work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work, True)
        binary = work / "engine"
        binary.write_bytes(elf_with_versions("GLIBC_2.39"))
        lines = []
        with self.assertRaisesRegex(bump_checks.CheckFailure,
                                    r"needs glibc 2.39 but versions.json records 2.38 - set "
                                    r"components.exasol-scheduler.glibc.linux-x86_64 to 2.39"):
            bump_checks.check_glibc("exasol-scheduler", "linux-x86_64", binary,
                                    {"glibc": {"linux-x86_64": "2.38"}}, lines)
        bump_checks.check_glibc("exasol-scheduler", "linux-x86_64", binary, {"glibc": {"linux-x86_64": "2.39"}},
                                lines)
        self.assertIn("glibc floor 2.39 matches", lines[-1])


@unittest.skipIf(os.name == "nt", "the stand-in binaries are shell scripts")
class SmokeTest(unittest.TestCase):
    """Each binary is fetched from the URL the install uses, verified, unpacked and run on this machine."""

    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work, True)

    def doc(self, **components):
        return {"components": components}

    def test_exapump_runs_and_names_its_version(self):
        script = b"#!/bin/sh\necho 'exapump 1.2.3'\n"
        url = "https://github.com/exasol-labs/exapump/releases/download/v1.2.3/exapump-1.2.3-linux-x86_64"
        doc = self.doc(exapump={"version": "1.2.3", "repo": "exasol-labs/exapump",
                                "sha256": {"linux-x86_64": sha(script)}})
        net = FakeNet({url: script})
        with patch.object(bump_checks, "download", net):
            smoke = bump_checks.Smoke(doc, self.work, "linux", "x86_64", bump_checks.KIT_REPO)
            report, failures = smoke.run_all(["exapump"])
        self.assertEqual([], failures)
        self.assertEqual([url], net.asked)
        self.assertIn("--version says exapump 1.2.3", report[0])

    def test_a_binary_that_names_another_version_fails(self):
        script = b"#!/bin/sh\necho 'exapump 1.2.2'\n"
        url = "https://github.com/exasol-labs/exapump/releases/download/v1.2.3/exapump-1.2.3-macos-aarch64"
        doc = self.doc(exapump={"version": "1.2.3", "sha256": {"macos-aarch64": sha(script)}})
        with patch.object(bump_checks, "download", FakeNet({url: script})):
            _, failures = bump_checks.Smoke(doc, self.work, "macos", "aarch64", bump_checks.KIT_REPO).run_all(
                ["exapump"])
        self.assertEqual(1, len(failures))
        self.assertIn("expected it to name 1.2.3", failures[0])

    def test_a_missing_release_asset_fails(self):
        doc = self.doc(exapump={"version": "1.2.3", "sha256": {"linux-aarch64": "0" * 64}})
        with patch.object(bump_checks, "download", FakeNet({})):
            _, failures = bump_checks.Smoke(doc, self.work, "linux", "aarch64", bump_checks.KIT_REPO).run_all(
                ["exapump"])
        self.assertIn("HTTP 404", failures[0])

    def test_scheduler_keys_arm_as_arm64_and_checks_its_glibc_floor(self):
        engine = elf_with_versions("GLIBC_2.38")
        archive = tar_gz({"target/aarch64-unknown-linux-gnu/release/exasol_scheduler": engine})
        url = ("https://github.com/exasol-labs/exasol-scheduler/releases/download/v0.5.0/"
               "exasol_scheduler-v0.5.0-linux-arm64.tar.gz")
        doc = self.doc(**{"exasol-scheduler": {"version": "0.5.0", "sha256": {"linux-arm64": sha(archive)},
                                               "glibc": {"linux-arm64": "2.34"}}})
        net = FakeNet({url: archive})
        with patch.object(bump_checks, "download", net):
            _, failures = bump_checks.Smoke(doc, self.work, "linux", "aarch64", bump_checks.KIT_REPO).run_all(
                ["exasol-scheduler"])
        self.assertEqual([url], net.asked)
        self.assertIn("needs glibc 2.38 but versions.json records 2.34", failures[0])

    def test_an_archive_must_hold_exactly_one_engine(self):
        archive = self.work / "a.tar.gz"
        archive.write_bytes(tar_gz({"a/exasol_scheduler": b"x", "b/exasol_scheduler": b"y"}))
        with self.assertRaisesRegex(bump_checks.CheckFailure, "holds 2 files named exasol_scheduler"):
            bump_checks.extract_member(archive, "exasol_scheduler", self.work / "out")

    def test_json_tables_is_not_offered_where_no_engine_is_published(self):
        doc = self.doc(**{"json-tables": {"version": "v0.4.1", "release": "json-tables-v0.4.1",
                                          "sha256": {"linux-x86_64": "0" * 64}}})
        with patch.object(bump_checks, "download", FakeNet({})):
            report, failures = bump_checks.Smoke(doc, self.work, "macos", "x86_64", bump_checks.KIT_REPO).run_all(
                ["json-tables"])
        self.assertEqual([], failures)
        self.assertIn("no ingest engine is published for macos-x86_64", report[0])

    def test_same_bytes_checks_run_on_one_runner_only(self):
        doc = self.doc(**{"exasol-vscode": {"version": "1.0.0", "sha256": {"vsix": "0" * 64}}})
        with patch.object(bump_checks, "download", FakeNet({})):
            report, failures = bump_checks.Smoke(doc, self.work, "windows", "x86_64",
                                                 bump_checks.KIT_REPO).run_all(["exasol-vscode"])
        self.assertEqual(([], []), (report, failures))

    def test_the_mcp_image_tag_must_be_the_version(self):
        with self.assertRaisesRegex(bump_checks.CheckFailure, "tagged 2.4.0 but components.mcp.version is 2.5.0"):
            bump_checks.check_image("docker.io/exasol/mcp-server:2.4.0@sha256:" + "a" * 64, "2.5.0")


class FederationPinsTest(unittest.TestCase):
    def test_every_shipped_pin_is_well_formed(self):
        pins = bump_checks.vs_targets(None)
        self.assertGreaterEqual(len(pins), 23)
        for rel, where, pin, _ in pins:
            with self.subTest(pin="%s %s" % (rel, where)):
                self.assertEqual([], bump_checks.vs_pin_problems(pin))
        lakehouse = [(where, context) for rel, where, _, context in pins if "lakehouse" in rel]
        self.assertTrue(lakehouse)
        for where, context in lakehouse:
            self.assertEqual("udf/liblakehouse_engine.so", context.get("member"), where)

    def test_shape_problems_are_named(self):
        pin = {"url": "http://example.test/x/a.jar", "sha256": "ABC", "size": "12", "asset": "b.jar",
               "member_sha256": "0" * 64}
        problems = " | ".join(bump_checks.vs_pin_problems(pin))
        for needle in ("not HTTPS", "not 64 lowercase hex", "positive whole number", "is not the file the url names",
                       "come together"):
            self.assertIn(needle, problems)

    def copy_tree(self) -> Path:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        shutil.copytree(ROOT / "setup" / "virtual-schemas" / "connectors", root / "setup/virtual-schemas/connectors")
        shutil.copytree(ROOT / "setup" / "virtual-schemas" / "profiles", root / "setup/virtual-schemas/profiles")
        return root

    def test_only_the_pins_that_changed_are_downloaded(self):
        root = self.copy_tree()

        def read_base(_ref, rel):
            path = ROOT / rel
            return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None

        self.assertEqual([], bump_checks.vs_targets("base", root, read_base))
        target = root / "setup/virtual-schemas/connectors/postgresql/connector.json"
        doc = json.loads(target.read_text(encoding="utf-8"))
        doc["driver"]["sha256"] = "0" * 64
        target.write_text(json.dumps(doc), encoding="utf-8")
        changed = bump_checks.vs_targets("base", root, read_base)
        self.assertEqual([("setup/virtual-schemas/connectors/postgresql/connector.json", "driver")],
                         [(rel, where) for rel, where, _, _ in changed])
        # A connector the base does not have: every pin it carries is new.
        new = root / "setup/virtual-schemas/connectors/newdb"
        new.mkdir()
        shutil.copy(target, new / "connector.json")
        self.assertEqual(3, len(bump_checks.vs_targets("base", root, read_base)))

    def test_a_bundle_member_that_differs_from_its_pin_fails(self):
        work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work, True)
        engine = b"engine bytes"
        payload = tar_gz({"udf/liblakehouse_engine.so": engine})
        pin = {"asset": "e.tar.gz", "url": "https://example.test/e.tar.gz", "size": len(payload),
               "sha256": sha(payload), "member_size": len(engine), "member_sha256": sha(engine)}

        def fetch(url, expected, dest, size=None):
            Path(dest).write_bytes(payload)

        context = {"member": "udf/liblakehouse_engine.so"}
        self.assertIn("udf/liblakehouse_engine.so verified", bump_checks.verify_vs_pin(pin, context, work, fetch))
        with self.assertRaisesRegex(bump_checks.CheckFailure, "does not match its pinned size and SHA-256"):
            bump_checks.verify_vs_pin(dict(pin, member_sha256="0" * 64), context, work, fetch)
        with self.assertRaisesRegex(bump_checks.CheckFailure, "holds no udf/other.so"):
            bump_checks.verify_vs_pin(pin, {"member": "udf/other.so"}, work, fetch)

    def test_a_driver_bundle_must_hold_its_entry(self):
        work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work, True)
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr("lib/Other.jar", b"x")
        payload = out.getvalue()
        pin = {"asset": "d.zip", "url": "https://example.test/d.zip", "size": len(payload), "sha256": sha(payload),
               "bundle": "zip", "entry": "GoogleBigQueryJDBC42.jar"}
        with self.assertRaisesRegex(bump_checks.CheckFailure, "holds no GoogleBigQueryJDBC42.jar"):
            bump_checks.verify_vs_pin(pin, {}, work, lambda url, expected, dest, size=None:
                                      Path(dest).write_bytes(payload))


class ReportTest(unittest.TestCase):
    REPORT = {
        "title": "Bump advertised versions: exapump 0.15.0",
        "date": "2026-11-19 03:30 UTC",
        "base_sha": "0123456789abcdef",
        "components": [{"key": "exapump", "old": "0.14.0", "new": "0.15.0",
                        "link": "https://github.com/exasol-labs/exapump/releases/tag/v0.15.0", "link_label": "v0.15.0",
                        "digests": "5 of 5 recomputed", "min_kit_version": None,
                        "notes": ["linux-x86_64 needs glibc 2.28"], "checks": ["downloaded 5 assets"]}],
        "touched": ["setup/lib/common.sh"],
        "left_alone": ["- `uv`: GitHub did not answer (HTTP 500), left alone"],
        "workflow_checks": ["hashed every asset"],
        "checklist": ["Severity is normal"],
    }

    def test_the_report_says_what_moved_and_how_to_open_the_pull_request(self):
        text = bump_checks.render_report(self.REPORT, "exasol-labs/exasol-personal-local-starterkit",
                                         "chore/versions-bump")
        for needle in ("| `exapump` | 0.14.0 | **0.15.0** | [v0.15.0](https://github.com/exasol-labs/exapump/"
                       "releases/tag/v0.15.0) | 5 of 5 recomputed | - |",
                       "linux-x86_64 needs glibc 2.28", "checked: downloaded 5 assets", "`setup/lib/common.sh`",
                       "GitHub did not answer", "from `main` at 0123456789ab",
                       "gh pr create -R exasol-labs/exasol-personal-local-starterkit --base main --head "
                       "chore/versions-bump --title 'Bump advertised versions: exapump 0.15.0' --body-file "
                       "<(git show origin/chore/versions-bump:.github/versions-bump-report.md)",
                       "https://github.com/exasol-labs/exasol-personal-local-starterkit/compare/main..."
                       "chore/versions-bump?expand=1",
                       "actions?query=branch%3Achore%2Fversions-bump", "component-smoke", "- [ ] Severity is normal"):
            self.assertIn(needle, text)


class WorkflowTest(unittest.TestCase):
    bump = (WORKFLOWS / "versions-bump.yml").read_text(encoding="utf-8")
    versions = (WORKFLOWS / "versions.yml").read_text(encoding="utf-8")

    def test_the_bump_runs_every_day_at_nine_ist_and_by_hand(self):
        self.assertRegex(self.bump, r"(?m)^    - cron: '30 3 \* \* \*'")
        self.assertRegex(self.bump, r"(?m)^  workflow_dispatch:")
        self.assertIn("vars.EXAKIT_AUTO_BUMP != 'false'", self.bump)

    def test_the_bump_pushes_only_its_own_branch(self):
        self.assertIn('BRANCH="chore/versions-bump"', self.bump)
        self.assertIn('git push -q --force origin "HEAD:refs/heads/$BRANCH"', self.bump)
        self.assertRegex(self.bump, r"main\|master\|feat/\*\|\"\"\) echo \"::error::refusing")
        pushes = re.findall(r"git push[^\n]*", self.bump)
        self.assertEqual(['git push -q --force origin "HEAD:refs/heads/$BRANCH"'], pushes)

    def test_a_refused_pull_request_is_not_a_failed_run(self):
        self.assertRegex(self.bump, r"elif gh pr create [^\n]*; then")
        self.assertIn("Open the pull request by hand", self.bump)
        self.assertIn("compare/$BASE...$BRANCH?expand=1", self.bump)

    def test_the_branch_is_tested_before_anyone_opens_the_pull_request(self):
        self.assertIn("for workflow in versions.yml windows-ps51.yml; do", self.bump)
        self.assertIn("actions: write", self.bump)
        for name in ("versions.yml", "windows-ps51.yml"):
            text = (WORKFLOWS / name).read_text(encoding="utf-8")
            self.assertRegex(text, r"(?m)^  workflow_dispatch:", name)

    def test_the_branch_carries_its_report_and_is_left_alone_when_a_person_pushed(self):
        self.assertIn('REPORT=".github/versions-bump-report.md"', self.bump)
        self.assertEqual(bump_checks.REPORT, ".github/versions-bump-report.md")
        self.assertIn("has commits from someone other than this workflow", self.bump)
        self.assertIn("already proposes exactly these versions", self.bump)

    def test_the_bump_script_compiles(self):
        start = self.bump.index("python3 - <<'PY'\n") + len("python3 - <<'PY'\n")
        end = self.bump.index("\n          PY\n", start)
        compile(textwrap.dedent(self.bump[start:end]), "versions-bump.yml", "exec")

    def test_the_mcp_image_fallbacks_are_found_exactly_once(self):
        found = re.findall(r'\("(setup/lib/mcp\.(?:sh|ps1))", r\'([^\']*)\'\)', self.bump)
        self.assertEqual(["setup/lib/mcp.ps1", "setup/lib/mcp.sh"], sorted(path for path, _ in found))
        image = VERSIONS["components"]["mcp"]["sidecar_image"]
        for path, pattern in found:
            matches = re.compile(pattern.replace("\\\\", "\\"), re.M).findall((ROOT / path).read_text(encoding="utf-8"))
            self.assertEqual([image], [m[1] for m in matches], path)

    def test_ci_smokes_each_changed_component_on_every_os_and_the_federation_pins(self):
        self.assertIn("component-smoke:", self.versions)
        self.assertIn("os: [ubuntu-latest, ubuntu-24.04-arm, macos-latest, macos-15-intel, windows-latest]",
                      self.versions)
        self.assertIn("python tools/bump_checks.py smoke \"$COMPONENTS\"", self.versions)
        self.assertIn("python3 tools/bump_checks.py changed --runnable /tmp/base-versions.json versions.json",
                      self.versions)
        self.assertIn("vs-artifacts-verify:", self.versions)
        self.assertIn("if: needs.changes.outputs.vs == 'true'", self.versions)
        self.assertIn("python3 tools/bump_checks.py vs-pins --base \"$BASE\"", self.versions)


if __name__ == "__main__":
    unittest.main()
