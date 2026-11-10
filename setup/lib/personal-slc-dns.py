"""Give Exasol Personal's language containers the deployment's DNS.

    personal-slc-dns.py [--engine CLI] [--deployment-id=ID] [--budget S] FLAVOR [FLAVOR ...]
    personal-slc-dns.py --engine docker --prepare STATE [--pull] [--budget S] [FLAVOR ...]

A language container (SLC) is its own filesystem, and the official ones ship
etc/resolv.conf and etc/hosts EMPTY. The database mounts the deployment's real
files into every UDF sandbox at /conf, but a UDF reads /etc: Java code in the
database can reach any IP address and resolve no name, so a virtual schema
adapter cannot connect to a remote source by hostname. Every database start
rebuilds the container from its image, so this runs after every start.

This is the host-engine route (Linux, WSL, Windows), where the database
container belongs to the engine this machine talks to: --engine names its CLI,
the one the kit recorded for the deployment (podman or docker; --podman is the
old spelling of the same option). On macOS the container lives in the
launcher's VM and runtime-personal.sh feeds the same logic, as a POSIX sh
script, to `exasol shell container`. Python because Windows has no sh and
Windows PowerShell 5.1 cannot pipe binary data between programs: the two
symlinks are written straight into an in-memory tar stream (no symlink
privileges needed on the host) and handed to `<engine> cp -`.

The database container is the one the launcher names exasol-db-<deployment
id> on both engines (Exasol Personal 2.4, internal/localinstall/
podman_install.go ContainerName); a sidecar is exasol-db-<id>-sidecar-<name>.
Nothing else is written to: see pick().

Only a file that is still the shipped EMPTY one is replaced, so a Personal
release that fixes this upstream turns the step into a no-op.

DOCKER MOUNTS THE IMAGE READ-ONLY. Podman mounts each SLC image with rw=true
(a throwaway overlay per container), so the two links are written into the
running database container. Docker has no writable image mount (the
launcher's dialect says so: writableImageMounts false), and `docker cp` into
it fails with "RemoveAll resolv.conf: read-only file system". On Docker the
links go into the IMAGE instead: a container is created from it (never
started), the links are copied into that container's own layer, and it is
committed back under the SAME tag the launcher mounts, with LABEL below. The
launcher only pulls an SLC image that is missing (podman_slc.go
materializeSLC), and keeps a tag it references (pruneUnreferencedSLCImages),
so the next start mounts the linked image and every start after it does too:
nothing to repair again until the tag is pulled anew. The official release
tarballs carry these two links already (exaslct's export,
_modify_extracted_container); the Docker Hub images the launcher mounts do
not, because Docker manages a container's /etc/resolv.conf and /etc/hosts.

  - After a start (FLAVOR...): a Docker database still showing the empty file
    gets its image linked, and "derived" says the database must start once
    more to see it. The caller restarts it.
  - --prepare STATE, before a start: every official SLC the launcher state
    file lists (installedSlcs, or only the FLAVORs named) is linked if its
    image is here and not linked yet, so the start that follows mounts it
    linked. An image not pulled yet is "absent": the launcher pulls it during
    the start, and the repair after the start links it - unless --pull
    pulls it first (the Java install, so its one restart is the only one).

The image is read through an image mount of itself (--mount type=image):
`docker cp` from a created container's own /etc shows Docker's empty
placeholders, never the image's files. Its etc/hostname is copied back with
the links, for the same reason: the commit would otherwise keep the
placeholder. The image this replaces is removed by id when nothing else holds
it; its layers stay, shared with the linked one.

The containers it creates are never started, carry PROBE_LABEL, and are
removed before it returns - also when it is stopped (SIGTERM). A run that was
killed outright leaves them behind, and the next Docker run removes them
first. --budget keeps the whole run inside the bound its caller puts on it.

Prints one "EXAKIT_SLC_DNS <flavor> repaired|derived|ok|absent|failed" line per
flavor (or "EXAKIT_SLC_DNS - nocontainer"). Exit 0 unless a repair failed.
"""

import argparse
import io
import json
import os
import signal
import subprocess
import sys
import tarfile
import time

LINKS = (("resolv.conf", "/conf/resolv.conf"), ("hosts", "/conf/hosts"))

# Where the launcher mounts an official SLC: /exa/slc/<flavor> (catalog.go
# targetDir).
SLC_ROOT = "/exa/slc/"

