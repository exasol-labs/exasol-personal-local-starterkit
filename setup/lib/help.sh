#!/usr/bin/env bash
# help.sh - the kit's help system, rendered from data rather than hardcoded text.
#
# WHY THIS EXISTS
#
# Help used to live in three different places: a heredoc in `usage()`, the
# comment block at the top of `setup/exakit`, and catalog.tsv. Three sources
# drift, and none of them could describe a COMPONENT - only a command. This
# module replaces all three with one document per component (setup/help/*.json)
# plus one for the CLI itself, so `exakit --help`, `exakit help --all`,
# `exakit <component> --help` and `exakit catalog` all read the same data.
#
# WHERE THE DATA COMES FROM
#
# The copy that shipped with this kit (setup/help/), and nothing else.
#
# It used to prefer a copy fetched from the kit repository, so the text could be
# corrected without shipping a kit update. That traded a small benefit for a
# confusing failure: "fetched and fresh" was treated as "better" with no
# comparison against what shipped, so a repository BEHIND the installed kit
# silently downgraded its own help. Someone who installed a kit whose page
# documented a feature could be shown an older page that did not - with nothing
# on screen to say why, and a 24-hour cache making it persist.
#
# Help now matches the code it was installed with, always. Correcting the text
# means shipping it, like every other asset in the kit.

# exakit_help_kit_dir - the documents that shipped with this kit copy.
exakit_help_kit_dir() {
    if [ -d "${_lib_dir:-}/../help" ]; then
        (cd "$_lib_dir/../help" && pwd)
    else
        printf '%s\n' "${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/kit/setup/help"
    fi
}

# exakit_help_ids - every document id this kit knows about, one per line.
# The shipped directory IS the registry: a component exists for help purposes
# exactly when this kit carries a document for it.
exakit_help_ids() {
    _hi_dir="$(exakit_help_kit_dir)"
    [ -d "$_hi_dir" ] || return 1
    for _hi_f in "$_hi_dir"/*.json; do
        [ -f "$_hi_f" ] || continue
        _hi_b="${_hi_f##*/}"
        printf '%s\n' "${_hi_b%.json}"
    done
}

exakit_help_is_id() {
    # -F and --: the topic is a literal name, never a pattern and never an
    # option. Without them `exakit --help --json` reached here with the topic
    # "--help", grep read it as a flag, and the user got grep's own usage
    # block printed at them mid-help-screen.
    exakit_help_ids 2>/dev/null | grep -qxF -- "$1"
}

# exakit_help_doc_local <id> - the document this kit shipped, or nothing.
exakit_help_doc_local() {
    _hdl_ship="$(exakit_help_kit_dir)/$1.json"
    [ -f "$_hdl_ship" ] || return 1
    printf '%s\n' "$_hdl_ship"
}

# exakit_help_doc <id> - kept as the name other code calls; there is only one
# source now, so it is the same answer.
exakit_help_doc() {
    exakit_help_doc_local "$1"
}

# _exakit_help_docs_args - "id=path" for every document this kit carries.
_exakit_help_docs_args() {
    exakit_help_ids 2>/dev/null | while IFS= read -r _hda_id; do
        [ -n "$_hda_id" ] || continue
        _hda_path="$(exakit_help_doc_local "$_hda_id" 2>/dev/null)" || continue
        printf '%s=%s\n' "$_hda_id" "$_hda_path"
    done
}

