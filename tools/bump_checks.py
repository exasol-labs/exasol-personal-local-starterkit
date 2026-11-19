"""What CI checks when a pinned version or artifact changes, and the report a version bump leaves on its branch.

    python3 tools/bump_checks.py changed [--runnable] BASE HEAD   # the component keys whose block differs (JSON)
    python3 tools/bump_checks.py smoke '["exapump","pyexasol"]'   # this machine: fetch, verify, run each one
    python3 tools/bump_checks.py vs-pins --base REF               # Federation pins that changed since REF
    python3 tools/bump_checks.py vs-pins --all                    # every Federation pin
    python3 tools/bump_checks.py glibc FILE                       # the highest GLIBC_x.y an ELF file references
    python3 tools/bump_checks.py report bump-report.json          # the bump branch's markdown report

A version bump that only moves a number proves nothing: the new release can be missing an asset, carry a binary
that does not start on one platform, need a newer glibc than the kit records, or a Python package that no longer
imports. `smoke` does on each CI runner what an install does there - download the pinned asset, refuse it unless
its SHA-256 is the pin, unpack it, run it - for the components a change touched, so a broken bump fails CI on
the platform it breaks. `vs-pins` does the same for the adapters, JDBC drivers, language container and CA bundle
the Federation connectors pin (setup/virtual-schemas/connectors/*/connector.json and profiles/*/profile.json):
the URL answers, and the bytes have the pinned size and SHA-256 (and, for a bundle, the member the engine reads).

Nothing here writes outside the work directory it is given or the system temp folder.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import platform
import posixpath
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "versions.json"
VS_GLOBS = ("setup/virtual-schemas/connectors/*/connector.json", "setup/virtual-schemas/profiles/*/profile.json")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
KIT_REPO = "exasol-labs/exasol-personal-local-starterkit"
REPORT = ".github/versions-bump-report.md"     # the report a bump branch carries
MANAGED_PYTHON = "3.12"      # EXAKIT_MANAGED_PYTHON_VERSION: what the kit builds every Python venv with


class CheckFailure(Exception):
    pass


# --- which components a change touched ---------------------------------------

def changed_components(base: dict | None, head: dict) -> list[str]:
    """The component keys whose block differs between two versions.json documents. No base (a first push, a
    rerun without history): every component, since nothing says what is already proven."""
    head_components = head.get("components") or {}
    if base is None:
        return sorted(head_components)
    base_components = base.get("components") or {}
    return sorted(key for key, block in head_components.items() if base_components.get(key) != block)


# --- the host, in each component's own platform key ---------------------------

def host() -> tuple[str, str]:
    """(os, arch) as the kit names them: linux|macos|windows, x86_64|aarch64."""
    system = platform.system().lower()
    system = {"darwin": "macos"}.get(system, system)
    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "x64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
    return system, arch


def platform_key(style: str, system: str, arch: str) -> str:
    """exapump, uv and json-tables key arm as aarch64; Personal and exasol-scheduler as arm64."""
    if style == "arm64" and arch == "aarch64":
        arch = "arm64"
    return "%s-%s" % (system, arch)


UV_TARGETS = {
    "macos-aarch64": "aarch64-apple-darwin",
    "macos-x86_64": "x86_64-apple-darwin",
    "linux-aarch64": "aarch64-unknown-linux-gnu",
    "linux-x86_64": "x86_64-unknown-linux-gnu",
    "windows-x86_64": "x86_64-pc-windows-msvc",
}


# --- download and verify ------------------------------------------------------

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, dest: Path) -> None:
    """HTTPS only, the way every kit download is made (curl first, urllib if there is none)."""
    if not url.startswith("https://"):
        raise CheckFailure("refusing a non-HTTPS URL: %s" % url)
    curl = shutil.which("curl")
    if curl:
        done = subprocess.run([curl, "-fL", "--proto", "=https", "--retry", "3", "--connect-timeout", "20",
                               "-sS", "-o", str(dest), url], capture_output=True, text=True)
        if done.returncode == 0:
            return
        raise CheckFailure("could not download %s: %s" % (url, done.stderr.strip() or "curl exit %d" % done.returncode))
    last = "unknown error"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "exakit-ci"}),
                                        timeout=120) as response, open(dest, "wb") as out:
                shutil.copyfileobj(response, out)
            return
        except Exception as error:      # network, DNS, HTTP
            last = str(error)
            time.sleep(2 * (attempt + 1))
    raise CheckFailure("could not download %s: %s" % (url, last))


def fetch_verified(url: str, expected: str, dest: Path, size: int | None = None) -> Path:
    """Download url to dest and refuse it unless its size (when pinned) and SHA-256 are the pin."""
    download(url, dest)
    if size is not None and dest.stat().st_size != int(size):
        raise CheckFailure("%s is %d bytes, the pin says %d" % (url, dest.stat().st_size, int(size)))
    actual = sha256_file(dest)
    if actual != expected:
        raise CheckFailure("%s does not match its pin\n    pinned: %s\n    actual: %s" % (url, expected, actual))
    return dest


# --- glibc floor of a Linux binary ---------------------------------------------

def glibc_floor(data: bytes) -> str | None:
    """The highest GLIBC_x.y a 64-bit little-endian ELF file's version references name (what `objdump -p` lists
    under "Version References"): the oldest glibc that can load it. None for a file that is not such an ELF or
    references no glibc version (a static binary)."""
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return None
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    if not shoff or shentsize < 64 or shoff + shnum * shentsize > len(data):
        return None
    sections = []
    for index in range(shnum):
        name, kind, _flags, _addr, offset, size, link, info = struct.unpack_from(
            "<IIQQQQII", data, shoff + index * shentsize)
        sections.append((name, kind, offset, size, link, info))

    def cstring(offset: int) -> str:
        end = data.find(b"\0", offset)
        return data[offset:end if end >= 0 else len(data)].decode("ascii", "replace")

    SHT_GNU_VERNEED = 0x6ffffffe
    best = None
    for _name, kind, offset, _size, link, info in sections:
        if kind != SHT_GNU_VERNEED or link >= len(sections):
            continue
        strtab = sections[link][2]
        entry = offset
        for _ in range(info):           # sh_info: the number of Verneed entries
            _version, count, _file, aux, following = struct.unpack_from("<HHIII", data, entry)
            pointer = entry + aux
            for _ in range(count):
                _hash, _flags, _other, name, aux_next = struct.unpack_from("<IHHII", data, pointer)
                match = re.fullmatch(r"GLIBC_(\d+)\.(\d+)(?:\.\d+)?", cstring(strtab + name))
                if match:
                    found = (int(match.group(1)), int(match.group(2)))
                    best = found if best is None or found > best else best
                if not aux_next:
                    break
                pointer += aux_next
            if not following:
                break
            entry += following
    return "%d.%d" % best if best else None


def glibc_floor_in_archive(payload: bytes, member: str) -> str | None:
    """glibc_floor of the one file named `member` (by basename) inside a .tar.gz held in memory."""
    try:
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
            for item in archive:
                if item.isfile() and posixpath.basename(item.name) == member:
                    return glibc_floor(archive.extractfile(item).read())
    except (tarfile.TarError, OSError):
        return None
    return None


def check_glibc(component: str, key: str, binary: Path, block: dict, lines: list[str]) -> None:
    """The floor versions.json records for a Linux binary (components.<c>.glibc.<key>) is the one the kit checks
    before installing it; a new build that needs a newer glibc than recorded would be installed where it cannot
    load. A floor that no longer matches the binary fails the check."""
    measured = glibc_floor(binary.read_bytes())
    pinned = (block.get("glibc") or {}).get(key)
    if pinned is None:
        lines.append("%s %s: needs glibc %s (no floor recorded in versions.json)" % (component, key, measured or "-"))
        return
    if measured != pinned:
        raise CheckFailure("%s %s: the binary needs glibc %s but versions.json records %s - set "
                           "components.%s.glibc.%s to %s" % (component, key, measured, pinned, component, key,
                                                             measured))
    lines.append("%s %s: glibc floor %s matches the binary" % (component, key, pinned))


# --- running what was downloaded ----------------------------------------------

def run(argv: list[str], expect: str | None, label: str, timeout: int = 120, env: dict | None = None) -> str:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL,
                              env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CheckFailure("%s did not run: %s" % (label, error))
    output = (done.stdout + done.stderr).strip()
    if done.returncode != 0:
        raise CheckFailure("%s exited %d: %s" % (label, done.returncode, output[-800:]))
    if expect is not None and expect not in output:
        raise CheckFailure("%s answered %r, expected it to name %s" % (label, output[:300], expect))
    return output.splitlines()[0] if output else ""


def executable(path: Path) -> Path:
    if os.name != "nt":
        path.chmod(0o755)
    return path


def extract_member(archive: Path, wanted: str, dest: Path) -> Path:
    """The one regular file named `wanted` (by basename) inside a .tar.gz or .zip, written to dest."""
    if archive.name.endswith(".zip"):
        with zipfile.ZipFile(archive) as source:
            hits = [item for item in source.infolist()
                    if not item.is_dir() and posixpath.basename(item.filename) == wanted]
            if len(hits) != 1 or hits[0].file_size == 0:
                raise CheckFailure("%s holds %d files named %s, the install needs exactly one"
                                   % (archive.name, len(hits), wanted))
            with source.open(hits[0]) as data, open(dest, "wb") as out:
                shutil.copyfileobj(data, out)
    else:
        with tarfile.open(archive, "r:gz") as source:
            hits = [item for item in source if item.isfile() and posixpath.basename(item.name) == wanted]
            if len(hits) != 1 or hits[0].size == 0:
                raise CheckFailure("%s holds %d files named %s, the install needs exactly one"
                                   % (archive.name, len(hits), wanted))
            data = source.extractfile(hits[0])
            with data, open(dest, "wb") as out:
                shutil.copyfileobj(data, out)
    return executable(dest)


def numeric(version: str) -> str | None:
    match = re.match(r"^v?(\d+(?:\.\d+)+)$", version.strip())
    return match.group(1) if match else None


class Smoke(object):
    """Each component's install-time proof, on this machine. A method returns the lines it reports; a failure
    raises CheckFailure. `portable` checks (the same bytes on every OS) run on one runner only."""

    def __init__(self, doc: dict, work: Path, system: str, arch: str, repo: str):
        self.components = doc.get("components") or {}
        self.work = work
        self.system, self.arch = system, arch
        self.repo = repo
        self.exe = ".exe" if system == "windows" else ""
        self._uv = None
        self.portable = (system, arch) == ("linux", "x86_64")

    def block(self, key: str) -> dict:
        return self.components.get(key) or {}

    def pinned(self, key: str, style: str) -> tuple[str, str | None]:
        platform_name = platform_key(style, self.system, self.arch)
        return platform_name, (self.block(key).get("sha256") or {}).get(platform_name)

    # binaries
    def personal(self) -> list[str]:
        block = self.block("personal")
        key = platform_key("arm64", self.system, self.arch)
        expected = ((block.get("s3") or {}).get("sha256") or {}).get(key)
        if not expected:
            return ["personal: no launcher is pinned for %s" % key]
        version = block["version"]
        os_name, arch = key.split("-", 1)
        url = "%s/%s/%s/%s/exasol%s" % (block["s3"]["base_url"].rstrip("/"), os_name, arch, version, self.exe)
        binary = executable(fetch_verified(url, expected, self.work / ("exasol" + self.exe)))
        said = run([str(binary), "version"], version, "exasol version")
        return ["personal %s %s: sha256 verified, `exasol version` says %s" % (version, key, said)]

    def exapump(self) -> list[str]:
        block = self.block("exapump")
        key, expected = self.pinned("exapump", "aarch64")
        if not expected:
            return ["exapump: no asset is pinned for %s" % key]
        version, repo = block["version"], block.get("repo", "exasol-labs/exapump")
        url = "https://github.com/%s/releases/download/v%s/exapump-%s-%s%s" % (repo, version, version, key, self.exe)
        binary = executable(fetch_verified(url, expected, self.work / ("exapump" + self.exe)))
        lines = ["exapump %s %s: sha256 verified, --version says %s"
                 % (version, key, run([str(binary), "--version"], version, "exapump --version"))]
        if self.system == "linux":
            lines.append("exapump %s: needs glibc %s (older systems run it through the kit's container shim)"
                         % (key, glibc_floor(binary.read_bytes()) or "-"))
        return lines

    def uv_binary(self) -> Path:
        """The pinned uv for this machine, verified - the Python checks build their venvs with it, as the kit does."""
        if self._uv is None:
            block = self.block("uv")
            key, expected = self.pinned("uv", "aarch64")
            if not expected or key not in UV_TARGETS:
                raise CheckFailure("uv: no archive is pinned for %s" % key)
            asset = "uv-%s.%s" % (UV_TARGETS[key], "zip" if self.system == "windows" else "tar.gz")
            url = "https://github.com/%s/releases/download/%s/%s" % (block.get("repo", "astral-sh/uv"),
                                                                     block["version"], asset)
            archive = fetch_verified(url, expected, self.work / asset)
            self._uv = extract_member(archive, "uv" + self.exe, self.work / ("uv" + self.exe))
        return self._uv

    def uv(self) -> list[str]:
        version = self.block("uv")["version"]
        said = run([str(self.uv_binary()), "--version"], "uv " + version, "uv --version")
        return ["uv %s %s: sha256 verified, --version says %s"
                % (version, platform_key("aarch64", self.system, self.arch), said)]

    def exasol_scheduler(self) -> list[str]:
        block = self.block("exasol-scheduler")
        key, expected = self.pinned("exasol-scheduler", "arm64")
        if not expected:
            return ["exasol-scheduler: no archive is pinned for %s" % key]
        version, repo = block["version"], block.get("repo", "exasol-labs/exasol-scheduler")
        asset = "exasol_scheduler-v%s-%s.%s" % (version, key, "zip" if self.system == "windows" else "tar.gz")
        archive = fetch_verified("https://github.com/%s/releases/download/v%s/%s" % (repo, version, asset),
                                 expected, self.work / asset)
        engine = extract_member(archive, "exasol_scheduler" + self.exe, self.work / ("exasol_scheduler" + self.exe))
        lines = []
        if self.system == "linux":
            check_glibc("exasol-scheduler", key, engine, block, lines)
        # The install's own probe ("Checking Scheduler engine"): the engine has no --version.
        run([str(engine), "--help"], "Usage", "exasol_scheduler --help")
        lines.insert(0, "exasol-scheduler %s %s: sha256 verified, one engine binary, --help answers" % (version, key))
        return lines

    def json_tables(self) -> list[str]:
        block = self.block("json-tables")
        pins = block.get("sha256") or {}
        release = block.get("release") or "json-tables-%s" % block["version"]
        base = "https://github.com/%s/releases/download/%s/" % (self.repo, release)
        key = platform_key("aarch64", self.system, self.arch)
        lines = []
        if pins.get(key):
            name = "exasol-json-tables-ingest-%s%s" % (key, self.exe)
            engine = executable(fetch_verified(base + name, pins[key], self.work / name))
            expect = numeric(block["version"])
            said = run([str(engine), "--version"], expect, "json-tables ingest --version")
            lines.append("json-tables %s %s: sha256 verified, --version says %s" % (block["version"], key, said))
            if self.system == "linux":
                check_glibc("json-tables", key, engine, block, lines)
        else:
            lines.append("json-tables: no ingest engine is published for %s (the add-on is not offered here)" % key)
        if self.system == "windows" and pins.get("cargo-windows-x86_64"):
            name = "exakit-json-tables-cargo-windows-x86_64.exe"
            fetch_verified(base + name, pins["cargo-windows-x86_64"], self.work / name)
            lines.append("json-tables cargo shim: sha256 verified")
        if block.get("wheel") and pins.get("wheel"):
            wheel = fetch_verified(base + block["wheel"], pins["wheel"], self.work / block["wheel"])
            lines.append(self._python_check("json-tables wheel", [str(wheel)], "exasol_json_tables", None, None))
        return lines

    # Python packages, installed the way the kit installs them: a uv venv on Python 3.12, then the pin.
    def _python_check(self, label: str, requirement: list[str], module: str, dist: str | None,
                      version: str | None) -> str:
        uv = str(self.uv_binary())
        venv = self.work / ("venv-" + re.sub(r"[^A-Za-z0-9]+", "-", label))
        env = dict(os.environ, UV_CACHE_DIR=str(self.work / "uv-cache"), UV_PYTHON_INSTALL_DIR=str(self.work / "py"))
        run([uv, "venv", "--python", MANAGED_PYTHON, str(venv)], None, "%s: uv venv" % label, timeout=300, env=env)
        python = venv / ("Scripts/python.exe" if self.system == "windows" else "bin/python")
        run([uv, "pip", "install", "--python", str(python)] + requirement, None, "%s: install" % label,
            timeout=900, env=env)
        probe = "import importlib, importlib.metadata as m; importlib.import_module(%r)" % module
        if dist:
            probe += "; print(m.version(%r))" % dist
        said = run([str(python), "-c", probe], version, "%s: import %s" % (label, module), env=env)
        return "%s: installs into a clean Python %s venv and `import %s` works%s" % (
            label, MANAGED_PYTHON, module, (" (%s %s)" % (dist, said)) if dist else "")

    def pyexasol(self) -> list[str]:
        block = self.block("pyexasol")
        package = block.get("package", "pyexasol")
        return [self._python_check("pyexasol " + block["version"], ["%s==%s" % (package, block["version"])],
                                   "pyexasol", package, block["version"])]

    def dbt_exasol(self) -> list[str]:
        block = self.block("dbt-exasol")
        package = block.get("package", "dbt-exasol")
        return [self._python_check("dbt-exasol " + block["version"], ["%s==%s" % (package, block["version"])],
                                   "dbt.adapters.exasol", package, block["version"])]

    def dash_server(self) -> list[str]:
        block = self.block("dash-server")
        repo = block.get("repo", "exasol-labs/dash-server")
        url = "https://github.com/%s/archive/refs/tags/v%s.tar.gz" % (repo, block["version"])
        return [self._python_check("dash-server " + block["version"], [url], "dash_server",
                                   block.get("package", "dash-server"), block["version"])]

    def mcp(self) -> list[str]:
        block = self.block("mcp")
        lines = []
        bridge = block.get("bridge")
        if bridge:
            # Claude Desktop reaches the server through this bridge, launched by uvx on the user's machine.
            name, _, version = bridge.partition("@")
            uv = str(self.uv_binary())
            env = dict(os.environ, UV_CACHE_DIR=str(self.work / "uv-cache"),
                       UV_PYTHON_INSTALL_DIR=str(self.work / "py"), UV_TOOL_DIR=str(self.work / "uv-tools"))
            run([uv, "tool", "run", "--python", MANAGED_PYTHON, "--from", "%s==%s" % (name, version), name, "--help"],
                None, "mcp bridge %s --help" % bridge, timeout=600, env=env)
            lines.append("mcp bridge %s: uvx installs it and --help answers" % bridge)
        if self.portable and block.get("sidecar_image"):
            lines.extend(check_image(block["sidecar_image"], block["version"]))
        return lines

    # Same bytes on every OS: one runner is enough.
    def exasol_vscode(self) -> list[str]:
        if not self.portable:
            return []
        block = self.block("exasol-vscode")
        expected = (block.get("sha256") or {}).get("vsix")
        repo = block.get("repo", "exasol-labs/exasol-vscode")
        asset = "exasol-vscode-%s.vsix" % block["version"]
        url = "https://github.com/%s/releases/download/v%s/%s" % (repo, block["version"], asset)
        vsix = fetch_verified(url, expected, self.work / asset) if expected else None
        if vsix is None:
            return ["exasol-vscode: no vsix digest is pinned"]
        with zipfile.ZipFile(vsix) as archive:
            manifest = json.loads(archive.read("extension/package.json"))
        if manifest.get("version") != block["version"]:
            raise CheckFailure("exasol-vscode: the vsix says version %s, versions.json %s"
                               % (manifest.get("version"), block["version"]))
        return ["exasol-vscode %s: vsix sha256 verified, its package.json names the same version" % block["version"]]

    def semantic_views(self) -> list[str]:
        if not self.portable:
            return []
        block = self.block("semantic-views")
        expected = (block.get("sha256") or {}).get("archive")
        url = "https://github.com/%s/releases/download/%s/%s" % (block["repo"], block["version"], block["asset"])
        archive = fetch_verified(url, expected, self.work / block["asset"])
        with zipfile.ZipFile(archive) as source:
            broken = source.testzip()
        if broken:
            raise CheckFailure("semantic-views: %s is damaged at %s" % (block["asset"], broken))
        return ["semantic-views %s: archive sha256 verified, the zip reads clean" % block["version"]]

    def run_all(self, keys: list[str]) -> tuple[list[str], list[str]]:
        report, failures = [], []
        for key in keys:
            method = getattr(self, key.replace("-", "_"), None)
            if method is None or key in COVERED_ELSEWHERE:
                report.append("%s: %s" % (key, COVERED_ELSEWHERE.get(key, "nothing to run")))
                continue
            try:
                report.extend(method())
            except CheckFailure as error:
                failures.append("%s: %s" % (key, error))
        return report, failures


COVERED_ELSEWHERE = {
    "preprocessor": "release.sql and its core-only text are hashed by digest-verify; nothing runs off a database",
    "skills": "nothing to fetch: installed kits take the skill files from main (tests/skills.sh)",
}


def runnable(key: str) -> bool:
    """A component smoke has a check for (the rest are covered by another job, or have nothing to fetch)."""
    return key not in COVERED_ELSEWHERE and callable(getattr(Smoke, key.replace("-", "_"), None))


def registry_digest(image: str) -> tuple[str | None, list[str], str | None]:
    """(index digest, platforms, error) for docker.io/<repo>:<tag>[@...], from Docker Hub's registry API."""
    reference = image.split("@", 1)[0]
    if not reference.startswith("docker.io/"):
        return None, [], "only docker.io images are checked (%s)" % reference
    repository, _, tag = reference[len("docker.io/"):].rpartition(":")
    accept = ", ".join(["application/vnd.oci.image.index.v1+json",
                        "application/vnd.docker.distribution.manifest.list.v2+json",
                        "application/vnd.docker.distribution.manifest.v2+json",
                        "application/vnd.oci.image.manifest.v1+json"])
    try:
        token_url = ("https://auth.docker.io/token?service=registry.docker.io&scope=repository:%s:pull"
                     % urllib.parse.quote(repository, safe="/"))
        with urllib.request.urlopen(token_url, timeout=30) as response:
            token = json.load(response)["token"]
        request = urllib.request.Request("https://registry-1.docker.io/v2/%s/manifests/%s" % (repository, tag),
                                         headers={"Authorization": "Bearer " + token, "Accept": accept})
        with urllib.request.urlopen(request, timeout=30) as response:
            digest = response.headers.get("Docker-Content-Digest")
            body = json.load(response)
    except Exception as error:
        return None, [], str(error)
    platforms = sorted("%s/%s" % ((m.get("platform") or {}).get("os"), (m.get("platform") or {}).get("architecture"))
                       for m in body.get("manifests") or [] if (m.get("platform") or {}).get("os") != "unknown")
    return digest, platforms, None


