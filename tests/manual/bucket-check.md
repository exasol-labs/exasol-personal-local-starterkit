# Manual check: the bucket directory on both platforms (T5, AC-ML4.1)

Run this once on a Windows 11 laptop and once on a macOS machine against Launcher 2.3.0. It answers two questions the automated suites cannot: does a file the kit drops into the deployment's bucket directory arrive at the printed `/buckets/...` path inside a UDF (AC-ML4.1, the week-1 gate for ML-4, ML-5 deploy and F-1), and can a UDF **write** under `/buckets` (decides the >1 MB model path, `.plan/design.md` §6). It needs a running kit with the udf-devkit add-on; 10 minutes.

| Item | Detail |
|---|---|
| Branch | `feat/persona-v05-completion` (or the release it becomes) |
| Covers | `.plan/requirements.md` ML-4 AC4.1, "Bucket directory" principle (§2.2); `.plan/design.md` §6 (writability), §9 (`model put`/`rm`) |
| Pass criterion | step 4 returns the file's size and sha256 unchanged on **both** platforms. Step 5 has no pass/fail: its answer is recorded. |
| Known so far | macOS (T16, 2026-10-27): read via `/buckets` yes; write `OSError(30)` read-only. Windows and Linux: unknown. |

## How the kit resolves the directory (read before running)

All platforms resolve the deployment bucket through `marketplace/udf_bucket.py`. The model and UDF-file commands use that resolver; the notebook check reads `exakit model list --json` and probes the reported UDF path. Verify visibility from a real UDF: a host folder alone does not prove that the database can read it. The resolver creates the default bucket when the deployment mapping supports it. Preserve existing mappings and model files during verification.

## Steps

Windows: Windows PowerShell 5.1, not as administrator. macOS: zsh. `exakit sql --write --file` is the kit's SQL path (it runs over the `starter-kit` exapump profile, `setup/exakit` `cmd_sql`); the raw form is `exapump sql -p starter-kit < file.sql` (macOS/Linux) or `cmd /c "exapump sql -p starter-kit < file.sql"` (Windows: a PowerShell pipe prepends a BOM and breaks the batch, `setup/lib/exapump.ps1:638`).

### 1. The database is running
```
exakit status
```
Expected: the `Database` line ends `· reachable`; exit 0 (`echo $?` / `$LASTEXITCODE`). Otherwise `exakit start` and wait; a `conflict` or `not reachable` here is **launcher**, stop.

### 2. The Python container answers a smoke UDF
```
exakit udf-setup
```
Expected: `Python UDFs run on PYTHON3 (Python 3.12.x)` (or `The official PYTHON3 container is already installed`) and `Use it in SQL: CREATE OR REPLACE PYTHON3 SCALAR SCRIPT ...`; exit 0. Exit 4–7 names the failed step (`download`, `verify`, `install`, `smoke`): **kit** unless the remedy says Podman/WSL (**environment**).

### 3. Drop a small file and note the printed path
macOS:
```sh
printf 'bucket-check %s\n' "$(date +%s)" > ~/bucket-check.txt && shasum -a 256 ~/bucket-check.txt && wc -c < ~/bucket-check.txt
exakit model put ~/bucket-check.txt
```
Windows:
```powershell
"bucket-check $(Get-Date -UFormat %s)" | Set-Content -NoNewline $HOME\bucket-check.txt; (Get-FileHash $HOME\bucket-check.txt).Hash.ToLower(); (Get-Item $HOME\bucket-check.txt).Length
exakit model put $HOME\bucket-check.txt
```
Expected, three lines, exit 0:
```
Copied bucket-check.txt into the bucket directory: <bucket dir>/models/bucket-check.txt
sha256 <64 hex>, <n> bytes, recorded
A UDF reads it as: /buckets/bfsdefault/default/models/bucket-check.txt
```
Record `<bucket dir>` (expected `~/.exasol/personal/deployments/default/local/runtime/exa/bucketfs/bfsdefault/default`, backslashes on Windows) and check the sha256 equals the one you computed. Exit 3 `The deployment has no BucketFS folder at ...` means `local/runtime/exa` is missing: **launcher** (the layout changed) if `exakit status` is reachable, else **environment**. Exit 4: udf-devkit not installed, run `exakit marketplace udf-devkit` then step 2.

