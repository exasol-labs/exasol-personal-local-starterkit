#!/usr/bin/env bash
# Language container DNS on Exasol Personal: the official script language
# containers ship etc/resolv.conf and etc/hosts EMPTY, so Java in the database
# (every virtual schema adapter) resolves no hostname. The kit points them at
# /conf after every database start, because every start rebuilds them.
#
# A stand-in engine CLI - the same script installed as `podman` and `docker` -
# keeps each container's etc/ as a real tar stream, so both routes are
# exercised byte for byte: the Python helper (Linux, WSL, Windows) and the
# POSIX sh script fed to the launcher VM's shell (macOS). Every call it gets is
# logged, so a test can say WHICH engine was asked and WHICH container.
#
# Docker mounts a language container image READ-ONLY, so there the stand-in
# refuses a copy into the database container, as Docker does, and keeps its
# images as folders too: the helper links the IMAGE (create, copy, commit under
# the same tag, labelled) and the database sees it from its next start, which
# a test plays by copying the image's etc/ over the container's.
#
# What it pins beyond the repair itself:
#   - the deployment's recorded engine is the one asked: a Docker deployment
#     (kit 0.2.4+) is invisible to Podman's CLI, and Podman stays the answer
#     when the record names none;
#   - the database container is exasol-db-<deployment id> (the launcher's own
#     name on both engines) and nothing else: not a sidecar
#     exasol-db-<id>-sidecar-<name>, not another deployment's exasol-db-*, not
#     a name that merely contains the id. Without an id (or the launcher's
#     "local"), a lone exasol-db-* that is not a sidecar; two are nocontainer;
#   - the id is read the way the launcher names the container: its own state
#     file first, trimmed, the top-level key only.
#
#   bash tests/personal-slc-dns.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Fake engine CLI: `ps --format {{.Names}}` prints FAKE_PS (space-separated,
# one name per line; a comma is kept, as Docker joins a container's names)
# unless FAKE_NO_CTR=1; `cp CTR:/exa/slc/F/etc -` streams $WORK/ctr/F/etc as
# tar; `cp - CTR:/exa/slc/F/etc/` extracts stdin there - as podman; as docker
# it fails, the image mount being read-only. Docker's images are folders under
# $WORK/img (etc/, id, labels.json), the database mounting docker.io/exa/slc:F
# at /exa/slc/F; `create`, `cp` in and out of a created container (its own
# /etc, or an image mounted at a target), `commit --change LABEL`, `rm`,
# `image inspect`, `image rm`, `inspect` (the mounts) and `pull` (from
# $WORK/registry) work on them. FAKE_COMMIT_FAILS=1 fails a commit,
# FAKE_COMMIT_SLEEP=N makes it take N seconds. A created container keeps its
# --label, and `ps -a -q --filter label=K` lists the ones that carry K. Each
# call appends "<cli> <verb> <container or image>" to $WORK/calls.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/podman" <<EOF
#!/usr/bin/env python3
import io, json, os, shutil, sys, tarfile, time
W = "$WORK"
root = W + "/ctr"
cli = os.path.basename(sys.argv[0])
a = sys.argv[1:]
def log(ctr):
    with open(W + "/calls", "a") as f: f.write("%s %s %s\n" % (cli, a[0], ctr))
