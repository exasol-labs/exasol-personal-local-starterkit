# Skills — agent guidance for the starter kit

> **TL;DR** — These are AI *skills*: small `SKILL.md` recipes that teach an
> agent how to drive this kit. The installer copies them into
> `~/.claude/skills/` and `~/.agents/skills/`; `exakit update` fetches a newer set.

**What is verified, and what is assumed.** Claude Code reads `~/.claude/skills/`
and picks these up on its next start — that path is tested. `~/.agents/skills/`
is written for agents that follow the same convention; whether a given tool reads
it is that tool's business, and the kit does not claim to have verified each one.
Nothing depends on it: an agent that reads no skills at all still gets the whole
contract from [AGENTS.md](../AGENTS.md), which inlines the guardrails (the
ask → inspect → run → validate loop, "exapump and `exakit sql` are the admin
connection", and the `SYS.EXA_USER_SYS_PRIVS` privilege probe) precisely so they
survive a skill-less harness. Skills make an agent better here; they are not what
makes it safe.

## What's here

One skill per thing an agent has to operate — so the agent loads only what the
user's request actually needs, not a manual for the whole kit.

**Start here**

| Skill | Use it when… |
|---|---|
| [`local-agent-ready-starter`](local-agent-ready-starter/SKILL.md) | Setting up the kit and running a first trusted, AI-assisted query — install → connect MCP → load data → ask/inspect/run/validate/rerun. |

**The fixed components** — always installed

| Skill | Use it when… |
|---|---|
| [`exasol-runtime`](exasol-runtime/SKILL.md) | Starting, stopping or diagnosing the local Exasol Personal deployment; autostart. |
| [`exasol-exapump`](exasol-exapump/SKILL.md) | Running SQL, opening a SQL shell, bulk-loading CSV/Parquet — and knowing that the `starter-kit` profile is the **admin**, unsandboxed connection. |
| [`exasol-mcp`](exasol-mcp/SKILL.md) | Connecting AI clients over MCP, diagnosing `mcp-doctor`, repairing config drift, proving the read-only user really is read-only. |
| [`exasol-pyexasol`](exasol-pyexasol/SKILL.md) | Querying the database from Python — the right interpreter, the TLS setting the self-signed certificate needs, reading credentials safely. |
| [`exakit-lifecycle`](exakit-lifecycle/SKILL.md) | Operating the kit itself — versions and what changed, updates, logs, the command surface, where the credential files live, and uninstalling with `--dry-run` first. |

**The wider Exasol ecosystem** — installed with the kit; it catalogs tools that are *not* part of it

| Skill | Use it when… |
|---|---|
| [`exasol-ecosystem`](exasol-ecosystem/SKILL.md) | Answering "is there an Exasol connector/driver/adapter for X" — which repo, which org, what support level, and which well-known projects are archived. |

**The marketplace** — opt-in add-ons

`exasol-marketplace` itself installs with the kit; the other five skills below
are **installed with their add-on**, not with the kit: each declares
`addon: <id>` in its frontmatter, and the marketplace places it as part of
installing that add-on and removes it again when the add-on goes.
A skill is a set of triggers for an agent to match on, and matching them for a
tool that is not on the machine is worse than not shipping the skill at all.

| Skill | Use it when… |
|---|---|
| [`exasol-marketplace`](exasol-marketplace/SKILL.md) | Choosing, installing, updating or removing add-ons; explaining why one is not offered at all. |
| [`dbt-exasol`](dbt-exasol/SKILL.md) | Building SQL models with dbt against the local database; the generated profile, why `~/.dbt` is never touched, and why the command is `dbt-exasol` and not `dbt`. |
| [`dash-server`](dash-server/SKILL.md) | Building live dashboards the agent drives over an MCP control plane while the user opens a browser URL. |
| [`json-tables`](json-tables/SKILL.md) | Loading JSON into the database (exapump takes CSV and Parquet only); the prebuilt engine that means no Rust toolchain. |
| [`exasol-scheduler`](exasol-scheduler/SKILL.md) | Scheduling SQL jobs in SCHED.SCHED_TASKS; the scheduler_svc trust boundary, task chains, and why missed runs are never replayed. |
| [`exasol-vscode`](exasol-vscode/SKILL.md) | SQL editing and schema browsing inside VS Code; why the kit refuses to manage a copy the user installed themselves. |

The set is versioned as one component (`components.skills` in `versions.json`),
and it updates like one: when the maintainers change a skill and bump that
version, `exakit version` shows a `skills` row with the newer number and
`exakit update` fetches the new set from the kit repository and installs it —
no kit release involved. `exakit skills` reports when the copies in your
agent's folders are behind the advertised set.

Each skill is a directory containing a `SKILL.md`: `name` + `description`
frontmatter, then the instructions. A skill that belongs to a marketplace add-on
adds one more key, `addon: <add-on id>` — that is the whole wiring, and it is
what makes the skill travel with its add-on instead of with the kit. The agent always sees the name and
description, and loads the full body only when it decides the skill is relevant
(progressive disclosure). The `description`'s **"Triggers —"** list is how the
agent decides when to fire it — keep it accurate.

## Seeing what you have

```bash
exakit skills          # every skill, with a summary and whether it is installed
exakit skills --json   # the same, machine-readable
```

States are `installed` (in every discovery folder), `partial` (in some — a
half-finished install or a hand deletion), `needs-addon` (it belongs to a
marketplace add-on you have not installed; it arrives with the add-on, and
`skills-install` will not place it) and `available` (in none, and it should be).
The panel spells the third one `with <add-on id>` so you can see whose it is;
`--json` reports it as `"state":"needs-addon"` with an `addon` and a runnable
`remedy`. Only `partial` and `available` count as pending, so a healthy machine
with add-ons it never installed does not read as half-installed.

## How a skill reaches your agent

Skills auto-load only from an agent's discovery folders, **not** from this repo
path. The installer copies each skill into the standard per-user locations, and
`exakit skills` shows the result:

```bash
exakit skills
```

The per-user locations:

- **Claude Code** → `~/.claude/skills/<name>/` — **verified**: Claude Code reads
  this and picks the skills up on its next start.
- **Open-standard agents** → `~/.agents/skills/<name>/` — the shared
  **convention**. The kit writes it; whether a given tool reads it is that
  tool's business, and the kit has not verified each one. `exakit skills`
  reports that the file is in place, not that your agent read it. If your client
  shows no Exasol skills, check its own docs for where it looks — nothing in the
  kit depends on this path (see [AGENTS.md](../AGENTS.md)).

`exakit skills` only reports; it changes nothing, so it is safe to run any time.
The installer places the set, and `exakit skills` names the next command when one
is needed — `exakit update` to move to a **newer** set the maintainers have
published (it fetches the set first, then places it), or `exakit skills-install`
to put back a skill folder that has gone missing.

> **Chat-only clients (Claude, Cursor GUI over MCP):** these do not read
> filesystem skills the same way. There, the skill still works as guidance you
> paste in, and the query loop (Step 5) runs against the connected `exasol` MCP
> server. Filesystem auto-discovery is for terminal/CLI agents.

## Too many approval prompts?

An agent driving the kit runs many commands; by default each one asks for
approval. See [reducing-agent-prompts.md](reducing-agent-prompts.md) to
pre-approve the kit's **read-only** commands per agent (Claude Code, Codex,
Cursor) while keeping SQL execution and mutations gated — the split that keeps
the inspect-before-run trust model intact.

## Why this layout (and not a plugin marketplace)

The kit is a **first-touch, low-friction** experience — the goal is time-to-first
value, not a tooling catalog. A plugin-marketplace install would assume the user
already runs Claude Code / Codex with plugin habits and would add steps before
value. Instead the existing installer — the thing the user already runs — places
the skill where agents look. If versioned team distribution is ever needed, a
marketplace wrapper is additive and can be layered on later.

## Adding or editing a skill

Verify with:

```bash
bash tests/skills.sh    # frontmatter, registry, install/state, uninstall scope
```

1. Add or edit a folder under `skills/<skill-name>/SKILL.md`.
2. Keep the `name` / `description` (with `Triggers —`) accurate — that's how the
   agent decides when to fire it.
3. Reference only real kit commands and paths (`exakit …`, `exapump …`,
   `~/.exasol-starter-kit/kit/…`) — never invent commands, flags, or SQL.
4. If you add shared material for multiple skills, keep it once at this folder's
   level and reference it by relative path from each skill.
