---
name: exasol-runtime
description: Operate the local Exasol database the starter kit deploys — an Exasol Personal local deployment on macOS, Linux and Windows x86_64 — starting and stopping it, reading its status honestly, noticing a database clock left behind by a sleeping computer, and deciding whether it comes back after a reboot. Triggers — "start my Exasol database", "the database is not running", "exakit status says stopped", "connection refused on 8563", "make Exasol start at login", "is my database running", "stop the database", "which Exasol runtime do I have", "the database time is wrong", "certificate not yet valid", "status shows a Clock row", "what is starter-kit-local", "exasol status does not show the kit's database".
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
| Where | macOS (its own VM runner), native Linux and WSL 2 (Docker Engine 29+ or Podman, inside the distro for WSL), Windows x86_64 (Docker Desktop or host Podman). The engine is chosen at the first deploy - Docker when usable, else Podman, `EXAKIT_CONTAINER_ENGINE` names one - and the deployment keeps it; the kit records it as `runtime.engine` in its manifest |
| Not supported | WSL 1 and Windows arm64 — the installer says so and exits, changing nothing (WSL 2 is supported: it takes the Linux path, with Docker or Podman inside the distro; Podman there, and Podman's machine on Windows, needs WSL 2.7 or newer unless Podman uses its iptables firewall driver: the kit checks before a fresh deploy or a replace, not before `exakit update`, and a start that then fails on nftables names `wsl --update`, never `repair-runtime`) |
| Deployed by | the `exasol` launcher (`exasol install local`) |
| The deployment | always **`starter-kit-local`**, the kit's own deployment next to anything of the user's |
| State lives in | `~/.exasol/launcher/deployments/starter-kit-local` (Windows: `%LOCALAPPDATA%\exasol\launcher\deployments\starter-kit-local`). Next to the user's own Exasol Personal 2.4, or a release newer than 2.5, on macOS and Linux, the kit runs its own launcher with a home folder of its own under `~/.exasol-starter-kit/personal/`, and the database lives there. `exakit info --json` names the folder (`runtime.deployment_dir`) and the launcher (`runtime.launcher`). A kit 0.3.0 database (`~/.exasol/personal/deployments/default`) is renamed to `starter-kit-local` by `exakit update` and moves to the new folder: the 2.5.0 launcher moves it, or the kit does, into its own folder, when the user's own 2.4 ran it on macOS or Linux. The kit follows both, so never move or rename the folder by hand |
| Extra detail command | `exakit info`. The launcher's own is `exakit exasol info -d starter-kit-local`. `exasol status` typed by hand looks at the launcher's `default` deployment, which is not the kit's |
| Machine minimum | 8 GB RAM, 20 GB disk |

It listens on **`127.0.0.1`** — port **8563**, or the next free port when another
Exasol uses it, which `exakit info` reports — connects as admin user **`sys`** with
**TLS using a self-signed certificate**, and keeps its data across restarts.

## Whose database it is

`exakit status --json` → `runtime.ownership` says whose `starter-kit-local` this is:

| `runtime.ownership` | What it is | What the kit may do |
|---|---|---|
| `kit` | the kit deployed it | everything, and `exakit uninstall` deletes it with its data |
| `user` | a database of the user's, picked in the install's one question (or one kit 0.3.0 was allowed to use), renamed to `starter-kit-local` | start, stop, restart, update it and lift its session limit. Never delete it: `exakit uninstall` keeps it and drops only the logins the kit created inside. `exakit repair-runtime` rebuilds it once confirmed, and it stays the user's |

The user's other deployments are never the kit's, and no kit command touches them.
A new install with Exasol Personal 2.5 and databases of the user's asks which one
to use, a new `starter-kit-local` being the default (and the answer without a
terminal). `EXAKIT_REUSE_DB=<name>` answers it for a script. Ask the user before
you name one of theirs, because it is renamed.

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
user before running it. The kit's own launcher is never on `PATH`: run it with
`exakit exasol <args>` (an `exasol` on `PATH` is the user's own). A database of the user's (`runtime.ownership: user`) is rebuilt
the same way and stays the user's, so `exakit uninstall` still keeps it.

The `--json` object includes `running`, `datasets_loaded` (verified against the database,
not just the manifest), `services`, `steps_completed`, and `remedies` — a map of component
to the exact repair command. Read the remedy from there rather than inferring it.

**The database clock can fall behind after the computer sleeps.** On macOS the database
runs in a VM whose clock does not catch up after sleep or hibernation (measured: 32 min to
2 h 26 min behind). Queries still answer; what breaks is anything that goes by the time —
a remote source's TLS certificate reads as "not yet valid", scheduled jobs run late,
`CURRENT_TIMESTAMP` is wrong. `status` measures it: `clock_skew_seconds` in the JSON
(negative is behind), and past two minutes a `Clock` row on the screen plus
`remedies.clock: "exakit stop"`. A restart resyncs it — `exakit stop`, then `exakit start`.
It is deliberately **not** the top-level `remedy`: stopping ends whatever is running, so
tell the user and let them pick the moment.

## Start and stop

```bash
exakit start    # the database AND every installed add-on service
exakit stop     # the add-on services, then the database
exakit stop <service>    # one of them: an add-on, or database (which asks before taking the database from running add-ons)
exakit start <service>   # one of them; an add-on needs the database up
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

**In WSL**, "after a restart" means when the *distro* starts, not the PC:
Windows starts a distro when it is opened and stops it when idle, so after a
Windows reboot nothing in it runs until it is opened again (or a Windows logon
task starts it: `wsl.exe -d <distro> --exec true`). It also needs systemd on in
the distro (`[boot] systemd=true` in `/etc/wsl.conf`); `exakit autostart` says so
when it is off.

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
`Failed to connect to 127.0.0.1:8563` (or the kit's own port) from exapump — means exactly one thing:
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
  makes all three lie. Read the database's state from `exakit status`:
  `exasol status` typed by hand reports on the launcher's `default`
  deployment, not on `starter-kit-local`.
- **Never rename or move `starter-kit-local`, and never touch the user's other
  deployments.** Renaming one of theirs is the install question's job, after
  the user picked it.
- **Never print or log the credential files** under
  `~/.exasol-starter-kit/credentials/`. Read them into a command when a command
  needs them; do not echo them into a transcript.
- **Do not invent** ports, paths or launcher flags. The facts
  above came from the machine — get the rest the same way (`exakit info`,
  `exakit status --json`, `exakit logs`).
