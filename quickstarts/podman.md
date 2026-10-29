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

- [Windows: rootful and rootless machines](#windows-rootful-and-rootless-machines)
- [Windows: the pids controller](#windows-the-pids-controller)
- [Windows: DNS inside the machine](#windows-dns-inside-the-machine)
- [Windows: database container stays Created](#windows-database-container-stays-created)
- [Windows: Podman is installed but cannot connect](#windows-connection-failures)
- [WSL2 and virtualization errors](#wsl2-and-virtualization)
- [Linux/WSL: missing rootless ID ranges or helpers](#linux-and-wsl-rootless-permissions)

### Windows rootful and rootless machines

The kit supports both rootful and rootless Podman machines. It reports the mode in the compatibility check and doesn't switch it unless it finds a specific problem and you agree. Check the mode in PowerShell:

```powershell
podman machine inspect --format "{{.Rootful}}"
podman version
```

If the database container runs but nothing answers on `127.0.0.1:8563` from Windows, the kit tells you why:

- **Podman 6.0.0 to 6.1.0 on a rootful machine.** These versions don't forward a rootful machine's published ports to Windows. The bug is fixed in 6.1.1, but a machine only gets the fix when you recreate it. Upgrade Podman, then recreate the machine. **This deletes the machine and every container and image in it.**

  ```powershell
  podman machine rm
  podman machine init
  podman machine start
  ```

- **Any other version.** Restart the machine with `podman machine stop` and `podman machine start`, then run `exakit start`. As another option, the kit offers to switch the machine to rootless mode. It switches back if rootless mode has no `pids` controller (see below), because the database can't start there.

Switching modes stops and restarts the machine, interrupting its containers. Containers, images and volumes created in one mode aren't visible in the other. They haven't been deleted or migrated. See [Podman's rootful/rootless setting](https://docs.podman.io/en/latest/markdown/podman-machine-set.1.html#rootful).

For an unattended Windows install, set `$env:EXAKIT_PODMAN_SELFHEAL = '1'` before running the installer only if you can allow the machine to restart. Without it, the installer names the cause and the commands but changes nothing. `EXAKIT_FORCE=1` has nothing to do with the machine's mode.

### Windows: the pids controller

The database container runs with a process (`pids`) limit. Since WSL 2.9, a rootless Podman machine can get no cgroup controllers at all, so the container stays `Created` with `crun: controller 'pids' is not available ... OCI runtime error`. This is a known upstream issue: [podman-container-tools/podman#29909](https://github.com/podman-container-tools/podman/issues/29909). Check the machine:

```powershell
podman info --format "{{.Host.CgroupControllers}}"
```

If the list doesn't contain `pids`, a rootful machine is the current workaround. The installer offers to make the switch for you. To do it yourself:

```powershell
podman machine stop
podman machine set --rootful
podman machine start
podman info --format "{{.Host.CgroupControllers}}"
```

Then re-run the starter-kit install. If a rootful machine still lists no `pids`, the database can't start in this machine until WSL or Podman fixes the issue. The kit stops before deploying and names the cause instead of waiting for a database that can't start.

### Windows: DNS inside the machine

The image is pulled inside Podman's machine, which can fail to resolve names even when Windows can. The error reads `lookup registry-1.docker.io: Temporary failure in name resolution`. Before a fresh deploy, the kit checks this with:

```powershell
podman machine ssh getent hosts registry-1.docker.io
```

On Windows 11 22H2 and later, turn on WSL DNS tunneling. Add this to `%USERPROFILE%\.wslconfig`, keeping any settings already in the file:

```ini
[wsl2]
dnsTunneling=true
```

Then restart WSL and the machine. **`wsl --shutdown` stops every running WSL distribution**, so save your work first:

```powershell
wsl --shutdown
podman machine start
```

The installer offers to make this edit and restart for you. On older Windows, switch the machine to user-mode networking instead:

```powershell
podman machine stop
podman machine set --user-mode-networking
podman machine start
```

### Windows: database container stays Created

When a deploy or start fails, the kit reads the container's own error and shows it, along with the launcher's last lines. You can check it yourself:

```powershell
podman ps -a --filter name=exasol-db
podman inspect --format "{{.State.Error}}" <container-name>
```

A `pids` error is covered [above](#windows-the-pids-controller). A deployment that never started holds no data, so the installer offers to remove it and deploy a fresh one. That question defaults to yes. Set `EXAKIT_REPLACE_DB=0` to keep it.

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

If you're installing inside a WSL distro, install Podman in that distro too. Keep the kit in your Linux home directory rather than under `/mnt/c`. Podman Desktop on Windows doesn't supply Podman for this install. See the [Linux/WSL quickstart](linux.md). Save your work before running `wsl --shutdown`, as it stops every running WSL distribution, including a WSL-backed Podman machine.

### Linux and WSL rootless permissions

Rootless Podman needs two things from your Linux account: a range of subordinate user and group IDs in `/etc/subuid` and `/etc/subgid`, and the `newuidmap` / `newgidmap` helpers. Check what is missing:

```bash
exakit preflight
```

**Missing helpers.** On Debian or Ubuntu:

```bash
sudo apt-get install -y uidmap
```

On other distributions, install the package the diagnostic names.

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
- An unattended install repairs these only when `EXAKIT_PODMAN_SELFHEAL=1` is set and `sudo` works without a password prompt. Otherwise the kit prints the manual fix and stops.

## Other Podman issues

### Podman Desktop and Docker Desktop

The launcher needs Podman on Windows, Linux and WSL. Docker Desktop doesn't meet that requirement. You can use the Podman CLI on its own, with Podman Desktop as an optional graphical interface. Windows also needs a Podman machine. On Linux and inside WSL, the kit uses Podman directly.

### Podman is missing or installation failed

On Windows, run `winget install --exact --id RedHat.Podman`. Approve the administrator prompt and reboot if asked. Then open a new PowerShell window so it picks up the updated `PATH`. Run `podman --version` and `podman info` before retrying the starter-kit install.

On Debian/Ubuntu, including a WSL distro, run `sudo apt-get update` followed by `sudo apt-get install -y podman uidmap`. On Fedora/RHEL, use `sudo dnf install -y podman`. For other distributions, use the package-manager command printed by the installer. If an agent or script can't answer a `sudo` password prompt, run this step in your own terminal. Setting `EXAKIT_INSTALL_PODMAN=0` skips automatic Podman installation on Linux/WSL.

Once Podman works, re-run the starter-kit install command. It skips completed steps. Run the kit as your normal user and use administrator privileges only for the system setup steps that need them.

### Cgroups v2 and resource limits

The kit's rootless deployment needs cgroups v2. Run `exakit preflight` for the steps that apply to your platform. On Linux, you may need to change the boot configuration and reboot. On WSL, edit `%USERPROFILE%\.wslconfig` on Windows as instructed, then restart WSL. Keep the file's existing settings and save your work before running `wsl --shutdown`, which stops all distributions.

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