def check_image(image: str, version: str) -> list[str]:
    """The launcher's MCP image: its tag is the MCP version, its pinned digest is what Docker Hub serves for that
    tag, and it is built for both Linux architectures the launcher runs on."""
    tag = image.split("@", 1)[0].rsplit(":", 1)[-1]
    pinned = image.split("@", 1)[1] if "@" in image else ""
    if tag != version:
        raise CheckFailure("mcp: sidecar_image is tagged %s but components.mcp.version is %s" % (tag, version))
    digest, platforms, error = registry_digest(image)
    if error:
        raise CheckFailure("mcp: %s did not resolve on Docker Hub (%s)" % (image.split("@")[0], error))
    if digest != pinned:
        raise CheckFailure("mcp: Docker Hub serves %s for %s, the pin says %s" % (digest, tag, pinned))
    missing = [p for p in ("linux/amd64", "linux/arm64") if p not in platforms]
    if missing:
        raise CheckFailure("mcp: image %s has no %s build" % (tag, ", ".join(missing)))
    return ["mcp sidecar image %s: digest is what Docker Hub serves, built for %s" % (tag, ", ".join(platforms))]


# --- Federation pins -------------------------------------------------------------

def vs_pins(doc, path: str = "") -> list[tuple[str, dict, dict]]:
    """Every {url, sha256} pin in a connector or profile document: (json path, pin, the nearest enclosing object
    that names a bundle member - lakehouse keeps `member` one level above its per-arch pins)."""
    found = []

    def walk(node, where, context):
        if isinstance(node, dict):
            if "member" in node:
                context = node
            if "url" in node and "sha256" in node:
                found.append((where, node, context))
            for key, value in node.items():
                walk(value, "%s.%s" % (where, key) if where else key, context)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, "%s[%d]" % (where, index), context)

    walk(doc, path, {})
    return found


