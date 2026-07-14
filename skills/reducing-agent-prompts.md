# Reducing approval prompts (per AI agent)

When an AI agent drives the starter kit, it runs a series of shell commands and
MCP tool calls. By default most agents ask for approval on **every** one, which
gets noisy fast. You can pre-approve the kit's **safe, read-only** operations
while keeping the ones that matter gated.

> There is **no single cross-agent file** for this — each agent has its own
> permission model. Below is the same principle applied to each.

## The principle (applies to every agent)

Allow without prompting:
- The kit's **read-only status commands** — they change nothing:
  `exakit status`, `exakit info`, `exakit version`, `exakit mcp-doctor`,
  `exakit logs`.
- The **`exasol` MCP tools** — the MCP server connects as a dedicated
  least-privilege read-only user, so the database itself rejects any write.

Keep prompting (do **not** auto-allow):
- **`exapump sql …`** — the `starter-kit` exapump profile connects as the
  **admin** user and is *not* read-only. Auto-allowing it would defeat the kit's
  inspect-before-run trust model. Every query through it should be seen first.
- **Mutating / lifecycle commands** — `exakit uninstall`, installs, upgrades,
  anything under `mcp-repair`/`mcp-remove`.

That split kills the noise (all the harmless status checks) without weakening
the guardrail that makes the kit trustworthy.

## Claude Code

Add a project allowlist in `.claude/settings.json` (checked into the repo so
every user benefits):

```json
{
  "permissions": {
    "allow": [
      "Bash(exakit status:*)",
      "Bash(exakit info:*)",
      "Bash(exakit version:*)",
      "Bash(exakit mcp-doctor:*)",
      "Bash(exakit logs:*)",
      "mcp__exasol"
    ],
    "deny": [
      "Bash(exakit uninstall:*)"
    ]
  }
}
```

`exapump sql` is intentionally absent, so SQL execution still prompts.

## Codex

Codex gates tool calls through its **approval policy** and **sandbox**, set in
`~/.codex/config.toml` (or per-project). Rather than run fully unattended, keep
approvals on but scope what runs without asking to read-only work. Conceptually:

```toml
# ~/.codex/config.toml
# Keep approvals for edits/commands, but allow the kit's read-only status checks.
approval_policy = "on-request"
# Restrict side effects with the sandbox; grant network/db access as needed.
sandbox_mode = "workspace-write"
```

> Codex's approval/sandbox option names have changed across releases — confirm
> the current keys in `codex --help` / the Codex docs before relying on them.
> The goal is the same: read-only kit commands + `exasol` MCP tools run freely;
> `exapump sql` and mutations still ask.

## Cursor

Cursor has its own command allow/deny list in its settings (Agent / terminal
permissions). Add the read-only `exakit …` status commands to the allowed list
and leave `exapump sql` and mutating commands to prompt. Check Cursor's current
settings UI for the exact location.

---

**Root cause note:** a lot of the prompt noise in an early run comes from the
agent *improvising* around a failure (e.g. hunting for configs). Keeping the kit
healthy — DB running, MCP configs correct — means the agent runs the short happy
path and asks far less. If you see heavy improvisation, fix the underlying issue
first; the allowlist is for the steady state.
