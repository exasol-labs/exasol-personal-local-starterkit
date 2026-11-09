# Podman troubleshooting

[Back to the README FAQ](../README.md#faq) · [Windows quickstart](windows.md) · [Linux/WSL quickstart](linux.md)

Use this guide for Windows, Linux or WSL2 installs. The macOS kit has its own managed VM and doesn't need Podman. Run the checks with the same user account and in the same environment you used for the install: PowerShell on Windows, or the Linux terminal on Linux/WSL.

These checks do not change your installation:

```text
podman --version
podman info
exakit status --json
exakit preflight
exakit logs
```

If `exakit` isn't available yet, start with the Podman commands. `exakit status --json` gives you the database state and a `remedy`. Read any `remedy_hint` before running the suggested command. A successful `podman info` means Podman is reachable, though the database may still need time to start.

## Common installation blockers

- [Windows: rootful machine and unreachable database](#windows-rootful-machine)
- [Windows: database container stays Created](#windows-database-container-stays-created)
- [Windows: Podman is installed but cannot connect](#windows-connection-failures)
- [WSL2 and virtualization errors](#wsl2-and-virtualization)
- [Linux/WSL: missing rootless ID ranges or helpers](#linux-and-wsl-rootless-permissions)

### Windows rootful machine

On Windows, the database port has only been reachable from a rootless default Podman machine: a rootful one publishes the port as an iptables rule inside the machine, which nothing forwards to Windows. The installer does not check the machine. If a Podman deployment fails to deploy, or deploys but never answers on `127.0.0.1:8563`, it prints the fix below. Check the setting in PowerShell:

```powershell
podman machine inspect --format "{{.Rootful}}"
```

If it returns `true`, run the commands below yourself. Finish other work on the machine first. **These commands stop and restart it, interrupting its containers.**

```powershell
podman machine stop
podman machine set --rootful=false
podman machine start
podman machine inspect --format "{{.Rootful}}"
podman info
```

The inspection should now return `false`, and you can re-run the starter-kit install. Containers, images and volumes created in rootful mode are no longer visible through the rootless connection. They haven't been deleted or migrated. See [Podman's rootful/rootless setting](https://docs.podman.io/en/latest/markdown/podman-machine-set.1.html#rootful).

`EXAKIT_PODMAN_SELFHEAL=1` has no effect here: the kit never switches the Windows machine for you.

### Windows: database container stays Created

When a deploy or start fails, the kit reads the container's own error and shows it, along with the launcher's last lines. You can check it yourself:

```powershell
podman ps -a --filter name=exasol-db
podman inspect --format "{{.State.Error}}" <container-name>
```

A deployment that never started holds no data, so the installer offers to remove it and deploy a fresh one. That question defaults to yes. Set `EXAKIT_REPLACE_DB=0` to keep it.

### Windows connection failures

In PowerShell, check the machine and its connection:

```powershell
podman machine list
podman system connection list
podman info
```

The kit's Windows launcher uses the default machine. If `podman-machine-default` exists but is stopped, run `podman machine start`. If no machine exists, run `podman machine init` followed by `podman machine start`. Before creating another machine, check whether you already have one under a different name or have selected a remote connection.

The installer tries to start a stopped machine automatically. If `podman machine start` still fails, use its error message to check for the WSL or virtualization problems below. Once `podman info` works, re-run an incomplete install. For a database that's already installed but stopped, use `exakit start`. You only need these `podman machine` steps on Windows. The kit runs Podman directly on Linux and inside WSL.

### WSL2 and virtualization

Check WSL from PowerShell:

```powershell
wsl --status
wsl --version
wsl --list --verbose
```

The kit needs WSL2 and won't run on WSL1. If virtualization is disabled, the Virtual Machine Platform feature is missing, or you see an error such as `0x80370102`, follow [Microsoft's WSL troubleshooting](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting). If Windows itself runs in a VM, ask the host administrator whether nested virtualization needs to be enabled. For an outdated WSL installation, run `wsl --update` and restart if prompted.

If you're installing inside a WSL distro, install Podman in that distro too, or enable Docker Desktop's WSL integration for it (the kit uses Docker Engine 29 or newer when it finds it). Keep the kit in your Linux home directory rather than under `/mnt/c`. Podman Desktop on Windows doesn't supply Podman for this install. See the [Linux/WSL quickstart](linux.md). Save your work before running `wsl --shutdown`, as it stops every running WSL distribution, including a WSL-backed Podman machine.

### WSL 2.7 and nftables

Exasol Personal 2.4 puts each deployment on its own network, which Podman builds with its nftables firewall driver. The kernel that WSL 2.6 and older ship has no nftables, so a Podman deploy inside WSL, or the first start of an existing deployment after the launcher update to 2.4, fails with:

```
Error: netavark: nftables error: "nft" did not return successfully while applying ruleset
```

The kit reads `wsl.exe --version` before a fresh Podman deploy and before replacing a Podman deployment (`exakit repair-runtime`), and stops with the fix, changing and deleting nothing. The replace check runs only when the replace can be consented to (`EXAKIT_REPLACE_DB=1`, or a terminal to ask), and a replace is also refused when this run's start already failed with the nftables error. `exakit preflight` fails a fresh Podman deploy on such a kernel; inside WSL, with an existing Podman deployment, it shows a note instead. `exakit update` does not check: it swaps the launcher and changes no data, and if the next `exakit start` then fails with the nftables error below, the kit says the launcher was updated and names `wsl --update`, `wsl --shutdown`, then `exakit start`, with the deployment untouched; `exakit status --json` keeps answering `remedy: "wsl --update"` until a start succeeds. If the release cannot be read (no `wsl.exe`, interop off, no answer), the kit warns and carries on: check it yourself with `wsl --version`. Replacing a deployment is the exception, because its destroy cannot be undone: there an unreadable release stops the replace until `wsl --version` shows 2.7 or newer and you re-run it with `EXAKIT_WSL_CHECKED=1`. `exakit start` names `wsl --update` only when its own output shows the nftables error below; it also names the iptables alternative (inside WSL in the distro's containers.conf, on Windows inside Podman's machine). Update WSL from PowerShell on Windows, restart it, then re-run the command the message names:

```powershell
wsl --update
wsl --shutdown
```

The error comes only from Podman's nftables driver, so a Podman that uses the iptables driver is not affected and the kit does not ask for the update:

- **Podman's machine on Windows.** The kit reads the machine's Podman configuration through `podman machine ssh` (no root needed), and only when the WSL release is below 2.7 or, on a replace, cannot be read. It reads the files Podman reads, in Podman's order: `/usr/share/containers/containers.conf`, `/etc/containers/containers.conf`, `/etc/containers/containers.conf.d/*.conf`, `~/.config/containers/containers.conf`, then `~/.config/containers/containers.conf.d/*.conf`. Only a `firewall_driver` inside the `[network]` table counts, the last one set wins, and the value must be quoted (`firewall_driver = iptables` without quotes does not count). When that is `"iptables"`, the kit lets a fresh deploy and a replace through on any WSL release (`exakit update` has no check to pass). A fresh deploy or a replace starts a stopped machine first, and says so; `exakit preflight` and the refusal messages never start it, and for a stopped machine they say the setting could not be read and name `podman machine start`. An ssh that fails counts as not set, and the release decides. The answer is kept for the rest of the run. Check it yourself with `podman machine ssh "grep -s firewall_driver /usr/share/containers/containers.conf /etc/containers/containers.conf /etc/containers/containers.conf.d/*.conf ~/.config/containers/containers.conf ~/.config/containers/containers.conf.d/*.conf"`.
- **Podman inside a WSL distro.** A machine that cannot update WSL can switch Podman to the iptables driver, inside the distro, with the `iptables` package installed (below). The kit reads the distro's files with the same rule (`~/.config` is `$XDG_CONFIG_HOME` when set, the value must be quoted), checks that the `iptables` command is there, and then does not ask for the update. When the setting is there but `iptables` is not installed, the refusal says so.

On Windows without either, `EXAKIT_CONTAINER_ENGINE=docker` with Docker Desktop is the way through without a WSL update. The kit also does not ask when the distro's Podman reports a network backend other than netavark (`podman info --format '{{.Host.NetworkBackend}}'` answers, for example, `cni`), which cannot hit this error. A Podman that answers `netavark`, or answers nothing, is still checked:

```ini
# ~/.config/containers/containers.conf
[network]
firewall_driver = "iptables"
```

Docker is not affected: Docker Desktop's WSL integration has no such floor. The same floor applies to Podman's machine on Windows, which runs on the WSL kernel too, unless the machine uses the iptables driver (see above).

### Linux and WSL rootless permissions

Rootless Podman needs two things from your Linux account: a range of subordinate user and group IDs in `/etc/subuid` and `/etc/subgid`, and the `newuidmap` / `newgidmap` helpers. The installer checks both before a Podman deployment, offers to repair a gap, and names what is still missing in its "Rootless Podman is not ready" warning (also in `exakit logs setup`). To check by hand:

```bash
podman info
grep "^$USER:" /etc/subuid /etc/subgid
command -v newuidmap newgidmap
```

**Missing helpers.** On Debian or Ubuntu:

```bash
sudo apt-get install -y uidmap
```

On other distributions, install the package the installer's warning names.

**Missing ID ranges.** The installer can add the `/etc/subuid` and `/etc/subgid` entries for you through `sudo`. On a shared or centrally managed machine, ask your administrator first: the new ranges must not overlap another user's. Once the ranges have changed, run this as your normal user, never as root:

```bash
podman system migrate
```

**This stops your running containers**, so finish any work that depends on them first. Podman's own [rootless setup guide](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md) has the full picture.

Then confirm Podman is happy and re-run the installer:

```bash
podman info
```

Two things to keep in mind:

- Run the whole install under your normal account. Installing with `sudo` uses root's separate Podman storage, and the database ends up where your user cannot reach it.
- An unattended install repairs these only when `EXAKIT_PODMAN_SELFHEAL=1` is set and `sudo` works without a password prompt. Otherwise the kit warns, prints the manual fix and carries on; the deploy step says if the gap matters.

## Other Podman issues

### Podman Desktop and Docker Desktop

From Exasol Personal 2.4 the launcher runs a new deployment on Docker Engine 29 or newer (Docker Desktop on Windows, set to Linux containers; Docker Engine or Docker Desktop's WSL integration on Linux and WSL) or on Podman. The kit picks Docker when it is usable and Podman otherwise, and a deployment keeps its engine. You can use the Podman CLI on its own, with Podman Desktop as an optional graphical interface. Windows also needs a Podman machine for the Podman path. On Linux and inside WSL, the kit uses the engine directly.

### Podman is missing or installation failed

On Windows, run `winget install --exact --id RedHat.Podman`. Approve the administrator prompt and reboot if asked. Then open a new PowerShell window so it picks up the updated `PATH`. Run `podman --version` and `podman info` before retrying the starter-kit install.

On Debian/Ubuntu, including a WSL distro, run `sudo apt-get update` followed by `sudo apt-get install -y podman uidmap`. On Fedora/RHEL, use `sudo dnf install -y podman`. For other distributions, use the package-manager command printed by the installer. If an agent or script can't answer a `sudo` password prompt, run this step in your own terminal. Setting `EXAKIT_INSTALL_PODMAN=0` skips automatic Podman installation on Linux/WSL.

Once Podman works, re-run the starter-kit install command. It skips completed steps. Run the kit as your normal user and use administrator privileges only for the system setup steps that need them.

### Cgroups v2 and resource limits

The kit's rootless deployment needs cgroups v2. When the installer finds it off, it names the steps that apply to your platform and carries on; the launcher says if it matters. On Linux, you may need to change the boot configuration and reboot. On WSL, edit `%USERPROFILE%\.wslconfig` on Windows as instructed, then restart WSL. Keep the file's existing settings and save your work before running `wsl --shutdown`, which stops all distributions.

On Linux and inside WSL, `exakit preflight` also checks that rootless Podman gets a `pids` cgroup controller. On Linux, delegate it to your user: create `/etc/systemd/system/user@.service.d/delegate.conf` containing `[Service]` and `Delegate=cpu cpuset io memory pids`, run `sudo systemctl daemon-reload`, then log in again. Inside WSL 2.9 and later, this is the known issue [podman-container-tools/podman#29909](https://github.com/podman-container-tools/podman/issues/29909).

`EXAKIT_PODMAN_SELFHEAL=1` doesn't change kernel boot settings or cgroup delegation, and `EXAKIT_FORCE=1` can't provide missing kernel capabilities. Ask your system administrator if you can't change them yourself.

### Proxy, VPN and certificate errors

Check whether the error names a DNS failure, timeout, proxy login problem or `x509: certificate signed by unknown authority`. The Podman machine may be unable to reach the image registry even when your browser and the kit's downloads work.

Configure the proxy in Podman Desktop, if you use it, and in the Podman machine. Install your organization's trusted CA where Podman needs it, following [Podman's restricted-environment guide](https://podman-desktop.io/docs/proxy). For VPN problems on Windows, use the [Podman Windows troubleshooting guide](https://podman-desktop.io/docs/troubleshooting/troubleshooting-podman-on-windows). User-mode networking may help, but a networking change can affect other workloads. Ask IT to allow the registry or download host named in the error, and keep TLS and checksum verification enabled.

### Memory and disk space

Check available memory and disk space both on the host and where Podman runs. WSL can have a lower memory limit than Windows, and the disk holding Podman's storage can fill up even if the directory where you downloaded the kit has space. Start with `exakit preflight` and `podman info`, then use `podman system df` to check Podman's storage usage.

The kit needs at least 8 GB RAM and 20 GB free disk. Close unused workloads or free space without deleting database volumes. To change WSL limits, follow [Microsoft's `.wslconfig` documentation](https://learn.microsoft.com/en-us/windows/wsl/wsl-config). You'll need to restart WSL, which interrupts its running distributions. `EXAKIT_FORCE=1` bypasses the check but doesn't give the database more resources.

### Database startup and connection errors

Rootless Podman can open the published port before Exasol is ready to accept queries. Check `exakit status --json` and the installer log. If the installer is still active (`installing: true`), let it finish before running `exakit start` again. Once it reports `running`, check that the database answers a query:

```text
exakit sql --json "SELECT CURRENT_TIMESTAMP"
```

The normal startup wait is 150 seconds. The first rebuild after a launcher update can wait 900 seconds. To allow 600 seconds for a slow start, run `$env:EXAKIT_PERSONAL_READY_TIMEOUT = '600'` in PowerShell or `export EXAKIT_PERSONAL_READY_TIMEOUT=600` on Linux/WSL before retrying. This setting overrides both waits, so choose a larger value if a rebuild needs longer.

If status says `conflict`, find the program using the port and stop it when it's safe to do so. It may be another kit running in Windows or WSL. Check `exakit info` for your database's actual port. Use `exakit start` if status says `stopped`. If the installer has ended with `installing: false` and missing steps, follow its install remedy to resume.

### Resets and data recovery

Try the fix for the reported error first. Re-running the installer resumes unfinished steps. **`podman system reset`, deleting a Podman machine, or removing volumes can destroy data**, including data from other projects that share the machine. Avoid these as routine install fixes. Check [what Podman reset removes](https://docs.podman.io/en/latest/markdown/podman-system-reset.1.html) before considering a reset.

If `exakit status --json` reports `interrupted`, starting it again won't repair the deployment. The suggested `exakit repair-runtime` command **destroys the database and its data**, then reloads only the bundled datasets. Before using it, decide how to preserve any data you need and make sure you accept the loss.

## Getting help

When opening an issue, include your operating system and architecture, whether you used PowerShell or WSL, `podman --version`, the error from `podman info`, and `exakit status --json` if available. On Windows, also include `podman machine list` and `wsl --version`. Use `exakit logs` to find the relevant log, then `exakit logs <target>` to read it. Share the failing step and nearby log lines, with secrets and private details removed. Never post credential files or AI-client MCP configs because they contain database passwords.