def vs_pin_problems(pin: dict) -> list[str]:
    """What is wrong with a pin without downloading it: the engine refuses each of these at connect time."""
    problems = []
    url = str(pin.get("url", ""))
    if not url.startswith("https://"):
        problems.append("url is not HTTPS")
    if not HEX64.match(str(pin.get("sha256", ""))):
        problems.append("sha256 is not 64 lowercase hex characters")
    if not isinstance(pin.get("size"), int) or pin["size"] <= 0:
        problems.append("size is not a positive whole number of bytes")
    if pin.get("asset") != posixpath.basename(urllib.parse.urlparse(url).path):
        problems.append("asset %r is not the file the url names" % pin.get("asset"))
    if ("member_sha256" in pin) != ("member_size" in pin):
        problems.append("member_sha256 and member_size come together")
    return problems


def git_show(ref: str, path: str) -> dict | None:
    done = subprocess.run(["git", "-C", str(ROOT), "show", "%s:%s" % (ref, path)], capture_output=True, text=True)
    if done.returncode != 0:
        return None
    try:
        return json.loads(done.stdout)
    except ValueError:
        return None


def vs_targets(base_ref: str | None, root: Path = ROOT, read_base=git_show) -> list[tuple[str, str, dict, dict]]:
    """(file, json path, pin, context) for every pin to check: all of them without a base, else the ones whose
    pin object differs from the base's (a new connector's pins are all new)."""
    targets = []
    for pattern in VS_GLOBS:
        for file in sorted(root.glob(pattern)):
            rel = file.relative_to(root).as_posix()
            head = json.loads(file.read_text(encoding="utf-8"))
            before = {}
            if base_ref:
                base_doc = read_base(base_ref, rel)
                before = {where: (pin, (context or {}).get("member"))
                          for where, pin, context in vs_pins(base_doc or {})}
            for where, pin, context in vs_pins(head):
                if base_ref and before.get(where) == (pin, (context or {}).get("member")):
                    continue
                targets.append((rel, where, pin, context))
    return targets