# The mark a linked image carries, so a start that finds it asks nothing more.
LABEL = "com.exasol.starter-kit.slc-dns"
LABEL_VALUE = "conf-links"

# Where a probe container sees its own image, untouched by Docker's /etc.
PROBE_MOUNT = "/exakit-slc"

# The label on the containers this helper creates (and never starts), so a
# run that was killed before it removed them has them removed by the next:
# LABEL's own key, valued "probe". A commit copies a container's labels into
# the image, and the writer's commit sets LABEL=LABEL_VALUE over it - so the
# linked image carries no probe mark, and a container someone else creates
# from it (LABEL=conf-links) is never taken for one of these.
PROBE_LABEL = LABEL + "=probe"

# THE RUN'S BUDGET (--budget seconds). The caller bounds this helper
# (exakit_run_bounded), and a kill skips the cleanup; so every engine call
# gets what is left of the budget, at most its own cap, and the helper ends
# - its containers removed - before the bound does. Removing a container,
# and the old image after a commit, is exempt and gets CLEANUP seconds; so is
# a --pull, whose time is added to the budget. None: no budget.
DEADLINE = None
CLEANUP = 20


def left(cap):
    """The timeout an engine call gets: its cap, or what is left of the budget."""
    if DEADLINE is None:
        return cap
    return max(0.0, min(cap, DEADLINE - time.monotonic()))


DB_PREFIX = "exasol-db-"


# What the launcher writes as the id when it cannot read its own state
# (internal/deploy/local_runtime.go): not a name any container carries.
NO_ID = ("", "local")


def clean_id(deployment_id):
    """The id as the launcher names the container by it (TrimSpace), or ""
    when it names none."""
    i = (deployment_id or "").strip()
    return "" if i in NO_ID else i


def pick(names, deployment_id=""):
    """The database container among the running containers' names, or "".

    WRITE ONLY INTO THIS DEPLOYMENT'S DATABASE. With the id known, only the
    launcher's own name, exasol-db-<id>: another exasol-db-* is another
    deployment (a second kit on a shared Docker Desktop, a second deployment
    folder, a stale container), and repairing it would report a repair this
    deployment never got. Without an id, an exasol-db-* that is not a sidecar
    only when it is the ONLY one: two are a choice nothing here can make."""
    i = clean_id(deployment_id)
    if i:
        return DB_PREFIX + i if DB_PREFIX + i in names else ""
    found = [n for n in names if n.startswith(DB_PREFIX) and "-sidecar-" not in n]
    return found[0] if len(found) == 1 else ""