def key(ref): return ref.replace("/", "_").replace(":", "_")
def img(ref): return os.path.join(W, "img", key(ref))
def cont(name): return os.path.join(W, "cont", name)
def put(tar_bytes, dest):
    os.makedirs(dest, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as t:
        for m in t.getmembers():
            path = os.path.join(dest, m.name)
            if os.path.lexists(path): os.remove(path)
            if m.issym(): os.symlink(m.linkname, path)
            else:
                with open(path, "wb") as f: f.write(t.extractfile(m).read())
def stream(path):
    if not os.path.isdir(path): sys.exit(1)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as t: t.add(path, arcname="etc")
    sys.exit(0)
if a[:3] == ["ps", "-a", "-q"] and cli == "docker":
    log("-a")
    want = a[a.index("--filter") + 1].split("=", 1)[1]
    for name in sorted(os.listdir(W + "/cont")) if os.path.isdir(W + "/cont") else []:
        lf = os.path.join(cont(name), "label")
        if os.path.exists(lf) and open(lf).read() == want: print(name)
    sys.exit(0)
if a[0] == "ps":
    log("-")
    if a[1:] != ["--format", "{{.Names}}"]: sys.exit(3)
    print("" if os.environ.get("FAKE_NO_CTR") == "1" else "\n".join(os.environ.get("FAKE_PS", "exasol-db-test").split()))
    sys.exit(0)
if a[0] == "cp" and a[2] == "-" and "/exa/slc/" in a[1]:
    log(a[1].split(":")[0])
    stream(os.path.join(root, a[1].split("/exa/slc/")[1].split("/")[0], "etc"))
if a[0] == "cp" and a[1] == "-" and "/exa/slc/" in a[2]:
    log(a[2].split(":")[0])
    with open(W + "/writes", "a") as f: f.write(a[2].split(":")[0] + "\n")
    if cli == "docker" or os.environ.get("FAKE_CP_FAILS") == "1": sys.exit(1)
    flavor = a[2].split("/exa/slc/")[1].split("/")[0]
    put(sys.stdin.buffer.read(), os.path.join(root, flavor, "etc"))
    sys.exit(0)
if cli != "docker": sys.exit(2)
if a[0] == "inspect":
    log(a[-1])
    mounts = [{"Type": "bind", "Source": "/data", "Target": "/exa"}]
    for flavor in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        mounts.append({"Type": "image", "Source": "docker.io/exa/slc:" + flavor, "Target": "/exa/slc/" + flavor})
    print(json.dumps(mounts)); sys.exit(0)
def tags(ident):
    """The image keys whose id is ident; None when no image has it."""
    found = [k for k in (os.listdir(W + "/img") if os.path.isdir(W + "/img") else [])
             if open(os.path.join(W, "img", k, "id")).read() == ident]
    return found if found or os.path.isdir(os.path.join(W, "dangling", ident)) else None
if a[:2] == ["image", "inspect"] and a[-1].startswith("sha256:"):
    log(a[-1])
    t = tags(a[-1])
    if t is None: sys.exit(1)
    print(json.dumps(t)); sys.exit(0)
if a[:2] == ["image", "inspect"]:
    log(a[-1])
    if not os.path.isdir(img(a[-1])): sys.exit(1)
    print('"%s" %s' % (open(img(a[-1]) + "/id").read(), open(img(a[-1]) + "/labels.json").read())); sys.exit(0)
if a[:2] == ["image", "rm"]:
    with open(W + "/calls", "a") as f: f.write("docker rmi %s\n" % a[2])
    shutil.rmtree(os.path.join(W, "dangling", a[2]), ignore_errors=True); sys.exit(0)
if a[0] == "pull":
    log(a[-1])
    src = os.path.join(W, "registry", key(a[-1]))
    if not os.path.isdir(src): sys.exit(1)
    shutil.copytree(src, img(a[-1]), symlinks=True); sys.exit(0)
if a[0] == "create":
    ref = a[-1]; name = a[a.index("--name") + 1]
    log(ref)
    if not os.path.isdir(img(ref)): sys.exit(1)
    os.makedirs(cont(name) + "/etc")
    open(cont(name) + "/ref", "w").write(ref)
    if "--label" in a: open(cont(name) + "/label", "w").write(a[a.index("--label") + 1])
    with open(W + "/creates", "a") as f: f.write("%s %s\n" % (name.rsplit("-", 1)[1], "mount" if "--mount" in a else "nomount"))
    if "--mount" in a:
        spec = dict(x.split("=", 1) for x in a[a.index("--mount") + 1].split(","))
        open(cont(name) + "/mount", "w").write(spec["target"] + " " + spec["source"])
    sys.exit(0)
if a[0] == "cp" and a[2] == "-":
    name, path = a[1].split(":", 1)
    log(name)
    target, source = open(cont(name) + "/mount").read().split()
    if path != target + "/etc": sys.exit(1)
    stream(img(source) + "/etc")
if a[0] == "cp" and a[1] == "-":
    name, path = a[2].split(":", 1)
    log(name)
    if path != "/etc/": sys.exit(1)
    put(sys.stdin.buffer.read(), cont(name) + "/etc"); sys.exit(0)
if a[0] == "commit":
    name, ref = a[-2], a[-1]
    log(ref)
    if os.environ.get("FAKE_COMMIT_FAILS") == "1": sys.exit(1)
    time.sleep(float(os.environ.get("FAKE_COMMIT_SLEEP", "0")))
    base = open(cont(name) + "/ref").read()
    new = os.path.join(W, "img-new")
    shutil.copytree(img(base), new, symlinks=True)
    for n in os.listdir(cont(name) + "/etc"):
        dest = os.path.join(new, "etc", n)
        if os.path.lexists(dest): os.remove(dest)
        shutil.move(os.path.join(cont(name), "etc", n), dest)
    labels = json.load(open(new + "/labels.json"))
    k, v = a[a.index("--change") + 1].split(" ", 1)[1].split("=", 1)
    labels[k] = v
    json.dump(labels, open(new + "/labels.json", "w"))
    old = open(img(ref) + "/id").read()
    open(new + "/id", "w").write(old + "d")
    shutil.move(img(ref), os.path.join(W, "img-old"))
    shutil.move(new, img(ref))
    # The image the tag named before: dangling, unless another tag names it.
    if tags(old) is None or not tags(old):
        os.makedirs(W + "/dangling", exist_ok=True)
        shutil.move(os.path.join(W, "img-old"), os.path.join(W, "dangling", old))
    shutil.rmtree(os.path.join(W, "img-old"), ignore_errors=True)
    sys.exit(0)
if a[0] == "rm":
    for name in [x for x in a[1:] if x != "-f"]:
        log(name); shutil.rmtree(cont(name), ignore_errors=True)
    sys.exit(0)
sys.exit(2)
EOF
chmod +x "$WORK/bin/podman"
cp "$WORK/bin/podman" "$WORK/bin/docker"
ctr() { rm -rf "$WORK/ctr" "$WORK/img" "$WORK/cont" "$WORK/registry" "$WORK/dangling"; mkdir -p "$WORK/ctr/java-17/etc" "$WORK/ctr/python-3.12/etc" "$WORK/cont"; : > "$WORK/ctr/java-17/etc/resolv.conf"; : > "$WORK/ctr/java-17/etc/hosts"; printf 'nameserver 9.9.9.9\n' > "$WORK/ctr/python-3.12/etc/resolv.conf"; mkimg java-17 img; mkimg python-3.12 img; printf 'nameserver 9.9.9.9\n' > "$WORK/img/docker.io_exa_slc_python-3.12/etc/resolv.conf"; : > "$WORK/calls"; : > "$WORK/writes"; : > "$WORK/creates"; }
# mkimg <flavor> <img|registry> - docker.io/exa/slc:<flavor>, as shipped: the
# two files empty, a hostname, no label.
mkimg() { _d="$WORK/$2/docker.io_exa_slc_$1"; rm -rf "$_d"; mkdir -p "$_d/etc"; : > "$_d/etc/resolv.conf"; : > "$_d/etc/hosts"; printf 'build-host\n' > "$_d/etc/hostname"; printf 'sha256:%s' "$1" > "$_d/id"; printf '{"org.opencontainers.image.version": "22.04"}' > "$_d/labels.json"; }
# restart <flavor> - the database starts again and mounts the image's etc/.
restart() { rm -rf "$WORK/ctr/$1/etc"; cp -RP "$WORK/img/docker.io_exa_slc_$1/etc" "$WORK/ctr/$1/etc"; : > "$WORK/calls"; }
ilink() { readlink "$WORK/img/docker.io_exa_slc_$1/etc/$2" 2>/dev/null || echo "regular"; }
ilabel() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("com.exasol.starter-kit.slc-dns", "none"))' "$WORK/img/docker.io_exa_slc_$1/labels.json"; }
verbs() { awk '{ print $1 "-" $2 }' "$WORK/calls" | tr '\n' ' ' | sed 's/ $//'; }
link() { readlink "$WORK/ctr/$1/etc/$2" 2>/dev/null || echo "regular"; }
# The engines asked, and the containers copied from or to, since the last ctr.
clis() { cut -d' ' -f1 "$WORK/calls" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
target() { awk '$2 == "cp" { print $3 }' "$WORK/calls" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# ...of them, the database's (not docker's own short-lived containers).
dbtarget() { awk '$2 == "cp" && $3 !~ /^exakit-slc-dns-/ { print $3 }' "$WORK/calls" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
HELPER="$ROOT/setup/lib/personal-slc-dns.py"
helper() { PATH="$WORK/bin:$PATH" python3 "$HELPER" "$@"; }
# A 2.4 deployment with a sidecar, listed first because it is the newer
# container, and another deployment's database.
ID=exa-7f3a
PS_24="exasol-db-$ID-sidecar-minio exasol-db-other exasol-db-$ID"

printf '\n== the Python helper (Linux, WSL, Windows) ==\n'
ctr
OUT="$(helper java-17 python-3.12 r-4.4)"; RC=$?
check "an empty resolv.conf is repaired" "EXAKIT_SLC_DNS java-17 repaired" "$(printf '%s\n' "$OUT" | grep java-17)"
check "...both files now point at /conf" "/conf/resolv.conf /conf/hosts" "$(link java-17 resolv.conf) $(link java-17 hosts)"
check "a container that already has DNS is left alone" "EXAKIT_SLC_DNS python-3.12 ok regular" "$(printf '%s\n' "$OUT" | grep python) $(link python-3.12 resolv.conf)"
check "a flavor that is not there is absent, not an error" "EXAKIT_SLC_DNS r-4.4 absent" "$(printf '%s\n' "$OUT" | grep r-4.4)"
check "...exit 0" "0" "$RC"
check "...no engine named: Podman, as before Docker deployments" "podman" "$(clis)"
OUT="$(helper java-17)"
check "a second run changes nothing" "EXAKIT_SLC_DNS java-17 ok" "$OUT"
ctr; OUT="$(FAKE_CP_FAILS=1 helper java-17)"; RC=$?
check "a copy that fails is reported, exit 1" "EXAKIT_SLC_DNS java-17 failed 1" "$OUT $RC"
OUT="$(FAKE_NO_CTR=1 helper java-17)"
check "no database container: said, not guessed" "EXAKIT_SLC_DNS - nocontainer" "$OUT"

printf '\n== the helper on the deployment engine ==\n'
ctr; OUT="$(helper --engine docker java-17)"
check "--engine docker links the image (read-only mount): derived" "EXAKIT_SLC_DNS java-17 derived" "$OUT"
check "...and never asks podman" "docker" "$(clis)"
ctr; helper --engine podman java-17 >/dev/null
check "--engine podman: podman only" "podman" "$(clis)"
ctr; OUT="$(helper --podman docker java-17)"
check "--podman, the old spelling, still names the CLI" "EXAKIT_SLC_DNS java-17 derived docker" "$OUT $(clis)"

printf '\n== which container is the database ==\n'
ctr; OUT="$(FAKE_PS="$PS_24" helper --deployment-id "$ID" java-17)"
check "2.4: exasol-db-<id>, past a sidecar listed first and another deployment" "exasol-db-$ID" "$(target)"
check "...repaired there" "EXAKIT_SLC_DNS java-17 repaired" "$OUT"
ctr; FAKE_PS="$PS_24" helper --engine docker --deployment-id "$ID" java-17 >/dev/null
check "...on docker, read from that container and its mount inspected" "exasol-db-$ID exasol-db-$ID" "$(dbtarget) $(awk '$2 == "inspect" { print $3 }' "$WORK/calls")"
ctr; FAKE_PS="$PS_24" helper --deployment-id "$ID" java-17 >/dev/null
check "...the same on podman" "exasol-db-$ID podman" "$(target) $(clis)"
ctr; FAKE_PS="$PS_24" helper "--deployment-id= $ID " java-17 >/dev/null
check "the id trimmed as the launcher trims it (TrimSpace)" "exasol-db-$ID" "$(target)"
ctr; OUT="$(FAKE_PS="exasol-db--x7" helper --deployment-id=-x7 java-17)"
check "an id starting with - is a value in the = form" "exasol-db--x7" "$(target)"
# Never another deployment's database: the id known, only its own name.
ctr; OUT="$(FAKE_PS="exasol-db-ffff0000" helper --engine docker --deployment-id 1a2b3c4d java-17)"
check "id known, only another deployment's exasol-db-* runs: nocontainer" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
check "...nothing copied in or out of it, the file untouched" " regular" "$(target) $(link java-17 resolv.conf)"
ctr; OUT="$(FAKE_PS="exasol-db-test" helper --deployment-id "$ID" java-17)"
check "...an old-named exasol-db-* that is not this id: nocontainer" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
for _n in "$ID-app" "$ID-db-1" "x-$ID" "xexasol-db-$ID" "exasol-db-$ID-sidecar-$ID" "$ID"; do
    ctr; OUT="$(FAKE_PS="$_n" helper --deployment-id "$ID" java-17)"
    check "a name that merely contains the id is not the database: $_n" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
done
# Without an id: a lone exasol-db-* that is not a sidecar, or nothing.
ctr; FAKE_PS="exasol-db-abc-sidecar-minio exasol-db-abc" helper java-17 >/dev/null
check "no id: the lone exasol-db-*, never a sidecar" "exasol-db-abc" "$(target)"
ctr; OUT="$(FAKE_PS="exasol-db-abc exasol-db-def" helper java-17)"
check "no id, two exasol-db-*: nocontainer, not the first" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
ctr; OUT="$(FAKE_PS="x-local" helper --deployment-id local java-17)"
check "the launcher's \"local\" is no id: x-local is not taken" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
ctr; FAKE_PS="exasol-db-abc" helper --deployment-id local java-17 >/dev/null
check "...and a lone exasol-db-* is" "exasol-db-abc" "$(target)"
ctr; FAKE_PS="exasol-db-abc" helper "--deployment-id=   " java-17 >/dev/null
check "a blank id is no id" "exasol-db-abc" "$(target)"
ctr; FAKE_PS="legacy,exasol-db-$ID" helper --engine docker --deployment-id "$ID" java-17 >/dev/null
check "Docker's comma-joined names are split" "exasol-db-$ID" "$(dbtarget)"
ctr; OUT="$(FAKE_PS="exasol-db-$ID-sidecar-minio" helper --deployment-id "$ID" java-17)"
check "only a sidecar runs: no database container" "EXAKIT_SLC_DNS - nocontainer" "$OUT"

printf '\n== Docker: the image is linked, not the read-only mount ==\n'
IMG_J="$WORK/img/docker.io_exa_slc_java-17"
ctr; OUT="$(FAKE_PS="$PS_24" helper --engine docker --deployment-id "$ID" java-17 python-3.12)"; RC=$?
check "an empty file under Docker: derived, exit 0" "EXAKIT_SLC_DNS java-17 derived|EXAKIT_SLC_DNS python-3.12 ok|0" "$(printf '%s\n' "$OUT" | tr '\n' '|')$RC"
check "...the image's two files point at /conf" "/conf/resolv.conf /conf/hosts" "$(ilink java-17 resolv.conf) $(ilink java-17 hosts)"
check "...its hostname kept, not Docker's empty placeholder" "build-host" "$(cat "$IMG_J/etc/hostname")"
check "...committed under the tag the database mounts, labelled" "conf-links" "$(ilabel java-17)"
check "...the image it replaced removed by id, once no tag names it" "1 0" "$(grep -c '^docker rmi sha256:java-17$' "$WORK/calls") $(ls "$WORK/dangling" 2>/dev/null | wc -l | tr -d ' ')"
check "...the read-only mount never written to" "" "$(cat "$WORK/writes")"
check "...the database container itself unchanged until it starts again" "regular" "$(link java-17 resolv.conf)"
check "...no container left behind" "0" "$(ls "$WORK/cont" | wc -l | tr -d ' ')"
check "...the image read through a mount of itself, linked in a container without one" \
    "docker-create docker-cp docker-rm docker-create docker-cp docker-commit docker-rm" \
    "$(awk '$2 == "create" || $2 == "commit" || ($2 == "cp" && $3 ~ /^exakit-slc-dns-/) || ($2 == "rm" && $3 ~ /^exakit-slc-dns-/) { print $1 "-" $2 }' "$WORK/calls" | tr '\n' ' ' | sed 's/ $//')"
check "...the reading container has the mount, the writing one none" "r mount|w nomount|" "$(tr '\n' '|' < "$WORK/creates")"
: > "$WORK/calls"; OUT="$(FAKE_PS="$PS_24" helper --engine docker --deployment-id "$ID" java-17)"
check "the database still started before the link: derived again (a restart), no second commit" "EXAKIT_SLC_DNS java-17 derived 0" "$OUT $(grep -c ' commit ' "$WORK/calls")"
restart java-17; OUT="$(FAKE_PS="$PS_24" helper --engine docker --deployment-id "$ID" java-17)"
check "after a start that mounts it: ok, nothing created (the listing, the sweep's listing, the read)" "EXAKIT_SLC_DNS java-17 ok docker-ps docker-ps docker-cp" "$OUT $(verbs)"
ctr; OUT="$(FAKE_COMMIT_FAILS=1 FAKE_PS="$PS_24" helper --engine docker --deployment-id "$ID" java-17)"; RC=$?
check "a commit that fails: failed, exit 1, no container left" "EXAKIT_SLC_DNS java-17 failed 1 0" "$OUT $RC $(ls "$WORK/cont" | wc -l | tr -d ' ')"
check "...the image untouched" "regular none" "$(ilink java-17 resolv.conf) $(ilabel java-17)"
ctr; rm -rf "$IMG_J"; OUT="$(FAKE_PS="$PS_24" helper --engine docker --deployment-id "$ID" java-17)"; RC=$?
check "the mounted image gone: failed, exit 1" "EXAKIT_SLC_DNS java-17 failed 1" "$OUT $RC"

printf '\n== Docker: a stopped or killed run leaves no container ==\n'
# The runner's SIGTERM used to skip Python's finally: rc 143, the writer left
# in Created, and the image it replaced never removed. Stopped mid-commit here.
ctr; FAKE_COMMIT_SLEEP=30 FAKE_PS="exasol-db-$ID" PATH="$WORK/bin:$PATH" python3 "$HELPER" --engine docker --deployment-id "$ID" java-17 > "$WORK/term.out" 2>&1 &
_hp=$!
_n=0; until grep -q ' commit ' "$WORK/calls" 2>/dev/null || [ "$_n" -ge 100 ]; do sleep 0.1; _n=$((_n + 1)); done
check "...(the run reached its commit)" "1" "$(grep -c ' commit ' "$WORK/calls")"
_t0="$(date +%s)"; kill -TERM "$_hp"; wait "$_hp"; RC=$?
check "SIGTERM during the commit: exit 143, at once" "143 yes" "$RC $([ $(( $(date +%s) - _t0 )) -lt 10 ] && echo yes || echo no)"
check "...no container left behind" "0" "$(ls "$WORK/cont" | wc -l | tr -d ' ')"
check "...both removed by name" "exakit-slc-dns-$_hp-r exakit-slc-dns-$_hp-w" "$(awk '$2 == "rm" { print $3 }' "$WORK/calls" | tr '\n' ' ' | sed 's/ $//')"
check "...the image untouched: not committed, not removed" "regular none 0" "$(ilink java-17 resolv.conf) $(ilabel java-17) $(grep -c ' rmi ' "$WORK/calls")"
# A run killed outright (SIGKILL: no finally) leaves its containers; the next
# Docker run removes every one that carries the label, and nothing else.
ctr; mkdir -p "$WORK/cont/exakit-slc-dns-4242-w" "$WORK/cont/someone-else" "$WORK/cont/from-linked"
printf 'com.exasol.starter-kit.slc-dns=probe' > "$WORK/cont/exakit-slc-dns-4242-w/label"
printf 'com.example.other=1' > "$WORK/cont/someone-else/label"
# A container someone created from a linked image inherits its label, valued
# conf-links: not one of these.
printf 'com.exasol.starter-kit.slc-dns=conf-links' > "$WORK/cont/from-linked/label"
OUT="$(FAKE_PS="exasol-db-$ID" helper --engine docker --deployment-id "$ID" java-17)"
check "a killed run's labelled container is removed by the next run, nothing else" "EXAKIT_SLC_DNS java-17 derived from-linked someone-else" "$OUT $(ls "$WORK/cont" | tr '\n' ' ' | sed 's/ $//')"
check "...listed by the label, before anything is created" "docker-ps docker-ps docker-rm" "$(verbs | cut -d' ' -f1-3)"
ctr; mkdir -p "$WORK/cont/exakit-slc-dns-4242-r"; printf 'com.exasol.starter-kit.slc-dns=probe' > "$WORK/cont/exakit-slc-dns-4242-r/label"
OUT="$(helper --engine docker --prepare "$WORK/state.json" java-17 2>/dev/null; ls "$WORK/cont" | wc -l | tr -d ' ')"
check "...the same before a start (--prepare)" "0" "$(printf '%s\n' "$OUT" | tail -1)"
# The image the tag named before is removed only when no tag names it: by id,
# Docker deletes an image its one remaining tag names (measured on Docker 29,
# where it took the official tag a test tag shared).
ctr; cp -R "$WORK/img/docker.io_exa_slc_java-17" "$WORK/img/other_tag"
OUT="$(FAKE_PS="exasol-db-$ID" helper --engine docker --deployment-id "$ID" java-17)"
check "the replaced image still named by another tag: kept" "EXAKIT_SLC_DNS java-17 derived 0 regular" \
    "$OUT $(grep -c ' rmi ' "$WORK/calls") $(readlink "$WORK/img/other_tag/etc/resolv.conf" 2>/dev/null || echo regular)"
# THE BUDGET keeps the run inside the bound its caller puts on it: a commit
# that would take 30 s gets what is left of 2, fails, and still cleans up.
ctr; _t0="$(date +%s)"
OUT="$(FAKE_COMMIT_SLEEP=30 FAKE_PS="exasol-db-$ID" helper --engine docker --deployment-id "$ID" --budget 2 java-17)"; RC=$?
check "--budget 2, a 30 s commit: failed, exit 1, within the budget" "EXAKIT_SLC_DNS java-17 failed 1 yes" "$OUT $RC $([ $(( $(date +%s) - _t0 )) -lt 8 ] && echo yes || echo no)"
check "...its containers still removed" "0" "$(ls "$WORK/cont" | wc -l | tr -d ' ')"
check "...the bounds the shells put on it cover the budgets they give it" "1 1 1 1" \
    "$(grep -c -F '_psdp_out="$(exakit_run_bounded 300 "${_EXAKIT_PY_ANY[@]}"' "$ROOT/setup/lib/runtime-personal.sh") $(grep -c -F -- '--engine docker --prepare "$_psdp_state" --budget 240 2>&1)"' "$ROOT/setup/lib/runtime-personal.sh") $(grep -c -F -- '--budget $((_psdr_bound - 60))' "$ROOT/setup/lib/runtime-personal.sh") $(grep -c -F '[ "$_psdr_engine" = docker ] && _psdr_bound=300' "$ROOT/setup/lib/runtime-personal.sh")"

printf '\n== Docker, before a start: --prepare ==\n'
STATE="$WORK/state.json"
printf '{"deploymentId": "%s", "installedSlcs": [{"language": "java", "flavor": "java-17", "image": "docker.io/exa/slc:java-17"}, {"flavor": "python-3.12", "image": "docker.io/exa/slc:python-3.12"}]}\n' "$ID" > "$STATE"
ctr; OUT="$(helper --engine docker --prepare "$STATE")"; RC=$?
check "every SLC the launcher state lists: java linked, python already had DNS" "EXAKIT_SLC_DNS java-17 derived|EXAKIT_SLC_DNS python-3.12 ok|0" "$(printf '%s\n' "$OUT" | tr '\n' '|')$RC"
check "...without a database container (nothing listed, nothing read)" "0" "$(grep -c ' ps -$' "$WORK/calls")"
check "...python, with DNS of its own, is not committed" "1" "$(grep -c ' commit ' "$WORK/calls")"
: > "$WORK/calls"; OUT="$(helper --engine docker --prepare "$STATE" java-17)"
check "a linked image: ok from its label - the sweep's listing, one inspect, nothing else" "EXAKIT_SLC_DNS java-17 ok docker-ps docker-image" "$OUT $(verbs)"
ctr; rm -rf "$IMG_J"; OUT="$(helper --engine docker --prepare "$STATE" java-17)"
check "an image not pulled yet: absent (the start pulls it), nothing pulled" "EXAKIT_SLC_DNS java-17 absent 0" "$OUT $(grep -c ' pull ' "$WORK/calls")"
ctr; rm -rf "$IMG_J"; mkimg java-17 registry; OUT="$(helper --engine docker --prepare "$STATE" --pull java-17)"
check "--pull: pulled, then linked" "EXAKIT_SLC_DNS java-17 derived 1 conf-links" "$OUT $(grep -c ' pull docker.io/exa/slc:java-17$' "$WORK/calls") $(ilabel java-17)"
ctr; : > "$WORK/calls"; OUT="$(helper --engine docker --prepare "$STATE" --pull java-17)"
check "...an image that is here is not pulled again" "EXAKIT_SLC_DNS java-17 derived 0" "$OUT $(grep -c ' pull ' "$WORK/calls")"
ctr; ln -sf /conf/resolv.conf "$IMG_J/etc/resolv.conf"; OUT="$(helper --engine docker --prepare "$STATE" java-17)"
check "an image that ships the link itself (fixed upstream): ok, not committed" "EXAKIT_SLC_DNS java-17 ok 0 none" "$OUT $(grep -c ' commit ' "$WORK/calls") $(ilabel java-17)"
ctr; OUT="$(helper --engine podman --prepare "$STATE")"; RC=$?
check "podman: nothing before the start (its mount is writable)" "|0|" "$OUT|$RC|$(cat "$WORK/calls")"
ctr; OUT="$(helper --engine docker --prepare "$WORK/no-such-state.json")"; RC=$?
check "no state file: nothing to link, said, exit 0 (the sweep's listing only)" "EXAKIT_SLC_DNS - none|0|docker ps -a" "$OUT|$RC|$(cat "$WORK/calls")"
printf '{"installedSlcs": [{"flavor": "java-17"}, "x", {"image": "i"}]}\n' > "$WORK/odd.json"
ctr; OUT="$(helper --engine docker --prepare "$WORK/odd.json")"
check "rows without a flavor and an image are skipped" "EXAKIT_SLC_DNS - none" "$OUT"
check "a flavor is still required without --prepare" "2" "$(helper --engine docker >/dev/null 2>&1; echo $?)"

printf '\n== the sh script for the launcher VM (macOS) ==\n'
gen() { bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"; shift; personal_slc_dns_script "$@"' _ "$ROOT" "$@"; }
GEN="$(gen java-17 python-3.12 r-4.4)"
ctr
OUT="$(printf '%s\n' "$GEN" | PATH="$WORK/bin:$PATH" sh)"
check "the same outcomes from the VM script" \
    "EXAKIT_SLC_DNS java-17 repaired|EXAKIT_SLC_DNS python-3.12 ok|EXAKIT_SLC_DNS r-4.4 absent|" "$(printf '%s\n' "$OUT" | tr '\n' '|')"
check "...the same two links" "/conf/resolv.conf /conf/hosts" "$(link java-17 resolv.conf) $(link java-17 hosts)"
check "...through podman, the VM's engine, by default" "podman" "$(clis)"
OUT="$(printf '%s\n' "$GEN" | PATH="$WORK/bin:$PATH" sh)"
check "...and idempotent" "EXAKIT_SLC_DNS java-17 ok" "$(printf '%s\n' "$OUT" | grep java-17)"
# The container choice, case for case the Python helper's ("" = nocontainer).
for case in "$PS_24|$ID|exasol-db-$ID" "exasol-db-ffff0000|1a2b3c4d|" "exasol-db-test|$ID|" \
            "$ID-app xexasol-db-$ID exasol-db-$ID-sidecar-$ID $ID-db-1|$ID|" "x-local|local|" \
            "exasol-db-abc|local|exasol-db-abc" "exasol-db-abc-sidecar-minio exasol-db-abc||exasol-db-abc" \
            "exasol-db-abc exasol-db-def||" "$PS_24| $ID |exasol-db-$ID"; do
    _ps="${case%%|*}"; _rest="${case#*|}"; _id="${_rest%%|*}"; _want="${_rest#*|}"
    ctr; gen --deployment-id "$_id" java-17 | FAKE_PS="$_ps" PATH="$WORK/bin:$PATH" sh >/dev/null
    _sh="$(target)"
    ctr; FAKE_PS="$_ps" helper "--deployment-id=$_id" java-17 >/dev/null
    check "VM script and helper agree: [$_ps] id=[$_id] -> [$_want]" "$_want $_want" "$_sh $(target)"
done
ctr; OUT="$(gen --deployment-id "$ID" java-17 | FAKE_PS="exasol-db-$ID-sidecar-minio" PATH="$WORK/bin:$PATH" sh)"
check "...only a sidecar: nocontainer" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
ctr; gen --engine docker --deployment-id "$ID" java-17 | FAKE_PS="$PS_24" PATH="$WORK/bin:$PATH" sh >/dev/null
check "--engine docker: the script asks docker" "docker exasol-db-$ID" "$(clis) $(target)"
check "an id or engine the launcher would not write never reaches the script" "1 1" \
    "$(gen --deployment-id "x';rm -rf /;'" java-17 | grep -c "^ID=''$") $(gen --engine 'podman;id' java-17 | grep -c "^E='podman'$")"
check "...nor the launcher's \"local\"" "1" "$(gen --deployment-id local java-17 | grep -c "^ID=''$")"
check "the VM script needs no tr (the VM's Podman never joins names)" "0" "$(gen java-17 | grep -c 'tr ')"
# A trailing option with no value used to loop for ever: `shift 2` with one
# argument left shifts nothing. perl's alarm bounds the run.
_trail="$(perl -e 'alarm 10; exec @ARGV' bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"; personal_slc_dns_script --engine docker --deployment-id' _ "$ROOT" | head -2 | tr '\n' ' ')"
check "a trailing --deployment-id with no value ends, the option dropped" "E='docker' ID='' " "$_trail"
_trail="$(perl -e 'alarm 10; exec @ARGV' bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"; personal_slc_dns_script --engine' _ "$ROOT" | head -2 | tr '\n' ' ')"
check "...and a trailing --engine" "E='podman' ID='' " "$_trail"

printf '\n== the repair asks the deployment engine (personal_slc_dns_repair) ==\n'
# Only the stubs and the system tools on PATH: a real docker (Docker Desktop's
# CLI in /usr/local/bin, the Engine in a CI runner's /usr/bin) must never
# answer. sys/ is /usr/bin and /bin without docker or podman; py/ is the
# python3 this suite runs with.
mkdir -p "$WORK/sys" "$WORK/py" "$WORK/podman-only" "$WORK/none" "$WORK/dep"
for _t in /usr/bin/* /bin/*; do
    case "${_t##*/}" in docker|podman) continue ;; esac
    ln -s "$_t" "$WORK/sys/" 2>/dev/null || true
done
ln -s "$(command -v python3)" "$WORK/py/python3"
cp "$WORK/bin/podman" "$WORK/podman-only/podman"
printf '{"deploymentId": "%s", "dbPort": 8563}\n' "$ID" > "$WORK/dep/deployment.json"
# A launcher whose `shell container` runs its stdin, as the VM's shell does.
cat > "$WORK/launcher" <<'EOF'
#!/bin/sh
[ "$1 $2" = "shell container" ] && exec sh
exit 2
EOF
chmod +x "$WORK/launcher"
# repair <bin dir> [VAR=value ...] - personal_slc_dns_repair (or CALL) with the
# record holding REC_ENGINE and REC_CONTAINER (none when unset) and the
# deployment folder DEP; prints its output, then rc=N.
repair() {
    _bin="$1"; shift
    env STUB_BIN="$_bin" "$@" WORK="$WORK" bash -c '
        EXAKIT_HOME="$WORK/home"; export EXAKIT_HOME
        . "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"
        detect_os() { printf "%s" "${STUB_OS:-linux}"; }
        personal_slc_installed_flavors() { printf "%s" "${FLAVORS:-java-17}"; }
        personal_cli() { printf "%s" "$WORK/launcher"; }
        manifest_get() {
            case "$1" in
                runtime.engine) [ -n "${REC_ENGINE:-}" ] && printf "%s" "$REC_ENGINE" ;;
                runtime.container) [ -n "${REC_CONTAINER:-}" ] && printf "%s" "$REC_CONTAINER" ;;
                *) return 1 ;;
            esac
        }
        # REAL_RB=1: the real exakit_run_bounded, timeout(1) and all.
        if [ -z "${REAL_RB:-}" ]; then exakit_run_bounded() { shift; "$@"; }; fi
        run_python_any() { python3 "$@"; }
        info() { printf "INFO %s\n" "$*"; }
        _exakit_log_file() { [ -z "${SHOW_LOG:-}" ] || printf "LOG %s\n" "$*"; return 0; }
        EXAKIT_PERSONAL_DEPLOY_DIR="${DEP:-$WORK/dep}"
        PATH="${PY_DIR:-$WORK/py}:$STUB_BIN:$WORK/sys"
        ${CALL:-personal_slc_dns_repair}; echo "rc=$?"' _ "$ROOT" 2>&1
}
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "a Docker-recorded deployment is repaired through docker" "docker" "$(clis)"
check "...in its database container" "exasol-db-$ID" "$(dbtarget)"
check "...its image linked: says so, exit 2 (the next start sees it)" \
    "INFO Gave the java-17 language container image the deployment's DNS; the database sees it from its next start|rc=2|" \
    "$(printf '%s\n' "$OUT" | tr '\n' '|')"
