"""Give Exasol Personal's language containers the deployment's DNS.

    personal-slc-dns.py [--engine CLI] [--deployment-id ID] FLAVOR [FLAVOR ...]

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
podman_install.go ContainerName); a sidecar is exasol-db-<id>-sidecar-<name>,
so the first exasol-db-* name is not necessarily the database. See pick().

Only a file that is still the shipped EMPTY one is replaced, so a Personal
release that fixes this upstream turns the step into a no-op.

Prints one "EXAKIT_SLC_DNS <flavor> repaired|ok|absent|failed" line per flavor
(or "EXAKIT_SLC_DNS - nocontainer"). Exit 0 unless a repair failed.
"""

import argparse
import io
import subprocess
import sys
import tarfile

LINKS = (("resolv.conf", "/conf/resolv.conf"), ("hosts", "/conf/hosts"))


DB_PREFIX = "exasol-db-"


def carries(name, deployment_id):
    """The name IS the deployment's id, or carries it as a whole leading or
    trailing segment - the kit's own rule for "this deployment's container"
    (_personal_names_carry_id in runtime-personal.sh). Never a substring."""
    i = deployment_id
    if name == i:
        return True
    if len(name) <= len(i):
        return False
    return name.startswith((i + "-", i + "_")) or name.endswith(("-" + i, "_" + i))


def pick(names, deployment_id=""):
    """The database container among the running containers' names: the
    launcher's own name for this deployment (exasol-db-<id>), else a name
    carrying the id as the kit matches it, else - the id unknown or nothing
    carrying it - the first exasol-db-* that is not a sidecar, as before."""
    exact = carry = first = ""
    for name in names:
        if deployment_id and not exact and name == DB_PREFIX + deployment_id:
            exact = name
        if deployment_id and not carry and carries(name, deployment_id):
            carry = name
        if not first and name.startswith(DB_PREFIX) and "-sidecar-" not in name:
            first = name
    return exact or carry or first


def container(engine, deployment_id=""):
    out = subprocess.run([engine, "ps", "--format", "{{.Names}}"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
    # Docker joins a container's several names with commas.
    names = out.stdout.decode("utf-8", "replace").replace(",", " ").split()
    return pick(names, deployment_id)


def state(engine, ctr, flavor):
    """absent | ok | empty: what etc/resolv.conf is in that container."""
    done = subprocess.run([engine, "cp", "%s:/exa/slc/%s/etc" % (ctr, flavor), "-"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
    if done.returncode != 0 or not done.stdout:
        return "absent"
    try:
        with tarfile.open(fileobj=io.BytesIO(done.stdout)) as archive:
            for member in archive.getmembers():
                if member.name.rstrip("/").endswith("etc/resolv.conf"):
                    if member.issym() or member.size > 0:
                        return "ok"
                    return "empty"
    except tarfile.TarError:
        return "absent"
    return "absent"


def links_tar():
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, target in LINKS:
            info = tarfile.TarInfo(name)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            info.mode = 0o777
            archive.addfile(info)
    return buffer.getvalue()


def main(argv=None):
    parser = argparse.ArgumentParser(prog="personal-slc-dns.py")
    # --podman: the option's name before Docker deployments; kept as an alias.
    parser.add_argument("--engine", "--podman", dest="engine", default="podman")
    parser.add_argument("--deployment-id", default="")
    parser.add_argument("flavors", nargs="+")
    args = parser.parse_args(argv)
    try:
        ctr = container(args.engine, args.deployment_id.strip())
    except (OSError, subprocess.SubprocessError):
        ctr = ""
    if not ctr:
        print("EXAKIT_SLC_DNS - nocontainer")
        return 0
    failed = False
    for flavor in args.flavors:
        try:
            found = state(args.engine, ctr, flavor)
            if found != "empty":
                print("EXAKIT_SLC_DNS %s %s" % (flavor, found))
                continue
            done = subprocess.run([args.engine, "cp", "-", "%s:/exa/slc/%s/etc/" % (ctr, flavor)],
                                  input=links_tar(), stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=120)
            ok = done.returncode == 0 and state(args.engine, ctr, flavor) == "ok"
        except (OSError, subprocess.SubprocessError):
            ok = False
        print("EXAKIT_SLC_DNS %s %s" % (flavor, "repaired" if ok else "failed"))
        failed = failed or not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
