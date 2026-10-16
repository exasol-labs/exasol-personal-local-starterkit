# Quickstart: Windows (Docker variant)

This guide takes you from Windows to a local Exasol database without leaving **PowerShell**. On this branch of the kit (`exasol-starterkit-docker`) the Windows database is **Exasol Nano**, running as a container in **Docker Desktop**. The standard kit on the main branch installs Exasol Personal through Podman instead; this page is only about the Docker variant.

If you would rather work inside **WSL**, that is supported too and is unchanged: follow the [Linux quickstart](linux.md) instead of this one. The kit runs in the distro with Exasol Personal through Podman there, and Podman has to be installed there as well.

## What you need

- Windows 10/11, x86_64 or arm64
- **Docker Desktop, installed and running.** The kit never installs or starts it. Docker Desktop is free for personal use, education and small businesses and needs a paid subscription in larger companies (see Docker's terms)
- 8 GB+ RAM recommended, 4 GB minimum; 20 GB free disk
- You don't need to install Python. The kit uses a system Python 3.11+ if it finds one, and otherwise installs a managed Python for its own use

On Windows arm64 the database runs, but exapump and the AI bridge have no arm64 build and are skipped. The database itself is fully usable from any SQL client.

To check your machine before installing, run the requirements check. It installs **nothing**:

```powershell
$env:EXAKIT_PREFLIGHT = '1'
irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/exasol-starterkit-docker/install.ps1 | iex
```

## Install (regular PowerShell, no admin needed)

```powershell
irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/exasol-starterkit-docker/install.ps1 | iex
```

What happens, in order:

1. A quick machine check runs before anything is downloaded or written: Docker Desktop must answer, and memory and disk are checked
2. The kit is downloaded from this branch to `~\.exasol-starter-kit\kit` and the plan is shown. You can read every script, before or after the run
3. The Exasol Nano image is pulled into Docker Desktop and checked against the digest pinned in `versions.json`. An image that does not match is removed and the install stops
4. The container starts over a named data volume (`exasol-nano-data`), with a generated SYS password, reachable only from your machine
5. exapump (the data tool) is installed, and the sample data is loaded and verified
6. The AI bridge is set up with a read-only database login, and your AI clients are connected
7. You get a connection panel with the details you need

A kit installed from this branch keeps following it: `exakit update` fetches the manifest, the kit scripts and the skills from `exasol-starterkit-docker`, never from main.

## Verify

```powershell
exakit status                                       # Runtime: nano (docker) - running
```

Any SQL client (DBeaver, for example) connects with host `127.0.0.1`, port `8563` and user `sys`. `exakit info` shows where the password is stored. To use another port, set `$env:EXAKIT_DB_PORT` once, for the install; the kit records it.

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
exakit version         # installed vs the versions this branch advertises
exakit update          # the quick ones in seconds, then it asks before touching the database
```

A database update pulls the newer Nano image, checks it against its pin, and recreates the container over the same data volume. Your data is kept. An unattended run never stops the database unless you opt in with `exakit update -Yes`. `$env:EXAKIT_NANO_TAG` pins another image tag by hand; a tag the manifest does not pin is pulled unverified, and the kit says so.

## Windows notes

| Issue | Fix |
|---|---|
| "Docker Desktop was not found" | Install Docker Desktop from https://docs.docker.com/desktop/setup/install/windows-install/ , start it, and re-run the command. The kit does not install it |
| "Docker is installed but not running" | Open Docker Desktop and wait until it reports that the engine is running. A machine that signs in with a company account may need that sign-in first. Then re-run |
| "Port 8563 is already in use" | Another program holds the port. Stop it and re-run, or install on another port: `$env:EXAKIT_DB_PORT = '8564'` before the install command |
| The image pull fails or is slow | Docker Desktop pulls through its own proxy settings: Settings > Resources > Proxies. The kit retries the pull three times before it gives up |
| "The pulled image does not match the digest versions.json pins" | Either Docker Hub now serves different bytes under that tag, or the pin is stale. Run `exakit update` to get a current kit, or check the tag at https://hub.docker.com/r/exasol/nano/tags . The image was removed and nothing was started |
| The database password does not work | The password file is mounted into the container on its first start. Docker Desktop > Settings > Resources > File sharing must include your user profile drive. Then `exakit uninstall` and install again |
| "Database did not become ready" | A first start initialises the database and can take a few minutes on a slow disk. Read the container's own log with `docker logs exasol-nano`. If a first install was interrupted, reset and retry: `docker rm -f exasol-nano; docker volume rm exasol-nano-data`, then re-run the installer |
| A step failed but the install continued | This is expected. The summary at the end lists each missing piece and the one command that installs it. That includes the database step: if Docker Desktop was not running or the port was taken, the kit records it instead of stopping |
| I already had the 0.1.0 kit | Re-run the install command. The 0.1.0 database was already an Exasol Nano container in Docker Desktop, so the kit adopts it, container, volume and password, and carries on with the rest |
| I have the standard kit (Exasol Personal) on this machine | This variant does not convert it. The installer stops before downloading anything. Run `exakit uninstall` first, or stay on the standard kit: `irm https://www.exasol.com/install/starter-kit.ps1 \| iex` |
| Script execution policy complaints | On a normal machine, the installer bypasses the policy for its own scripts only, and nothing changes system-wide. On a **company-managed machine** where Group Policy sets the policy, `-ExecutionPolicy Bypass` is ignored by design. The installer detects this at the start and stops with the fix: `Get-ExecutionPolicy -List` shows the MachinePolicy and UserPolicy rows, and you can ask IT for RemoteSigned |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running. The installer uses it for every download, with your signed-in Windows credentials for proxies that ask for them (HTTP 407). The image pull uses Docker Desktop's own proxy settings |
| After a reboot | Usually nothing to do. A fresh install turns on automatic start: the container carries Docker's `unless-stopped` restart policy and a Startup entry runs `docker start` as well, so the database is back once Docker Desktop is. Turn on "Start Docker Desktop when you sign in" in its settings. If you turned autostart off (run `exakit autostart` and answer the question), `exakit start` brings the database back with all its data |
| Does the installer change my `PATH`? | Yes. It puts `~\.local\bin` at the front of your **user** `PATH` (a per-user registry value, so no admin rights and nothing machine-wide), and `exakit` then works in every new terminal |
| "The specified path, file name, or both are too long" during an update | This is Windows' 260-character path limit, reached while unpacking into a deep profile folder (a home folder redirected to OneDrive uses most of the limit before the kit adds anything). Turn on long paths (`LongPathsEnabled` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`; this needs IT) and re-run |
| Your security team asks what this is | The kit downloads from `github.com`, `objects.githubusercontent.com`, `pypi.org`, `files.pythonhosted.org` and `astral.sh`, and pulls the `exasol/nano` image from Docker Hub, checked against the digest pinned in `versions.json`. It installs unsigned prebuilt binaries (`exapump.exe` and any add-on you choose) into `~\.local\bin`, each checked against a SHA-256 digest from `versions.json`. `exakit update` also starts one short-lived, hidden `powershell.exe -EncodedCommand` child process whose only job is to replace the kit folder the running script was executing from, after that script has exited. Some EDR products flag this process on sight |

To remove everything, run `exakit uninstall`. The Nano container and its data volume are removed; Docker Desktop stays.
