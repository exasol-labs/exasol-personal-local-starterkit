# Quickstart: Linux

This guide takes you from a Linux machine to a local Exasol database with an AI assistant connected. The database is an **Exasol Personal** local deployment, which the Exasol launcher runs on Docker Engine 29+ or Podman.

This is also the WSL path. The launcher treats a WSL2 distro as Linux, so everything below applies inside it. Four things are different in WSL, and each is noted where it matters: the container engine must be reachable inside the distro (Podman installed there, or Docker Desktop's WSL integration), Podman there needs WSL 2.7 or newer, keep the kit off `/mnt/c`, and turn systemd on if you want the database to come back after a reboot.

## What you need

- **A container engine.** Docker Engine 29 or newer is used when its daemon is running and set to Linux containers; otherwise Podman, as below. The choice is made once, at the first deploy, and the deployment keeps it. `EXAKIT_CONTAINER_ENGINE=docker|podman` names one.
- **Podman** (rootless is fine), which the database runs through when no usable Docker is found. You don't have to install it first. If it is missing, the installer says so and installs it between the launcher step and the database step, without stopping to ask, because the database can't run without it. It runs one package-manager command through `sudo` and asks for your password only if `sudo` wants one. The command's output goes to the logfile, not the screen. Podman also has to work, not just be installed: the kit runs `podman info` before deploying, and if that fails it shows you what Podman said.
- 8 GB+ RAM, 20 GB free disk
- You don't need to install Python. The kit uses a system Python 3.11+ if it finds one, and otherwise installs a managed Python for its own use.

To check your machine first (this installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ line tells you what to fix. If no container engine is found, the check gives the exact Podman package-manager command.

## Install

```bash
curl https://www.exasol.com/install/starter-kit.sh | sh
```

What happens, in order:

1. The installer checks your machine (container engine, RAM, disk) and shows the plan. If the machine is short of RAM or disk, it stops before downloading anything and tells you why. A missing engine is reported here and dealt with at the database step
2. The Exasol launcher is downloaded and checksum-verified, then deploys the database locally, reachable only from your machine
3. The database is ready, usually within a few minutes
4. exapump (the data tool) is installed, and the sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with the details you need

The launcher picks the database's port and remembers it (8563 unless something else was using it). `exakit info` shows the port in use, and every later command reads it back from the deployment.

**Inside WSL**, whether the two sides see each other's port 8563 depends on WSL's networking mode. With mirrored networking (`networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`) they share it both ways, so an Exasol Personal deployed on the Windows side holds 8563 inside the distro as well. Under WSL 2's default NAT mode only one way: Windows reaches a database in the distro on `localhost`, but the distro does not see one running on Windows - the kit in the distro can deploy its own, and on Windows `localhost:8563` then answers with whichever started first. The kit never adopts a database it cannot log in to. It reports it ("answers like an Exasol database this kit did not deploy") and asks you to stop it on the Windows side first (`exakit stop` in PowerShell), then re-run.

## Headless, over SSH

The database and every add-on listen only on `127.0.0.1`. This is by design, and the bind address can't be configured. To reach them from your laptop, forward the port over SSH, using the port `exakit info` shows:

```bash
ssh -N -L 8563:127.0.0.1:8563 you@server     # the database, for a local SQL client
ssh -N -L 5100:127.0.0.1:5100 you@server     # dash-server, then open http://127.0.0.1:5100
```

On a headless machine, the clipboard and browser conveniences quietly do less, and the kit prints what it would have copied. Everything else works as usual.

## Connect your AI assistant

The installer already offered to connect every AI client it found. To run
that step again, for example after installing a new client or if you skipped it,
use `exakit mcp-setup`. It writes the read-only database connection into each
client's own config. Then ask your first question. The
[example questions](../data/example-questions.md) are written for the
bundled sample data, and the [QUICKSTART](../QUICKSTART.md) walks through the
full ask → inspect → run → validate loop.

## Everyday commands

```bash
exakit status      # is everything running? (exit 0 = yes)
exakit start       # start the database and services
exakit stop        # stop them
exakit sql 'SELECT 1'
exakit autostart   # asks, then flips start-at-boot
exakit update      # bring the kit and its components up to date
```

## Notes

For Podman installation, rootless permissions or WSL2 errors, see the [Podman troubleshooting guide](podman.md).

| Situation | What to know |
|---|---|
| Docker or Podman? | Docker when `docker info` answers with Engine 29 or newer and Linux containers; Podman otherwise. A Docker that is installed but stopped is offered once: start it and press Enter, or type `p` for Podman. A run with no terminal takes Podman straight away and says so. The kit never installs or starts Docker. |
| WSL: `netavark: nftables error: "nft" did not return successfully while applying ruleset` | Podman on Exasol Personal 2.4 needs WSL 2.7 or newer. The kit reads `wsl.exe --version` before a fresh Podman deploy, and an `exakit start` that fails with this error after an update says the same; the fix: in PowerShell `wsl --update`, then `wsl --shutdown`, reopen the distro and re-run. A machine that cannot update WSL can set `firewall_driver = "iptables"` under `[network]` in `~/.config/containers/containers.conf`, quoted as shown (install the `iptables` package; the refusal says so when it is missing). Below 2.7, `exakit preflight` fails only a fresh Podman deploy; an existing Podman deployment gets a note instead. A later `containers.conf.d/*.conf` drop-in that sets `firewall_driver` overrides it: Podman reads the files in order and the last setting wins. Docker is not affected. |
| No Podman (and no usable Docker) | The installer installs Podman for you at the database step (apt, dnf, yum, zypper, pacman or apk), without stopping to ask, because the database can't run without it. It uses `sudo`, so you will be asked for your password. If it doesn't know your package manager, it skips the database step and lists it in the closing summary; the rest of the install still completes. Install Podman yourself (`sudo apt-get install -y podman uidmap`, `sudo dnf install -y podman`), then re-run the install command. Completed steps are skipped, and it resumes at the database step. Without a usable Docker it has to be Podman: the launcher drives no other engine. |
| Podman is installed but nothing works | The kit runs `podman info` before it deploys, so the problem shows up at the start instead of minutes into the launcher. The most common cause is a missing subordinate ID range, which the kit offers to repair. Otherwise, fix what `podman info` reports and re-run the install command. |
| "Reusing the existing Exasol deployment (started)" and then nothing | Fixed. The launcher accepts a start for a deployment it has only initialized, does nothing, and says so in a warning the installer used to miss. The kit now checks with the database itself instead of the launcher's record, runs the launcher's own deploy when nothing answers, and checks again. |
| The database step failed but the install continued | This is expected. If you decline to reuse a running database or to delete a stopped one, if another process holds port 8563, or if a deploy can't finish, the kit records it instead of stopping. Everything that doesn't need a database still installs, and the closing summary gives the one command that finishes the job. |
| Rootless Podman | Fully supported, and the usual case. Your user needs subordinate ID ranges (`/etc/subuid`, `/etc/subgid`; most distros set these up when the user is created) and cgroups v2 (the default on every current distro). If the ranges are missing, the kit offers to add them with `sudo`. When there is no terminal (an AI agent or a script), it only adds them if `EXAKIT_PODMAN_SELFHEAL=1` is set, and otherwise prints the command for you to run. |
| Autostart on a headless server | `exakit autostart` registers a systemd **user** unit that runs the launcher's start. A user unit only runs while you have a session, so the kit turns on lingering for your user when it can (`loginctl enable-linger`). If that is refused, it tells you and gives the command an admin has to run. |
| Upgrading the launcher | Before it asks, `exakit update` explains what a launcher update does, including the longer first start afterwards. That happens once, while the deployment rebuilds part of its runtime, and your data is kept. Moving from 2.3 to 2.4 keeps the deployment's engine and its password; the next `exakit stop` and `exakit start` moves its containers onto the launcher's own network, once. |
| `exapump` says a file is not there, but you can `ls` it | On an older distro (glibc < 2.38: RHEL/Rocky/Alma 8–9, Debian 11–12, Amazon Linux 2023), the exapump release binary can't run, so the kit generates a small container wrapper for it. exapump can then see your home directory, `/tmp` and the directory you run it from, and nothing else. A file outside those really is invisible to it: copy the file into one of them, or run the command from the directory that holds it. `exakit info` tells you when the wrapper is in use. |
| Where did everything go? | The kit lives in `~/.exasol-starter-kit` (credentials under `credentials/`, logs under `logs/`). The database deployment lives under `~/.exasol/personal/`, and **it holds the database software and your data together**. |
| Which database is this? | Exasol Personal, deployed locally by the Exasol launcher through Docker or Podman. It is the only runtime the kit installs. |
| I already had the kit, with the database in a container | Re-run the install command. It finds the old installation and asks whether to bring your data across: **Migrate my data** or **Skip and continue**. Neither option deletes the old container or its data volume, but both stop it, because it holds the port the new database needs. The kit's own sample data is not copied, because the install loads it itself. If you skipped the migration or were never asked, `exakit migrate docker-nano` copies the data later, into the running database. |
| Removing it | Run `exakit uninstall`. It is interactive and lists what it will remove, including the deployment and its data. |
