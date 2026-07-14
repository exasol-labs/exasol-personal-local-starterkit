# Skills — AI assistant guidance for the starter kit

> **TL;DR** — These are AI *skills*: small `SKILL.md` recipes that teach an AI
> assistant how to drive this kit. They use the open `SKILL.md` standard that
> **Claude Code, Codex, Cursor, and other compatible agents** read, so the same
> files work everywhere — no per-tool copies.

## What's here

| Skill | Use it when… | Version |
|---|---|---|
| [`local-agent-ready-starter`](local-agent-ready-starter/SKILL.md) | Setting up the kit and running a first trusted, AI-assisted query — install → connect MCP → load data → ask/inspect/run/validate/rerun. | v0.1 |

Each skill is a directory containing a `SKILL.md`: `name` + `description`
frontmatter, then the instructions. The agent always sees the name and
description, and loads the full body only when it decides the skill is relevant
(progressive disclosure). The `description`'s **"Triggers —"** list is how the
agent decides when to fire it — keep it accurate.

## How a skill reaches your agent

Skills auto-load only from an agent's discovery folders, **not** from this repo
path. The kit installs them for you:

```bash
exakit skills-install
```

This copies each skill into the standard per-user locations so your CLI agent
finds it automatically:

- **Claude Code** → `~/.claude/skills/<name>/`
- **Codex / Cursor / other open-standard agents** → `~/.agents/skills/<name>/`

Re-running is safe — it refreshes the installed copy. The kit setup also offers
to do this once at the end of an install.

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

1. Add or edit a folder under `skills/<skill-name>/SKILL.md`.
2. Keep the `name` / `description` (with `Triggers —`) accurate — that's how the
   agent decides when to fire it.
3. Reference only real kit commands and paths (`exakit …`, `exapump …`,
   `~/.exasol-starter-kit/kit/…`) — never invent commands, flags, or SQL.
4. If you add shared material for multiple skills, keep it once at this folder's
   level and reference it by relative path from each skill.
