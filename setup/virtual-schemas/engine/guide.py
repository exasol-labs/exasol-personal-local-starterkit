"""The terminal guide: `exakit connect <connector> --help` and `exakit connect --help`.

    guide.py --defs DIR [--width N] [--shell bash|powershell] [--exact] [CONNECTOR]

Every word it prints comes from docs/virtual-schemas/ (the connector guides
and their README index), setup/virtual-schemas/catalog.json and the connect
entry of setup/help/exakit.json: one source of truth, so a guide changed in
the docs is the guide the terminal shows. A section a guide does not have is
left out; a guide that is missing falls back to the catalog's own words.

Standard library only, and no credential is read: it runs on the kit's Python
or any python3, before the kit is installed too. The output is ASCII (the
Windows console and Windows PowerShell 5.1 pipes), one line per row, each
"<style>|<text>" for the shell to colour: T title, N normal, D dimmed,
H heading, A a command. Exit 0 with a guide, 2 for a word that is no
connector (the list follows it), 10 with --exact for a word that is no
connector's id or alias (nothing printed: the caller's own help answers).
"""

import argparse
import json
import os
import re
import sys
import textwrap

# -I (isolated) leaves the script's folder off sys.path; publicip is beside it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import publicip  # noqa: E402

# Characters the guides use that an ASCII console cannot show.
ASCII = {"→": ">", "←": "<", "—": "-", "–": "-", "‘": "'", "’": "'",
         "“": '"', "”": '"', "…": "...", " ": " ", "×": "x", "•": "-"}
# Words that say nothing about which field a "where to find" step covers.
STOP = {"the", "and", "for", "with", "its", "your", "this", "open", "name", "file", "from", "into"}


def ascii_text(text):
    for k, v in ASCII.items():
        text = text.replace(k, v)
    return text.encode("ascii", "replace").decode("ascii")


def plain(text):
    """Markdown inline syntax off: links to their text, no bold, no code ticks."""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = text.replace("`", "")
    return ascii_text(re.sub(r"\s+", " ", text).strip())


def sections(text, level):
    """{heading: body} for every heading of this level, in order, and what comes before the first."""
    mark = "#" * level + " "
    head, out, current = [], [], None
    for line in text.splitlines():
        if line.startswith(mark):
            current = [line[len(mark):].strip(), []]
            out.append(current)
        elif current is None:
            head.append(line)
        else:
            current[1].append(line)
    return head, [(h, "\n".join(b)) for h, b in out]


def find(parts, words):
    """The body of the first section whose plain heading starts with words."""
    for heading, body in parts:
        if plain(heading).lower().startswith(words.lower()):
            return body
    return None


def paragraphs(lines):
    out, cur = [], []
    for line in lines:
        if line.strip():
            cur.append(line.strip())
        elif cur:
            out.append(" ".join(cur)); cur = []
    if cur:
        out.append(" ".join(cur))
    return out


def code_blocks(body):
    blocks, cur = [], None
    for line in (body or "").splitlines():
        if line.strip().startswith("```"):
            if cur is None:
                cur = []
            else:
                blocks.append(cur); cur = None
        elif cur is not None:
            cur.append(line.strip())
    return blocks


def prose(body):
    """The body without its code blocks, as lines."""
    out, inside = [], False
    for line in (body or "").splitlines():
        if line.strip().startswith("```"):
            inside = not inside
            continue
        if not inside:
            out.append(line)
    return out


def items(body):
    """A step as its items in order: ("text", words) for a paragraph or a
    bullet, ("code", [lines]) for a code block (one inside a bullet too)."""
    out, cur, code = [], None, None
    for line in (body or "").splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            if code is None:
                if cur:
                    out.append(("text", " ".join(cur))); cur = None
                code = []
            else:
                out.append(("code", code)); code = None
        elif code is not None:
            code.append(stripped)
        elif not stripped:
            if cur:
                out.append(("text", " ".join(cur))); cur = None
        elif line.startswith("- "):
            if cur:
                out.append(("text", " ".join(cur)))
            cur = [line[2:].strip()]
        elif cur is None:
            cur = [stripped]
        else:
            cur.append(stripped)
    if cur:
        out.append(("text", " ".join(cur)))
    return out


def first_point(body):
    """A step's first paragraph or bullet (where to look: a console path), and
    the command of the code block right after it, when one follows."""
    found = items(body)
    for i, (kind, value) in enumerate(found):
        if kind == "text":
            command = ""
            if i + 1 < len(found) and found[i + 1][0] == "code":
                command = next((ascii_text(l) for l in found[i + 1][1] if l and not l.startswith("#")), "")
            return plain(value), command
    return "", ""


def table(body):
    rows = []
    for line in (body or "").splitlines():
        if line.startswith("|") and not re.match(r"^\|[\s|:-]+\|$", line):
            rows.append([c.strip() for c in line.strip().strip("|").split("|")])
    return rows[1:]


def stems(text):
    return {w[:4] for w in re.findall(r"[a-z0-9]+", text.lower()) if len(w) >= 3 and w not in STOP}


