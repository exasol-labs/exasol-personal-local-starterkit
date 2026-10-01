---
name: exasol-mcp
description: Connect AI clients to the local Exasol database over MCP and keep that connection healthy — running mcp-setup for Claude, Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode and Continue, diagnosing with mcp-doctor, repairing config drift, and understanding the dedicated read-only database user that makes MCP querying safe. Triggers — "connect my AI to Exasol", "set up MCP", "my assistant cannot see the database", "mcp-doctor reports problems", "the exasol MCP server is missing", "repair my MCP config", "which AI clients are supported", "is the MCP user really read-only".
---

# MCP — connecting AI clients to the database

MCP is how an AI client queries the local Exasol database. The kit configures
the client for you, provisions a least-privilege database user for it, and
gives you diagnostics for when it drifts.

## The commands

```bash
exakit mcp-setup              # configure MCP in supported clients (the main one)
exakit mcp-doctor             # diagnose problems; --json for raw per-client results
exakit mcp-status [clients]   # managed MCP state for every supported client
exakit mcp-doctor [clients]   # check the configured clients and repair what drifted
```

Start with `mcp-doctor`. It checks the **database is running first**, so a
stopped database is diagnosed as "run `exakit start`" (exit `3`) rather than
failing deep inside a user-creation step and blaming the wrong subsystem.

Exit codes on `mcp-doctor`: `0` healthy, `3` database not running, `4` kit not
installed.

## Supported clients — and how to name them

Eight clients are supported:

```
claude_desktop  claude_code  cursor  codex
vscode_copilot  gemini_cli   opencode  continue
```

Interactively, `exakit mcp-setup` presents a **checkbox multi-select**. Clients
already connected, or not installed on this machine, are greyed out with the
reason and cannot be picked; **every selectable client is pre-selected**, so
Enter accepts and Cancel backs out.

Non-interactively — which is how *you* should drive it — answer with names:

```bash
EXAKIT_MCP_CLIENTS=claude,codex exakit mcp-setup
```

| Value | Means |
|---|---|
| `claude` | the desktop app **and** the Claude Code CLI |
| `claude_desktop` / `claude_code` | just one of them |
| `copilot` / `gemini` | aliases for `vscode_copilot` / `gemini_cli` |
| `all` | every supported client found |
| `skip` | configure none now |

**Always use names, never menu numbers** — numbers change between releases.

`exakit mcp-setup` edits the selected client config files directly, taking a
backup of each first (backups live under the kit's `mcp/` directory; the live
configs stay inside each client's own config file — `exakit mcp-status` lists
where). **The user must restart or reload the client afterwards.**

### Two managed entries, not one

Setup writes an entry per server the kit owns. Always **`exasol`** — the
read-only database server this skill is about. And, when the **dash-server**
add-on is installed, a second entry named **`dash-server`** for that add-on's
MCP control plane (Streamable HTTP on the port dash-server recorded). A second
managed entry in a client config is expected, not drift.

Claude Desktop is left out of the `dash-server` entry — its config file cannot
express a remote MCP server; the app takes those through its own Connectors
settings — and that is printed as a note, never a failure of the run. Everything about that entry lives in the `dash-server`
skill; the rest of this page is the database path.

## What the connection actually is

After setup, the client starts an MCP server named **`exasol`** on demand over
stdio. It is **not** a background service — nothing is listening between calls.

The login is a **dedicated, read-only database user**. It can read every schema
in the database but cannot write, and that limit is **enforced by the database**,
not by trust or by prompt wording.

### Prove the boundary rather than asserting it

Two layers stop a write, and only one of them is load-bearing:

1. The **MCP tool gate** rejects a statement that does not *begin* with SELECT,
   before it reaches the database. The message `The query is invalid or not a
   SELECT statement` comes from the tool, not the engine. It is a keyword check,
   not a parser: `SELECT 1; DROP TABLE T` passes it and reaches the engine, which
   refuses it for its own reasons. Treat this as a typo-catcher, never as the
   boundary.
2. Beneath it, the **privilege gate** — enforced by the database, and the layer
   that actually holds no matter what got through. Run this as the MCP user any
   time:

```sql
SELECT PRIVILEGE FROM SYS.EXA_USER_SYS_PRIVS
```

It returns exactly `CREATE SESSION`, `SELECT ANY TABLE`, `USE ANY SCHEMA` — no
write privilege exists to misuse.

> Use that system table. The natural guess `EXA_SESSION_PRIVILEGES` does not
> exist and will error.

## Diagnosing "my assistant cannot see the database"

In this order:

1. **Is the database up?** `exakit status` (exit `3` = not running). The remedy is
   `exakit start` for `stopped` — but for `interrupted` it is `exakit repair-runtime`,
   because a start cannot succeed in that state. `status --json` puts the right one in
   `remedies.database`; use that rather than assuming.
2. **Is MCP configured, and does the server actually run?** `exakit mcp-doctor` — it names
   the problem per client, and it starts the configured server and completes an MCP
   handshake, so it catches a missing `uvx` or a package that will not resolve instead of
   reporting a well-formed config entry as `connected`.
3. **Was the client restarted?** A config change does not reach a running
   client. This is the single most common cause — and if *you* ran the setup, it
   applies to you: your own MCP tools appear only after your process restarts.
   Use `exakit sql` in the meantime.
4. **Has the config drifted?** `exakit mcp-doctor` puts it back to the
   known-good state — a deleted entry, a loosened file mode — and re-checks; each
   finding names the client it is about, and only that client reads
   `needs_attention`. `mcp-doctor --json` only *reports* (its `remedy` names the
   repairing form); run the plain command to repair, which also acts on a
   warning it can fix, such as a loosened file mode. A client that is gone from
   the machine but still has the kit's entries is `configured_client_missing`:
   `exakit mcp-remove <client>` takes the entries out and forgets them. `exakit mcp-setup` takes no
   options — name clients with `EXAKIT_MCP_CLIENTS=...` — and offers a client
   again once its file no longer holds the kit's entry.
5. **Read the MCP tool's error for what it hides.** The server masks the engine:
   `A database error occurred. Please try again later or contact your
   administrator` almost always means the database is not running — run
   `exakit status --json` and follow its `remedy`, do not retry. `The query is
   invalid or not a SELECT statement` for a statement that *is* a `SELECT` means
   the server's gate refused it before the engine saw it: `SELECT TOP n` (use
   `LIMIT n`), a second statement, or a leading `--` comment line.
6. Still stuck → `exakit logs`, then re-run the installer (safe and resumable).

For scripted checks, `exakit mcp-doctor --json` prints the raw per-client
result and nothing else on stdout.

## The server itself

The client runs the server on demand as `uvx exasol-mcp-server@<version>`. An
HTTP mode also exists (`exasol-mcp-server-http --host <h> --port <p>`) but the
kit configures **stdio**, which is what the supported clients expect.

Update it like any other component:

```bash
exakit version    # the mcp row shows what is installed and what is advertised
exakit update
```

## Guardrails

- **Read-only means read-only.** Never try to satisfy a write request through
  the MCP path, and never fall back to `exapump -p starter-kit` (which connects
  as **admin** and is *not* sandboxed) to get around an MCP rejection.
- **Do not hand-edit client config files.** `mcp-setup` and `mcp-doctor` own
  them and keep backups; a hand edit is what `mcp-doctor` will later report as
  drift.
- **Never print or log** the password files under
  `~/.exasol-starter-kit/credentials/` — including the MCP user's.
- **Do not invent** client ids, config paths or MCP tool names. `exakit
  mcp-status` lists the real locations.