restart java-17; OUT="$(repair "$WORK/bin" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "...after that start: exit 0, nothing said" "rc=0" "$OUT"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=podman FAKE_PS="$PS_24")"
check "a Podman-recorded deployment: podman" "podman exasol-db-$ID rc=0" "$(clis) $(target) $(printf '%s\n' "$OUT" | tail -1)"
ctr; OUT="$(repair "$WORK/bin" FAKE_PS="$PS_24")"
check "no engine recorded (before kit 0.2.4): podman, as before" "podman exasol-db-$ID rc=0" "$(clis) $(target) $(printf '%s\n' "$OUT" | tail -1)"
ctr; repair "$WORK/bin" EXAKIT_PERSONAL_ENGINE=docker FAKE_PS="$PS_24" >/dev/null
check "nothing recorded: this run's choice (an install not recorded yet)" "docker" "$(clis)"
ctr; repair "$WORK/bin" REC_ENGINE=podman EXAKIT_PERSONAL_ENGINE=docker FAKE_PS="$PS_24" >/dev/null
check "the record beats a stray EXAKIT_PERSONAL_ENGINE in the environment" "podman" "$(clis)"
ctr; repair "$WORK/bin" REC_ENGINE=docker REC_CONTAINER=exasol-nano FAKE_PS="$PS_24" >/dev/null
check "a nano record's engine is the old database's: podman" "podman" "$(clis)"
ctr; repair "$WORK/bin" REC_ENGINE=docker REC_CONTAINER=null FAKE_PS="$PS_24" >/dev/null
check "...runtime.container null (manifest_get says \"null\") is a nano record too" "podman" "$(clis)"
ctr; OUT="$(repair "$WORK/podman-only" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "Docker recorded, no docker on PATH: exit 1, podman never asked" "rc=1|" "$(printf '%s\n' "$OUT" | tr '\n' '|')$(cat "$WORK/calls")"
check "...the java-17 file untouched" "regular" "$(link java-17 resolv.conf)"
ctr; OUT="$(repair "$WORK/none" FAKE_PS="$PS_24")"
check "no engine at all: exit 1, as before" "rc=1" "$OUT"
ctr; OUT="$(repair "$WORK/bin" STUB_OS=macos REC_ENGINE=docker FAKE_PS="$PS_24")"
check "macOS: the VM's podman, whatever a stale record says" "podman exasol-db-$ID rc=0" "$(clis) $(target) $(printf '%s\n' "$OUT" | tail -1)"