# exakit_help_render <mode> [arg] - every screen this module draws.
exakit_help_render() {
    _hr_mode="$1"
    _hr_arg="${2:-}"
    exakit_can_run_python || {
        # No python: fall back to the shipped exakit document, read as text, so
        # help still says something useful instead of dying.
        _hr_ship="$(exakit_help_kit_dir)/exakit.json"
        [ -f "$_hr_ship" ] && printf 'exakit - help data at %s (python3 is needed to render it)\n' "$_hr_ship"
        return 1
    }
    if [ -t 1 ] && [ "${EXAKIT_HELP_PLAIN:-0}" != "1" ]; then _hr_color=1; else _hr_color=0; fi
    _hr_width="${COLUMNS:-0}"
    case "$_hr_width" in ''|*[!0-9]*) _hr_width=0 ;; esac
    if [ "$_hr_width" -lt 40 ] && command -v tput >/dev/null 2>&1; then
        _hr_width="$(tput cols 2>/dev/null || echo 0)"
        case "$_hr_width" in ''|*[!0-9]*) _hr_width=0 ;; esac
    fi
    [ "$_hr_width" -lt 40 ] && _hr_width=80

    # shellcheck disable=SC2046
    run_python - "$_hr_mode" "$_hr_color" "$_hr_width" "$_hr_arg" \
        $(_exakit_help_docs_args | tr '\n' ' ') <<'EXAKIT_HELP_RENDER_PY'
import json, sys, textwrap

mode, color, width, arg = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3]), sys.argv[4]
docs = {}
for pair in sys.argv[5:]:
    if "=" not in pair:
        continue
    key, path = pair.split("=", 1)
    try:
        docs[key] = json.load(open(path, encoding="utf-8"))
    except Exception:
        pass

WRAP = min(width, 100)

if color:
    CY, CYB, DIM, B, GN, YL, R = ("\033[36m", "\033[1;36m", "\033[2m",
                                  "\033[1m", "\033[1;32m", "\033[33m", "\033[0m")
else:
    CY = CYB = DIM = B = GN = YL = R = ""

def out(text=""):
    sys.stdout.write(text + "\n")

def para(text, indent="  ", first=None):
    for line in textwrap.wrap(text, width=WRAP - len(indent)) or [""]:
        out((first if first is not None else indent) + line)
        first = None

def rule():
    out("  %s%s%s" % (CY, "-" * (min(WRAP, 72) - 2), R))

def header(title, subtitle=""):
    out()
    rule()
    out("   %s%s%s%s" % (CYB, title, R, ("  %s%s%s" % (DIM, subtitle, R)) if subtitle else ""))
    rule()

def section(title):
    out()
    out("  %s%s%s" % (B, title, R))
    out()

def kv(key, value, pad=16):
    para(value, indent=" " * (4 + pad), first="    %s%-*s%s" % (GN, pad, key, R))

def cmd_line(prefix, command, options, summary, pad=22, indent="    "):
    label = ("%s %s" % (prefix, command)).strip() if prefix else command
    if options:
        label = "%s %s" % (label, options)
    if len(label) <= pad and summary:
        para(summary, indent=" " * (len(indent) + pad + 1),
             first="%s%s%-*s%s " % (indent, GN, pad, label, R))
    else:
        out("%s%s%s%s" % (indent, GN, label, R))
        if summary:
            para(summary, indent=indent + "  ")

def commands_of(doc, include_hidden=False):
    """The commands a document lists. An entry marked "hidden": true still has
    a page (`exakit <cmd> --help` finds it through find_command) but is left
    off the overview, `--all`, the catalogue and the JSON surfaces: it exists
    for repair, not for discovery. skills-install is the first such command -
    the installer places the skills itself and `exakit update` fetches a newer
    set, so advertising it only sent readers to a step they did not need."""
    entries = doc.get("commands", []) or []
    if include_hidden:
        return entries
    return [entry for entry in entries if not entry.get("hidden")]

def with_hidden_marked(doc):
    """A copy of a document keeping its hidden commands, each carrying
    "hidden": true.

    THE JSON SURFACES MARK; THE SCREENS OMIT. AGENTS.md says of catalog --json:
    "every supported command (a handful of internal upgrade paths are marked
    hidden and are not for you to call)" - but the dumps deleted the entries
    outright, so no row carried a hidden key and three dispatchable commands
    were simply absent. That is not a cosmetic gap: `exakit skills --json`
    answers a machine with {"status": "missing", "next": "exakit
    skills-install"}, and catalog --json denied that command existed. An agent
    holding both documents had to conclude one of them was lying.

    The human surfaces are unchanged - these commands exist for repair, not for
    discovery, and still do not belong on the overview or in --all."""
    copy = dict(doc)
    copy["commands"] = [dict(e, hidden=bool(e.get("hidden")))
                        for e in commands_of(doc, include_hidden=True)]
    return copy

