# Manual test plan: Windows Podman self-heal

Run these on a real Windows machine, in **Windows PowerShell** (not as administrator unless a step says so). The automated suites cover this change with simulated Podman responses only. This plan covers what only a real Windows and WSL machine can show.

| Item | Detail |
|---|---|
| Branch | `fix/windows-podman-selfheal` |
| Covers | rootful and rootless support, the Podman readiness check (machine, DNS, `pids`), the real container error, the never-started flow, `exakit start`, `repair-runtime`, `status` |
| Best machine | one on WSL 2.9 or later, where rootless Podman lacks the `pids` controller (for example the hackathon laptop from the incident), plus one where it works |

## 0. Setup

**0.1 Record the machine.** Attach this output to the results.
```powershell
wsl --version
```
```powershell
podman version
```
```powershell
podman machine inspect --format "{{.Rootful}}"
```
```powershell
podman info --format "{{.Host.CgroupControllers}}"
```
If the last command's output contains `pids`, the machine is **pids-OK**. Otherwise it is **pids-missing**. Each test below says which kind it needs.

**0.2 Get the branch.** The staging repo is private, so install from a local checkout:
```powershell
git clone -b fix/windows-podman-selfheal https://github.com/ranjanm-chn/exasol-personal-local-starterkit-backup.git $HOME\kit-selfheal
```

**0.3 How to install from it.** This is used in every test below:
```powershell
$env:EXAKIT_LOCAL_KIT="$HOME\kit-selfheal"; & "$HOME\kit-selfheal\install.ps1"
```
To run **unattended** (no terminal answers), pipe nothing into it:
```powershell
$null | powershell -NoProfile -ExecutionPolicy Bypass -Command "`$env:EXAKIT_LOCAL_KIT='$HOME\kit-selfheal'; & '$HOME\kit-selfheal\install.ps1'"
```

**0.4 Clean start between tests**, when a test says so:
```powershell
exakit uninstall
```

**0.5 After each test, collect:**
```powershell
exakit status
```
```powershell
exakit logs setup --lines 200
```

## 1. Rootful and rootless both supported

### TC-01: a rootful machine is accepted
- **Needs:** any machine; clean start.
- **Steps:**
  1. Make the machine rootful:
     ```powershell
     podman machine stop; podman machine set --rootful; podman machine start
     ```
  2. Install (0.3).
- **Expected:**
  - The compatibility line reads `Compatibility check passed (windows amd64, NN GB RAM, Podman machine rootful)`.
  - No "rootful ... not reachable" refusal, and no offer to switch to rootless.
  - On a pids-OK rootful machine, the install completes and `exakit status` shows the database running.
  - Windows reaches `127.0.0.1:8563`: the connection panel appears and `exakit status` says reachable.

### TC-02: a rootless machine is accepted unchanged
- **Needs:** a pids-OK machine; clean start.
- **Steps:**
  1. Make the machine rootless:
     ```powershell
     podman machine stop; podman machine set --rootful=false; podman machine start
     ```
  2. Install.
- **Expected:**
  - The compatibility line ends `Podman machine rootless`.
  - The install completes as before, and the database is running.

### TC-03: `exakit preflight` only reports
- **Needs:** a rootful machine.
- **Steps:**
  1. Note the machine's `LastUp`:
     ```powershell
     podman machine inspect --format "{{.LastUp}}"
     ```
  2. Run:
     ```powershell
     exakit preflight
     ```
  3. Read `LastUp` again.
- **Expected:**
  - Preflight reports the mode and passes.
  - It doesn't stop or restart the machine: `LastUp` is unchanged, and nothing asks to switch modes.

## 2. Podman readiness check

### TC-04: missing `pids`, interactive, accept the fix
- **Needs:** a pids-missing **rootless** machine; clean start.
- **Steps:** install, and answer **Y** to the switch question.
- **Expected:**
  1. The kit warns: `Podman's machine offers no 'pids' cgroup controller, so the database container cannot start in it (podman-container-tools/podman#29909).`
  2. It asks: `Switch Podman's default machine to rootful, where the limit works? ... (separate storage - nothing is deleted)`, default Y.
  3. The machine stops, switches to rootful and starts. Then: `Podman's rootful machine offers the pids controller`.
  4. The deploy runs and the database comes up. `podman machine inspect --format "{{.Rootful}}"` prints `true`.