def wrap(text, width, first="", rest=None, lines=0):
    rest = first if rest is None else rest
    out = textwrap.wrap(text, width=max(20, width), initial_indent=first, subsequent_indent=rest,
                        break_on_hyphens=False, break_long_words=False,
                        max_lines=lines or None, placeholder=" ...")
    return out or [first.rstrip()]


def fit(text, width):
    return text if len(text) <= width else text[:max(0, width - 3)] + "..."


def say(style, text):
    sys.stdout.write("%s|%s\n" % (style, text))


def shown_path(path):
    home = os.path.expanduser("~")
    if home and path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def connect_options(defs):
    try:
        doc = json.load(open(os.path.join(os.path.dirname(defs), "help", "exakit.json"), encoding="utf-8"))
        entry = [c for c in doc["commands"] if c["command"] == "connect"][0]
        return ascii_text(entry.get("options") or "")
    except (OSError, ValueError, LookupError):
        return ""


def options(defs, width):
    synopsis = connect_options(defs)
    if synopsis:
        for line in wrap(synopsis, width, "Options:    ", "            "):
            say("D", line)
    say("D", "Every option: exakit help connect")


def readme_point(readme, label):
    """A bullet of the README's "Before you start" that starts with **label**."""
    body = find(readme, "Before you start") or ""
    for point in re.split(r"\n(?=- )", body):
        if point.lstrip("- ").startswith("**" + label):
            text = plain(point.lstrip("- "))
            return text[len(label):].strip()
    return ""


def catalog(defs):
    return json.load(open(os.path.join(defs, "catalog.json"), encoding="utf-8"))["connectors"]


def lookup(defs, word):
    q = re.sub(r"[\s_]+", "-", (word or "").strip().lower())
    for e in catalog(defs):
        if q in [e["id"]] + [a.lower() for a in e.get("aliases", [])]:
            return e
    return None


def load(path):
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        return None


def guide_list(defs, docs, width):
    text = load(os.path.join(docs, "README.md"))
    entries = catalog(defs)
    head, parts = sections(text or "", 2)
    title = next((plain(l[2:]) for l in head if l.startswith("# ")), "")
    say("T", title or "exakit connect: the connectors")
    rows = {}
    for row in table("\n".join(head)):
        if len(row) >= 4:
            rows[plain(row[0])] = row
    col = max(len(e["id"]) for e in entries) + 2
    for e in entries:
        row = rows.get(e["id"])
        if row:
            need = plain(row[2])
            ca = plain(row[3])
            if ca.lower().startswith("yes"):
                extra = re.search(r"\(([^)]*)\)", ca)
                need += "; CA file" + (" (%s)" % extra.group(1) if extra else "")
        else:
            need = ascii_text(e.get("summary", ""))
        for i, line in enumerate(wrap(need, width - col - 2, "", "")):
            say("N", "  " + (e["id"] if i == 0 else "").ljust(col) + line)
    say("N", "")
    say("A", "One connector's guide: exakit connect <connector> --help")
    easiest = find(parts, "Easiest")
    if easiest:
        paras = paragraphs(prose(easiest))
        if paras:
            for line in wrap(plain(re.split(r"(?<=\.)\s", paras[0])[0]), width):
                say("N", line)
    options(defs, width)
    if text is not None:
        say("D", "Full guides: " + shown_path(os.path.join(docs, "README.md")))
    return 0


def settings_block(defs, cid, width):
    """A connector with settings (lakehouse): its catalogs x files choices,
    from connector.json, and how to pick them without the form."""
    try:
        doc = json.load(open(os.path.join(defs, "connectors", cid, "connector.json"), encoding="utf-8"))
    except (OSError, ValueError):
        return
    settings = doc.get("settings")
    if not settings:
        return
    files = settings["files"]
    labels = dict((c["value"], c["label"]) for c in files["choices"])
    say("N", "")
    say("H", "  --set catalog=   and the --set files= it takes (* the default when files is left out)")
    for choice in settings["catalog"]["choices"]:
        valid = files["valid"].get(choice["value"], [])
        default = files["default"].get(choice["value"])
        cells = ", ".join("%s%s (%s)" % (f, "*" if f == default else "", ascii_text(labels[f])) for f in valid)
        text = "%s. Files: %s" % (ascii_text(choice["label"]), cells)
        for i, line in enumerate(wrap(text, max(24, width - 18), "", "")):
            say("N", "  " + (choice["value"] if i == 0 else "").ljust(14) + "  " + line)
    off = [ascii_text(c["label"]) for c in files["choices"] if c.get("disabled")]
    if off:
        say("D", "  " + "; ".join(off))
    login = settings.get("login")
    if login:
        cats = ", ".join(login.get("when", {}).get("catalog", []))
        text = "Login (--set login=..., %s only): %s; default %s." % (
            cats, ", ".join("%s (%s)" % (c["value"], ascii_text(c["label"])) for c in login["choices"]), login["default"])
        for line in wrap(text, width, "  ", "  "):
            say("N", line)
    for line in wrap("Secrets: the catalog's (a token, an OAuth client secret; Glue: the AWS secret key; no catalog: "
                     "the storage secret) on --password-file or --password-stdin; the storage secret beside a catalog "
                     "login (S3 secret key, Azure account key or SAS) on --storage-secret-file. Never as an argument.",
                     width, "  ", "  "):
        say("N", line)
    say("A", "  e.g. exakit connect %s --name sales_lake --set catalog=unity --set files=vended "
             "--set workspace_url=https://dbc-1.cloud.databricks.com --set namespace=main.sales "
             "--password-file ~/token.txt" % cid)