# Every binary the kit documents. A command whose first word is one of these is
# already spelled out ("exakit start" on the runtime page); anything else is a
# bare subcommand and gets its document's prefix put in front.
KNOWN_TOOLS = ("exakit", "exapump", "exasol", "dash-server",
               "exasol-json-tables", "exasol-mcp-server", "exasol-mcp-server-http")

def invocation(doc_id, entry):
    """The command as a reader would actually type it."""
    command = (entry.get("command") or "").strip()
    parts = command.split()
    if parts and parts[0] in KNOWN_TOOLS:
        return command
    prefix = (docs.get(doc_id) or {}).get("invocation_prefix") or doc_id
    return ("%s %s" % (prefix, command)).strip()

def invocation_with_options(doc_id, entry):
    label = invocation(doc_id, entry)
    options = entry.get("options") or ""
    if options:
        label = "%s %s" % (label, options)
    return label

def find_command(doc, name):
    name = name.strip().lower()
    exact, prefix = [], []
    for entry in commands_of(doc, include_hidden=True):
        key = entry.get("command", "").lower()
        if key == name:
            exact.append(entry)
        elif key.startswith(name + " ") or name.startswith(key + " "):
            prefix.append(entry)
    return exact or prefix

def render_command_detail(doc, entry, prefix=""):
    label = ("%s %s" % (prefix, entry.get("command", ""))).strip()
    opts = entry.get("options", "")
    out()
    out("  %s%s%s%s" % (B, label, (" " + opts) if opts else "", R))
    out()
    para(entry.get("description") or entry.get("summary", ""), indent="    ")
    if entry.get("warning"):
        out()
        para(entry["warning"], indent="    ", first="    %s!%s " % (YL, R) + "")
    if entry.get("exit_codes"):
        out()
        out("    %sExit codes%s" % (DIM, R))
        for code in sorted(entry["exit_codes"], key=lambda c: int(c)):
            out("      %s%s%s  %s" % (GN, code, R, entry["exit_codes"][code]))
    if entry.get("environment"):
        out()
        out("    %sEnvironment%s" % (DIM, R))
        for line in entry["environment"]:
            para(line, indent="        ", first="      " + "")
    if entry.get("examples"):
        out()
        out("    %sExamples%s" % (DIM, R))
        for example in entry["examples"]:
            out("      %s%s%s" % (CY, example, R))
    out()

# ---------------------------------------------------------------- overview --
def render_overview():
    doc = docs.get("exakit")
    if not doc:
        out("No help data found. Reinstall the kit or run: exakit update")
        return 1
    header(doc.get("title", "exakit"), doc.get("tagline", ""))
    # Both optional, and the blank line belongs to the prose rather than to the
    # header: section() opens with its own blank, so emitting one here for a
    # document that has no role leaves two, and para("") would draw a line of
    # spaces on top of that (textwrap.wrap("") is empty, and the `or [""]`
    # fallback prints the indent).
    if doc.get("role"):
        out()
        para(doc["role"], indent="   ")

    if doc.get("quickstart"):
        section("Start here")
        for number, step in enumerate(doc["quickstart"], 1):
            out("    %s%s.%s %s" % (B, number, R, step.get("step", "")))
            if step.get("run"):
                out("       %s%s%s" % (CY, step["run"], R))
            if step.get("note"):
                para(step["note"], indent="       %s" % DIM)
                if color:
                    sys.stdout.write(R)
        out()

    by_name = {c.get("command"): c for c in commands_of(doc)}
    # First group wins, exactly as render_all already does. A command that reads
    # naturally in two groups (mcp-setup belongs to both "Get started" and "AI
    # clients") was printed twice, so the one screen whose whole job is "find the
    # command you want" answered the same question in two places. The section
    # header is held back until a row actually survives, so a group whose every
    # command was already listed does not leave an empty heading behind.
    seen = set()
    for group in doc.get("groups", []):
        rows = []
        for name in group.get("commands", []):
            entry = by_name.get(name)
            if not entry or name in seen:
                continue
            seen.add(name)
            rows.append(entry)
        if not rows:
            continue
        section(group.get("title", ""))
        for entry in rows:
            cmd_line("", invocation("exakit", entry), "", entry.get("summary", ""), pad=24)

    # NO per-component command dump here, and no trailing pointer line. This
    # screen is the map, not the atlas: it used to run past a screenful by
    # printing every command of every component, which made the one thing it is
    # for - finding the command you want - harder. The component pages moved to
    # `exakit help --all`, which is where a reader who wants everything goes,
    # and `exakit catalog` is already listed above under Reference.
    out()
    if color:
        sys.stdout.write(R)
    out()
    return 0

