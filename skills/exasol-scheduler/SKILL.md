---
name: exasol-scheduler
addon: exasol-scheduler
description: Schedule SQL jobs on the local Exasol database with the Exasol Scheduler add-on — jobs are rows in SCHED.SCHED_TASKS, history is a table, and the whole surface is plain SQL. Covers installing it from the marketplace, the dedicated scheduler_svc user and why the MCP user cannot write tasks, cron schedules with timezones, task chains via AFTER, granting job privileges, and the laptop realities — missed runs are never replayed, one instance per task table, the engine restarts itself and says so when it gives up. Triggers — "schedule a SQL job", "run this query every night", "cron for Exasol", "install exasol-scheduler", "my scheduled job did not run", "SCHED_TASKS", "task history", "chain SQL jobs", "pause a scheduled job", "scheduler gave up", "insufficient privileges in a scheduled task".
---

# Exasol Scheduler — SQL jobs on a schedule

`exasol-scheduler` is a **marketplace add-on**: a single small binary that
polls `SCHED.SCHED_TASKS` and runs each due row's `SQL_TEXT` against the local
database. Jobs are defined, paused, chained and audited with **plain SQL** —
no config files, no external state, and every execution lands in
`SCHED_HISTORY` where you (and the MCP tools) can query it.

It is a SQL scheduler, not a workflow runner: it never invokes a shell, a
Python script, or any external tool. Work that is an executable belongs
elsewhere; work that is SQL (or `EXECUTE SCRIPT`) belongs here.

## Read this before you write a task

**`SCHED_TASKS` is a code-execution surface.** Whoever can `INSERT` or
`UPDATE` a row runs arbitrary SQL as the scheduler's database user. The kit
builds the trust model around that fact:

| Path | Connects as | SCHED_TASKS |
|---|---|---|
| MCP tools (`mcp__exasol…`) | `mcp_readonly` | can **read**, writes rejected **by the database** |
| `exakit sql --write` / exapump | `sys` (admin) | can write — only you stop a bad row |
| the scheduler itself | `scheduler_svc` | executes what the rows say |

Three rules follow, and they are not negotiable:

- **Never route a task-write around an MCP rejection.** The rejection is the
  boundary working — the read-only path is *supposed* to see the schedule and
  never change it. Creating or editing tasks goes through the admin path,
  with the SQL shown to the user first.
- **Show the user a task's `SQL_TEXT` before inserting it.** That text will
  run unattended, repeatedly, as `scheduler_svc`. It deserves the same review
  as a deploy.
- **Validate with `SCHED_HISTORY`, not with silence.** A task that never
  appears in history did not run; do not report success without a
  `SUCCEEDED` row.

## The user it runs as

Install creates a dedicated `scheduler_svc` database user. Upstream's
bootstrap privileges (`CREATE SCHEMA`, `CREATE TABLE`) are granted for first
startup and **revoked automatically** once the schema exists. Prove the
posture rather than asserting it:

```sql
SELECT PRIVILEGE FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = 'SCHEDULER_SVC';
-- exactly: CREATE SESSION
```

`scheduler_svc` therefore starts with **no access to your schemas**. Every
job needs its grants stated explicitly, which is a feature — the grant list
IS the blast radius of the scheduler:

```sql
GRANT SELECT, INSERT ON SCHEMA MY_SCHEMA TO SCHEDULER_SVC;
```

Its password lives in the kit's credentials directory, readable only by you —
`~/.exasol-starter-kit/credentials/exasol_scheduler_password` (file mode `600`)
on macOS, Linux and WSL, and
`%USERPROFILE%\.exasol-starter-kit\credentials\exasol_scheduler_password`
(an owner-only NTFS ACL — file modes mean nothing there) on native Windows.
The launcher reads it at run time — never placed on an argv where `ps` would
show it, and never for you to print or log.

## Install and operate

```bash
exakit marketplace                          # Space selects, Enter installs
EXAKIT_MARKETPLACE_ADDONS=exasol-scheduler exakit marketplace   # scripted
```

In PowerShell on native Windows, an environment variable is its own statement —
the `VAR=value command` form above is shell syntax and will not run there:

```powershell
exakit marketplace                          # Space selects, Enter installs
$env:EXAKIT_MARKETPLACE_ADDONS = "exasol-scheduler"; exakit marketplace   # scripted
```

The install downloads a digest-verified prebuilt binary (no Rust, ever),
creates `scheduler_svc`, starts the service, waits for the engine to
bootstrap `SCHED`, then revokes the bootstrap grants. It joins the service
set like dash-server:

