"""The text of a Lua adapter script (Profile C).

A Lua adapter is not a file the database reads: its whole text goes into
CREATE LUA ADAPTER SCRIPT. The kit assembles it from three parts, each
checked here before the database sees any of it:

  1. upstream's module-loading preamble (its user guide: required on Exasol 8);
  2. the dist file, byte for byte - the artifact cache has already checked its
     SHA-256 against the pin;
  3. the kit's suffix (profile adapter_script.suffix) with the pinned CA bundle
     put in place of its one marker line. The bundle must hold certificates
     only, and nothing that could end the Lua long string it sits in.
"""

import os
import re

MARKER = "--@EXAKIT_CA_BUNDLE@"

# From the databricks-virtual-schema user guide, verbatim in effect.
PREAMBLE = """table.insert(package.searchers,
    function (module_name)
        local loader = package.preload[module_name]
        if(loader == nil) then
            error("Module " .. module_name .. " not found in package.preload.")
        else
            return loader
        end
    end
)
"""

CERT = re.compile(r"-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+-----END CERTIFICATE-----")


class LuaAdapterError(Exception):
    pass


def certificates(bundle_text):
    """The PEM certificate blocks of a CA bundle, in order; anything else is dropped."""
    found = CERT.findall(bundle_text.replace("\r\n", "\n"))
    if not found:
        raise LuaAdapterError("the CA bundle holds no certificates")
    return found


def body(defs_root, suffix_path, adapter_path, bundle_path):
    """The script text after AS: preamble, dist file, suffix with the bundle."""
    with open(adapter_path, encoding="utf-8") as handle:
        dist = handle.read()
    # The bundle's comments name CAs in UTF-8; only its certificates are kept.
    with open(bundle_path, encoding="utf-8") as handle:
        certs = certificates(handle.read())
    with open(os.path.join(defs_root, suffix_path), encoding="utf-8") as handle:
        suffix = handle.read()
    if suffix.count(MARKER) != 1:
        raise LuaAdapterError("the adapter suffix %s must hold the CA bundle marker exactly once" % suffix_path)
    # A line that is only "/" ends a script in SQL clients; the kit sends the
    # text over the session, but a copy of it must stay usable there too.
    text = PREAMBLE + dist.rstrip("\n") + "\n" + suffix.replace(MARKER, "\n".join(certs))
    if re.search(r"^/\s*$", text, re.M):
        raise LuaAdapterError("the adapter text has a line holding only /")
    return text
