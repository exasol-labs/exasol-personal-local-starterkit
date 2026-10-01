---
name: dash-server
addon: dash-server
description: Build and operate live dashboards on the local Exasol database with the dash-server add-on — an agent-operated Dash hosting server the AI drives through its MCP control plane while the user opens a browser URL. Covers installing it from the marketplace, starting and stopping it as a kit service, the port it serves on, how the control plane is registered with AI clients as an MCP server named dash-server, and diagnosing a control plane that answers while the dashboards page does not. Triggers — "build me a dashboard", "chart this", "plot this data", "make a graph from this table", "visualize this Exasol data", "install dash-server", "dash-server is not running", "port 5100", "my dashboard page is blank or 500", "deploy a dashboard on my database", "I do not see the dash-server MCP tools", "register dash-server with my AI client".
---

# dash-server — agent-built dashboards

`dash-server` is a **marketplace add-on**: an agent-operated Dash hosting
server for Exasol-backed dashboards. The division of labour is the point —
**you build and deploy dashboards through its MCP control plane; the user just
opens a URL in a browser.**

## Install it (it is never installed by default)

```bash
EXAKIT_MARKETPLACE_ADDONS=dash-server exakit marketplace
```

Interactively, `exakit marketplace` lists it with Space to select and Enter to
install. Nothing in the kit's setup flow installs it for you.

## The two endpoints

| Endpoint | For | Default |
|---|---|---|
| Dashboards UI | the **user**, in a browser | `http://127.0.0.1:5100` |
| MCP control plane | **you**, the agent (Streamable HTTP) | `http://127.0.0.1:5100/mcp`, registered as `dash-server` |

`5100` is only the default. If something else already holds that port, the
install **moves to the next free one and records it** — so read the real port
from the machine rather than assuming:

```bash
exakit status --json    # .urls["dash-server"] is the full URL; .services["dash-server"] is running / stopped
exakit info --json      # .components.dash_server.port — the recorded port
```

The plain `exakit info` panel does **not** carry the port; it is in the JSON,
and `status --json` carries the whole URL ready to hand to the user.

Move it deliberately with:

```bash
EXAKIT_DASH_SERVER_PORT=<port> exakit update
```

## The control plane is a registered MCP server

You do not hand-roll a transport over `/mcp`. Whenever the add-on is installed,
`exakit mcp-setup` registers the control plane as a normal MCP server named
**`dash-server`** — Streamable HTTP at `http://127.0.0.1:<port>/mcp`, the port
read from the same recorded value every other dash-server command uses. Its
tools then appear in your session alongside the `exasol` ones.

```bash
exakit mcp-setup     # writes the exasol entry, and the dash-server one
```

Which clients get it: **Cursor**, **Claude Code**, **Codex**, **GitHub Copilot
(VS Code)**, **Gemini CLI**, **OpenCode** and **Continue**. **Claude Desktop is
the one left out** — its config file knows only `command`/`args`, and the app
takes remote MCP servers through its own Connectors settings instead — so setup
prints one note naming the URL, not a warning, and the run is not affected by it.

**The client must restart or reload before the tools appear.** The same rule as
the `exasol` server, and the same trap: if *you* just ran `exakit mcp-setup`,
your own process has no `dash-server` tools this session. Drive the endpoint over
HTTP for the rest of it, and expect the tools next session.

## Running it

dash-server is a long-running HTTP process, so the kit treats it exactly like
the database:

```bash
dash-server          # the launcher, starts it directly
exakit start         # the database AND every installed service, including this
exakit stop
exakit status        # running | stopped | not installed
exakit autostart     # asks, then flips it; EXAKIT_AUTOSTART_CHANGE=1 pre-answers
exakit logs dash-server
```

Prefer `exakit start` / `exakit stop` when the user is managing the kit as a
whole; the bare `dash-server` launcher is for starting just this one thing.

## What it connects to

The launcher bootstraps the server against the kit's local database using the
**dedicated read-only MCP user** — dashboards read, they do not write, the same
least-privilege posture as the MCP server itself. Credentials are supplied by
the launcher at run time from the kit's credential files; they are never baked
into generated files, and you must never print them.

## Diagnosing

Work these in order:

1. **`exakit status`** — is it `running`, `stopped`, or is the port held by
   something else? Status distinguishes "stopped" from "another process holds
   the port", and those need different fixes.
2. **Port held by a foreign process.** The kit will not fight for it and will
   not touch a process it does not own. Either stop that process, or move
   dash-server: `EXAKIT_DASH_SERVER_PORT=<port> exakit update`.
3. **`exakit logs dash-server`** — the server's own log.
4. **`exakit update`** — doubles as the repair command.

### The specific failure worth knowing

The control plane and the dashboards page can fail **independently**. It is
possible for `/mcp` to answer correctly while the browser page returns a
`500` — typically a stale process still running from before an update, serving
templates it never re-read.

Symptom: agents can drive it fine over MCP, the user sees an error page. Fix:

```bash
exakit stop && exakit start        # restart it
# or
exakit update          # the repair path
```

If the control plane answers but the page does not, say so plainly rather than
reporting the add-on as healthy — the user's half is the broken half.

## Guardrails

- **Do not hand-manage the process.** No manual `kill`, no starting a second
  instance to "test" the port — the kit tracks the pid and the recorded port,
  and a second instance just fails to bind.
- **Dashboards read; they do not write.** The connection is the read-only user
  by design. Do not reconfigure it to the admin user to make something work.
- **Never print or log** the credential files under
  `~/.exasol-starter-kit/credentials/`.
- **Report the user-facing state honestly.** "The MCP control plane answers" is
  not the same as "the dashboard works" — verify the page the user will open.
- **Do not invent** dash-server MCP tool names or REST paths. Connect to the
  control plane and discover what it offers.