printf '\n== the real bounded runner, with timeout(1) on PATH ==\n'
# THE HARNESS STUB HID IT. `repair` above swaps exakit_run_bounded for
# `shift; "$@"`, and the repair handed it a shell FUNCTION (run_python_any).
# timeout(1) - coreutils, on every Linux and WSL host - execs its command, and
# a function is no file: "failed to run command 'run_python_any': No such file
# or directory", exit 127, the repair never ran, and only "DNS could not be
# repaired" surfaced. The stand-in behaves like coreutils (it can run a file,
# nothing else) and notes what it ran, so a stock macOS proves it too.
mkdir -p "$WORK/timeout-bin"
cat > "$WORK/timeout-bin/timeout" <<'EOF'
#!/bin/sh
shift
[ -z "${TIMEOUT_LOG:-}" ] || printf '%s\n' "$1" >> "$TIMEOUT_LOG"
command -v "$1" >/dev/null 2>&1 || { printf "timeout: failed to run command '%s': No such file or directory\n" "$1" >&2; exit 127; }
exec "$@"
EOF
chmod +x "$WORK/timeout-bin/timeout"
# bounded <PATH> <limit> <command...> - the real runner alone; prints the
# command's output, then rc=N.
bounded() {
    _bp="$1"; shift
    PATH="$_bp" TIMEOUT_LOG="$WORK/timeout.log" bash -c '
        . "$1/setup/lib/common.sh"; shift
        greet() { printf "ran %s" "$1"; }
        exakit_run_bounded "$@"; echo " rc=$?"' _ "$ROOT" "$@" 2>&1
}
: > "$WORK/timeout.log"
check "a shell function is refused out loud: exit 2, the reason on stderr (was 127, or a silent run)" \
    "exakit_run_bounded needs an executable, not the shell function greet| rc=2|" \
    "$(bounded "$WORK/timeout-bin:$WORK/sys" 5 greet x | tr '\n' '|')"
