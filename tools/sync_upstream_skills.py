#!/usr/bin/env python3
"""Copy the components' own AI skills into skills/, unchanged, at a pinned ref.

    python3 tools/sync_upstream_skills.py           fetch every source in skills/upstream.json, rewrite the copies
                                                    and skills/upstream.lock.json
    python3 tools/sync_upstream_skills.py --check   offline: every copy matches the lock, every pin matches the
                                                    version the kit installs (exit 1 and the reasons otherwise)

A copy is the upstream file byte for byte with two additions, both made here and nowhere else: an `addon:` line in
the frontmatter for a skill that belongs to a marketplace add-on (or a whole frontmatter for a guide that has none),
and one quoted line under it naming where the skill came from and that the kit's own `exakit` skill comes first on
this machine. Only Markdown is copied - an upstream skill's scripts are code the kit does not ship - plus the
repository's LICENSE beside each copy. GITHUB_TOKEN is used when set.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILLS = ROOT / "skills"
SOURCES = SKILLS / "upstream.json"
LOCK = SKILLS / "upstream.lock.json"
API = "https://api.github.com/repos/"
LICENSE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt")


class SameHostAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Follow a redirect, but never hand the Authorization header to another host (SEC-12)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).hostname != urllib.parse.urlsplit(req.full_url).hostname:
            new.remove_header("Authorization")
        return new


def get(url: str, raw: bool = False) -> bytes:
    accept = "application/vnd.github.raw" if raw else "application/vnd.github+json"
    request = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": "exasol-starter-kit-skill-sync"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.build_opener(SameHostAuthRedirect).open(request, timeout=30) as response:
        return response.read()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pinned_version(path: str) -> str:
    node = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
    for part in path.split("."):
        node = node[part]
    return str(node["version"] if isinstance(node, dict) else node)


def split_front(text: str) -> tuple:
    """(frontmatter lines, body) - ([], text) for a file with none."""
    lines = text.split("\n")
    if lines and lines[0] == "---":
        for index in range(1, len(lines)):
            if lines[index] == "---":
                return lines[1:index], "\n".join(lines[index + 1:])
    return [], text


def kit_entry(text: str, skill: dict, repo: str, ref: str) -> str:
    """The upstream entry file as the kit places it: frontmatter (with addon:), the provenance line, the body."""
    front, body = split_front(text)
    if front:
        names = [line[len("name: "):].strip().strip("\"'") for line in front if line.startswith("name: ")]
        if names != [skill["name"]]:
            raise ValueError(f"{repo} {skill['path']}: its name is {names or 'missing'}, not {skill['name']}")
        if not any(line.startswith("description: ") for line in front):
            raise ValueError(f"{repo} {skill['path']}: no description in its frontmatter")
    else:
        if not skill.get("description"):
            raise ValueError(f"{repo} {skill['path']}: no frontmatter upstream, so upstream.json must give a description")
        front = [f"name: {skill['name']}", "description: " + json.dumps(skill["description"], ensure_ascii=False)]
    if skill.get("addon"):
        front = [line for line in front if not line.startswith("addon: ")]
        front.insert(1, f"addon: {skill['addon']}")
    note = (f"> **Exasol starter kit:** Exasol's own skill, copied unchanged from "
            f"[{repo}](https://github.com/{repo}) at `{ref}`. On this machine the `exakit` skill comes first: "
            f"how to connect, how to load data and which tool to reach for.")
    return "---\n" + "\n".join(front) + "\n---\n\n" + note + "\n\n" + body.lstrip("\n")


def sync() -> int:
    sources = json.loads(SOURCES.read_text(encoding="utf-8"))
    lock = {"schema_version": 1, "skills": {}}
    for source in sources["sources"]:
        repo, ref = source["repo"], source["ref"]
        commit = json.loads(get(f"{API}{repo}/commits/{urllib.parse.quote(ref)}"))["sha"]
        tree = json.loads(get(f"{API}{repo}/git/trees/{commit}?recursive=1"))
        blobs = {item["path"] for item in tree["tree"] if item["type"] == "blob"}
        license_path = next((name for name in LICENSE_NAMES if name in blobs), None)
        if not license_path:
            raise ValueError(f"{repo}@{ref}: no LICENSE at the repository root - the kit copies nothing without one")
        license_bytes = get(f"{API}{repo}/contents/{license_path}?ref={commit}", raw=True)
        for skill in source["skills"]:
            base = skill["path"].rstrip("/")
            entry = skill.get("entry", "SKILL.md")
            wanted = {f"{base}/{entry}": "SKILL.md"}
            for extra in skill.get("files", []):
                wanted[f"{base}/{extra}"] = extra
            if "files" not in skill:                  # a SKILL.md folder: its references, Markdown only
                for path in sorted(blobs):
                    if path.startswith(f"{base}/references/") and path.endswith(".md"):
                        wanted[path] = path[len(base) + 1:]
            missing = [path for path in wanted if path not in blobs]
            if missing:
                raise ValueError(f"{repo}@{ref}: not found: {', '.join(missing)}")
            target = SKILLS / skill["name"]
            if target.exists():
                shutil.rmtree(target)
            files = {}
            for path, local in wanted.items():
                data = get(f"{API}{repo}/contents/{urllib.parse.quote(path)}?ref={commit}", raw=True)
                if local == "SKILL.md":
                    data = kit_entry(data.decode("utf-8"), skill, repo, ref).encode("utf-8")
                out = target / local
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(data)
                files[local] = sha256(data)
            (target / "LICENSE").write_bytes(license_bytes)
            files["LICENSE"] = sha256(license_bytes)
            lock["skills"][skill["name"]] = {"repo": repo, "ref": ref, "commit": commit, "path": base,
                                             "addon": skill.get("addon"), "files": dict(sorted(files.items()))}
            print(f"{skill['name']:<24} {repo}@{ref} ({commit[:7]}), {len(files)} files")
    LOCK.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


def check() -> list:
    """Every reason the copies, the lock and the sources disagree - empty when they agree."""
    problems = []
    sources = json.loads(SOURCES.read_text(encoding="utf-8"))
    lock = json.loads(LOCK.read_text(encoding="utf-8"))["skills"]
    declared = {}
    for source in sources["sources"]:
        follows = source.get("follows")
        if follows:
            version = pinned_version(follows)
            if source["ref"].lstrip("v") != version.lstrip("v"):
                problems.append(f"{source['repo']} is pinned at {source['ref']}, but the kit installs {version} "
                                f"({follows}): update the ref and run tools/sync_upstream_skills.py")
        for skill in source["skills"]:
            declared[skill["name"]] = (source["repo"], source["ref"], skill.get("addon"))
    for name, (repo, ref, addon) in declared.items():
        entry = lock.get(name)
        if not entry:
            problems.append(f"{name}: in upstream.json but never synced")
            continue
        if (entry["repo"], entry["ref"], entry.get("addon")) != (repo, ref, addon):
            problems.append(f"{name}: upstream.json changed since the last sync - run tools/sync_upstream_skills.py")
        folder = SKILLS / name
        on_disk = {str(path.relative_to(folder)) for path in folder.rglob("*") if path.is_file()} if folder.is_dir() else set()
        for local, digest in entry["files"].items():
            path = folder / local
            if not path.is_file():
                problems.append(f"{name}/{local}: missing")
            elif sha256(path.read_bytes()) != digest:
                problems.append(f"{name}/{local}: edited by hand - it must match {entry['repo']}@{entry['ref']}")
        for extra in sorted(on_disk - set(entry["files"])):
            problems.append(f"{name}/{extra}: not from upstream")
    for name in sorted(set(lock) - set(declared)):
        problems.append(f"{name}: in the lock but no longer in upstream.json - delete skills/{name} and re-sync")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="verify the copies offline instead of fetching")
    parser.add_argument("--names", action="store_true", help="print the vendored skill names, one per line")
    args = parser.parse_args()
    if args.names:
        print("\n".join(sorted(json.loads(LOCK.read_text(encoding="utf-8"))["skills"])))
        return 0
    if args.check:
        problems = check()
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1 if problems else 0
    try:
        return sync()
    except (urllib.error.URLError, ValueError, KeyError) as error:
        print(f"sync failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