def verify_vs_pin(pin: dict, context: dict, work: Path, fetch=fetch_verified) -> str:
    """Download one pin and prove what the engine will prove: size, SHA-256, and the member it reads."""
    dest = work / pin["asset"]
    fetch(pin["url"], pin["sha256"], dest, pin["size"])
    said = "%d bytes, sha256 verified" % pin["size"]
    member = (context or {}).get("member")
    if member and "member_sha256" in pin:
        with tarfile.open(dest, "r:gz") as archive:
            try:
                entry = archive.getmember(member)
            except KeyError:
                raise CheckFailure("%s holds no %s" % (pin["asset"], member))
            if not entry.isfile():
                raise CheckFailure("%s in %s is not a regular file" % (member, pin["asset"]))
            digest = hashlib.sha256()
            data = archive.extractfile(entry)
            size = 0
            for block in iter(lambda: data.read(1 << 20), b""):
                digest.update(block)
                size += len(block)
        if size != int(pin["member_size"]) or digest.hexdigest() != pin["member_sha256"]:
            raise CheckFailure("%s from %s does not match its pinned size and SHA-256" % (member, pin["asset"]))
        said += ", %s verified" % member
    if pin.get("bundle") == "zip" and pin.get("entry"):
        with zipfile.ZipFile(dest) as archive:
            names = [posixpath.basename(item.filename) for item in archive.infolist() if not item.is_dir()]
        if pin["entry"] not in names:
            raise CheckFailure("%s holds no %s" % (pin["asset"], pin["entry"]))
        said += ", holds %s" % pin["entry"]
    dest.unlink()
    return said