check "...and timeout(1) was never handed it" "" "$(cat "$WORK/timeout.log")"
check "a file goes through timeout(1), as before" "ok rc=0|printf" \
    "$(bounded "$WORK/timeout-bin:$WORK/sys" 5 printf ok)|$(cat "$WORK/timeout.log")"
# The repair itself, through the real runner: the case the live test met. Its
# interpreter is an executable now (exakit_python_any_argv), so timeout(1)
# runs it - and on a real timeout(1) cuts off its whole process group.
: > "$WORK/timeout.log"
ctr; OUT="$(repair "$WORK/timeout-bin:$WORK/bin" REAL_RB=1 TIMEOUT_LOG="$WORK/timeout.log" REC_ENGINE=docker FAKE_PS="$PS_24")"
# On Docker the repair links the image (read-only mount): exit 2, the next
# start mounts it.
LINKED="INFO Gave the java-17 language container image the deployment's DNS; the database sees it from its next start|rc=2|"
check "the repair through the real runner and timeout(1): the image linked, exit 2" \
    "docker exasol-db-$ID $LINKED" \
    "$(clis) $(dbtarget) $(printf '%s\n' "$OUT" | tr '\n' '|')"
check "...timeout(1) ran python3 itself, not a function" "python3" "$(cat "$WORK/timeout.log")"
check "...the java-17 image points at /conf now" "/conf/resolv.conf conf-links" "$(ilink java-17 resolv.conf) $(ilabel java-17)"
if [ -x "$WORK/sys/timeout" ]; then
    ctr; OUT="$(repair "$WORK/bin" REAL_RB=1 REC_ENGINE=docker FAKE_PS="$PS_24")"
    check "...and under the system's own timeout(1) too" "$LINKED" \
        "$(printf '%s\n' "$OUT" | tr '\n' '|')"