- **If the rootful machine still lacks `pids`:**
  - The kit says `Podman's machine is rootful now, and still offers no 'pids' controller.`, names the issue, and stops step 2 without a 150 s wait.
  - Record this result, because it means the WSL build needs an upstream fix.

### TC-05: missing `pids`, interactive, decline
- **Needs:** a pids-missing rootless machine; clean start.
- **Steps:** install, and answer **n** to the switch question.
- **Expected:**
  - `Not changed.`, then `Fix: podman machine stop; podman machine set --rootful; podman machine start - then re-run the installer: ...`
  - No deploy starts and there is no 150 s wait. The machine is still rootless.
  - The install ends with one failed step whose reason contains `podman-container-tools/podman#29909`.

### TC-06: missing `pids`, unattended
- **Needs:** a pids-missing rootless machine; clean start.
- **Steps:**
  1. Run the unattended install (0.3) without `EXAKIT_PODMAN_SELFHEAL`.
  2. Repeat with it set:
     ```powershell
     $env:EXAKIT_PODMAN_SELFHEAL="1"
     ```
- **Expected:**
  - **Without the variable:** nothing about the machine changes. The output includes `so an unattended run has to opt in:  EXAKIT_PODMAN_SELFHEAL=1`, and the reason names #29909.
  - **With it:** the machine switches to rootful without a question, as in TC-04 step 3.
- **Afterwards:** close the window so the variable doesn't carry into later tests.

### TC-07: DNS failure before a fresh deploy
- **Needs:** Windows 11 22H2 or later (build 22621+); clean start.
- **Steps:**
  1. Back up `.wslconfig`, and give it existing content to check it's preserved:
     ```powershell
     Copy-Item $HOME\.wslconfig $HOME\.wslconfig.bak -ErrorAction SilentlyContinue; Set-Content $HOME\.wslconfig "[wsl2]`r`nmemory=8GB`r`n`r`n[experimental]`r`nautoMemoryReclaim=gradual" -Encoding ASCII
     ```
  2. Break DNS inside the machine. This is temporary; a WSL restart undoes it:
     ```powershell
     podman machine ssh "echo nameserver 192.0.2.1 | sudo tee /etc/resolv.conf"
     ```
  3. Install, and answer **Y** to the DNS question.
- **Expected:**
  1. `Podman's machine cannot resolve registry-1.docker.io, so the database image cannot be downloaded.`
  2. The question: `Turn on WSL DNS tunneling (dnsTunneling=true in .wslconfig) and restart WSL? 'wsl --shutdown' stops every running WSL distribution, not only Podman's`.
  3. After Y: WSL restarts, then `Podman's machine resolves registry-1.docker.io now`, and the deploy continues.
  4. `Get-Content $HOME\.wslconfig` still has `memory=8GB` and the `[experimental]` section. `dnsTunneling=true` appears once, under `[wsl2]`.
- **Also:**
  - Re-run the install. `.wslconfig` gets no second `dnsTunneling` line.
  - Answering **n** instead stops before any deploy with the `add 'dnsTunneling=true' under [wsl2] ...` fix line, and nothing is pulled.
- **Afterwards:** restore with `Move-Item -Force $HOME\.wslconfig.bak $HOME\.wslconfig` if you backed up.

### TC-08: `exakit start` brings Podman's machine back
- **Needs:** a working install with the database running.
- **Steps:**
  1. Stop everything:
     ```powershell
     exakit stop; podman machine stop
     ```
  2. Start the kit:
     ```powershell
     exakit start
     ```