# --- the bump branch's report ------------------------------------------------------

def render_report(report: dict, repo: str, branch: str, base: str = "main") -> str:
    """The markdown a version-bump branch carries: what moved, from where, what was proven, and how to open the
    pull request by hand (GitHub Actions in this repository may not open one itself)."""
    bumped = report.get("components") or []
    lines = ["# Version bump proposal: %s" % (", ".join("%s %s" % (c["key"], c["new"]) for c in bumped) or "nothing"),
             "",
             "Written by the `versions-bump` workflow on %s from `%s` at %s. This branch is a proposal: nothing "
             "reaches users until a pull request from it is reviewed and merged."
             % (report.get("date", "today"), base, report.get("base_sha", "")[:12] or "the base"),
             "",
             "| Component | Was | Now | Upstream release | Digests | Min kit |",
             "|---|---|---|---|---|---|"]
    for c in bumped:
        lines.append("| `%s` | %s | **%s** | [%s](%s) | %s | %s |" % (
            c["key"], c["old"], c["new"], c.get("link_label", "release"), c.get("link", ""),
            c.get("digests", "-"), c.get("min_kit_version") or "-"))
    for c in bumped:
        if not (c.get("notes") or c.get("checks")):
            continue
        lines += ["", "## %s %s -> %s" % (c["key"], c["old"], c["new"]), ""]
        for note in c.get("notes") or []:
            lines.append("- %s" % note)
        for check in c.get("checks") or []:
            lines.append("- checked: %s" % check)
    if report.get("touched"):
        lines += ["", "## Files changed beside versions.json", ""]
        lines += ["- `%s`" % path for path in report["touched"]]
    if report.get("left_alone"):
        lines += ["", "## Left alone", ""] + list(report["left_alone"])
    lines += ["", "## What this workflow checked before pushing", ""]
    lines += ["- %s" % item for item in report.get("workflow_checks") or []]
    lines += ["", "## What CI checks on this branch", "",
              "The bump workflow starts `versions` and `windows-ps51` on this branch itself (a push made with the "
              "workflow token starts no workflow). Their runs: "
              "https://github.com/%s/actions?query=branch%%3A%s" % (repo, urllib.parse.quote(branch, safe="")),
              ""]
    lines += ["- %s" % item for item in CI_ON_BRANCH]
    lines += ["", "## Open the pull request", "",
              "GitHub Actions may not open pull requests in this repository, so open it by hand:", "",
              "    git fetch origin %s" % branch,
              "    gh pr create -R %s --base %s --head %s --title %s --body-file <(git show origin/%s:%s)"
              % (repo, base, branch, shell_quote(report.get("title", "Bump advertised versions")), branch, REPORT),
              "",
              "or in the browser: https://github.com/%s/compare/%s...%s?expand=1" % (repo, base, branch),
              "",
              "This file (`%s`) only describes this proposal and is replaced by the next one; it is a commit of "
              "its own, so it can be dropped from the pull request: `git rm %s`." % (REPORT, REPORT),
              "", "## Before merging", ""]
    lines += ["- [ ] %s" % item for item in report.get("checklist") or []]
    return "\n".join(lines) + "\n"