def container(engine, deployment_id=""):
    out = subprocess.run([engine, "ps", "--format", "{{.Names}}"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=left(60))
    # Docker joins a container's several names with commas.
    names = out.stdout.decode("utf-8", "replace").replace(",", " ").split()
    return pick(names, deployment_id)


def classify(data):
    """(absent | ok | empty, etc/hostname member or None) of an etc/ tar."""
    if not data:
        return "absent", None
    found, hostname = "absent", None
    try:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive.getmembers():
                name = member.name.rstrip("/")
                if name.endswith("etc/resolv.conf"):
                    found = "ok" if member.issym() or member.size > 0 else "empty"
                elif name.endswith("etc/hostname") and member.isfile():
                    handle = archive.extractfile(member)
                    hostname = (member, handle.read() if handle else b"")
    except tarfile.TarError:
        return "absent", None
    return found, hostname


def state(engine, ctr, flavor):
    """absent | ok | empty: what etc/resolv.conf is in that container."""
    done = subprocess.run([engine, "cp", "%s:%s%s/etc" % (ctr, SLC_ROOT, flavor), "-"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=left(120))
    if done.returncode != 0:
        return "absent"
    return classify(done.stdout)[0]


def links_tar(hostname=None):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, target in LINKS:
            info = tarfile.TarInfo(name)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            info.mode = 0o777
            archive.addfile(info)
        if hostname is not None:
            member, content = hostname
            info = tarfile.TarInfo("hostname")
            info.size = len(content)
            info.mode = member.mode
            info.mtime = member.mtime
            archive.addfile(info, io.BytesIO(content))
    return buffer.getvalue()


def is_docker(engine):
    """Docker's CLI, named or by path (docker, docker.exe, /usr/bin/docker)."""
    return os.path.basename(engine).lower() in ("docker", "docker.exe")


def run(argv, timeout, data=None, own=False):
    """(returncode, stdout bytes) of an engine call; never raises for one.
    The timeout is left(timeout) unless own (a cleanup, a pull): see DEADLINE."""
    if not own:
        timeout = left(timeout)
        if timeout <= 0:
            return 1, b""
    try:
        done = subprocess.run(argv, input=data, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return 1, b""
    return done.returncode, done.stdout


def image_label(engine, ref):
    """The image's LABEL value, "" without one, None when there is no image."""
    code, out = run([engine, "image", "inspect", "--format",
                     "{{json .Id}} {{json .Config.Labels}}", "--", ref], 60)
    if code != 0 or not out.strip():
        return None, None
    ident, _, labels = out.decode("utf-8", "replace").strip().partition(" ")
    try:
        labels = json.loads(labels) or {}
        ident = json.loads(ident)
    except ValueError:
        return None, None
    return ident, (labels.get(LABEL, "") if isinstance(labels, dict) else "")


def read_etc(engine, ref):
    """classify() of the image's own etc/, read through an image mount of
    itself in a container that is created and never started."""
    probe = "exakit-slc-dns-%d-r" % os.getpid()
    try:
        if run([engine, "create", "--name", probe, "--label", PROBE_LABEL, "--network", "none",
                "--mount", "type=image,source=%s,target=%s" % (ref, PROBE_MOUNT), ref], 120)[0] != 0:
            return "failed", None
        return classify(run([engine, "cp", "%s:%s/etc" % (probe, PROBE_MOUNT), "-"], 120)[1])
    finally:
        run([engine, "rm", "-f", probe], CLEANUP, own=True)


def untagged(engine, ident):
    """True when no tag names the image any more."""
    code, out = run([engine, "image", "inspect", "--format", "{{json .RepoTags}}", "--", ident], CLEANUP, own=True)
    try:
        return code == 0 and not json.loads(out.decode("utf-8", "replace").strip() or "null")
    except ValueError:
        return False


def derive(engine, ref):
    """ok | derived | absent | failed: ref's own etc/resolv.conf and etc/hosts
    pointed at /conf, committed back under ref (Docker; see the top)."""
    ident, label = image_label(engine, ref)
    if ident is None:
        return "absent"
    if label == LABEL_VALUE:
        return "ok"
    found, hostname = read_etc(engine, ref)
    if found != "empty":
        return found
    # A second container, with no mount: the probe's mount point would be
    # committed with it as an empty directory at the image's root.
    writer = "exakit-slc-dns-%d-w" % os.getpid()
    committed = False
    try:
        if run([engine, "create", "--name", writer, "--label", PROBE_LABEL, "--network", "none",
                ref], 120)[0] != 0:
            return "failed"
        if run([engine, "cp", "-", "%s:/etc/" % writer], 120, links_tar(hostname))[0] != 0:
            return "failed"
        if run([engine, "commit", "--change", "LABEL %s=%s" % (LABEL, LABEL_VALUE), writer, ref], 600)[0] != 0:
            return "failed"
        committed = True
    finally:
        run([engine, "rm", "-f", writer], CLEANUP, own=True)
        # The image the tag named before, once the commit moved the tag - and
        # only when no other tag names it: `image rm <id>` deletes an image a
        # single remaining tag names (measured, Docker 29), so another tag on
        # it keeps it. Without -f, so a container that runs from it keeps it
        # too. Here, so a stop after the commit still removes it.
        if committed and untagged(engine, ident):
            run([engine, "image", "rm", ident], CLEANUP, own=True)
    if image_label(engine, ref)[1] != LABEL_VALUE:
        return "failed"
    return "derived"


def sweep(engine):
    """Remove the containers a killed run of this helper left behind: they
    carry PROBE_LABEL and were never started. Every Docker run starts here."""
    code, out = run([engine, "ps", "-a", "-q", "--filter", "label=" + PROBE_LABEL], 60)
    ids = out.decode("utf-8", "replace").split() if code == 0 else []
    if ids:
        run([engine, "rm", "-f"] + ids, CLEANUP, own=True)


def mounted_image(engine, ctr, flavor):
    """The image the database container mounts at /exa/slc/<flavor>."""
    code, out = run([engine, "inspect", "--format", "{{json .HostConfig.Mounts}}", ctr], 60)
    try:
        mounts = json.loads(out.decode("utf-8", "replace")) if code == 0 else None
    except ValueError:
        mounts = None
    for mount in mounts or []:
        if isinstance(mount, dict) and mount.get("Type") == "image" and \
                str(mount.get("Target", "")).rstrip("/") == SLC_ROOT + flavor:
            return str(mount.get("Source") or "")
    return ""


def installed_images(path, flavors):
    """(flavor, image) of every official SLC the launcher state file lists,
    or of the FLAVORs named."""
    try:
        with open(path, encoding="utf-8-sig") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        return []
    rows = doc.get("installedSlcs") if isinstance(doc, dict) else None
    found = []
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict):
            continue
        flavor, image = row.get("flavor"), row.get("image")
        if isinstance(flavor, str) and flavor and isinstance(image, str) and image \
                and (not flavors or flavor in flavors):
            found.append((flavor, image))
    return found


def prepare(engine, path, flavors, pull=False):
    """Link every installed official SLC image before a start (Docker only:
    Podman's writable mount is repaired after the start). With pull, an image
    that is not here yet is pulled first - the pull the start would make."""
    global DEADLINE
    failed = False
    if not is_docker(engine):
        return 0
    sweep(engine)
    images = installed_images(path, flavors)
    if not images:
        # Said, so a caller tells "nothing installed" from "did not run".
        print("EXAKIT_SLC_DNS - none")
        return 0
    for flavor, image in images:
        if pull and image_label(engine, image)[0] is None:
            began = time.monotonic()
            run([engine, "pull", "--quiet", image], 1800, own=True)
            if DEADLINE is not None:
                DEADLINE += time.monotonic() - began
        result = derive(engine, image)
        print("EXAKIT_SLC_DNS %s %s" % (flavor, result))
        failed = failed or result == "failed"
    return 1 if failed else 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="personal-slc-dns.py")
    # --podman: the option's name before Docker deployments; kept as an alias.
    parser.add_argument("--engine", "--podman", dest="engine", default="podman")
    parser.add_argument("--deployment-id", default="")
    parser.add_argument("--prepare", metavar="STATE", default="")
    parser.add_argument("--pull", action="store_true")
    parser.add_argument("--budget", type=float, default=None)
    parser.add_argument("flavors", nargs="*")
    args = parser.parse_args(argv)
    global DEADLINE
    if args.budget is not None:
        DEADLINE = time.monotonic() + max(args.budget, 0.0)
    # A stop (the runner's SIGTERM) raises SystemExit here: the finally blocks
    # run, and the containers this run created are removed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    if args.prepare:
        return prepare(args.engine, args.prepare, args.flavors, args.pull)
    if not args.flavors:
        parser.error("name at least one FLAVOR")
    try:
        ctr = container(args.engine, args.deployment_id)
    except (OSError, subprocess.SubprocessError):
        ctr = ""
    if not ctr:
        print("EXAKIT_SLC_DNS - nocontainer")
        return 0
    if is_docker(args.engine):
        sweep(args.engine)
    failed = False
    for flavor in args.flavors:
        try:
            found = state(args.engine, ctr, flavor)
            if found != "empty":
                print("EXAKIT_SLC_DNS %s %s" % (flavor, found))
                continue
            if is_docker(args.engine):
                # Read-only on Docker: link the image, and the next start
                # mounts it. "ok" here is an image linked already that this
                # database started before it was: the same restart.
                ref = mounted_image(args.engine, ctr, flavor)
                result = derive(args.engine, ref) if ref else "failed"
                result = "derived" if result in ("ok", "derived") else "failed"
                print("EXAKIT_SLC_DNS %s %s" % (flavor, result))
                failed = failed or result == "failed"
                continue
            done = subprocess.run([args.engine, "cp", "-", "%s:%s%s/etc/" % (ctr, SLC_ROOT, flavor)],
                                  input=links_tar(), stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=left(120))
            ok = done.returncode == 0 and state(args.engine, ctr, flavor) == "ok"
        except (OSError, subprocess.SubprocessError):
            ok = False
        print("EXAKIT_SLC_DNS %s %s" % (flavor, "repaired" if ok else "failed"))
        failed = failed or not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