# --------------------------------------------------------------------- all --
def render_all():
    doc = docs.get("exakit")
    if not doc:
        return 1
    header("exakit - every command", doc.get("tagline", ""))
    by_name = {c.get("command"): c for c in commands_of(doc)}
    seen = set()
    for group in doc.get("groups", []):
        section(group.get("title", ""))
        for name in group.get("commands", []):
            entry = by_name.get(name)
            if not entry or name in seen:
                continue
            seen.add(name)
            cmd_line("", invocation_with_options("exakit", entry), "",
                     entry.get("summary", ""), pad=30)
    rest = [c for c in commands_of(doc) if c.get("command") not in seen]
    if rest:
        section("Other")
        for entry in rest:
            cmd_line("", invocation_with_options("exakit", entry), "",
                     entry.get("summary", ""), pad=30)

    # The per-component command lists, which the overview no longer carries.
    # THIS is "every command", so this is where they belong - the overview was
    # showing more than --all did, which is backwards.
    others = [key for key in sorted(docs) if key != "exakit"]
    if others:
        section("Components")
        for key in others:
            sub = docs[key]
            out("    %s%s%s  %s%s%s" % (B, key, R, DIM, sub.get("tagline", ""), R))
            for entry in commands_of(sub):
                cmd_line("", invocation_with_options(key, entry), "",
                         entry.get("summary") or entry.get("description", ""),
                         pad=34, indent="      ")
            out()
    out()
    para("Detail for one command: exakit <command> --help", indent="  %s" % DIM)
    if color:
        sys.stdout.write(R)
    out()
    return 0

