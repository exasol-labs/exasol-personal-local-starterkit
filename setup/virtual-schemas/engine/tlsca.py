"""A private certificate authority for a source: read, chosen, embedded.

Managed databases (AWS RDS, Azure) and company servers sign with a CA the
JVM's public trust store does not hold, so tls=verify fails with "PKIX path
building failed" although nothing is wrong. The fix is to trust that CA - not
to stop verifying.

For PostgreSQL the certificate is a file the URL names (pgJDBC's
SingleCertValidatingFactory with "file:<path>"), at a path RELATIVE to where
the adapter and the loader start, a copy written for each (see
lifecycle.stage_ca_file): the loader sees the bucket at /exa/bucketfs, not
/buckets, so an absolute path fails there. The certificate used to travel
inside the URL as text; that made the URL some 2,000 characters long, and a
database message that quotes the URL was cut before its reason. A source
connected that way keeps its URL until it is connected again.

That factory trusts exactly one certificate, and a vendor's download is
often a bundle (RDS: three roots per region, over a hundred globally). The
one that signs this server is found the way a client would: a verified TLS
handshake from this computer, host name checked, one candidate at a time.
"""

import base64
import hashlib
import re
import socket
import ssl
import struct
import urllib.parse

MAX_BYTES = 2 * 1024 * 1024
PEM = re.compile(r"-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+?-----END CERTIFICATE-----")
POSTGRES_SSL_REQUEST = struct.pack("!ii", 8, 80877103)


class CaError(Exception):
    pass


def certificates(path):
    """The PEM certificates in a file, in file order."""
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_BYTES + 1)
    except OSError as error:
        raise CaError("the CA file %s cannot be read (%s)" % (path, error.strerror or error))
    if len(data) > MAX_BYTES:
        raise CaError("the CA file %s is larger than 2 MB; give the PEM certificate (or bundle) itself" % path)
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    found = certificates_from_text(data.decode("ascii", "replace"))
    if not found:
        raise CaError("the CA file %s holds no PEM certificate (-----BEGIN CERTIFICATE-----); "
                      "a DER .cer/.crt needs converting to PEM first" % path)
    return found


def normalise(text):
    """A PEM as every driver reads it: no byte-order mark, LF line ends, no
    trailing whitespace on a line. A Windows editor (or git autocrlf) writes
    CRLF, and Oracle's wallet parser refuses the \\r in the base64 the kit
    embeds (measured: the same file with LF connects)."""
    text = (text or "").lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(line.rstrip() for line in text.split("\n"))


def certificates_from_text(text):
    return [m.group(0) + "\n" for m in PEM.finditer(normalise(text))]


def handshake(host, port, protocol, pem, timeout):
    """A verified TLS handshake trusting only `pem`. Raises ssl.SSLCertVerificationError
    when it does not sign the server (or names another host), OSError when the
    server cannot be reached."""
    context = ssl.create_default_context(cadata=pem)
    with socket.create_connection((host, int(port)), timeout=timeout) as raw:
        if protocol == "postgres":
            raw.sendall(POSTGRES_SSL_REQUEST)
            if raw.recv(1) != b"S":
                raise CaError("%s:%s answered, but does not offer TLS" % (host, port))
        with context.wrap_socket(raw, server_hostname=host):
            return True


def choose(certs, host, port, protocol, path, timeout=8):
    """The one certificate to trust. A single certificate is taken as given
    (the database's own verification judges it); from a bundle, the first one
    a verified handshake accepts."""
    if len(certs) == 1:
        return certs[0]
    try:
        # One handshake with the whole bundle first: if nothing in it signs
        # the server, say so now rather than after a hundred tries.
        handshake(host, port, protocol, "".join(certs), timeout)
    except ssl.SSLCertVerificationError as error:
        raise CaError("none of the %d certificates in %s signs %s (%s); check that the bundle is the one for "
                      "this server, or its region" % (len(certs), path, host, error.verify_message or error))
    except (OSError, ssl.SSLError) as error:
        raise CaError("%s holds %d certificates, and this computer could not reach %s:%s to tell which one signs "
                      "it (%s); give the one root certificate instead" % (path, len(certs), host, port, error))
    for pem in certs:
        try:
            handshake(host, port, protocol, pem, timeout)
            return pem
        except ssl.SSLCertVerificationError:
            continue
        except (OSError, ssl.SSLError):
            break
    raise CaError("the bundle %s signs %s as a whole, but no single certificate in it does (an intermediate "
                  "without its root); give the root certificate" % (path, host))


def jks(certs):
    """A Java KeyStore (JKS, version 2) holding `certs` as trusted
    certificates, for drivers that only read a truststore from a file
    (Connector/J, mssql-jdbc). It holds public certificates only and is read
    without a password, so the integrity digest is keyed on the empty one."""
    body = struct.pack(">III", 0xFEEDFEED, 2, len(certs))
    for index, pem in enumerate(certs):
        der = base64.b64decode("".join(pem.strip().splitlines()[1:-1]))
        alias = ("exakit-ca-%d" % index).encode("utf-8")
        body += struct.pack(">I", 2) + struct.pack(">H", len(alias)) + alias + struct.pack(">Q", 0)
        body += struct.pack(">H", 5) + b"X.509" + struct.pack(">I", len(der)) + der
    return body + hashlib.sha1(b"Mighty Aphrodite" + body).digest()


def class_arg(host, pem_text):
    """The kit's TLS helper's constructor argument: "<host>|<cert>.<cert>",
    each certificate as unpadded base64url DER - only [A-Za-z0-9_.|-] and the
    host's own characters, so it survives the driver's ;-separated URL."""
    ders = [base64.urlsafe_b64encode(ssl.PEM_cert_to_DER_cert(pem.strip() + "\n")).decode("ascii").rstrip("=")
            for pem in certificates_from_text(pem_text)]
    return "%s|%s" % (host.lower(), ".".join(ders))


def url_value(pem):
    """The certificate as one URL parameter value: every byte percent-encoded
    except letters and digits, so '+', '/', '=' and the line breaks survive the
    driver's URL decoding."""
    return urllib.parse.quote(pem, safe="")
