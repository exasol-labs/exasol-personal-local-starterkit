# Report a security issue (/security/report-an-issue)



Send a suspected vulnerability to **[plg.connect@exasol.com](mailto:plg.connect@exasol.com)**. That is the address the documentation's Feedback button uses (`FEEDBACK_ADDRESS` in `notebook/docs/components/feedback.tsx`), and the one the repository's issue chooser offers as "Write to the team" (`.github/ISSUE_TEMPLATE/config.yml`).

## What the repository does not publish [#what-the-repository-does-not-publish]

* There is no `SECURITY.md` file in the repository root. This page does not link one, and it does not invent a disclosure process, a response time or a security contact other than the address above.
* The repository does not state how the team handles a report after it arrives. Nothing in this section describes that process.

## What to include [#what-to-include]

Describe what you did and what you saw. These help the team reproduce it:

* The kit version, from `exakit status --json`.
* The command or notebook cell, and the file or page it came from.
* Your operating system and whether you ran the Windows or the Unix installer.
* What you expected, and what happened instead.

Read the output before you send it. The kit redacts the secrets listed on the [Credentials](/security/credentials) page in the places that page names. Logs can still hold your data, file paths and table names.

## What not to send [#what-not-to-send]

Do not send the contents of `~/.exasol-starter-kit/credentials/`, `~/.exapump/config.toml`, the notebook connection store, or an `exakit.env` file. Describe the problem without them.

## A problem that is not a vulnerability [#a-problem-that-is-not-a-vulnerability]

For an ordinary problem with the kit, the repository's issue chooser suggests an issue with the output of `exakit status --json` and `exakit logs`. Check that output for anything private before you post it in public.

<Callout>
  `exakit tls-pin` with no options compares the pinned certificate with the live one and changes nothing. `exakit mcp-doctor` tests the AI connection and repairs it, so run it only when you are ready for a repair.
</Callout>