# --------------------------------------------------------------- component --
def render_component(key):
    doc = docs.get(key)
    if not doc:
        out("  No help document for '%s'." % key)
        out("  Known: %s" % ", ".join(sorted(docs)))
        return 1
    header(doc.get("title", key), doc.get("tagline", ""))
    out()
    para(doc.get("role", ""), indent="   ")

    facts = [("Repository", doc.get("repo")), ("Package", doc.get("package")),
             ("Binary", doc.get("binary")), ("Runs via", doc.get("runs_via")),
             ("Image", doc.get("image")), ("Config", doc.get("config")),
             ("Profile", doc.get("profile")), ("Venv", doc.get("venv")),
             ("Python", doc.get("python")), ("URL", doc.get("url")),
             ("Control plane", doc.get("control_plane")),
             ("DSN", doc.get("dsn")), ("Admin user", doc.get("admin_user")),
             ("DB user", doc.get("db_user")),
             ("Deployment", doc.get("deployment_dir")),
             ("Platforms", doc.get("platforms")), ("Requires", doc.get("requires")),
             ("Installed by", doc.get("installed_by")), ("Docs", doc.get("docs"))]
    facts = [(k, v) for k, v in facts if v]
    if facts:
        section("At a glance")
        for key_name, value in facts:
            kv(key_name, value)

    if doc.get("warning"):
        section("Important")
        para(doc["warning"], indent="    ", first="    %s!%s " % (YL, R))

    if doc.get("boundary"):
        section("The read-only boundary")
        para(doc["boundary"], indent="    ")

    if doc.get("clients"):
        section("Supported clients")
        para(", ".join(doc["clients"]), indent="    ")

    if doc.get("quickstart"):
        section("How to start")
        for number, step in enumerate(doc["quickstart"], 1):
            out("    %s%s.%s %s" % (B, number, R, step.get("step", "")))
            if step.get("run"):
                out("       %s%s%s" % (CY, step["run"], R))
            if step.get("note"):
                para(step["note"], indent="       ")

    if commands_of(doc):
        section("Commands")
        for entry in commands_of(doc):
            cmd_line("", invocation_with_options(key, entry), "",
                     entry.get("summary") or entry.get("description", ""), pad=34)

    if doc.get("snippets"):
        # Blank line BETWEEN blocks, not after the last one: several examples
        # run together into one wall otherwise, and the titles stop reading as
        # headings for the code under them.
        section("Examples")
        for index, snippet in enumerate(doc["snippets"]):
            if index:
                out()
            out("    %s%s%s" % (B, snippet.get("title", ""), R))
            for line in snippet.get("code", "").split("\n"):
                out("      %s%s%s" % (CY, line, R))

    if doc.get("environment"):
        section("Environment")
        for item in doc["environment"]:
            kv(item.get("name", ""), item.get("effect", ""), pad=26)

    if doc.get("notes"):
        section("Good to know")
        for note in doc["notes"]:
            para(note, indent="      ", first="    %s-%s " % (DIM, R))

    if doc.get("troubleshooting"):
        section("If something goes wrong")
        for item in doc["troubleshooting"]:
            out("    %s%s%s" % (B, item.get("symptom", ""), R))
            para(item.get("remedy", ""), indent="      ")

    if doc.get("see_also"):
        section("See also")
        para(", ".join(doc["see_also"]), indent="    ")
    out()
    return 0

# ----------------------------------------------------------------- command --
def render_command(name):
    doc = docs.get("exakit")
    matches = find_command(doc, name) if doc else []
    if matches:
        for entry in matches:
            render_command_detail(doc, entry, prefix="exakit")
        return 0
    for key in sorted(docs):
        if key == "exakit":
            continue
        found = find_command(docs[key], name)
        if found:
            for entry in found:
                render_command_detail(docs[key], entry)
            out("  %sFull reference: exakit %s --help%s" % (DIM, key, R))
            out()
            return 0
    if name in docs:
        return render_component(name)
    out()
    out("  No help entry for '%s'." % name)
    out("  Try: exakit catalog %s   or   exakit help --all" % name)
    out()
    return 1

# ----------------------------------------------------------------- catalog --
def catalog_rows(include_hidden=False):
    rows = []
    for key in sorted(docs):
        doc = docs[key]
        tool = "exakit" if key == "exakit" else key
        for entry in commands_of(doc, include_hidden=include_hidden):
            command = entry.get("command", "")
            hidden = bool(entry.get("hidden"))
            # A component document may list a command that belongs to another
            # tool (exakit start on a runtime page); keep the tool it names.
            parts = command.split()
            if parts and parts[0] in ("exakit", "exapump", "exasol") and key != parts[0]:
                rows.append({"tool": parts[0], "command": " ".join(parts[1:]),
                             "options": entry.get("options", ""),
                             "description": entry.get("summary") or entry.get("description", ""),
                             "source": key, "hidden": hidden})
            else:
                rows.append({"tool": tool, "command": command,
                             "options": entry.get("options", ""),
                             "description": entry.get("summary") or entry.get("description", ""),
                             "source": key, "hidden": hidden})
    # Dedupe on (tool, command) WITHOUT options. Keying on options too let the
    # same command through twice whenever two documents spelled its options
    # differently: exakit.json lists `status [--json | -j]` while
    # dash-server.json mentions a bare `exakit status`, and the catalogue
    # printed both. When that happens the tool's OWN document wins - a
    # component page describing `exakit status` is contextual rephrasing, not
    # the canonical description of the command.
    at, unique = {}, []
    for row in rows:
        key = (row["tool"], row["command"])
        if key not in at:
            at[key] = len(unique)
            unique.append(row)
            continue
        kept = unique[at[key]]
        if row["source"] == row["tool"] and kept["source"] != kept["tool"]:
            unique[at[key]] = row
    return unique