else
    check "...no timeout(1) on this system (stock macOS): the stand-in stood for it" "skip" "skip"
fi
# No python3 at all: the uv-managed runtime, as run_python would run it - one
# command, `uv run --python <v> --no-project python <helper> ...`. The stand-in
# uv checks those words and hands the rest to this suite's python3.
mkdir -p "$WORK/fake-uv"
cat > "$WORK/fake-uv/uv" <<EOF
#!/bin/sh
[ "\$1 \$2 \$4 \$5" = "run --python --no-project python" ] || { echo "fake uv: unexpected \$*" >&2; exit 9; }
shift 5
exec "$(command -v python3)" "\$@"
EOF
chmod +x "$WORK/fake-uv/uv"
: > "$WORK/timeout.log"
ctr; OUT="$(repair "$WORK/timeout-bin:$WORK/bin" REAL_RB=1 TIMEOUT_LOG="$WORK/timeout.log" EXAKIT_DISABLE_SYSTEM_PYTHON=1 \
    _EXAKIT_UV_VETTED="$WORK/fake-uv/uv" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "no python3: the repair runs on uv's Python, through timeout(1)" \
    "$WORK/fake-uv/uv $LINKED" \
    "$(cat "$WORK/timeout.log") $(printf '%s\n' "$OUT" | tr '\n' '|')"
