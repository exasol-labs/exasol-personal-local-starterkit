# Quickstart: Windows

This guide takes you from Windows to a local Exasol database without leaving **PowerShell**. The database is an **Exasol Personal** local deployment. The Exasol launcher runs it through Podman on the host and installs Podman itself if it is missing.

Exasol Personal supports Windows **x86_64**. It does not support Windows arm64: the installer says so and exits without changing anything (the notes below say what you can still do on an arm64 machine). If you would rather work inside **WSL**, that is supported too. Follow the [Linux quickstart](linux.md) instead of this one: the kit runs in the distro, and Podman has to be installed there as well.

## What you need

- Windows 10/11 on x86_64
- 8 GB+ RAM, 20 GB free disk
- Nothing installed in advance. The database runs through Podman's default machine. If Podman is missing, the Exasol launcher offers to install it with Windows Package Manager. That install may ask for administrator approval, and it is the only step that ever does
- You don't need to install Python. The kit uses a system Python 3.11+ if it finds one, and otherwise installs a managed Python for its own use

To check your machine before installing, run the requirements check. It installs **nothing**:

```powershell
$env:EXAKIT_PREFLIGHT = '1'
irm https://www.exasol.com/install/starter-kit.ps1 | iex
```

## Install (regular PowerShell, no admin needed)

```powershell
irm https://www.exasol.com/install/starter-kit.ps1 | iex
```

What happens, in order:

1. A quick machine check runs before anything is downloaded or written
2. The kit is downloaded to `~\.exasol-starter-kit\kit` and the plan is shown. You can read every script, before or after the run
3. The Exasol launcher is downloaded and checksum-verified, then deploys the database locally. If Podman is missing, the launcher offers to install it, and this is where the one possible administrator prompt appears. Podman's default machine is prepared, or **left exactly as it is** if one already exists
4. The database starts, reachable only from your machine
5. exapump (the data tool) is installed, and the sample data is loaded and verified
6. The AI bridge is set up with a read-only database login, and your AI clients are connected
7. You get a connection panel with the details you need


## The Podman machine is shared, and the kit does not manage it

Podman's default machine is one machine for the whole computer. The Exasol launcher uses it, never reconfigures one that already exists, and leaves it running after `exakit stop` and even after an uninstall. The kit owns the **deployment** (the database and its data) and nothing else, so if you use Podman for other work, that work is not affected.

## Verify

```powershell
exakit status                                       # Status: running
```

Any SQL client (DBeaver, for example) connects with host `127.0.0.1`, user `sys` and the port shown by `exakit info`. The launcher picks that port and remembers it (8563 unless something else was using it). `exakit info` also shows where the password is stored.

## Load data

The installer loads the sample data for you. To load more datasets or your own files later, open the menu again:

```powershell
exakit data-load
```

## Connect your AI assistant

The installer does this too. To run it again, use `exakit mcp-setup`. The [QUICKSTART](../QUICKSTART.md) has the details.

Restart your AI client, then try the [example questions](../data/example-questions.md).

## Keeping it current

```powershell
exakit version         # installed vs the versions the maintainers advertise
exakit update          # the quick ones in seconds, then it asks before touching the database
```

When a database update is waiting, `exakit update` explains it before asking y/N. That includes the longer first start after a launcher change, which happens once while the deployment rebuilds part of its runtime; your data is kept. An unattended run is never asked and never stops the database unless you opt in with `exakit update -Yes`.