def guide_one(defs, docs, entry, width, shell):
    cid = entry["id"]
    path = os.path.join(docs, cid + ".md")
    text = load(path)
    if text is None:
        say("T", "%s - exakit connect %s" % (ascii_text(entry["name"]), cid))
        say("N", "This kit copy has no guide for %s (%s). Update the kit: exakit update" % (cid, shown_path(path)))
        say("A", "Connect: exakit connect %s" % cid)
        options(defs, width)
        return 0
    head, parts = sections(text, 2)
    title = next((plain(l[2:]) for l in head if l.startswith("# ")), ascii_text(entry["name"]))
    say("T", "%s - exakit connect %s" % (title, cid))
    # The top box: "> **Easiest ...**" and "> **You still need ...**".
    box = paragraphs([l[1:].strip() if l.startswith(">") else "" for l in head if l.startswith(">") or not l.strip()])
    for lead in ("Easiest", "You still need"):
        for para in box:
            if para.startswith("**" + lead):
                for line in wrap(plain(para), width, "", "  ", 3):
                    say("N", line)
    # What it asks for: which fields are required, matched to the steps by their words.
    fields = [(plain(r[0]), plain(r[1]).lower()) for r in table(find(parts, "What exakit connect asks for")) if len(r) >= 2]
    where = find(parts, "Where to find each value")
    rows = []
    network = None
    if where is not None:
        for heading, body in sections(where, 3)[1]:
            need = re.sub(r"^\d+\.\s*", "", plain(heading))
            if re.search(r"\bnetwork\b", need, re.I):
                network = body
                continue
            mark, note = " ", ""
            for label, required in fields:
                if stems(label) & stems(need):
                    if required == "yes":
                        mark = "*"
                    elif required and not required.startswith("no") and not note:
                        note = " (%s)" % required
            rows.append((mark, need + note) + first_point(body))
    if rows:
        col = min(24, max(len(r[1]) for r in rows) + 2)
        right = max(24, width - col - 4)
        say("N", "")
        say("H", "  " + "You need (* required)".ljust(col + 2) + "Where to find it")
        for mark, need, point, command in rows:
            left = wrap(need, col, "", "", 2)
            text_lines = wrap(point, right, "", "", 2) if point else [""]
            for i in range(max(len(left), len(text_lines))):
                l = left[i] if i < len(left) else ""
                r = text_lines[i] if i < len(text_lines) else ""
                say("N", (mark if i == 0 else " ") + " " + l.ljust(col + 2) + r)
            if command:
                say("D", " " * (col + 4) + fit(command, right))
    say("N", "")
    ip = publicip.get()
    if ip:
        for line in wrap("Network: " + ascii_text(re.sub(r"^Tip:\s*", "", publicip.advice(ip))), width, "", "  ", 3):
            say("N", line)
    else:
        readme = sections(load(os.path.join(docs, "README.md")) or "", 2)[1]
        point = readme_point(readme, "Your public IP.")
        if point or network is not None:
            for line in wrap("Network: " + (point or first_point(network)[0]), width, "", "  ", 3):
                say("N", line)
    paste = find(parts, "Connection string you can paste")
    blocks = code_blocks(paste)
    if blocks and blocks[0]:
        say("N", "Paste at the prompt, e.g.:")
        say("A", "  " + ascii_text(blocks[0][0]))
        if shell == "powershell":
            for para in paragraphs(prose(find(parts, "Connect"))):
                if para.startswith("**Windows:**"):
                    first = re.split(r"(?<=\.)\s", plain(para))[0]
                    for line in wrap(first, width, "", "  ", 2):
                        say("N", line)
    settings_block(defs, cid, width)
    say("A", "Connect: exakit connect %s" % cid)
    say("D", "Full guide: " + shown_path(path))
    options(defs, width)
    return 0


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--defs", required=True)
    p.add_argument("--width", type=int, default=80)
    p.add_argument("--shell", default="bash")
    p.add_argument("--exact", action="store_true")
    p.add_argument("connector", nargs="?", default="")
    args = p.parse_args(argv)
    defs = os.path.abspath(args.defs)
    docs = os.path.join(os.path.dirname(os.path.dirname(defs)), "docs", "virtual-schemas")
    width = max(60, min(args.width or 80, 100))
    if not args.connector:
        if args.exact:
            return 10
        return guide_list(defs, docs, width)
    entry = lookup(defs, args.connector)
    if entry is None:
        if args.exact:
            return 10
        say("N", "No connector is named %s; the connectors:" % ascii_text(args.connector))
        guide_list(defs, docs, width)
        return 2
    publicip.start()
    return guide_one(defs, docs, entry, width, args.shell)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
