---
name: exasol-vscode
addon: exasol-vscode
description: Install and use the Exasol for VS Code extension from the starter kit's marketplace — SQL editing and schema browsing against the local Exasol database inside the editor, including why it is hidden on machines without VS Code and why the kit refuses to manage a copy the user installed themselves. Triggers — "Exasol extension for VS Code", "browse my schema in the editor", "write SQL in VS Code against Exasol", "install exasol-vscode", "the VS Code add-on is not listed", "remove the Exasol extension".
---

# Exasol for VS Code

`exasol-vscode` is a **marketplace add-on**: the official Exasol extension for
Visual Studio Code, giving SQL editing and schema browsing against the local
database from inside the editor. Extension id: `exasol.exasol-vscode`.

## Install it

```bash
EXAKIT_MARKETPLACE_ADDONS=exasol-vscode exakit marketplace
```

The kit downloads the release's single `.vsix` asset, **verifies its sha256
digest**, and installs it with VS Code's own CLI (`code --install-extension`).
The extension then lives in VS Code's extensions directory — **not** under the
kit home.

Re-running is safe: an installed extension already at the desired version is
kept as-is.

## Two reasons it may not be offered

This add-on has an **applicability gate**, so its absence from the menu is
usually correct, not a bug:

**1. VS Code is not on this machine.** The add-on is then hidden entirely — no
row, no mention. Asking for it by name explains the reason instead of failing
partway through an install:

```bash
EXAKIT_MARKETPLACE_ADDONS=exasol-vscode exakit marketplace
# -> explains that VS Code was not found
```

If the user wants it, they install VS Code first, then re-run the marketplace.

**2. The user already has the extension.** If it was installed from the VS Code
Marketplace rather than by the kit, it shows as *already on this system — the
kit leaves it alone*, and is never offered again.

That second case is a hard promise: **the kit never updates or uninstalls an
extension it did not install.** Do not try to take it over, and do not suggest
removing the user's copy so the kit can install its own — there is no benefit
and it destroys their existing setup.

## Connecting it to the database

The extension is an editor integration, not a second database. It connects to
the same local database everything else uses:

```bash
exakit info      # DSN, admin user, and where the password file lives
```

Defaults are `127.0.0.1:8563`, admin user `sys`, TLS with a **self-signed
certificate** — so if the extension offers a certificate-verification setting,
it must be relaxed for a local connection, exactly as the kit's DBeaver and
DbVisualizer guidance describes (`exakit guide`).

Read the password from its file at connection time. **Never print it, and never
paste it into a settings file you then show the user.**

## Managing it

```bash
exakit version                   # its row shows installed vs advertised
exakit update      # also the repair command
exakit uninstall                 # selectable on its own
```

`exakit uninstall` removes only a **kit-installed** copy, through the add-on's
own hook. A user-installed copy is left untouched.

## Guardrails

- **Never touch a copy the kit did not install** — not to update it, not to
  remove it, not to "fix" its version.
- **Do not install the extension by hand** with `code --install-extension` to
  work around the applicability gate. If the gate says VS Code is missing, VS
  Code really is missing, and a hand install leaves the kit's manifest wrong.
- **This is an admin-user connection**, like every non-MCP path in the kit —
  writes are possible. Show SQL before running it.
- **Never print or log** the credential files under
  `~/.exasol-starter-kit/credentials/`.