# A repair that cannot run leaves one log line with the reason: every caller
# ignores its exit code, so this line is all a reader of the log gets.
mkdir -p "$WORK/badpy"
printf '#!/bin/sh\necho "python3: no such helper" >&2\nexit 2\n' > "$WORK/badpy/python3"
chmod +x "$WORK/badpy/python3"
ctr; OUT="$(repair "$WORK/timeout-bin:$WORK/bin" REAL_RB=1 SHOW_LOG=1 PY_DIR="$WORK/badpy" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "a repair that did not run: exit 1, one WARN line naming exit and reason" \
    "LOG WARN  language container DNS repair did not run (exit 2): python3: no such helper|rc=1|" \
    "$(printf '%s\n' "$OUT" | tr '\n' '|')"
check "the repair hands the runner no function" "0" \
    "$(sed -n '/^personal_slc_dns_repair()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c 'exakit_run_bounded [0-9]* run_python')"

printf '\n== before the start on Docker (personal_slc_dns_prepare) ==\n'
mkdir -p "$WORK/dep-st"
printf '{"deploymentId": "%s", "installedSlcs": [{"flavor": "java-17", "image": "docker.io/exa/slc:java-17"}]}\n' "$ID" > "$WORK/dep-st/.exasolLauncherState.json"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/dep-st" CALL=personal_slc_dns_prepare)"
check "Docker: the state file's images linked before the start, and said" \
    "INFO Gave the java-17 language container image the deployment's DNS|rc=0|conf-links" "$(printf '%s\n' "$OUT" | tr '\n' '|')$(ilabel java-17)"
check "...no database container asked (it is not running yet)" "0" "$(grep -c -e ' ps -$' -e ' inspect ' "$WORK/calls")"
ctr; rm -rf "$WORK/img/docker.io_exa_slc_java-17"; mkimg java-17 registry
OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/dep-st" CALL='personal_slc_dns_prepare --pull')"
check "--pull reaches the helper: pulled, then linked" "rc=0 1 conf-links" "$(printf '%s\n' "$OUT" | tail -1) $(grep -c ' pull ' "$WORK/calls") $(ilabel java-17)"
ctr; rm -rf "$WORK/img/docker.io_exa_slc_java-17"; mkimg java-17 registry
OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/dep-st" CALL=personal_slc_dns_prepare)"
check "...without it, nothing is pulled" "rc=0 0" "$OUT $(grep -c ' pull ' "$WORK/calls")"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=podman DEP="$WORK/dep-st" CALL=personal_slc_dns_prepare)"
check "nothing before the start - podman" "rc=0||none" "$OUT|$(cat "$WORK/calls")|$(ilabel java-17)"
ctr; OUT="$(repair "$WORK/bin" STUB_OS=macos REC_ENGINE=docker DEP="$WORK/dep-st" CALL=personal_slc_dns_prepare)"
check "nothing before the start - macOS (the VM's Podman)" "rc=0||none" "$OUT|$(cat "$WORK/calls")|$(ilabel java-17)"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/dep" CALL=personal_slc_dns_prepare)"
check "nothing before the start - no launcher state file" "rc=0||none" "$OUT|$(cat "$WORK/calls")|$(ilabel java-17)"
ctr; OUT="$(repair "$WORK/podman-only" REC_ENGINE=docker DEP="$WORK/dep-st" CALL=personal_slc_dns_prepare)"
check "...no docker on PATH: nothing, exit 0" "rc=0|" "$OUT|$(cat "$WORK/calls")"

# It always answers, so silence is a run that did not happen: logged, as the
# repair's is. Nothing installed answers "- none", and is no warning.
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/dep-st" SHOW_LOG=1 PY_DIR="$WORK/badpy" CALL=personal_slc_dns_prepare)"
check "a prepare that did not run: one WARN line naming exit and reason, never a failed start" \
    "LOG WARN  language container DNS before the start did not run (exit 2): python3: no such helper|rc=0|" "$(printf '%s\n' "$OUT" | tr '\n' '|')"
mkdir -p "$WORK/dep-none"; printf '{"deploymentId": "%s"}\n' "$ID" > "$WORK/dep-none/.exasolLauncherState.json"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/dep-none" SHOW_LOG=1 CALL=personal_slc_dns_prepare)"
check "...nothing installed: said, no warning" "LOG INFO  language container DNS (before the start): -:none|rc=0|" "$(printf '%s\n' "$OUT" | tr '\n' '|')"

printf '\n== a linked image beside a flavor that failed ==\n'
# Java linked, python's mounted image gone: the restart Java needs still
# happens (exit 2), and python's failure is its own WARN line.
ctr; : > "$WORK/ctr/python-3.12/etc/resolv.conf"; rm -rf "$WORK/img/docker.io_exa_slc_python-3.12"
OUT="$(repair "$WORK/bin" REC_ENGINE=docker FLAVORS="java-17 python-3.12" SHOW_LOG=1 FAKE_PS="$PS_24")"
check "derived and failed: exit 2, not 1" "rc=2" "$(printf '%s\n' "$OUT" | tail -1)"
check "...the failed flavor named in a WARN line" "1" "$(printf '%s\n' "$OUT" | grep -c '^LOG WARN  language container DNS could not be given to python-3.12$')"
check "...java linked" "conf-links" "$(ilabel java-17)"