def render_catalog(search):
    rows = catalog_rows()
    if search:
        needle = search.lower()
        rows = [r for r in rows if needle in
                (" ".join([r["tool"], r["command"], r["options"], r["description"]])).lower()]
    header("command catalog", ("results for \"%s\"" % search) if search else
                              "exakit - exapump - exasol - components")
    if not rows:
        out()
        out("  %sNo commands match \"%s\".%s  Try: exakit catalog mcp" % (DIM, search, R))
        out()
        return 1
    # GROUP by tool, do not merely break on a change of tool. The rows arrive
    # in help-document order and nearly every component document contributes
    # `exakit ...` commands, so a run-length break printed the "exakit" heading
    # once per component - five times on a full install, interleaved with the
    # component sections. Collect first, then print one section per tool.
    grouped = {}
    for row in rows:
        grouped.setdefault(row["tool"], []).append(row)
    tools = sorted(grouped)
    if "exakit" in tools:                      # the kit's own command first
        tools.remove("exakit")
        tools.insert(0, "exakit")
    for tool in tools:
        section(tool)
        entries = grouped[tool]
        # NAME AND PURPOSE ONLY, sorted, with the column sized to this section.
        #
        # The option syntax used to ride along in the label, and a third of the
        # rows were then too long for a fixed 26-column gutter -- so they broke
        # onto a second line and the descriptions stopped lining up. A catalog
        # is for scanning down; a ragged one is the one thing it must not be.
        # The full signature is one command away (`exakit help <component>`),
        # and SEARCH still matches on the option text -- only the display drops
        # it. Sorted because the rows arrive in help-document order, which put
        # `update dash-server` between `logs` and `version`.
        pad = max([len(r["command"]) for r in entries] + [12])
        pad = min(pad, 30)
        for row in sorted(entries, key=lambda r: r["command"]):
            cmd_line("", row["command"], "", row["description"], pad=pad)
    out()
    if color:
        sys.stdout.write(R)
    out()
    return 0

def render_json(which):
    # Shape kept compatible with the original `exakit catalog --json`: one
    # object carrying a "commands" array of tool/command/options/description.
    rows = catalog_rows(include_hidden=True)
    for row in rows:
        row["invocation"] = ("%s %s" % (row["tool"], row["command"])).strip()
    if which in ("", "all"):
        payload = {"schema_version": 1, "search": None, "count": len(rows),
                   "commands": rows, "documents": {k: with_hidden_marked(d) for k, d in docs.items()}}
    elif which in docs:
        payload = with_hidden_marked(docs[which])
    else:
        needle = which.lower()
        hit = [r for r in rows if needle in
               (" ".join([r["tool"], r["command"], r["options"], r["description"]])).lower()]
        payload = {"schema_version": 1, "search": which, "count": len(hit),
                   "commands": hit}
    print(json.dumps(payload, indent=2))
    return 0

if mode == "overview":
    sys.exit(render_overview())
elif mode == "all":
    sys.exit(render_all())
elif mode == "component":
    sys.exit(render_component(arg))
elif mode == "command":
    sys.exit(render_command(arg))
elif mode == "catalog":
    sys.exit(render_catalog(arg))
elif mode == "json":
    sys.exit(render_json(arg))
else:
    sys.exit(render_overview())
EXAKIT_HELP_RENDER_PY
}
