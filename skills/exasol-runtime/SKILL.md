---
name: exasol-runtime
description: Operate the local Exasol database the starter kit deploys — an Exasol Personal local deployment on macOS, Linux and Windows x86_64 — starting and stopping it, reading its status honestly, and deciding whether it comes back after a reboot. Triggers — "start my Exasol database", "the database is not running", "exakit status says stopped", "connection refused on 8563", "make Exasol start at login", "is my database running", "stop the database", "which Exasol runtime do I have".
---

# The local Exasol runtime

The kit deploys **one local database** and manages it for you. Everything below
is done with `exakit` — never by driving the `exasol` launcher by hand, because
the kit records state in its manifest and hand-driving it makes that record lie.

## The runtime

There is exactly one: an **Exasol Personal** local deployment, put in place by
the `exasol` launcher. Ask the machine rather than guessing at its details:

```bash
exakit info        # the Runtime line, the DSN and the port actually in use
```

| | **Exasol Personal** |
|---|---|
| Where | macOS, native Linux (Podman), WSL 2 (Podman inside the distro), Windows x86_64 (host Podman) |
| Not supported | WSL 1 and Windows arm64 — the installer says so and exits, changing nothing (WSL 2 is supported: it takes the Linux path, with Podman inside the distro) |
| Deployed by | the `exasol` launcher (`exasol install local`) |
| State lives in | `~/.exasol/personal/deployments/default` |
| Extra detail command | `exasol info` |
| Machine minimum | 8 GB RAM, 20 GB disk |

It listens on **`127.0.0.1`** — port **8563** unless the launcher had to pick
another, which `exakit info` reports — connects as admin user **`sys`** with
**TLS using a self-signed certificate**, and keeps its data across restarts.

## Status — and read the exit code, not just the text

```bash
exakit status          # human summary: installed, healthy, datasets loaded
exakit status --json   # one machine-readable object, nothing else on stdout
```

`status` carries its answer in the **exit code**, which is what you should
branch on:

| Exit | Meaning | Do |
|---|---|---|
| `0` | running | carry on |
| `3` | installed but the database is not running | read the status line: `stopped` → `exakit start`; `interrupted` → `exakit repair-runtime` |
| `4` | not installed | run the installer |

**`interrupted` is a third state, and `exakit start` cannot fix it.** After a crash
(SIGKILL, a hard power loss) the launcher records the deployment as interrupted, and every
start attempt afterwards fails identically — as does re-running the installer. Only
`exakit repair-runtime` clears it, and that **rebuilds the deployment and destroys its
data** (bundled datasets are reloaded afterwards; the user's own uploads are not). Ask the
user before running it.

The `--json` object includes `running`, `datasets_loaded` (verified against the database,
not just the manifest), `services`, `steps_completed`, and `remedies` — a map of component
to the exact repair command. Read the remedy from there rather than inferring it.

## Start and stop

```bash
exakit start    # the database AND every installed add-on service
exakit stop     # the add-on services, then the database
```

`exakit start` deploys the database if it has never been deployed, and simply
starts it if it has. Prefer it over re-running the installer when the database
is merely stopped — a re-run is safe and skips the deploy, but `start` is the
direct tool.

**The first deployment usually completes in under 2 minutes** on every
platform, and it holds the foreground while it works. That is not a hang. If
you cannot keep a long foreground command open, have the user run it and tell
you when it finishes, then poll `exakit status`.

## Autostart

```bash
exakit autostart        # show the current state
exakit autostart        # asks, then flips it; EXAKIT_AUTOSTART_CHANGE=1 pre-answers
EXAKIT_AUTOSTART_CHANGE=0 exakit autostart   # scripted: leave it off
```

On by default from a fresh install. The mechanism differs per platform —
launchd on macOS, `systemd --user` on Linux, a Startup entry on Windows — but
the command is the same everywhere.

## When the database will not come up

Work the ladder in order; do not improvise past it:

1. `exakit status` — what does the exit code, and the status line, actually say?
2. `exakit start` — the direct fix for a **stopped** database. If it fails once, read the
   status again rather than running it a second time: an `interrupted` deployment fails
   this way every time, and repeating it is the loop, not the fix.
3. `exakit logs` — lists every log the kit can show, with size and last-updated
   (`--json` for the list and paths). `exakit logs -f <target>` follows one live;
   `exakit logs <target> --path` prints its path.
4. Re-run the installer. It is **safe and resumable** — finished steps are
   skipped, failed ones retried.
5. `exakit repair-runtime` — the last resort, and the *only* thing that clears an
   `interrupted` deployment. It replaces the database and **its data is not
   recoverable**. Ask the user first; pass `--yes` only once they have agreed.

### The error you will hit most

`Connection refused` — as `[Errno 61]` / `[Errno 111]` from the MCP tools, or
`Failed to connect to 127.0.0.1:8563` from exapump — means exactly one thing:
**the database is not running**. Run `exakit start`, confirm with
`exakit status`, then retry. Do not go hunting for config problems first.

## Updating the runtime

A runtime version change is **announced but never applied silently**, because
it touches the deployment:

```bash
exakit version    # every component at once: installed, and what is advertised
```

A MAJOR update is never applied on its own. The update reports that one is
available, takes no destructive action, and points at the Exasol Personal
migration guidance for the new version. Database data is left exactly where it
is. A minor launcher update is offered inline, and its first start afterwards
rebuilds the deployment's VM guest once — several minutes, that once only.

## Guardrails

- **Never drive the runtime underneath the kit.** No `exasol stop` or
  `exasol install local` by hand. The kit's manifest is how `status`,
  `version` and a re-run of the installer know the truth; bypassing it
  makes all three lie.
- **Never print or log the credential files** under
  `~/.exasol-starter-kit/credentials/`. Read them into a command when a command
  needs them; do not echo them into a transcript.
- **Do not invent** ports, paths or launcher flags. The facts
  above came from the machine — get the rest the same way (`exakit info`,
  `exakit status --json`, `exakit logs`).