For the full detail, see [Staying up to date](../README.md#staying-up-to-date).

## Windows notes

| Issue | Fix |
|---|---|
| The Podman install asked for administrator approval | That is Windows Package Manager installing Podman, once, and the installer tells you before it happens. Approve it, or install Podman yourself first (`winget install RedHat.Podman`; you may need to reboot) and re-run. The kit itself never needs admin rights. If you refuse the approval, the kit reports Podman as the cause rather than the database, skips the database step and carries on. Everything that doesn't need a database still installs, and re-running the install command afterwards finishes the job (completed steps are skipped) |
| "Podman is installed, but it cannot run containers" | Podman on Windows is a Linux machine under WSL, and it is off after a reboot. The kit runs `podman info` before deploying and starts the machine if it is only stopped. If Podman still doesn't answer, fix what `podman info` reports (`podman machine start`, or `podman machine init` if there is no machine at all) and re-run the install command |
| "Port 8563 is already in use" | The launcher picks the deployment's port itself, and the kit uses whichever port it picked. If the port holds a running Exasol Personal that this launcher deployed, the kit adopts it. Anything else is reported: stop that application and re-run |
| "It answers like an Exasol database this kit did not deploy" | Windows and WSL share one network stack, so an Exasol Personal running **inside a WSL distro** holds port 8563 for Windows too, and the other way round. The kit never adopts a database it cannot log in to. Stop it on the other side first (`exakit stop` in that distro, or in PowerShell when installing into WSL), then re-run |
| `TLS error: tls handshake eof` right after an install or start | The database is still booting behind its published port. Under rootless Podman the port opens as soon as the container starts, a minute or more before the database inside accepts connections. The kit waits for a completed handshake before it reports the deployment as reachable. If you see this error from your own client, wait a minute and check `exakit status` |
| A step failed but the install continued | This is expected. The summary at the end lists each missing piece and the one command that installs it. That includes the database step itself: if you decline to reuse a running database or to delete a stopped one, if another process holds port 8563, or if a deploy can't finish, the kit records it instead of stopping |
| "Reusing the existing Exasol deployment (started)" and then nothing | Fixed. The launcher accepts a start for a deployment it has only initialized and then does nothing. The kit now checks with the database itself instead of the launcher's record, runs the launcher's own deploy when nothing answers, and checks again |
| Script execution policy complaints | On a normal machine, the installer bypasses the policy for its own scripts only, and nothing changes system-wide. On a **company-managed machine** where Group Policy sets the policy, `-ExecutionPolicy Bypass` is ignored by design. The installer detects this at the start and stops with the fix: `Get-ExecutionPolicy -List` shows the MachinePolicy and UserPolicy rows, and you can ask IT for RemoteSigned |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running. The installer uses it for every download, with your signed-in Windows credentials for proxies that ask for them (HTTP 407) |
| After a reboot | Usually nothing to do. A fresh install turns on automatic start, with a Startup entry that runs the launcher. If you turned it off (run `exakit autostart` and answer the question), `exakit start` brings the database back with all its data |
| Does the installer change my `PATH`? | Yes. It puts `~\.local\bin` at the front of your **user** `PATH` (a per-user registry value, so no admin rights and nothing machine-wide), and `exakit` then works in every new terminal. |
| I already had the kit, with the database in a container | Re-run the install command. It finds the old installation and asks whether to bring your data across: **Migrate my data** or **Skip and continue**. Neither option deletes the old container or its data volume, but both stop it, because it holds the port the new database needs. The kit's own sample data is not copied, because the install loads it itself. If you skipped the migration or were never asked, `exakit migrate docker-nano` copies the data later, into the running database. It finds the container in Docker Desktop by name. |
| Windows on ARM (Snapdragon / Copilot+ PC) | Windows arm64 is not supported for local deployments. The installer says so and exits without downloading or changing anything. Run the kit inside WSL2 or a Linux VM instead, where the Linux arm64 build runs |
| "The specified path, file name, or both are too long" during an update | This is Windows' 260-character path limit, reached while unpacking into a deep profile folder (a home folder redirected to OneDrive uses most of the limit before the kit adds anything). Turn on long paths (`LongPathsEnabled` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`; this needs IT) and re-run |
| Your security team asks what this is | The kit downloads from `github.com`, `objects.githubusercontent.com`, `pypi.org`, `files.pythonhosted.org` and `astral.sh`. It installs unsigned prebuilt binaries (`exapump.exe` and any add-on you choose) into `~\.local\bin`, and checks each one against a SHA-256 digest published in `versions.json`. The Exasol launcher is checked against its release's checksums file. `exakit update` also starts one short-lived, hidden `powershell.exe -EncodedCommand` child process. Its only job is to replace the kit folder the running script was executing from, after that script has exited. Some EDR products flag this process on sight |
| I had the old container-based install | It keeps working. An installed kit records which runtime it uses, and every `exakit` command, update and repair follows that record. The Personal default only applies to fresh installs |

To remove everything, run `exakit uninstall`. The database deployment and its data are removed; Podman and its machine stay.
