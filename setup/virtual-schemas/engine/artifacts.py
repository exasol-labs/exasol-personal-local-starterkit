"""Pinned artifacts: fetch once, verify, cache by digest, stage where SQL reads.

    <EXAKIT_HOME>/cache/virtual-schemas/<sha256>/<asset>     the verified download
    <deploymentDir>/local/runtime/exa/bucketfs/...           what adapter scripts read
    <deploymentDir>/local/runtime/exa/jdbc/<DRIVERNAME>/      the loader's driver

A file is fetched only from the exact URL its connector pins, never "latest",
and is used only if its size and SHA-256 match the pin. A cache hit is
re-verified before it is trusted. A failed download or a mismatch leaves
nothing behind and stops the operation; there is no fallback to anything the
pin does not name.
"""

import hashlib
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile


class ArtifactError(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verified(path, pin):
    return (os.path.isfile(path) and os.path.getsize(path) == int(pin["size"])
            and sha256_file(path) == pin["sha256"])


class Cache(object):
    def __init__(self, kit_home, log=None):
        self.root = os.path.join(kit_home, "cache", "virtual-schemas")
        self.log = log or (lambda text: None)

    def path(self, pin):
        return os.path.join(self.root, pin["sha256"], pin["asset"])

    def has(self, pin):
        return verified(self.path(pin), pin)

    def fetch(self, pin):
        """The verified cached file for a pin, downloading it if needed."""
        target = self.path(pin)
        if verified(target, pin):
            return target
        os.makedirs(os.path.dirname(target), exist_ok=True)
        handle, partial = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".part-")
        os.close(handle)
        try:
            self._download(pin["url"], partial)
            size = os.path.getsize(partial)
            if size != int(pin["size"]):
                raise ArtifactError("%s is %d bytes, the pin says %d" % (pin["asset"], size, int(pin["size"])))
            actual = sha256_file(partial)
            if actual != pin["sha256"]:
                raise ArtifactError("%s does not match its pinned SHA-256 (expected %s, got %s)"
                                    % (pin["asset"], pin["sha256"], actual))
            os.replace(partial, target)
            self.log("fetched %s (%d bytes, sha256 verified)" % (pin["asset"], size))
            return target
        finally:
            if os.path.exists(partial):
                os.remove(partial)

    def _download(self, url, dest):
        if not url.startswith("https://"):
            raise ArtifactError("refusing a non-HTTPS download: %s" % url)
        # curl first: it honours the machine's proxy settings and CA store the
        # same way every other kit download does. urllib is the fallback.
        curl = shutil.which("curl")
        if curl:
            done = subprocess.run([curl, "-fL", "--proto", "=https", "--retry", "3", "--connect-timeout", "15",
                                   "-sS", "-o", dest, url], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if done.returncode == 0:
                return
            self.log("curl could not fetch %s: %s" % (url, done.stderr.decode("utf-8", "replace").strip()))
        try:
            with urllib.request.urlopen(url, timeout=60) as response, open(dest, "wb") as out:
                shutil.copyfileobj(response, out)
        except Exception as error:      # network, TLS, HTTP - all mean "not downloaded"
            raise ArtifactError("could not download %s: %s" % (url, error))


class Runtime(object):
    """Where a Personal deployment's database reads files, host side and SQL side."""

    def __init__(self, deployment_dir, bucket):
        self.exa = os.path.join(deployment_dir, "local", "runtime", "exa")
        self.bucket = bucket            # {"service", "bucket", "dir"}

    def bucket_dir(self, *parts):
        return os.path.join(self.exa, "bucketfs", self.bucket["service"], self.bucket["bucket"],
                            *(self.bucket["dir"].split("/") + list(parts)))

    def bucket_sql(self, *parts):
        return "/".join(["/buckets", self.bucket["service"], self.bucket["bucket"], self.bucket["dir"]] + list(parts))

    def sql_path(self, host_path):
        """The /buckets path the database reads a host-side bucket file at; None for a file outside the bucket."""
        root = os.path.join(self.exa, "bucketfs", self.bucket["service"], self.bucket["bucket"])
        try:
            relative = os.path.relpath(host_path, root)
        except ValueError:          # Windows: another drive
            return None
        if relative == ".." or relative.startswith(".." + os.sep):
            return None
        return "/".join(["/buckets", self.bucket["service"], self.bucket["bucket"]] + relative.split(os.sep))

    def loader_dir(self, drivername):
        return os.path.join(self.exa, "jdbc", drivername)

    def available(self):
        return os.path.isdir(self.exa)


def stage_file(source, dest):
    """Copy a verified file into place atomically; True when it was created now."""
    if os.path.isfile(dest) and sha256_file(dest) == sha256_file(source):
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    handle, partial = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".part-")
    os.close(handle)
    shutil.copyfile(source, partial)
    os.replace(partial, dest)
    return True


def stage_zip(source, dest_dir):
    """Extract a verified driver bundle; the JAR names it holds, sorted."""
    jars = []
    with zipfile.ZipFile(source) as archive:
        for member in archive.infolist():
            name = os.path.basename(member.filename)
            if not name.lower().endswith(".jar") or member.is_dir():
                continue
            target = os.path.join(dest_dir, name)
            os.makedirs(dest_dir, exist_ok=True)
            with archive.open(member) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)
            jars.append(name)
    return sorted(jars)


def stage_tar_member(source, member, size, sha256, dest):
    """Extract one regular file of a verified .tar.gz into place, checked
    against its own pin; True when it was created now. Nothing else in the
    archive is read, and a link or any other kind of entry is refused."""
    if os.path.isfile(dest) and os.path.getsize(dest) == int(size) and sha256_file(dest) == sha256:
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    handle, partial = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".part-")
    os.close(handle)
    try:
        with tarfile.open(source, "r:gz") as archive:
            try:
                entry = archive.getmember(member)
            except KeyError:
                raise ArtifactError("%s holds no %s" % (os.path.basename(source), member))
            if not entry.isfile():
                raise ArtifactError("%s in %s is not a regular file" % (member, os.path.basename(source)))
            with archive.extractfile(entry) as src, open(partial, "wb") as out:
                shutil.copyfileobj(src, out)
        if os.path.getsize(partial) != int(size) or sha256_file(partial) != sha256:
            raise ArtifactError("%s from %s does not match its pinned size and SHA-256"
                                % (member, os.path.basename(source)))
        os.chmod(partial, 0o644)
        os.replace(partial, dest)
        return True
    except (tarfile.TarError, OSError) as error:
        raise ArtifactError("could not extract %s from %s: %s" % (member, os.path.basename(source), error))
    finally:
        if os.path.exists(partial):
            os.remove(partial)


def settings_cfg(etl, jar_name, extra_jars=()):
    """The loader's settings.cfg: the documented keys, LF endings, a final blank
    line. Extra JAR= lines put more jars on the driver's classpath (measured:
    the loader loads the kit's TLS helper from a second one)."""
    lines = ["DRIVERNAME=%s" % etl["drivername"], "PREFIX=%s" % etl["prefix"],
             "DRIVERMAIN=%s" % etl["main"], "FETCHSIZE=100000", "INSERTSIZE=-1", "JAR=%s" % jar_name]
    lines += ["JAR=%s" % jar for jar in extra_jars]
    if etl.get("nosecurity"):
        lines.append("NOSECURITY=YES")
    return "\n".join(lines) + "\n\n"
