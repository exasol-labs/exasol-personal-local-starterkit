"""This computer's public IP address: the one a source on the internet sees.

The database runs in a local VM or container whose traffic leaves through this
computer, so a source that filters by address - an RDS security group, an
Azure or MongoDB Atlas firewall, a Snowflake network policy, a Databricks IP
access list, an S3 bucket policy - sees this computer's public egress address,
not the database's. Nothing on this computer knows that address; one HTTPS
service is asked, once per run.

The address is advice, never a step: the question is asked in a background
thread and waited for at most TIMEOUT seconds in all (a resolver that hangs
included), and any failure - offline, a timeout, an answer that is not an
address - leaves it unknown, with one line to the log and nothing on screen.

EXAKIT_NO_IP_LOOKUP=1 skips the question. EXAKIT_PUBLIC_IP_URL asks another
URL instead; the test suite points it at a file:// URL.

One command is several engine runs (the connect menu's catalog, each source's
plan, each connect). The first one that asks hands its answer on in
_EXAKIT_VS_PUBLIC_IP (the shells export it): an address, or anything else for
"not known", and a later run of the same command takes it without asking.
"""

import ipaddress
import os
import sys
import threading
import time
import urllib.request

URL = "https://checkip.amazonaws.com"
TIMEOUT = 3.0
# The answer is one address and a newline; anything longer is not one.
MAX_BYTES = 64
# This command's answer, from an earlier engine run of it (see above).
KNOWN = "_EXAKIT_VS_PUBLIC_IP"

_state = {}


def disabled():
    return os.environ.get("EXAKIT_NO_IP_LOOKUP", "").strip() not in ("", "0")


def parse(body):
    """The address in a lookup's answer, or None: a single IPv4 or IPv6
    address, nothing else, and one a router could send from."""
    if not body or len(body) > MAX_BYTES:
        return None
    try:
        ip = ipaddress.ip_address(body.decode("ascii").strip())
    except (UnicodeDecodeError, ValueError):
        return None
    if ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local:
        return None
    return str(ip)


def _ask(url, answer):
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
            answer["body"] = response.read(MAX_BYTES + 1)
    except Exception as error:      # offline, DNS, TLS, HTTP: all mean "not known"
        answer["error"] = "%s: %s" % (type(error).__name__, error)


def start():
    """Ask in the background; get() collects the answer. Once per run, and
    not at all when an earlier run of this command already asked."""
    if "thread" in _state or disabled() or os.environ.get(KNOWN) is not None:
        return
    answer = {}
    thread = threading.Thread(target=_ask, args=(os.environ.get("EXAKIT_PUBLIC_IP_URL") or URL, answer))
    thread.daemon = True
    _state.update(thread=thread, answer=answer, started=time.time())
    thread.start()


def get():
    """This computer's public IP as text, or None when it is not known. Waits
    at most what is left of TIMEOUT since start(); the answer is kept for the
    rest of the run."""
    if "ip" in _state:
        return _state["ip"]
    if disabled():
        return None
    known = os.environ.get(KNOWN)
    if known is not None:
        _state["ip"] = parse(known.encode("ascii", "replace"))
        return _state["ip"]
    start()
    _state["thread"].join(max(0.0, TIMEOUT - (time.time() - _state["started"])))
    answer = _state["answer"]
    ip = None
    if _state["thread"].is_alive():
        reason = "no answer within %g s" % TIMEOUT
    elif "error" in answer:
        reason = answer["error"]
    else:
        ip = parse(answer.get("body"))
        reason = None if ip else "the answer is not an IP address"
    if reason:
        # The log only: the shells send the engine's stderr there (with --json
        # it is the event stream, and a line with no level is not an event).
        sys.stderr.write("public IP lookup: %s\n" % reason)
        sys.stderr.flush()
    _state["ip"] = ip
    return ip


def advice(ip, host=None):
    """The plan's line for a source on the internet; without a host, the
    connect menu's first line, for any source on the internet."""
    if not host:
        return "This computer's public IP is %s: a source on the internet must allow it." % ip
    return ("This computer's public IP is %s: %s must allow it if it filters by address (security group, "
            "firewall or IP access list)" % (ip, host))