```bash
exakit status                      # running / stopped, next to the database
exakit start | exakit stop         # with the database and every service
exakit logs exasol-scheduler -f    # the engine and its supervisor, live
exakit update exasol-scheduler     # new binary; jobs and history untouched
```

Supported everywhere the kit runs — macOS (Apple Silicon **and** Intel),
Linux x86_64/arm64, WSL, Windows x86_64. Windows ARM64 has no published
binary and is not offered.

## Defining tasks

Always double-quote the scheduler's column names — they are case-sensitive
identifiers in its own table. Plain quotes: `"TASK_ID"`, never `\"TASK_ID\"`.

```sql
INSERT INTO SCHED.SCHED_TASKS ("TASK_ID", "SCHEDULE", "SQL_TEXT")
VALUES ('nightly_cleanup',
        'CRON 0 0 2 * * * TZ=UTC',
        'DELETE FROM MY_SCHEMA.STAGING WHERE created_at < ADD_DAYS(CURRENT_TIMESTAMP, -7)');
```

- The schedule is six-field cron (seconds first) plus an explicit timezone:
  `CRON <sec> <min> <hour> <dom> <mon> <dow> TZ=<zone>`. State the TZ you
  mean — the laptop's clock is not the schedule's clock.
- The scheduler notices new and changed rows on its next poll (~10s).
  **No restart, ever** — an `INSERT` is a deploy, an `UPDATE` is a config
  change.
- Pause without deleting: `UPDATE ... SET "ENABLED" = FALSE`. The row and its
  history stay; set it back to `TRUE` to resume.

### Chains and finalizers

Multi-step pipelines are rows linked by `"AFTER"`:

- a **child** carries the parent's `TASK_ID` in `"AFTER"` and a NULL
  `"SCHEDULE"` — it runs when the parent succeeds
- downstream steps are **skipped when a parent fails**
- a **finalizer** always runs, success or failure — the place for cleanup
  and notification rows

### Audit

```sql
SELECT "TASK_ID", "STATUS", "STARTED_AT"
FROM SCHED.SCHED_HISTORY
ORDER BY "STARTED_AT" DESC LIMIT 20;
```

Every execution is a row — `SUCCEEDED`, `FAILED`, `SKIPPED` — readable over
MCP, so "what runs at night and did anything fail?" is answerable without
touching the scheduler at all.

## Laptop realities — say these plainly, they are design

- **Missed runs are never replayed.** A machine asleep at 02:00 does not run
  the 02:00 job on wake; the next occurrence is computed from the current
  clock. If a run must happen after wake, use a shorter schedule or trigger
  the SQL once by hand.
- **One instance per task table**, enforced by the launcher's pidfile guard —
  a second copy refuses to start, because two pollers would run every job
  twice.
- **The engine exits on fatal errors, and the kit supervises it.** The
  launcher waits (bounded, ~2 min) for the database at login, restarts the
  engine with 5s backoff, and after five rapid failures **gives up loudly**:
  `exakit status` then shows
  `stopped (gave up after 5 rapid failures — diagnose: exakit logs exasol-scheduler, restart: exakit start)`
  rather than a bare "stopped". A deliberate `exakit start` clears that
  state — a fresh start is a fresh chance.

## Diagnosing

| You see | It means | Do |
|---|---|---|
| `stopped (gave up after N rapid failures ...)` in `exakit status` | the engine kept dying — bad credentials, unreachable DB, or a fatal task error | `exakit logs exasol-scheduler`, fix the cause, `exakit start` |
| a `FAILED` row with `insufficient privileges` | the task touches a schema `scheduler_svc` has no grant for | `GRANT` what the job needs to `SCHEDULER_SVC`, it retries on the next occurrence |
| `exasol-scheduler is already running (pid ...)` on start | the singleton guard — one poller per task table | that is the answer, not an error; `exakit stop` first if you truly mean to restart |
| a task ran twice per minute | a second scheduler outside the kit polls the same table | stop the copy the kit does not manage; the guard only covers kit-started ones |
| the MCP tools cannot `INSERT` into `SCHED_TASKS` | the read-only boundary, by design | create tasks via `exakit sql --write` (admin), with the SQL shown first |
| nothing in `SCHED_HISTORY` for a due task | scheduler not running, or task `ENABLED = FALSE` | `exakit status`, then check the row's `"ENABLED"` |

## Uninstall — what stays

`exakit uninstall exasol-scheduler` removes the service, binary, credential
and the `scheduler_svc` user — and deliberately **leaves the `SCHED` schema**:
job definitions and execution history are the user's data, not part of the
add-on. Say that when asked, so nobody fears losing their audit trail.