### 4. A UDF reads the file at the printed path (AC-ML4.1)
Save as `~/bucket-read.sql` (`$HOME\bucket-read.sql`):
```sql
CREATE OR REPLACE PYTHON3 SCALAR SCRIPT EXAKIT_UDF.BUCKET_READ(p VARCHAR(2000)) EMITS (ITEM VARCHAR(20), DETAIL VARCHAR(200)) AS
import hashlib, os
def run(ctx):
    try:
        with open(ctx.p, 'rb') as handle:
            blob = handle.read()
        ctx.emit('size', str(len(blob))); ctx.emit('sha256', hashlib.sha256(blob).hexdigest())
    except OSError as err:
        ctx.emit('error', str(err)); ctx.emit('parent', str(os.path.isdir(os.path.dirname(ctx.p))))
```
Then (same on both platforms; on Windows write `$HOME\bucket-read.sql`):
```
exakit sql --write "CREATE SCHEMA IF NOT EXISTS EXAKIT_UDF"
exakit sql --write --file ~/bucket-read.sql
exakit sql "SELECT EXAKIT_UDF.BUCKET_READ('/buckets/bfsdefault/default/models/bucket-check.txt')"
```
Expected: two rows, `size` = the byte count from step 3 and `sha256` = the digest from step 3. **Pass for this platform.**
Failure reading: `error  [Errno 2] No such file ...` with `parent False` = the VM/container does not mount the host folder (**launcher**); `parent True` + Errno 2 = the kit put the file somewhere else than it printed (**kit**); `Errno 13` = permissions on the mount (**launcher**); the CREATE SCRIPT itself failing = step 2 was not green (**environment**).

### 5. Can a UDF write under /buckets? (decides design §6)
Save as `~/bucket-write.sql`:
```sql
CREATE OR REPLACE PYTHON3 SCALAR SCRIPT EXAKIT_UDF.BUCKET_WRITE(p VARCHAR(2000)) RETURNS VARCHAR(2000) AS
import os
def run(ctx):
    try:
        os.makedirs(os.path.dirname(ctx.p), exist_ok=True)
        with open(ctx.p, 'w') as handle:
            handle.write('written from a UDF')
        return 'written: ' + str(os.path.getsize(ctx.p))
    except OSError as err:
        return 'OSError %s: %s' % (err.errno, err)
```
```
exakit sql --write --file ~/bucket-write.sql
exakit sql "SELECT EXAKIT_UDF.BUCKET_WRITE('/buckets/bfsdefault/default/models/udf-wrote.txt')"
```
Expected on macOS (T16): `OSError 30: [Errno 30] Read-only file system: ...`. Record whatever Windows returns verbatim. If it says `written: 18`, also check the host side: `dir <bucket dir>\models` must list `udf-wrote.txt`; a file the UDF sees but the host does not is "writable: inside the VM only" and does not count for §6. Clean up: `exakit sql --write "DROP SCRIPT EXAKIT_UDF.BUCKET_WRITE"` and delete `udf-wrote.txt` from the host folder if it exists.

### 6. Remove the dropped file
```
exakit model rm bucket-check.txt
exakit model list
exakit sql --write "DROP SCRIPT EXAKIT_UDF.BUCKET_READ"
```
Expected: `Removed bucket-check.txt from the bucket directory and the kit's record`; `model list` no longer shows it and the host folder has no `bucket-check.txt`; exit 0. A file still on disk after exit 0 is **kit**.

## Failure classification

| Class | Meaning | Example |
|---|---|---|
| **Launcher** | Launcher 2.3.0 does not present the folder as the kit assumes | step 4 `parent False`; step 3 exit 3 while the database is reachable; `Errno 13` |
| **Kit** | the kit's path or command differs from what it printed | printed path and real file differ; `rm` leaves the file; sha256 mismatch |
| **Environment** | this machine, not the design | database stopped; Podman machine down; udf-devkit not installed; WSL without `pids` |

## Results (copy into `.plan/design.md` §6/§9 and the T5 row)

| Platform (chip / Windows build, Launcher) | Bucket dir path printed by step 3 | Readable by UDF (step 4: size, sha256 match) | Writable by UDF (step 5 verbatim; host sees the file?) | Time | Failure class + step | Notes |
|---|---|---|---|---|---|---|
| macOS Apple silicon, Launcher 2.3.0 (T16, 2026-10-27) | `~/.exasol/personal/deployments/default/local/runtime/exa/bucketfs/bfsdefault/default` | yes (via `/buckets/bfsdefault/default/models/...`) | no: `OSError 30` read-only file system | — | — | T6: `check_bucket` FAIL on a fresh deployment because `bfsdefault/default` is only created by the first `model put` |
| macOS (re-run, this plan) | | | | | | |
| Windows 11 (build ____), Launcher 2.3.0 | | | | | | |

Decision after both rows are filled: writable on neither → §6 stays as written (>1 MB model = error row, model stays client-side); writable on Windows/Linux only → §6 gains a platform note and the template keeps `MODEL_DIR = /buckets/bfsdefault/default/models` (`packages/exasol-mlflow/exasol_mlflow/udf.py:17`) with the macOS error path; either platform not readable → AC-ML4.1 fails and ML-4 is dropped (requirements §2.2 step 10).