printf '\n== the start (personal_start) ==\n'
# start_run <bin dir> [VAR=value ...] - personal_start with the launcher
# replaced: `start` mounts each image's etc/ (pulling a missing one from the
# registry, as the launcher does), `stop` does nothing; every launcher call
# is printed as RUN <verb>, then rc=N.
start_run() {
    _bin="$1"; shift
    env "$@" STUB_PATH="$WORK/py:$_bin:$WORK/sys" WORK="$WORK" bash -c '
        EXAKIT_HOME="$WORK/home"; export EXAKIT_HOME
        . "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"
        detect_os() { printf "%s" "${STUB_OS:-linux}"; }
        personal_slc_installed_flavors() { printf "java-17"; }
        personal_cli() { printf "LAUNCHER"; }
        manifest_get() { case "$1" in runtime.engine) printf "%s" "${REC_ENGINE:-}" ;; *) return 1 ;; esac; }
        _personal_start_engine_ok() { return 0; }
        personal_launcher_supports() { return 0; }
        personal_launcher_state() { printf "stopped"; }
        personal_note_guest_rebuild() { :; }
        port_in_use() { return 1; }
        personal_auto_approve_flag() { :; }
        run_logged() {
            shift; printf "RUN %s\n" "$1"
            if [ "$1" = start ]; then
                _i="$WORK/img/docker.io_exa_slc_java-17"
                [ -d "$_i" ] || cp -RP "$WORK/registry/docker.io_exa_slc_java-17" "$_i"
                rm -rf "$WORK/ctr/java-17/etc"; cp -RP "$_i/etc" "$WORK/ctr/java-17/etc"
            fi
            return 0
        }
        run_python_any() { python3 "$@"; }
        info() { printf "INFO %s\n" "$*"; }
        ok() { :; }
        die() { printf "DIE %s\n" "$*"; exit 1; }
        _exakit_log_file() { :; }
        EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/dep-st"
        PATH="$STUB_PATH"
        personal_start; echo "rc=$?"' _ "$ROOT" 2>&1
}
ctr; OUT="$(start_run "$WORK/bin" REC_ENGINE=docker FAKE_PS="exasol-db-$ID")"
check "Docker, the image here: linked before the start, one start, DNS in place" \
    "RUN start|rc=0|/conf/resolv.conf" "$(printf '%s\n' "$OUT" | grep -e '^RUN' -e '^rc=' | tr '\n' '|')$(link java-17 resolv.conf)"
ctr; rm -rf "$WORK/img/docker.io_exa_slc_java-17"; mkimg java-17 registry
OUT="$(start_run "$WORK/bin" REC_ENGINE=docker FAKE_PS="exasol-db-$ID")"
check "Docker, the image pulled by the start: linked after it, then ONE restart" \
    "RUN start|RUN stop|RUN start|rc=0|/conf/resolv.conf" "$(printf '%s\n' "$OUT" | grep -e '^RUN' -e '^rc=' | tr '\n' '|')$(link java-17 resolv.conf)"
check "...and says why it restarts" "1" "$(printf '%s\n' "$OUT" | grep -c '^INFO Restarting the database once, so Java in it can resolve host names$')"
: > "$WORK/calls"; OUT="$(start_run "$WORK/bin" REC_ENGINE=docker FAKE_PS="exasol-db-$ID")"
check "...the start after that: one start, nothing linked" "RUN start|rc=0|0" "$(printf '%s\n' "$OUT" | grep -e '^RUN' -e '^rc=' | tr '\n' '|')$(grep -c ' commit ' "$WORK/calls")"
ctr; OUT="$(start_run "$WORK/bin" REC_ENGINE=podman FAKE_PS="exasol-db-$ID")"
check "Podman: one start, the container repaired after it, the image never touched" \
    "RUN start|rc=0|/conf/resolv.conf none" "$(printf '%s\n' "$OUT" | grep -e '^RUN' -e '^rc=' | tr '\n' '|')$(link java-17 resolv.conf) $(ilabel java-17)"

printf '\n== the id the container is named by (personal_slc_container_id) ==\n'
# st <dir> <state json or -> <deployment.json or -> - a deployment folder.
st() { rm -rf "$1"; mkdir -p "$1"; [ "$2" = - ] || printf '%s\n' "$2" > "$1/.exasolLauncherState.json"; [ "$3" = - ] || printf '%s\n' "$3" > "$1/deployment.json"; }
cid() { repair "$WORK/none" DEP="$1" CALL=personal_slc_container_id | sed '$d'; }
st "$WORK/d1" '{"currentWorkflowState": {"running": {}}, "deploymentId": "  '"$ID"' "}' '{"deploymentId": "local"}'
check "the launcher's state file first, trimmed; deployment.json's \"local\" ignored" "$ID" "$(cid "$WORK/d1")"
st "$WORK/d2" '{"deploymentId": "aaaa1111"}' '{"deploymentId": "bbbb2222"}'
check "...state and deployment.json disagree: the state's id (the one the launcher names by)" "aaaa1111" "$(cid "$WORK/d2")"
st "$WORK/d3" '{"nested": {"deploymentId": "nested-id"}, "deploymentId": "top-id", "x": {"deploymentId": "later-id"}}' -
check "the top-level key, not an occurrence before or after it" "top-id" "$(cid "$WORK/d3")"
st "$WORK/d4" '{"nested": {"deploymentId": "nested-id"}}' '{"deploymentId": "bbbb2222"}'
check "a state file with none at the top: deployment.json's" "bbbb2222" "$(cid "$WORK/d4")"
st "$WORK/d5" '{not json' '{"deploymentId": "bbbb2222"}'
check "an unreadable state file: deployment.json's" "bbbb2222" "$(cid "$WORK/d5")"
st "$WORK/d6" '{"deploymentId": "   "}' -
check "a blank id is none" "" "$(cid "$WORK/d6")"
st "$WORK/d7" - -
check "no state at all: none" "" "$(cid "$WORK/d7")"
ctr; repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/d1" FAKE_PS="$PS_24" >/dev/null
check "the repair targets the state file's id over deployment.json's \"local\"" "exasol-db-$ID" "$(dbtarget)"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/d7" FAKE_PS="$PS_24")"
check "no id and two exasol-db-* listed: nothing written, exit 1" "rc=1 " "$(printf '%s\n' "$OUT" | tail -1) $(target)"

printf '\n== wiring ==\n'
check "every start repairs (bash): the call after the start, its exit kept" "1" "$(sed -n '/^personal_start()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c '^ *personal_slc_dns_repair || _pst_dns=\$?$')"
check "...and once more after a Docker restart" "1" "$(sed -n '/^personal_start()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c '^ *personal_slc_dns_repair || true$')"
check "every start repairs (PowerShell; again after a Docker restart)" "2" "$(sed -n '/^function Start-Personal/,/^function Get-PersonalSlcInstalledFlavors/p' "$ROOT/setup/lib/runtime-personal.ps1" | grep -c 'try { \[void\](Repair-PersonalSlcDns) }')"
check "macOS feeds the VM shell inside the bounded command (stdin survives a background job)" "1" \
    "$(grep -c "exakit_run_bounded 90 sh -c 'exec \"\$0\" shell container < \"\$1\"'" "$ROOT/setup/lib/runtime-personal.sh")"
check "the repair no longer gates on podman alone" "0" \
    "$(sed -n '/^personal_slc_dns_repair()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c 'command -v podman')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
