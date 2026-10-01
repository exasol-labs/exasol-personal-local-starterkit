# Reducing approval prompts (per AI agent)

When an AI agent drives the starter kit, it runs a series of shell commands and
MCP tool calls. By default most agents ask for approval on **every** one, which
gets noisy fast. You can pre-approve the kit's **safe, read-only** operations
while keeping the ones that matter gated.

> There is **no single cross-agent file** for this — each agent has its own
> permission model. Below is the same principle applied to each.

## The principle (applies to every agent)

Allow without prompting:
- The kit's **read-only commands** — they change nothing: `exakit status`,
  `info`, `version`, `mcp-doctor`, `logs`, `catalog`, `preflight`, `guide`,
  `mcp-status`, `help`, and the exact forms `exakit skills` and
  `exakit skills --json`.
- The **`exasol` MCP tools** — the MCP server connects as a dedicated
  least-privilege read-only user, so the database itself rejects any write.

Keep prompting (do **not** auto-allow):
- **`exapump sql …` and `exakit sql …`** — both connect as the **admin** user and
  are *not* read-only. (`exakit sql` refuses a non-read statement without
  `--write` and translates errors into remedies, which makes it the better one to
  use — but that gate is a seatbelt, not a sandbox.) Auto-allowing either would
  defeat the kit's inspect-before-run trust model. Every query should be seen first.
- **Mutating / lifecycle commands** — `exakit uninstall`, installs, upgrades,
  and `exakit mcp-setup`, which writes to AI client config files.

That split kills the noise (all the harmless status checks) without weakening
the guardrail that makes the kit trustworthy.

## Claude Code

**`exakit skills-install` already does this for you.** It merges the allowlist below
into `~/.claude/settings.json` — additively and idempotently, never removing or
overwriting anything you have set. The block below is the **complete** list it
writes on macOS, Linux and WSL — 37 allow entries and 3 deny entries — so you can
see what was granted, and paste it by hand if the merge was skipped (it declines
rather than clobber a settings file it cannot parse). To see the list this
machine actually has, open `~/.claude/settings.json`; to re-apply it, run
`exakit skills-install`.

```json
{
  "permissions": {
    "allow": [
      "Bash(exakit status:*)",
      "Bash(exakit info:*)",
      "Bash(exakit version:*)",
      "Bash(exakit mcp-doctor:*)",
      "Bash(exakit logs:*)",
      "Bash(exakit catalog:*)",
      "Bash(exakit preflight:*)",
      "Bash(exakit guide:*)",
      "Bash(exakit mcp-status:*)",
      "Bash(exakit help:*)",
      "Bash(exakit skills)",
      "Bash(exakit skills --json)",
      "Bash(~/.local/bin/exakit status:*)",
      "Bash(~/.local/bin/exakit info:*)",
      "Bash(~/.local/bin/exakit version:*)",
      "Bash(~/.local/bin/exakit mcp-doctor:*)",
      "Bash(~/.local/bin/exakit logs:*)",
      "Bash(~/.local/bin/exakit catalog:*)",
      "Bash(~/.local/bin/exakit preflight:*)",
      "Bash(~/.local/bin/exakit guide:*)",
      "Bash(~/.local/bin/exakit mcp-status:*)",
      "Bash(~/.local/bin/exakit help:*)",
      "Bash(~/.local/bin/exakit skills)",
      "Bash(~/.local/bin/exakit skills --json)",
      "Bash($HOME/.local/bin/exakit status:*)",
      "Bash($HOME/.local/bin/exakit info:*)",
      "Bash($HOME/.local/bin/exakit version:*)",
      "Bash($HOME/.local/bin/exakit mcp-doctor:*)",
      "Bash($HOME/.local/bin/exakit logs:*)",
      "Bash($HOME/.local/bin/exakit catalog:*)",
      "Bash($HOME/.local/bin/exakit preflight:*)",
      "Bash($HOME/.local/bin/exakit guide:*)",
      "Bash($HOME/.local/bin/exakit mcp-status:*)",
      "Bash($HOME/.local/bin/exakit help:*)",
      "Bash($HOME/.local/bin/exakit skills)",
      "Bash($HOME/.local/bin/exakit skills --json)",
      "mcp__exasol"
    ],
    "deny": [
      "Bash(exakit uninstall:*)",
      "Bash(~/.local/bin/exakit uninstall:*)",
      "Bash($HOME/.local/bin/exakit uninstall:*)"
    ]
  }
}
```

**Three spellings of every command, and that is not redundancy.** A permission rule
matches the command *text*. `~/.local/bin` is not on a bare non-interactive `PATH`,
so an agent is told — by AGENTS.md, in as many words — to call the binary by its
absolute path. Listing only the bare `exakit` form therefore covered the one
invocation the docs steer agents away from, and every "pre-approved" command kept
prompting anyway. The deny needs all three for the mirror-image reason: a rule that
names only `exakit uninstall` is sidestepped by typing the full path.

**Windows adds three more spellings, and the PowerShell tool.** The command there
is `exakit.cmd`: PowerShell resolves the bare name, but Git Bash — Claude Code's
shell on Windows — does not, and `~/.local/bin/exakit` does not exist, so the Unix
spellings above matched nothing an agent on that machine could type and every
status call kept prompting. To build the Windows list, take the block above and
repeat every `Bash(exakit …)` rule three more times with `exakit.cmd`,
`~/.local/bin/exakit.cmd` and `$HOME/.local/bin/exakit.cmd` in place of
`exakit`, then add a `PowerShell(exakit …)` form of each — Claude Code's
PowerShell tool has its own rule namespace, and bare `exakit` resolves there.
That is what `exakit skills-install` writes on Windows: 85 allow entries and
7 deny entries. On macOS, Linux and WSL those extra spellings match nothing you
can type, which is why the block above leaves them out. Rules for
commands that no longer exist (`update-check`, `mcp-validate`) are swept out on
the way through, and the file is written without a UTF-8 BOM, which strict JSON
readers reject.

`exakit skills-install` is deliberately *not* prefix-matched, which is why
`exakit skills` and `exakit skills --json` appear as exact forms above:
`Bash(exakit skills:*)` would also match `exakit skills-install`, which writes
this very file, and an allowlisted command that can grant permissions is an
escalation path.

`exapump sql` and `exakit sql` are both intentionally absent, so SQL execution still
prompts. Both connect as the **admin** user.

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