- **Expected:**
  - The kit starts Podman's machine itself (`Podman's machine is running`), then the database.
  - `exakit status` shows it running.
  - The old behaviour was a wait on a database whose Podman machine was off.

## 3. The real error, and no long waits

### TC-09: a container that can't start is named
- **Needs:** a pids-missing rootless machine with the kit installed (TC-05 leaves one).
- **Steps:**
  1. Create a deployment directly with the launcher. This bypasses the kit's check on purpose:
     ```powershell
     & "$HOME\.exasol-starter-kit\bin\exasol.exe" deploy
     ```
  2. Wait for it to finish.
  3. Run:
     ```powershell
     exakit status
     ```
  4. Run:
     ```powershell
     exakit start
     ```
- **Expected:**
  - `exakit status`: the Database line says `the launcher records this deployment as failed (it never finished starting); the database container could not start: crun: controller 'pids' is not available ...`.
  - `exakit start`: the readiness check reports the `pids` problem (and offers the fix) before any wait.
  - If it waits, the wait ends within about 15 s once Podman's error is there, with `The database container could not start: ...`, not after 150 s.

### TC-10: the launcher's own output on a failed deploy
- **Needs:** any deploy failure (TC-05 or TC-11).
- **Expected:**
  - The last lines of the launcher's output are printed on screen under the failure. Before this change they were only in the log.
  - If Podman itself fails to answer, a `What it said: ...` line quotes it.

## 4. Deployments that never started

### TC-11: a never-started deployment is offered for replacement
- **Needs:** a pids-OK machine; clean start.
- **Steps:**
  1. Install. When `Deploying Exasol Personal locally` appears, turn Wi-Fi off. Leave it off until the step fails, then turn it back on.
  2. Re-run the install.
- **Expected:**
  1. `The launcher records this deployment as failed - retrying its deploy.`
  2. When the retry can't bring it up, the question is `This deployment never started, so it holds no data. Remove it and deploy a fresh one? [Y/n]`, default **Y**.
  3. The kit does **not** ask `Start the existing database and keep its data?`.
  4. After Enter: `Removing the deployment that never started, and deploying a fresh one.`, then the install completes.
- **Also:**
  - With `$env:EXAKIT_REPLACE_DB="0"`, nothing is deleted: `Nothing was deleted. ... re-run with EXAKIT_REPLACE_DB=1 to replace it`.
  - With `$env:EXAKIT_REUSE_DB="1"`, the old questions appear instead.

### TC-12: a deployment that did run keeps the old questions
- **Needs:** a working install whose database has answered at least once.
- **Steps:**
  1. Stop the database:
     ```powershell
     exakit stop
     ```
  2. Re-run the install.
- **Expected:**
  - `An Exasol deployment was found, not running.`, then `Start the existing database and keep its data? [Y/n]`, exactly as before.
  - The never-started question does not appear.
  - Pressing Enter keeps the data, and the database starts.

## 5. Repair and status

### TC-13: `repair-runtime` asks once and reports honestly
- **Needs:**
  - **Run A:** a working install.
  - **Run B:** a pids-missing rootless machine where you decline the fix.
- **Steps:**
  1. Run:
     ```powershell
     exakit repair-runtime --yes
     ```
  2. Then, separately:
     ```powershell
     exakit repair-runtime --yes --json
     ```
- **Expected:**
  - No second `DELETE ...` question after the confirmation.
  - **Run A:** the database is rebuilt, and `--json` reports repaired.
  - **Run B:** `--json` does **not** report repaired. It names the failure reason (#29909).

## 6. Optional

### TC-14: rootful ports on Podman 6.0.x to 6.1.0
- **Needs:** Podman 6.0.x or 6.1.0, and a rootful machine.
- **Expected:**
  - If the container runs but `127.0.0.1:8563` doesn't answer: `... does not forward a rootful machine's ports to Windows - a known regression in Podman 6.0.0 to 6.1.0, fixed in 6.1.1.`
  - The fix line names upgrading Podman and recreating the machine.

### TC-15: Linux or WSL native (Bash installer)
- **Needs:** Ubuntu on WSL 2.9 or later, with rootless Podman inside it, where `podman info --format '{{.Host.CgroupControllers}}'` lacks `pids`.
- **Expected:** `exakit preflight` and the installer name the missing `pids` controller and #29909, as advice only. Nothing runs `sudo` for it.

## Results

| Test | Machine (pids-OK / pids-missing, rootful / rootless) | Pass / Fail | Notes (attach `exakit logs setup --lines 200` on a failure) |
|---|---|---|---|
| TC-01 | | | |
| TC-02 | | | |
| TC-03 | | | |
| TC-04 | | | |
| TC-05 | | | |
| TC-06 | | | |
| TC-07 | | | |
| TC-08 | | | |
| TC-09 | | | |
| TC-10 | | | |
| TC-11 | | | |
| TC-12 | | | |
| TC-13 | | | |
| TC-14 | | | |
| TC-15 | | | |