CI_ON_BRANCH = [
    "validate: canonical versions.json, schema, the MCP constant",
    "personal-s3-digest-verify, digest-verify, uv-digest-verify: every pinned asset downloaded and hashed",
    "upstream-exists: each advertised version is published (PyPI not yanked, GitHub tags, vsix digest)",
    "component-smoke on linux x86_64 and arm64, macOS arm64 and x86_64, Windows: each changed component "
    "downloaded, verified and run there (`--version`, `--help`, a clean-venv install and import)",
    "the shell, PowerShell 5.1 and Python suites, including the fallback constants (tests/versions-manifest.sh)",
]


def shell_quote(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


# --- command line ------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    changed = commands.add_parser("changed")
    changed.add_argument("--runnable", action="store_true", help="only components smoke has something to run for")
    changed.add_argument("base")
    changed.add_argument("head")
    smoke = commands.add_parser("smoke")
    smoke.add_argument("components", help="a JSON list of component keys")
    smoke.add_argument("--work")
    pins = commands.add_parser("vs-pins")
    pins.add_argument("--base")
    pins.add_argument("--all", action="store_true")
    glibc = commands.add_parser("glibc")
    glibc.add_argument("file")
    rendered = commands.add_parser("report")
    rendered.add_argument("file")
    rendered.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", KIT_REPO))
    rendered.add_argument("--branch", default="chore/versions-bump")
    rendered.add_argument("--base-branch", default="main")
    args = parser.parse_args(argv)

    if args.command == "changed":
        base = None
        if os.path.isfile(args.base):
            try:
                base = json.loads(Path(args.base).read_text(encoding="utf-8"))
            except ValueError:
                base = None
        keys = changed_components(base, json.loads(Path(args.head).read_text(encoding="utf-8")))
        if args.runnable:
            keys = [key for key in keys if runnable(key)]
        print(json.dumps(keys))
        return 0

    if args.command == "glibc":
        print(glibc_floor(Path(args.file).read_bytes()) or "none")
        return 0

    if args.command == "report":
        report = json.loads(Path(args.file).read_text(encoding="utf-8"))
        sys.stdout.write(render_report(report, args.repo, args.branch, args.base_branch))
        return 0

    if args.command == "smoke":
        keys = json.loads(args.components)
        system, arch = host()
        work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="exakit-smoke-"))
        work.mkdir(parents=True, exist_ok=True)
        doc = json.loads(MANIFEST.read_text(encoding="utf-8"))
        smoke_run = Smoke(doc, work, system, arch, os.environ.get("GITHUB_REPOSITORY") or KIT_REPO)
        print("component smoke on %s-%s for: %s" % (system, arch, ", ".join(keys) or "nothing"))
        report, failures = smoke_run.run_all(keys)
        for line in report:
            print("  ok  " + line)
        for line in failures:
            print("  FAIL " + line, file=sys.stderr)
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)
        return 1 if failures else 0

    if args.command == "vs-pins":
        if not args.all and not args.base:
            parser.error("vs-pins needs --base REF or --all")
        all_pins = vs_targets(None)
        static = [(rel, where, problem) for rel, where, pin, _ in all_pins for problem in vs_pin_problems(pin)]
        for rel, where, problem in static:
            print("  FAIL %s %s: %s" % (rel, where, problem), file=sys.stderr)
        targets = all_pins if args.all else vs_targets(args.base)
        print("%d Federation pins in all, %d to download (%s)"
              % (len(all_pins), len(targets), "all" if args.all else "changed since %s" % args.base))
        failures = len(static)
        with tempfile.TemporaryDirectory(prefix="exakit-vs-pins-") as temp:
            for rel, where, pin, context in targets:
                try:
                    print("  ok  %s %s: %s" % (rel, where, verify_vs_pin(pin, context, Path(temp))))
                except (CheckFailure, tarfile.TarError, zipfile.BadZipFile, OSError) as error:
                    failures += 1
                    print("  FAIL %s %s: %s" % (rel, where, error), file=sys.stderr)
        return 1 if failures else 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
