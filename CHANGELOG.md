# Changelog

## Unreleased

**A rate-limited GitHub no longer stops the exapump install.** The kit asks
the GitHub release API for a version's checksum, and that API allows 60
unauthenticated requests an hour per address - repeated installs, or an office
behind one NAT, run out. When the version being installed has no checksum in
versions.json or in the kit's pinned table and the API will not answer, setup
now installs the pinned fallback release (exapump 0.13.0) instead, verified
against its pinned digest, and says so - where before it stopped with "refusing
to install an unverified exapump binary". The pinned table carries the 0.13.0
digests for all five platforms. Under the default manifest policy the digest
comes from versions.json and the API is never asked, so this only changes
`EXAKIT_VERSION_POLICY=latest` and explicit version overrides.
`EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1` keeps its meaning: install the requested
version unverified. Carried over from the production hotfix
(exasol-labs/exasol-personal-local-starterkit#24).

**Sample data loads on Windows again, first time.** A fresh Windows install
could end with "Dataset(s) tpch did not load": five of TPC-H's eight tables
empty. The database runs inside the Podman WSL machine and reads each file back
from exapump on the host, and on that link the engine loses the **last 10-90 KB
of a file** - `ETL-5105 ... failed after 393216 bytes. [transfer closed with
outstanding read data remaining]` - on most attempts for files between about
400 KB and a few MB, while files under ~390 KB never failed. The two retries
already there mostly repeated the same cut (customer.csv needed nine attempts
by hand). A file that is cut is now re-sent in 128 KB pieces instead, each its
own attempt, and the pieces go into a staging copy of the target
(`CREATE TABLE ... LIKE`) that ONE `INSERT ... SELECT` moves across only once
every piece is in - so the target is never left half-loaded, and a table you
were appending to is exactly as it was if the load still fails. Measured
against a live deployment: three full TPC-H loads through the kit's loader, no
failures, every row count exact. Your own CSV files get the same recovery. An
upload that fails with **no output at all** - seen in the same runs, a 415-byte
file among them - is retried too, and its exit code is now written to the log
instead of nothing. `EXAKIT_UPLOAD_PIECE_KB` sets the piece size (0 turns
piecing off).

**The Podman install stopped asking, and stopped shouting.** It used to put a
y/n in the middle of the install and then three screens of `apt` unpacking
twenty-four packages through a run that gives every other step one line. The
question is gone — the database runs through Podman and you asked for the
database, so a y/n whose only sensible answer is yes bought nothing — and the
package manager now runs behind the spinner, with every line it printed in the
logfile. What is left on screen is one line saying Podman is missing, a
password prompt **only when `sudo` actually wants one** (decided at runtime by
`sudo -n true`, not guessed), and the spinner. `EXAKIT_INSTALL_PODMAN=0` is the
way out for a run where package installs are somebody else's job: the database
step is recorded as not finished, and the rest of the install completes.
Moving apt behind the spinner is also why its prompts are now turned off at the
source. `needrestart` ships by default on Ubuntu 22.04 and later and asks which
services to restart; dpkg asks about config files. On screen those were
answerable, and behind a spinner they are not - the install waits on stdin for
an answer nobody can see while the only thing moving is a counter, measured at
over 500 seconds before anyone gave up. `DEBIAN_FRONTEND`, `NEEDRESTART_MODE`
and dpkg's force-conf options stop the asking, and the command is run with its
input closed so anything that still asks fails in a second with the command to
run by hand.
The compatibility check no longer pre-announces the install either — the step
that does it says it, a few seconds later.

**An upgrade no longer offers you the kit's own sample data back.** Installing
0.2.0 over a kit that had loaded the energy dataset said "1 table(s) in 1
schema(s) of your own" and offered to migrate it - on a database holding
nothing but the kit's own samples. The one table was ENERGY.ENERGY_READINGS,
and the crossing works out what belongs to the kit by reading the CSV files
each dataset ships. That table has no CSV: energy generates its 108,000 rows in
02_load_data.sql, so it was invisible to the catalog and fell through to "the
user's own". The same catalog is what tells the restore to stand aside for a
table the dataset load is about to create, so those rows were also copied out,
restored, and then replaced by the dataset load a few minutes later. The
catalog now also reads the tables dataset.conf already declares in `markers=`,
which covers the ones no CSV accounts for; a declared table with no file behind
it has no row count to compare against, so it counts as the kit's own and stays
where it is. A database that holds only the kit's samples now says nothing at
all, which is what it always meant to do.

**A machine without Podman is given Podman, not turned away.** On Linux and in
WSL the install refused: "This machine is not ready ... 'podman' is not on
PATH", with a package-manager command to run and the whole install to start
again. The database runs through Podman, so the kit now fetches it where it is
needed - between the launcher step and the database step - and says so first:
one line naming what is missing, and the version it ended up with. (This
shipped asking a y/n first; see the entry above, which removed it.)
apt, dnf, yum, zypper, pacman and apk are known, and on
Debian and Ubuntu `uidmap` comes along in the same command - rootless Podman
needs it, and without it the failure arrives much later inside a container
start, naming neither. The gate still refuses before anything is downloaded
where none of that can work: no package manager it knows, or no way to become
root.

**Windows says it too, where the launcher is the one that installs.** There
the kit does not fetch Podman itself - `exasol install local` does, through
winget - so the deploy step now names Podman when it is missing, says the
launcher is about to install it and that Windows may ask for administrator
approval, and gives the command to run if that is refused. An unelevated
winget on a managed laptop does fail, and the first a user heard of it was
the launcher's own error, mid-deploy, with no mention of Podman at all; a
deploy that fails with Podman still absent now says that is what failed.
The clause promising a Podman install on every deploy, needed or not, is
gone.

**No Podman is a step that did not finish, not the end of the run.** Saying no
to the Podman install used to close the whole installer, and so did a machine
whose package manager the kit does not know - taking the launcher, exapump, the
AI bridge, pyexasol and the `exakit` command that repairs all of them with it,
none of which the user had declined and none of which need Podman. It is now
the same shape as every other step that cannot finish: the database step
records itself, the closing summary names it with the one command that
completes it (re-running the install command), and the four steps that do need a database say
so once, together, instead of failing one at a time. The requirements gate no
longer stops either - it says what is missing and what it will cost, and lets
one place decide. Both halves: `setup-linux.sh`/`setup-macos.sh` on the first
run and on the resume arm, and `setup-windows.ps1`, where the launcher is the
one that installs Podman and an unelevated winget on a managed laptop is the
failure this covers.

**A start the launcher accepted is not a database.** The launcher's `start`
exits 0 and does nothing at all in more than one state. The kit knew about one
of them; it did not know about a deployment the launcher has *initialized but
never deployed*, which takes the start, warns that a deploy is what it actually
needs, and leaves nothing listening. The installer said "Reusing the existing
Exasol deployment (started)", waited its whole 150-second budget, and ended the
run at step 2 of 6 - while `exasol deploy`, typed by hand, brought the same
deployment up in twenty seconds. The kit now asks the *database* rather than
the launcher's record: a deployment that does not answer after a start it
accepted was never started, so the launcher's own deploy is run and the
database is asked again. Reading behaviour instead of a state string means the
next spelling of this state needs no new case arm. `exakit start` heals itself
the same way, and so do all three adoption paths in the install.

**Nothing in the database step ends the run any more.** Declining to reuse a
database already running on port 8563 closed the installer at step 2 of 6 - and
so did declining to delete a stopped deployment, a foreign process holding the
port, and a deploy the launcher could not complete. None of those leave
anything half written, and none of them are a reason to withhold the launcher,
the AI bridge or the `exakit` command. Each is now recorded like any other step
that did not finish, named in the closing summary with the command that
completes it, and the install carries on. The destroy that the deploy arms as
its undo is *disarmed* rather than fired on those paths, because the run is no
longer ending and a partial deployment is exactly what a retry has to look at -
and the licence notice is replayed there too, since a deployment that survives
has accepted the terms. The one hard stop left in that step is a machine that
cannot create a temporary directory.

**Installed is not running, and the difference was a whole failed install.**
`command -v podman` answers whether the binary is on PATH and says nothing
about whether it can start a container: a rootless Podman with no sub-id range,
storage left behind by another uid, or - on Windows - a machine that is simply
switched off all passed that test and failed inside the launcher minutes later,
with an error that named neither Podman nor the kit. Both halves now ask Podman
itself (`podman info`) before deploying, repair the commonest cause once, and
report what Podman said. On Windows a machine that exists but is stopped is
started rather than reported - after a reboot it is off, and starting one is
not reconfiguring it - and only then, if it still cannot answer, is it recorded
like any other step that did not finish.

**Exasol Personal is pinned to 2.3.0** (was 2.3.0-rc6): the final release
published on 2026-09-21, so the kit no longer ships a pin on a release
candidate. Candidates were the reason the comment on the fallback demands a
check before pinning — rc2 and rc3 were both deleted upstream while pinned
here, and rc3 reached a user as a 404 with the launcher half-downloaded. The
v2.3.0 tag was verified before this bump: published, not a draft, not a
prerelease, and carrying every asset the kit fetches (macOS and Linux
arm64/x86_64 tarballs, the Windows x86_64 zip, and the checksums file).
versions.json and both built-in fallbacks move together, as that comment
requires.

**Exasol Personal is the kit's only database runtime.** The container runtime
(Exasol Nano) and every road to it are gone: `setup/lib/runtime-nano.sh`,
`setup/lib/runtime-nano.ps1`, `setup/help/nano.json`, the `components.nano`
block in versions.json, the `EXAKIT_RUNTIME` knob and the `EXAKIT_NANO_*`
variables. The launcher now deploys the database on macOS, native Linux
(through Podman, which the gate checks and names) and Windows x86_64 (host
Podman, which the launcher installs itself when missing). WSL takes the Linux
road, with Podman inside the distro (see below). The one platform Exasol
Personal does not support — **Windows arm64** — is refused before anything is
downloaded, with the support matrix named and nothing changed on the machine;
there is no silent reroute, because there is nowhere left to reroute to.

- `setup/setup-wsl.sh` is now `setup/setup-linux.sh`, matching what it
  installs. `quickstarts/windows-wsl.md` is removed and its readers are sent to
  the Windows quickstart or to a native Linux machine.
- Engine detection is `detect_podman`: no other container engine substitutes,
  because the launcher only drives Podman.
- `exakit uninstall` removes the local deployment and its data, on both halves
  of the mirror. The Windows+WSL shared-engine hazard is gone with the engine
  that caused it.
**An existing installation crosses over by re-running the installer, and it is
asked what to do with its data.** A machine whose manifest records a container
database — one made by this kit before the change, or by the upstream
`exasol-labs/exasol-personal-local-starterkit` — is recognised before the
install touches anything, and offered two answers:

- **Migrate my data** — every non-system table is copied out of the old
  database while it is still running, the new deployment is made, and the
  tables are restored into it at the end of the run. Types are preserved: each
  table is recreated from the source's own column types before its rows are
  loaded, so nothing is inferred. One caveat is named on screen before the copy
  starts: a text column that held an empty string arrives as NULL, because a
  CSV field cannot tell the two apart.
- **Skip and continue** — the new database is set up empty and the old one is
  left alone, with its data.

Both answers stop the old container, because it is holding the port the new
deployment needs — and **neither deletes it**. The container and its data
volume stay; the exact command that removes them is printed for whenever the
user wants it. A table the fresh install has already created (the bundled
sample data) is left alone rather than appended to, and named. `exakit status`
on such a machine now says "from an older kit, not managed here" rather than
"nano · not installed", which read like a broken install.

**Asked once, and only where there is something to ask about.** This code runs
on every install, so it is silent unless all three gates open: the record says
this is a container install, the crossing has not already happened on this
machine, and there is a readable database with tables in it. A container that
is gone, a machine that already crossed, and a resumed attempt at the same
install all print nothing at all — the reason goes to the install log, where
someone asking "why was I not offered a migration?" can find it. The probe
therefore runs before the banner, not after it, and the offer is made only once
the tables have been counted.

`EXAKIT_LEGACY_DATA=migrate|skip` pre-answers the question. An unattended run
with no answer **skips**: copying a database is not something to start on
someone's behalf while they are not there, and skipping destroys nothing.

**The kit's own sample data is not "my data", and is left out of the copy.** A
bundled dataset (TPC-H, energy, weather) found in the old database with the
same tables and the same row counts as the kit ships — `EXA_ALL_TABLES` keeps
the count, one query for every sample schema, checked exact against a real Nano
— is the kit's, unchanged, and the install loads it itself. Copying it out and
in again spent minutes on tables the new database already had, and the restore
then had to refuse each one as "already created". The offer now says "It holds
11 table(s). 8 of them belong to the kit's bundled sample data (tpch), unchanged
— the kit loads that itself, so they are not copied. Your own: 3 table(s)", and
the copy is the three. A sample table the user has changed (rows added or
deleted, so the count differs) is theirs and travels; a count the database
cannot give is not evidence of anything and the table travels too. A container
holding nothing but the kit's sample passes in the same silence as an empty
one, with the reason in the log and `legacy.sample_left_out` in the record.

**`exakit migrate docker-nano` — the same copy, after the install.** The
installer asks once; this is for the machine that answered skip (or was never
asked, in an unattended run) and wants the data after all, and for a container
the installer never saw: made by hand with `docker run exasol/nano`, or by the
upstream kit on a machine this kit was installed fresh on. Every non-system
table is copied out while the container runs and restored into the running
deployment with its types preserved, the sample data left out as above, nothing
in the container changed or removed. **The port is the complication**: both
databases want 8563, so when the container publishes the deployment's port the
deployment is stopped for the copy out and started again before the copy in —
said before the confirmation, never silently; a container on another port costs
no downtime. The container ends as it began, except one holding the
deployment's port stays stopped. What is not named (`--container`, `--engine
docker|podman`, `--dsn`, `--user`) comes from the record the crossing now keeps
under `legacy.*` before the deployment overwrites `runtime.*` — so a skip
answered today needs no options when it is reversed next month — then from the
old install's own record, then from the machine (which engine answers for the
container, which port it publishes), then from an older kit's defaults. **The
password never travels on a command line**: there is no `--password`, and
asking for one is refused with the alternatives named — `--password-file`,
`EXAKIT_LEGACY_PASSWORD` for a scripted run, or a prompt on a terminal that
does not echo. A copy that did not finish is kept and restored first by the
next run; a copy that did is cleared before a fresh one lands. Exit codes are
the kit's closed set (`0` done or nothing of yours to copy, `1` not finished,
`2` bad input, `3` no deployment to copy into, `4` not installed, `5` not
confirmed) and `--json` answers with one object. `exakit status` names an
old database that was not copied as `Old database … not copied` with the
command, and `status --json` carries it as `legacy_database` with `copied`
and `command`. Both halves of the mirror; `tests/legacy-crossing.sh`,
`tests/legacy-crossing-resilience.sh` and `tests/legacy-crossing-ps.ps1` drive
the sample check and the migrate road through the fault engine, exapump and a
new Personal-runtime stub (`tests/lib/legacy-fault-personal.*`) — a clash and
no clash, a stopped container, a declined prompt, an absent container, a gone
engine, no password, a silent database, a container that will not start, a
deployment that will not stop or does not come back, only sample data, every
export failing, a partial restore, a waiting copy, a second fresh copy.

**A first boot the launcher gave up on is no longer a failed install.** The
launcher waits 27 seconds for the database on `install local`, and a first boot
in a fresh Podman machine takes 40 to 60; it then records `deployment_failed`,
a state in which its own `stop` and `start` do nothing - so a database that came
up ten seconds too late was reported as "Local deployment failed", and every
later `exakit start` waited the full 150 s for a port the launcher would never
bring back. Seen four times in one day, on WSL and on Windows. When the deploy
command fails but the deployment exists, both halves now wait with the kit's
own budget, and when the database answers they run the launcher's own `deploy`
retry so its record agrees.

**"Answering" means a completed TLS handshake, never an open port.** Under
rootless Podman the published port is pasta's from the moment the container
starts: it accepts the TCP connection itself and resets it while the database
behind it is still booting, which every client reports as `tls handshake eof`
- the launcher's own 27-second budget ran out on exactly that, and the kit's
port-open waits returned the instant the container started, declared the
deployment "reachable" and let the next step's `SELECT 1` fail six times. Both
halves now probe with a handshake (`openssl s_client` or python3's `ssl` on the
sh side, `SslStream` on Windows; the self-signed certificate is accepted, not
validated) in `personal_wait_ready`, the slow-first-boot recovery and the
adoption check. The launcher's `deploy` retry is the ownership proof: when it
fails after something answered, the recovery fails too, instead of carrying on
with "the database it can reach".

**A database the launcher does not own is never adopted.** Windows and WSL
share one network stack, so an Exasol Personal deployed on either side holds
port 8563 for both. The Windows installer saw "already running on 8563",
adopted the WSL database, wrote a profile with its own launcher's password and
watched exapump and pyexasol fail against it. Now: with a deployment of its
own, the launcher's word outranks the port (`stopped` and `deployment_failed`
are not running); with none, only a `SELECT 1` through the kit's own profile
counts. A port that answers like Exasol but is not ours is named for what it
is, with the WSL/Windows explanation and the remedy (stop it on the other side
first). New suite: `tests/personal-readiness.sh`; the PowerShell twin's checks
join `tests/runtime-personal-ps.ps1`.

**A deployment the launcher records as failed is deployed again, not
"started".** In `deployment_failed` the launcher's `start` and `stop` exit 0
doing nothing, so the installer's reuse path reported "started" over a record
that stayed failed, and `exakit start` said "Database started" and then waited
its whole budget. Both now run the launcher's `deploy` retry for that state,
then the kit's slow-first-boot budget and reconcile; only a database that
never answers reaches the replace question.

**An import connection cut mid-transfer is tried again, quietly.** The
database reads each data file through its own import proxy; when the client
side of that connection closes before the last byte, the engine reports
`ETL-5105 ... transfer closed with outstanding read data remaining`. On
Windows with exapump 0.12 that hit one or two of eight tpch files per run, a
different file each time, and the same file loaded fine a moment later (the
network path was measured sound: 34 of 34 15 MB uploads through pasta, alone
and eight in parallel). Both halves now retry a cut-short upload up to two
more times, one file at a time (`EXAKIT_UPLOAD_RETRIES`, `0` disables); the
log keeps every attempt, the screen only the outcome. A malformed file, a
missing table or a refused login is never retried.

**A dataset whose tables are empty is not "loaded".** A dataset's DDL creates
its tables before a single file is uploaded, so an upload that failed left
empty tables that the marker check counted as loaded - `exakit data-load`
answered "already loaded - nothing to do" over `ORDERS` and `PART` with 0
rows. The table listing behind the check now asks for tables with rows
(`TABLE_ROW_COUNT > 0`, exact in `EXA_ALL_TABLES`), with a sentinel row so an
answered-but-empty database is not mistaken for one that could not be asked.

**A kit-managed exapump of another version is replaced, not "already
installed".** Both halves trusted any binary that answered `--version`, then
recorded the version the kit pins: 0.13.0 in the manifest, 0.12.0 on disk. The
version is compared now; only the kit's own path is replaced, a binary the user
put elsewhere is left alone.

**The crossing finds the container in whichever engine actually holds it.** The
old kit ran the database under Docker when it was there and Podman otherwise,
and wrote whichever it used into `runtime.engine`. A record without that key,
or a machine where the user has since moved from one engine to the other, had
the whole crossing declined - "the container engine this database needs is not
on this machine any more" - while the container sat in the other engine, and
the install then walked straight into the port it holds and stopped there. The
recorded engine is still preferred and still costs nothing when it works; only
when it cannot be run does the kit ask each engine on the machine whether it
has that container, Docker first. The record and every message then name the
engine actually in use.

**The question about your old database is asked where it belongs: after
exapump, before the sample data.** It used to be the first thing an install
said, before the kit had put a single file on the machine - a question about a
database the user may have forgotten they had. It cannot simply be moved,
because the old container publishes the port the new deployment is about to
take: the only moment its tables can be read is before the install starts. So
the first half now reads them out quietly into a directory under the kit's own
home, says nothing but why the container is stopping, and records the counts;
the second half, after exapump, names what was found in one line and asks. A
"no" deletes the copy and leaves the old container exactly as it was. A run
that comes back after dying between the two halves does not copy a second time,
and a run that died after the answer finishes the restore without asking again.

**Your own tables come back before the kit's sample data, and the copy has a
progress bar.** The restore used to run last, after every step of the install,
which put a user's own tables at the end of a run that is mostly about them; it
now runs where it first can - a database that is up, an exapump binary and a
profile pointing at the new database - immediately before the sample-data
offer. A table a bundled dataset would create is left in the copy rather than
restored, so the load that follows cannot overwrite it; that was already the
outcome when the restore ran second, and it no longer depends on the order.
Both the copy out and the copy back in now draw the same bar the deploy and the
dataset loads use, naming the table and its position, instead of a spinner that
only said "still going".

**The question before it is one line.** Six lines of explanation stood between
finding an old database and asking about it: what the kit no longer manages,
what it deploys instead, what the copy costs, which tables are the kit's own,
and a caveat about empty strings. What is left names the container, its state
and how much of the user's own data is in there. The caveat is said with the
copy, where it is about to matter.

**A crossing that could not ask is no longer a crossing that was answered.**
When the offer could not be made, the kit wrote `legacy.choice = skip` and
closed the crossing for good - even when the reason was a condition rather than
a decision. One run that could not see the container engine therefore cost that
machine its data permanently: no later run ever offered again, and because the
already-done path did not stop the container either, every later install died
at the database step on the port it holds, with no way forward but stopping it
by hand. Now: "there is nothing to copy" (the container is gone, the database
is empty, it holds only unchanged sample data) still settles it forever, while
"this machine cannot read it right now" (no engine, no exapump yet, the
container would not start, the database did not answer, no password on file)
records the reason and leaves the question open for the next run. And the
container is stopped on every one of those paths, including the already-done
one, because it holds the port the new deployment needs.

**A port held by your own previous kit says so.** The hint on a busy 8563 named
WSL whatever was really there, which sent a Windows user with a local container
looking for a database in a distro that did not have one. When the port is held
by the recorded container, the message names it, the command that stops it, and
the fact that re-running the installer then offers to copy its data across.

**An installer and a kit from different repositories say so.** Both installers
are read from a URL, but the kit they unpack comes from `EXAKIT_REPO`, which is
the upstream repository whatever URL the installer itself was read from. So
fetching a fork's `install.ps1` installs the *upstream* kit, and when the two
layouts differ the handoff died on the shell's own "The argument ... does not
exist" - a path, with no hint that two repositories were in play. Two people
hit exactly that in one morning. Both halves now check for the setup script
before handing off and name what happened: which repository and ref the kit
came from, and the two variables that point it at the same place as the
installer.

**A checksum no longer depends on a cmdlet that may not load.** `Get-FileHash`
comes from `Microsoft.PowerShell.Utility` through module auto-loading, and on a
machine whose `$env:PSModulePath` starts with a OneDrive-redirected Documents
folder that can fail: `exakit update` died with "The term 'Get-FileHash' is not
recognized" - after downloading the binary, at the moment it was about to be
verified. Every SHA-256 in the Windows half now goes through one helper that
falls back to the .NET class behind the cmdlet, which is part of the runtime
and cannot fail to load. The digests are identical, and the suite proves it by
hiding the cmdlet.

**A freshly installed exapump that the machine will not let run yet is waited
for, not blamed on the database.** Windows Defender and corporate endpoint
agents hold a newly written, unsigned 20 MB executable open while they scan it,
and every attempt to start it meanwhile fails with `Access is denied`. Measured
on a managed laptop: three and a half minutes, in which all six `SELECT 1`
attempts failed and the install reported `SELECT 1 failed via profile
'starter-kit'` - against a database that was healthy throughout, so the data
menu, the MCP database check and pyexasol all fell over behind it. The
PowerShell half now smoke-tests the binary right after installing it, the twin
of `exapump_verify_runs`, which the sh half has always had and this one never
did; both wait out that one error (`EXAKIT_EXAPUMP_READY_TIMEOUT`, default
180s) and then say what is really holding it. A binary that is broken rather
than locked still fails in the same second it always did.

**A broken exapump can no longer report a healthy database as down.** The
liveness probe asked exapump for a `SELECT`, so the run above also printed
"Self-heal: the database is deployed but not running" about a database that was
up. Whether our own deployment answers is a TLS handshake; proving *whose*
database answers on a shared port stays where that question arises.

**One failure, one telling (Windows).** A dataset that did not load printed its
reason three times - the `x` line with the log path, a `!` repeat, and the
closing `x` with the retry command. The repeats go to the log; the screen keeps
the first line and a short closing one naming the retry command.

**Windows refuses a rootful default Podman machine before downloading
anything.** Podman Desktop creates the default machine rootful, and a rootful
container publishes its port as an iptables rule inside the machine - no
listener, so neither WSL's localhost relay nor gvproxy forwards it to Windows.
The launcher then deploys a database that answers inside the machine and never
on 127.0.0.1:8563. Measured on one laptop: a plain listener in the machine is
forwarded, a rootful published port is not, a rootless one is. The requirements
gate names the fix (`podman machine set --rootful=false`, or remove the machine
and let the launcher create one); `EXAKIT_FORCE=1` steps past it.

**`exakit repair-runtime` reloads the sample data it promises to.** The record's
"loaded" flags survived the rebuild, and the data step trusts the record
whenever the database cannot be asked - which a database that came up seconds
ago sometimes cannot - so a run said "Dataset 'tpch' already loaded" over an
empty schema. The flags are reset before the rebuild, on both halves. Found
behind it: `manifest_set_many` had never written anything, because
`run_python -` takes the program from stdin and the script's own stdin read came
back empty - every piped key was dropped, including the dataset-flag healing in
`exakit_verified_datasets`. It reads its lines before Python now.

**Exasol Personal is pinned to 2.3.0-rc3** (was rc2): the Windows path in rc3 selects and
keeps a concrete database port and no longer changes an existing Podman
machine. versions.json and both built-in fallbacks move together, as the
comment on the fallback requires.

**Two crossing defects found by running it on a real WSL machine, fixed.**
**(1)** The old kit's manifest carries its own step ticks — `steps_completed:
["runtime"]` meant the container. The new kit trusted the tick, skipped the
deployment step as already done, never recorded the Personal runtime, and every
later step then spoke to the new database with the old container's password
(`SELECT 1 failed via profile 'starter-kit'`). The crossing now drops the old
kit's ticks while the record still names the container, so every step of this
kit runs. **(2)** The export named each table with exapump's bare `--table
S.T`, and a schema or table that needs quoting (`"My Schema"."Sales 2025"`,
legal in Exasol) never resolved: the export sat for its full 300 s timeout and
the table was reported as left behind. It is named as a query with both
identifiers quoted now — the way the restore has always named its target.
**(3)** The restore read a failed `CREATE TABLE` as "the fresh install already
created it" — and with the profile above pointing at the wrong password, every
one failed on authentication, so a database the kit could not reach reported
"Restored 0 table(s), Left alone: <every table>" and recorded the restore as
done. The restore now asks the new database to answer first; when it cannot,
the copy is kept, said so, and left for the next run to land.

- **A kit installed before this change cannot self-update past it.** The
  payload validator in every older copy requires `setup/lib/runtime-nano.sh`,
  which no longer ships, so its `exakit update` refuses the new archive and
  leaves the old kit untouched. Re-running the installer is the crossing, and
  it is what the notice above points at.
- **Four defects in the crossing, found by running it under fault.** On the
  sh side a schema or table name containing a space was word-split into two
  tables that do not exist ("My Schema.T" became "My" and "Schema.T"), and a
  malformed index line whose first word matched a file was restored into
  `"".""`. On the PowerShell side a 0-byte password file was a terminating
  error that ended the install instead of a quiet skip, and the two silent
  paths (a resumed attempt, a gate closed with nothing to offer) still printed
  "Stopping the old database container ..." where the sh side said nothing.
  All four are pinned by `tests/legacy-crossing-resilience.sh` (181 checks) and
  `tests/legacy-crossing-ps.ps1` (149), which drive both modules through a
  fault-injection engine and exapump - hangs, refusals, a container lost between
  calls, no password, no answer, a late answer, partial and total export
  failure, partial restore, a crash between the two halves - and end by
  measuring line coverage of the module with an 85 % floor (99 % and 97 %
  measured). Two limits are recorded rather than hidden: a hang in a CHILD of
  the engine outlives `exakit_run_bounded` on a machine without timeout(1), and
  xtrace-based coverage on bash 3.2 cannot see code run under a stderr redirect.
- **Fix: `exakit start` refused to clear its own mess.** The launcher can leave
  an orphaned runner (`.../exasol-local-runner/.../launcher __daemon__`) bound
  to the database port after a failed deploy or a destroy that could not find
  its PID file, and `personal_reap_orphan_daemon` exists to clear exactly that.
  But `exakit start` has a fast path for the resulting "conflict" status, and it
  died there with *"held by another process … not by Exasol. Stop that
  process"* — a sentence that was **false** on the commonest cause of that
  state, since the holder was Exasol's own. The reap never ran and the user was
  handed a manual `kill` for a process the kit knew how to clean up.
  Reproduced on a real machine, where `exakit start` was a dead end until the
  pid was killed by hand. The reap runs first now; the refusal is kept for the
  case it was written for, a genuinely foreign program on the port.
- Fix: `EXAKIT_EXAPUMP_BIN` was assigned unconditionally in `exapump.sh`, so an
  override set in the environment was discarded the moment the file was sourced
  and `exapump_cli` fell through to whatever `exapump` was on PATH. A test that
  sandboxed `EXAKIT_HOME` and `EXAKIT_BIN_DIR` but pointed that variable at a
  stub therefore ran the real binary against the real database. Both halves now
  honour it, and the PowerShell side lets it outrank PATH.
- **Four crossing bugs found by the new fault-injection suites**
  (`tests/legacy-crossing-resilience.sh`, `tests/legacy-crossing-ps.ps1` — an
  engine that hangs, refuses or loses the container; a database with no
  password, no answer, a late answer or nothing in it; copies and restores that
  fail for some tables or all; a run that dies between the two halves — each
  suite ending with a line-coverage floor of 85% on its module). **(1)** On the
  sh side a schema or table name with a space in it (`My Schema.T`, legal in
  Exasol) was handed to the export unquoted with the default IFS and arrived as
  two tables, `My` and `Schema.T`; the list is split on newlines only now.
  **(2)** On the sh side an index line with fewer than three fields whose first
  word matched a file was uploaded into `"".""`; it is stepped over, as the
  PowerShell side already did. **(3)** On the PowerShell side a 0-byte password
  file was a terminating error inside `Write-LegacyProfile` — the install
  would have died on it — instead of "no profile"; the sh side had tested `-s`
  all along. **(4)** On the PowerShell side the two paths that must pass in
  silence (a resumed attempt, a gate that closed with nothing to offer) still
  printed "Stopping the old database container …"; `Stop-LegacyContainer -Quiet`
  is the twin of the sh side's redirect. One limit found and documented rather
  than fixed: on a machine without `timeout(1)`, `exakit_run_bounded` cannot
  end a hang in a *child* of the probed command, so a container engine whose
  CLI spawns a helper that wedges is waited out.


- **WSL is a supported platform now, and it always could have been.** The kit
  refused it in three places before anything was downloaded, on the grounds
  that "Personal's Windows path is host Podman inside a Podman machine, not
  WSL". That confused two different things. The WSL the launcher's sources
  talk about is the one podman-for-windows boots for *itself*
  (`podman-machine-default`), driven by the Windows launcher; it says nothing
  about a user's own distro, where the **Linux** launcher runs. And the Linux
  local runtime asks for exactly one thing: a `podman` on `PATH`
  (`linuxHostEnvironmentPreparer.EnsureReady` is a single `exec.LookPath`), with
  no systemd, cgroup or WSL check anywhere on that path. A WSL2 distro is an
  AMD64 Linux with a real kernel, so it meets that as published.
  `install.sh`, the preflight and the runtime gate now route WSL down the Linux
  road, and the three remedies that would have been wrong there are written for
  it: Podman is installed *inside the distro* (Podman or Docker Desktop on the
  Windows side does not count), too little memory points at `[wsl2] memory=` in
  `.wslconfig` rather than at buying a bigger machine, and a missing cgroups v2
  points at `kernelCommandLine` in the same file rather than at a GRUB edit that
  does not exist in WSL. A missing `newuidmap` is warned about rather than
  refused, since rootless Podman fails much later and much less clearly without
  it. Autostart already knew about WSL's systemd being off by default, and the
  credential guard already refused to keep passwords on a `/mnt/c` path.

- **Fix: on Windows, every quoted identifier the kit sent to exapump arrived
  unquoted.** Windows PowerShell 5.1 builds one command line for a native
  program and does not escape a double quote inside an argument, so the
  receiving program reads it as a delimiter and drops it: `CREATE TABLE
  "s1"."t2"` left as `CREATE TABLE s1.t2`, and Exasol upper-cases what is not
  quoted. The legacy crossing therefore rebuilt each restored table under a
  different name than the one it had exported from, its "this install already
  created it" test always answered no, and `exakit sql` silently changed the
  meaning of any statement a user had quoted. Arguments are now escaped for
  those rules at the three places that carry SQL (`Invoke-ExakitLogged`,
  `Invoke-Exapump`, the MCP setup's probe); PowerShell 7 passes an argument
  vector straight through and is left alone. Found by the Windows runner, and
  `tests/data-load-shapes-ps.ps1` now reproduces the 5.1 rules on every
  platform so the defect cannot come back unnoticed.

- **`exakit data-load` on the files people actually have.** Seven public
  open-data sets (Munich's bicycle counters, population, cycling network,
  district boundaries, roadworks, the MVV GTFS feed, MVG bike trips) loaded
  zero tables through the kit as downloaded. The kit stays a bridge - it hands
  every file to exapump or JSON Tables **as it is**, never a converted copy -
  and now says what it sees: `.geojson` is JSON and loads through the add-on
  like `.json`; a `;`- or tab-separated header is passed on as exapump's own
  `--delimiter` instead of a warning; a file with a header and no rows (GTFS
  ships `shapes.txt` that way) is skipped by name instead of failing type
  inference; a tabular `.txt` or `.tsv` - exapump picks the format from the
  extension and reads `.csv` and `.parquet` only - is listed with the one
  rename that loads it instead of being silently ignored; and a failed upload
  shows the engine's full `ETL-` detail (it was cut at the first bracket) with
  the cause the kit saw in the header appended when the file has Windows line
  endings, which exapump does not yet pass to the database correctly (its
  IMPORT sets no row separator, so `7.4` arrives as `7.4<CR>`). That last one
  is exapump's to fix, and the reason now says so. A CRLF file whose last
  column is text *loads* - with a carriage return on every value in that
  column (49,812 of 49,812 rows, checked) - so a successful load of such a
  file is followed by a warning that says exactly that. A folder holding only
  `.txt` tables (a GTFS feed as extracted) is no longer told it holds "no
  files"; it is told the rename. Both platforms;
  `tests/bulk-folder-load.sh` and `tests/data-load-shapes-ps.ps1` pin the
  argv and the bytes the loader receives.

## 0.2.0

The third agent-operability audit, end to end: 148 of its 149 findings, plus five defects found by running the kit on a real Windows machine. Eleven pull requests. Nothing here changes a command's name or its arguments, so an existing install updates in place.

- **The JSON an agent reads now matches what AGENTS.md promises.** Every state query carries `installed`, `status` and `remedy`, and **`remedy` is a command you can run verbatim** - the prose that used to sit in that field moved to `remedy_hint` and `remedy_hints`, so a parser can execute one and read the other. `exakit version --json` gained **`addon`** on every component row, `true` for the four marketplace tools and `false` for the kit's own parts: an agent reading `status: "available"` could not previously tell "you never installed this optional tool" from "a piece of your kit is missing". The flag is computed from the add-on registry on both platforms, never a hand-written list. Exit codes are a closed set - `0` running, `2` bad input, `3` not running or still installing, `4` not installed, `5` a destructive command you did not confirm.

- **Autostart says what the machine will do, not what you asked for.** `exakit status` and `exakit status --json` read the install record's `autostart.enabled`, which is the last thing the *user requested*. A machine whose boot entry had since gone reported `"autostart": true` for a database nothing would restart, and on the container path that is routine rather than exotic: recreating the container drops its restart policy, so a stop/start cycle turned autostart off while the record went on saying it was on. Both platforms now probe the boot entries, with the same rule `exakit autostart` applies - on means **every** service is registered, because a partly-registered set will not bring the kit back.

- **Uninstall names what it is about to delete, before it asks.** On a Windows+WSL machine Docker Desktop is one engine shared by both sides, so `exakit uninstall` in either one removes the container the other is using. The warning existed but was printed *after* the user had typed UNINSTALL, and the confirmation named neither the container nor the data volume - so there was no moment at which anyone could have noticed. Both halves now state the hazard and name the container and the volume ahead of the gate, and ahead of the removal on the scripted `--yes` path where there is no gate to read.

- **Uninstall stops leaving an admin credential behind.** On Windows, `exapump` resolves its profile store from `%USERPROFILE%`, because that is where `exapump.exe` itself looks, while uninstall deleted `$HOME\.exapump`. On an ordinary machine those are the same directory and nothing showed; on a domain-joined machine with a redirected home they are not, and the uninstall reported success while leaving a `config.toml` holding an **admin** connection string on disk. Both locations are now removed. Separately, the credentials **directory** gets a real ACL to match the files inside it - the shell half has always had `chmod 700` there and the Windows half had nothing.

- **Five defects that only a real Windows machine could show.** `exakit version`, `exakit version --json`, `exakit marketplace` and the installer's closing offer died with a bare `Traceback (most recent call last):` on any machine carrying a stock `python` without `exasol-json-tables` - the common case, not a corner one: under PowerShell's `Stop` error preference a native command's stderr becomes a *terminating* error before its exit code can be read, so a probe answering "not present" escaped as a crash. A guard for that pattern found two more instances, one of them in `exakit repair-runtime --json`, where a rebuild that printed a single warning and then succeeded would have surfaced as an unhandled crash. `exakit --version` printed the help screen and exited `0`; an unknown leading option now exits `2` like an unknown command. A failure note kept only the first line of a multi-line error, which for a Python traceback is the one line that names nothing - the informative line is kept now, and the log keeps all of them. And a 20 MB download that exhausted a 120-second timeout on a link doing 2.9 MB/s streams to disk instead.

- **The kit's own claims match its behaviour.** The database's licence is named **before** the software arrives - on the container path nothing mentioned a licence at all, and on macOS the terms were replayed only after the deployment already existed. The README no longer implies MIT covers the database, no longer claims a checksum for two components that have none, and describes the AI-client picker the way it actually renders. `EXAKIT_DB_PORT` is validated where it enters the kit rather than travelling to the container engine and coming back as the engine's own complaint. `dash-server` stopped advertising a host setting it does not honour: that control plane is unauthenticated and is deliberately pinned to loopback.

- **Skills: retired when dropped, honest when gated.** A skill the new set no longer carries is now removed from the discovery folders on Windows as well as on macOS and Linux - only names the install record holds, never a skill you placed yourself. A skill belonging to an add-on you have not installed is a fourth state (`needs-addon`) with its own runnable remedy, rather than a missing one. New **`exakit-lifecycle`** skill covering versions, updates, logs, the command surface, where the credentials live and how to uninstall safely.

- **Tests.** The PowerShell suites now run on a real Windows PowerShell 5.1 engine in CI, not only under PowerShell 7 on Linux, and the Windows-only cmdlet allowlist became a self-check there instead of an article of faith. That runner found four defects during this release, three of them in the tests themselves. A guard that read a single function body - so a helper could call anything and stay green - now walks transitively. `tests/marketplace-e2e.sh` had its skip guard inverted and began a real install on a machine that was supposed to skip.

- **Thirteen fixes from the marketplace add-on and agent-marketplace audits.** **(1)** The generated `dash-server` launcher - the documented way to start it - printed a pre-flight verdict for the recorded port and then execed the server with no port at all, so a machine that had moved off a busy 5100 bound the busy one; the launcher now setdefaults and exports `DASH_SERVER_PORT` and `DASH_SERVER_HOST=127.0.0.1`, so the kit's loopback promise holds on the one path it did not control, and an exported value still wins. Both platforms. **(2)** `Update-JsonTables` had no same-version early return, so `exakit update` re-downloaded the wheel, the ingest engine and the compiled cargo shim on Windows every run while macOS and Linux did nothing; it now compares the installed build, rewrites the launcher and says "JSON Tables is already current" in the same words as the shell half, falling through to a full install when the engine or shim is missing. **(3)** The stdin-draining guard that stopped the marketplace silently losing the rows after exasol-vscode existed only on the shell side; `Invoke-ExasolVscodeCode` now redirects the child's standard input too. **(4)** `exasol-vscode` saw only VS Code proper, so it vanished with no explanation on Cursor, VSCodium, Windsurf and Insiders machines the kit already writes MCP config for; detection now takes each fork's own CLI (`code-insiders`, `cursor`, `windsurf`, `codium`) and their install locations, VS Code first, and the not-applicable reason and help document name them. **(5)** `setup/help/exasol-scheduler.json` documents that `SCHEDULER_SVC` can only write inside its own `SCHED` schema - validate revokes the bootstrap `CREATE SCHEMA` and `CREATE TABLE` - with the literal grants to run before the first job. **(6)** dash-server's MCP control plane is unauthenticated and loopback-bound and nothing said so; a `warning` field and a line in MARKETPLACE.md now do. **(7)** dash-server is the one add-on installed without a kit-pinned digest; the help document, MARKETPLACE.md and the reference-add-on guidance say so plainly instead of implying a verified download. **(8)** The "no checksum available" refusals for json-tables and exasol-scheduler named a retry but not the way out; both now name `EXAKIT_ALLOW_UNVERIFIED_<ID>` and the versions.json key, and exasol-scheduler gained the override the message promises. **(9)** MARKETPLACE.md's sample `exakit marketplace` output showed a Status/Action table and a `Cancel` row the command has not printed for two releases; it is re-captured from the real component and every `Cancel` is now `Skip`. **(10)** `skills/json-tables/SKILL.md` told the agent not to guess table names and documented no way to learn them; it now carries the post-ingest discovery step (`describe wrappers`, then `SYS.EXA_ALL_TABLES`). **(11)** CHANGELOG pointed at a `MAINTAINERS.md` that does not exist. **(12)** The fold's "every external link into either file still resolves" claim is narrowed to what is true - anchors - and MARKETPLACE.md's Verifying section carries back the dropped "enforced by the automated suites" sentence. **(13)** `tests/marketplace.sh` says in its header that it takes three to four minutes and why, so a slow run is not mistaken for a hang. `tests/marketplace.sh` gains guards for (1), (2) and (3) that fail against the previous code. `components.skills.version` 1.9.5.
- **exasol-vscode from a WSL install now reaches the Windows VS Code.** On WSL the `code` on PATH is the Windows build over interop, so the add-on was rightly offered - and then failed with only "did not finish, see the log": the CLI was handed the downloaded .vsix as a UNC path and refused it (`ERR_UNC_HOST_NOT_ALLOWED: UNC host 'wsl.localhost' access is not allowed`). The install now stages the file on a Windows drive (the user's `%TEMP%`, over `/mnt`; the system temp folders as fallbacks) and hands the CLI a `C:` path, removes both copies afterwards, and the failure message names the fallback (install from VS Code's Extensions view). When no VS Code is reachable at all the add-on is not offered, as before.
- **Skills: one advertised command, `exakit skills`, and the install record says when a newer set exists.** `skills-install` was listed beside it on the help screen and in the catalogue, and three documents told readers to run it after the install - a step the installer had already done, and the wrong repair for a stale set (that is `exakit update`). It is now a hidden command: the help document gained a `hidden` flag that both renderers honour, so the overview, `--all`, the catalogue and the JSON surfaces leave it out while `exakit skills-install --help` still renders its page. `exakit skills` moved to the Reference group and names the next command only when one is needed: `exakit update` for a newer advertised set, `exakit skills-install` for a placed skill that has gone missing; its `--json` carries `installed_version`, `advertised_version`, `status` and `next`. `exakit info` gained a `Skills:` row and `info --json` a `skills` block with the same verdict, read from the manifest and the cached versions document so info stays offline. AGENTS.md, README, QUICKSTART and skills/README no longer send anyone to `skills-install`. Both platforms; `tests/skills.sh` guards it.
- **Docs: MARKETPLACE-FLOWS.md is folded into MARKETPLACE.md.** The marketplace had two documents side by side, one for the user's journey (six scenarios as flowcharts, the surfaces table, the quick reference) and one for the maintainer (the contract, where the pieces live, the add-a-new-add-on walkthrough), each opening with a pointer at the other. They are one document now, in that order: contract, scenarios, walkthrough. Every section heading and anchor is unchanged, so the flowcharts' click targets and every in-page link still resolve, and so does an external link to any anchor of either file; the README's two links become one. The flows document itself is gone, so a bookmark of the file path (`MARKETPLACE-FLOWS.md`) or of its old H1 no longer resolves - that document's anchors all live in MARKETPLACE.md now.

- **Fixes from the fifth agent-operability audit (cold Windows install through `exakit.cmd`, PowerShell 5.1).** **(1)** `exakit start` reused neither the port nor the image the install recorded: after an install on `EXAKIT_DB_PORT=8564` the first stop/start recreated the container on 8563, and a start that had to create the container pulled `docker.io/exasol/nano:` with no tag and blamed the network. Both now come from the manifest when the environment names neither (bash twin: `nano_adopt_recorded_settings`). **(2)** A crashed Windows install read as `installing` forever; the installer now holds `.install.lock` with its pid, and `status`, `info` and `mcp-doctor` report a dead one as a stopped install with `remedies.install`, all three agreeing mid-install too. **(3)** Under Windows PowerShell 5.1 `exakit sql --json` wrapped rows as `{"value":[...],"Count":n}`, `mcp-doctor --json`, `mcp-status --json` and `skills --json` printed nothing, `catalog --json` and `help <x> --json` trailed a bare `0`, and a one-element `steps_completed` was a string; every shape is fixed and pinned by `tests/ps51-json-contracts.ps1` on a `windows-latest` job under both engines. **(4)** The connection-refused remedy did not match Windows' "Failed to connect ... actively refused it (os error 10061)", on either platform. **(5)** Doctor on Windows never repaired: a drift report exited 1 as "MCP doctor failed (see log)"; it now repairs and re-checks, and `--json` carries `mcp_privileges`, the read-only user's own privilege list. **(6)** `.last-failure` was overwritten by any command's `Fail()` and never held a soft failure; only the installer and soft steps write it, it carries the retry command, and a clean run clears it. **(7)** One dataset's failed load no longer aborts the rest; soft failures persist in the manifest and surface as `remedies.<step>`; the manifest publish move is retried against a concurrent reader. **(8)** The port-conflict remedy leads with `EXAKIT_DB_PORT` and names a WSL container publishing the port instead of offering `wsl --shutdown`. **(9)** Logs no longer interleave UTF-16 error-record dumps, `exakit sql` no longer prints a `NativeCommandError` block, `--json` error text is no longer cut at console width, `mcp-doctor --json` with the database down carries the `installed/status/remedy` triad, `datasets_source` says whether the list was verified, and `exakit version` no longer says `inspect`. **(10)** AGENTS.md documents `exakit.cmd`, the Podman-in-WSL port conflict, the recorded port, `datasets_source` and `mcp_privileges`; `reducing-agent-prompts.md` and `skills-install` carry the Windows and PowerShell-tool rule spellings, sweep legacy rules and write BOM-less; `data/data-dictionary.md` covers ENERGY and WEATHER. **(11)** Two residuals from re-running the evaluation against the merged kit: `mcp-doctor --json` on a report with findings printed the failure card on stdout after the object (exit 1 stays, the card goes), and the WSL port-publisher probe named nothing because wsl.exe's default shell expanded the probe's `$e` before the inner shell ran and a quoted `--` was not taken as the separator - it is now a variable-free, podman-only `bash -lc` probe passed verbatim, and names the rootless container holding the port. `components.skills.version` 1.9.1.
- **Seven fixes from the fourth agent-operability audit (`main` as of 2026-09-07).** **(1)** `exakit sql --json` on a large result (120,000 rows, 43 MB) printed nothing and exited 0: the rows were handed to Python as an argument and the OS refused with "Argument list too long". Rows, error text and remedy now travel through files, the answer carries `row_count`, and a render failure is itself a JSON answer with exit 1. **(2)** A crashed installer's lock pid, reused by any live process of the same user, kept `status --json` saying `installing` with a remedy that said keep polling; the lock now records the holder's start time and `exakit_lock_holder_alive` compares both (an old one-line lock still falls back to the pid check). **(3)** With `EXAKIT_HOME` pointing at a folder with no install, every state query answered prose and exit 1; the wrapper now answers `{"installed": false, "status": "not installed", "remedy": ...}` when `--json` is present and exits 4 either way. **(4)** An unsupported data file (`.txt`, unknown extension) or a missing file died inside the loader and was recorded as `last_failure`; both are refused before the loader runs as bad input (exit 2, no note), on both platforms. **(5)** A CSV whose header has no comma but a `;` or a tab loaded silently as one column; the load now warns and names `exapump upload --delimiter`. **(6)** The launchd service logs were created 0644 while every other kit log is 0600; they are created owner-only before `launchctl load`. **(7)** On some fresh installs the `exakit` command appeared over a minute after the installer started and nothing recorded where the time went; `install.sh` stamps its start and setup's first log line reports the elapsed bootstrap. `tests/agent-audit.sh` guards all seven.
- **Seven fixes from the third agent-operability audit (fresh install of kit 0.2.4).** **(1)** Doctor's repair handed the add-on's MCP endpoint to every supported client, which created config files for four clients that were not on the machine and then warned about each of them, forever, with a remedy naming `exakit mcp-remove` — a command that did not exist. An add-on endpoint is now written only into connected clients (detected, `exasol` entry present), and `exakit mcp-remove <client>` exists on both platforms. **(2)** `mcp-setup` counted any managed record as "configured", so a client whose `exasol` entry was gone but whose add-on entry remained was "already connected"; only the `exasol` entry counts. **(3)** A repairable WARNING (a loosened file mode) was reported and never repaired because the run exited 0; doctor now repairs when the report carries a repairable finding at any severity, one loosened file is one finding rather than one per managed entry, and the hoisted `remedy` prefers the worst finding about a file over one about an absent client. **(4)** Twelve commands accepted unknown options and did their work anyway (`stop --bogus` stopped the database, `help --bogus` handed the flag to grep, `update --bogus` recorded a failure note); one dispatcher rule refuses an unknown option with exit 2 before anything runs, and `update` rejects bad input instead of dying. **(5)** `exakit sql --json` refusals are JSON: `{"ok": false, "error": ..., "rejected": true}`, exit 2. **(6)** The not-found hint on a `STARTER_KIT` table says that file-loaded columns keep the file's case and must be quoted; the exapump skill says the same. **(7)** Uninstall removes the permission rules skills-install merged into `~/.claude/settings.json` — exactly the kit's own entries, nothing the user added. `components.skills.version` 1.8.0.
- **Ten fixes from the second agent-operability audit (kit 0.2.3).** **(1)** `exakit mcp-setup` read "configured" off the manifest record, so a client whose file the user had emptied by hand was reported "already connected" and never re-applied; the module's `discover-clients` now inspects the file and a record whose entry is gone reads as not configured, so setup offers the client again. The `mcp-doctor --json` remedy said "Run repair" — an operation no `exakit` command exposes by that name — and now names `exakit mcp-doctor` (its human form repairs and re-checks; `--json` only reports). **(2)** The permission and missing-file findings carried no client in their scope, so doctor's per-client state tainted every managed client for one loosened file; every per-artifact finding names its client and only that client reads `needs_attention`. **(3)** A successful `exakit start` retires the failure note an earlier refused start left ("Port 8563 is held by another process ..."); `status --json` reported it as `last_failure` beside `running`. Only a runtime note is cleared: an install-step note is a different fault and stays. **(4)** `status --json` names a remedy for every install step that never finished (`steps_missing`, and `remedies.mcp: "exakit mcp-setup"`, `remedies.pyexasol: "exakit update"`, the installer for the rest); with the installer gone, `steps_completed` was the only trace and `remedies` was empty. **(5)** `SELECT TOP n` fails as `unexpected UNSIGNED_INTEGER_`, which no pattern matched, so the LIMIT remedy the help promised never printed; the matcher now also reads the statement. **(6)** The MCP server masks a stopped database as "A database error occurred" and a `TOP` query as "not a SELECT statement"; AGENTS.md and the exasol-mcp skill now carry both texts with what to do (the wording fix itself is proposed upstream: exasol/mcp-server#294). **(7)** Under a port conflict `exakit sql` printed `TLS error: tls handshake eof` with no remedy; it now points at `exakit status`, which names the process. **(8)** `exakit mcp-setup --anything` ran the plain setup and exited 0; options and arguments are refused with exit 2 and the `EXAKIT_MCP_CLIENTS` form is named. **(9)** The skills caught up with the kit: `exakit sql --file`/`--json`, discovery without MCP through `SYS.EXA_ALL_TABLES` / `SYS.EXA_ALL_COLUMNS` and `data/data-dictionary.md`, the two MCP error texts; `components.skills.version` 1.7.0. **(10)** `exakit sql --json` returns one object — `{"ok": true, "rows": [...]}` or `{"ok": false, "error", "remedy"}` — with nothing else on stdout, by way of exapump's own `--format json`, which keeps its framing lines on stderr. Both platforms; `tests/agent-audit.sh` guards the shell half, `mcp/tests/test_doctor_attribution.py` and `test_cli_discover.py` the module.
- **MCP client detection looks for the client, not for a file the kit wrote.** Detection was "the config file exists, or its directory does" — and the kit writes that file itself, so any client it had ever configured counted as installed forever. On the audited machine the four clients a mis-scoped `EXAKIT_MCP_CLIENTS=all` had once configured kept reading as installed (and doctor as connected) until their files were deleted by hand. The rule is now: the client's program on PATH or its app bundle; else a config file that holds anything beyond the kit's own entries; else the client's directory holding files of its own. A config with only the kit's entries proves nothing. An explicit config-path override keeps the old file rule, since that is the caller vouching for the client. One implementation in the adapter base, used by all eight adapters; unit tests cover a kit-only config (not detected), a config with the user's own settings (detected), a program on PATH (detected) and an override (old rule).
- **Twelve agent-operability fixes, from an audit that drove the kit the way an agent does.** **(1)** `EXAKIT_MCP_CLIENTS=all` configured every client the kit knows, writing the read-only password into config files for tools that were not installed; `all` now means every client detected on the machine, the same set the menu offers, and a client named explicitly is still configured. **(2)** The `exakit` command was written by the last install step, so the poll AGENTS.md prescribes answered "command not found" for 98 % of the run; it is now put in place before step 1, the current step is recorded in the manifest, and `exakit status --json` answers `installing` with `install_step`, exit 3, until the install completes. **(3)** With another process on port 8563, `exakit start` said "already running" and exited 0 while `status` said stopped; a busy port is now a `conflict` state with its own remedy, and start refuses with the pid. **(4)** `exakit info --json` gains the `installed`, `status` and `remedy` keys every state query promises. **(5)** Unattended `EXAKIT_DATASETS=weather exakit data-load` on an already-loaded set fell into the local-file prompt and exited 1; it says "already loaded" and exits 0. **(6)** Uninstall deleted VS Code's `mcp.json` outright once the kit's entries were the last in it, and the snapshot went with the kit home; the file is kept with an empty `servers` table and the snapshots are moved beside the kit home before it is removed. **(7)** `exakit sql` remedies were printed on stderr after exapump's generic stdout hint; they come first, on stdout, as `! ...` lines, and the generic hint is dropped. **(8)** Doctor called clients "connected" because a manifest record existed, with the entry deleted and for clients not installed; the state is derived from the checks, `mcp-doctor --json` carries `details.clients`, and `remedy` comes only from a WARNING or ERROR finding. **(9)** `exakit sql` reads `--file <path>` and stdin and drops comment lines, so the saved workflow files rerun without the admin tool; `--help` answers. **(10)** `SELCT 1` was reported as a write attempt pointing at `--write`; an unrecognised first word is reported as a typo. **(11)** `version --json` prints one object (`components` with installed, advertised, status, severity) instead of the decorated table; `mcp-status --json` works instead of reading `--json` as a client; both reject unknown options with exit 2. **(12)** A successful doctor repair clears the `.last-failure` marker it may have left. Both platforms; `tests/agent-audit.sh` guards the shell half.
- **The AI skills update on their own: `exakit update` fetches a newer skill set, no kit release needed.** Skills reached a machine only inside a kit update. Bumping `components.skills.version` alone did worse than nothing: `exakit skills` reported the set as stale and pointed at `exakit skills-install`, which copied the *old* files from the local kit copy and then recorded the *new* number over them, so the drift disappeared from view while the files stayed old. The skill set is now a light component like exapump. It has a row in `exakit version`, it is part of `exakit update`, and its updater downloads the kit repository's `main` archive (the same URL and trust as the kit self-update), moves its `skills/` directory into the kit copy, places the skills, and records the version the *archive's* `versions.json` names rather than the advertised one — the raw endpoint can run minutes ahead of the branch, and a record that runs ahead of the files is how the drift was hidden before. A skills-only update leaves a `skills/.version` marker beside the files so a later `skills-install` records the set it actually placed. Failures warn and never fail the run, like the skills refresh inside the kit self-update. The Windows twin gets the same component, and now records the skill-set version and installed list at all, which it never did. Maintainer workflow: edit `skills/<name>/SKILL.md`, bump `components.skills.version`, merge; the fleet sees the row within a day and picks the set up on its next `exakit update`.
- **`exakit whats-new` is on the help screen.** The command existed but had no entry in the help document, so it was missing from `exakit help`, `exakit whats-new --help` answered "No help entry", and `exakit catalog whats-new` matched nothing — the only place a reader could learn of it was this file. It now sits in the Reference group ("What changed in this kit version.") with a full page and examples, on both platforms since both render from the same document. `tests/whats-new.sh` guards it.
- **CI is green again: three pre-existing test failures and one real defect they hid.** Every run of `versions.yml` on `main` had failed since 2026-09-01, so no pull request could show a real signal and every suite after the first failure went unrun. **(1)** `tests/versions-manifest.sh` died on every macOS runner with `syntax error near unexpected token '('`: bash 3.2 cannot parse a `)` inside a double-quoted string inside a `case` arm inside `$(...)`; the decision moves into a variable. **(2)** Four `tests/marketplace.sh` checks still asserted the pre-table wording ("on this system") and row format of the marketplace screen; they now assert the current ones. One of them uncovered a defect on the all-covered path: the covered list is `id|why|version` but was read into two names, so every line ended in a stray `|` ("managed outside the kit|"). Fixed, and guarded. **(3)** The json-tables "missing release" check stubbed the lookup without leaving the HTTP status behind, so the module rightly said "could not be reached" instead of naming the workflow; the stub now records a 404 the way a real miss does. **(4)** `tests/update-command-surface.sh` found `exakit update runtime` in the three quickstarts and one help example — the per-component form the kit deliberately stopped advertising; they now show `exakit update --yes` for the unattended case instead. **(5)** `tests/test_sample_data_schema.py` still expected the PowerShell data-load prompt not to mention JSON, from before the compiled cargo shim made json-tables installable on Windows; both sides name JSON and the test now says so. **(6)** With the earlier steps green, the two PowerShell-native suites ran in CI for the first time in weeks and `uninstall-ps.ps1` died on `OkStep`, a bare output helper it did not stub; the pwsh-free proxy `tests/lib/ps-uninstall-calls.sh` only resolved Verb-Noun names, so it now checks the bare helpers too.
- **The update notice no longer ends with "Silence this with EXAKIT_NO_UPDATE_NOTICE=1".** The notice is one dim line, at most once a day; a second line explaining how to switch it off was longer than the notice itself and read as nagging. The variable still works and stays documented in `exakit help` and AGENTS.md. Both platforms.
- **dash-server registers with Codex, and the one client that cannot take it is a note, not a warning.** Every `exakit update` and `exakit mcp-setup` on a machine with dash-server printed two `!` lines, `Claude cannot be configured for the 'dash-server' server over HTTP (skipped)` and the same for Codex, which read as a failure and prompted "why is it so?". Two things were wrong. **(1) The Codex reason was stale.** The adapter refused HTTP because an earlier Codex gated remote servers behind an experimental flag; Codex CLI 0.147.0 writes `[mcp_servers.<name>] url = "..."` itself for `codex mcp add --url` with no flag (verified by letting it do so), so the adapter now renders exactly that and Codex gets the dash-server control plane like every other CLI client. **(2) The finding was INFO but printed as a warning.** The summary printer used the warning glyph for every finding regardless of severity, on both platforms; INFO findings now print as notes, and the message says what is actually true — `Claude has no config-file shape for a remote MCP server, so the 'dash-server' endpoint (http://127.0.0.1:5100/mcp) is not registered there` — since Claude Desktop takes remote servers through its Connectors settings, not its config file. Skills, help page and AGENTS.md updated; `components.skills.version` bumped to 1.6.0.
- **json-tables: one immutable release per build, and versions.json is the only authority.** Every json-tables install failed on 2026-09-03 with `Checksum mismatch for exasol-json-tables-ingest-macos-aarch64` (and its siblings on every platform). The cause was structural, not a bad digest: the prebuilt engine was served from a single rolling `mirror-json-tables` release with unversioned filenames, so when upstream shipped v0.3 the packaging workflow **overwrote the v0.2 binaries in place** while versions.json still pinned the v0.2 digests — and the advertise pull request it opened bumped only `version`, leaving the wheel pin and every digest stale, so merging it would not have helped. Meanwhile the install read the *version* off the release body (v0.3) and the *wheel and digests* off versions.json (v0.2), three sources of truth that had quietly disagreed. Now the workflow publishes **one immutable release per build**, tagged `json-tables-<version>` (a forced rebuild gets a `-2` suffix), refuses to touch a tag that already exists, and its advertise job writes the **whole pin** — `version`, `release`, `wheel` and the six `sha256` values — computed from the very files it just published. The module reads only that block: the release tag, wheel name and digests all come from versions.json, the GitHub API call to read the release body is gone from the install path, and a build chosen by hand with `EXAKIT_JSON_TABLES_VERSION` reads its own release's digests instead of the pins of a different build. CI refuses any versions.json whose json-tables pins do not match the assets on the named release, so a hand edit cannot merge either. The v0.3 build that was already on the rolling tag is frozen as `json-tables-v0.3` and pinned. **The property this buys:** an upstream json-tables release changes nothing for anyone until its advertise pull request merges — new installs keep pulling the previous release, which still exists byte for byte. `tests/json-tables-release.sh` guards both halves: the module never applies a pin to a build it is not installing, and the workflow can never publish to a fixed tag or over an existing one. Also corrected in passing: the help page, AGENTS.md and the skill still said json-tables was not available on Windows, a year after the compiled cargo shim made Windows x86_64 a supported platform.
- **Docs: seven claims the shipped documentation made that the code does not.** Each was reachable from the front page or the Windows quickstart, and each cost a reader something concrete. **(1) Windows and WSL share one Docker engine, and nothing said so.** Docker Desktop with WSL integration is a single engine; both installs default to the container `exasol-nano` on the volume `exasol-nano-data`, so a WSL run takes over a Windows install's database — verified on a real machine, where it left the shared container `Exited (1)` and the Windows kit had no database. `EXAKIT_NANO_CONTAINER` and `EXAKIT_NANO_VOLUME` are the only separation there is, and they appeared in no user-facing document. Both Windows quickstarts get a "Windows and WSL share one Docker engine" section — what the second install takes over, what `exakit uninstall` on either side removes, and the two names to set **before** installing; AGENTS.md gets the caveat where it advertises adoption as a feature; `exakit nano --help` gets both variables and a troubleshooting row. **(2) `EXAKIT_REUSE_DB` was documented as "macOS: adopt an existing database".** Both container paths honour it too, and there `=0` deletes the container *and its data volume*, which is the database — corrected in the AGENTS.md table and in the CLI's help document. **(3) Eight environment variables existed only in code.** A new "Troubleshooting and advanced overrides" table in AGENTS.md covers `EXAKIT_HOME` (the only fix for a redirected, cloud-synced or UNC home, and it has to stay set for later `exakit` commands, not just the install), the two Nano names, `EXAKIT_NANO_READY_TIMEOUT` (600s by default, raise it on a slow machine rather than reading the timeout as a failure), the four RAM and free-disk floors with their real defaults, and `EXAKIT_AUTO_ROLLBACK`, which turns the failed-step rollback question into an unattended undo. The three a stuck Windows user reaches for are in both quickstarts' notes tables as well. **(4) The README promised "Ready in under 2 minutes. One command installs and connects the whole stack."** A measured full Windows install on a clean machine took 700 seconds, so the promise made a healthy install look hung and invited someone to kill it. The two minutes are now scoped to the database deploy, exactly as QUICKSTART.md and AGENTS.md already scoped them, with the rest — sample data, the AI bridge, the driver — named as taking longer, Windows most of all. **(5) Python 3.11+ was stated as a hard prerequisite** in two README places and left out of the Windows quickstart entirely, while the code treats a system interpreter as optional and bootstraps a uv-managed 3.12 when it is missing or too old (the bash preflight says so in as many words). All of them now agree: no Python install needed, a suitable one is used if present. **(6) The requirements check was offered to Windows users as `curl ... | EXAKIT_PREFLIGHT=1 sh`**, which a PowerShell user cannot run — there is no `sh`, and `curl` is an alias for `Invoke-WebRequest`. The README, QUICKSTART.md and the Windows quickstart now give the `$env:EXAKIT_PREFLIGHT = '1'` form beside the sh one. **(7) The Windows quickstart's install order, disk, reboot and ARM rows were wrong.** It claimed the machine was checked and Docker verified before anything was fetched, when the download and `~\.exasol-starter-kit` came first; it asked for "~10 GB free disk" where the code checks up to three volumes on different floors (10 GB at Docker's data root, 5 GB on the system drive when that root is elsewhere, 3 GB at the kit home, collapsing into one check on a single-drive machine); its reboot row sent people to `exakit start` although automatic start is on by default for a fresh install, so the database returns once Docker Desktop is running; and its Windows-on-ARM row mentioned only exapump, when the sample data **and the whole AI bridge** are skipped with it, because the read-only MCP user is provisioned through exapump. **And one mangled example, duplicated in four places:** two consecutive lines running the identical `exakit update` under contradictory comments, the second claiming to update the database. It reads `exakit update runtime` now — in both Windows quickstarts, the macOS quickstart and `setup/help/exakit.json`, where `exakit catalog --json` had been handing agents the duplicate as two distinct examples.

- **Feat: `exakit mcp-setup` registers the dash-server add-on's control plane, not just the database server.** Setup wrote exactly one entry — `exasol`, the read-only database server over stdio — so dash-server's MCP control plane, the endpoint an agent is *supposed* to drive, was registered nowhere. Building a dashboard therefore opened with ceremony that had nothing to do with dashboards: hand-rolling a Streamable HTTP transport over `/mcp`, roughly four tool calls and a helper script per dashboard, spent entirely on reaching a server already running on the machine. Setup now writes a second managed entry, **`dash-server`**, pointing at `http://127.0.0.1:<port>/mcp` whenever the add-on is installed — the port read from the add-on's own manifest block (`components.dash_server.port`, `5100` unless the install had to move), with `EXAKIT_DASH_SERVER_PORT` outranking it exactly as it does everywhere else, so every command still agrees on one port. Its tools then arrive in a client's session beside the `exasol` ones. **Cursor, Claude Code, GitHub Copilot, Gemini CLI, OpenCode and Continue** get the entry. **Codex and Claude Desktop are skipped**: neither can express a remote MCP server in the config shape this kit writes, and half-configuring one leaves the user an entry to clean up — so setup reports them as skipped, names the URL for a by-hand addition, and moves on. A skipped client never fails the run, and neither does an unregistrable control plane: the run's headline status stays the `exasol` server's, because an AI client that can query the database is what setup promised. Registration is keyed on the add-on's manifest block, which its installer writes and its uninstall removes wholesale, so "installed" and "registered" cannot drift apart. The entry is a pointer to a loopback port with no credential in it. Removal is per-entry — the uninstall operation takes the server names to act on — so taking one add-on out leaves every other managed entry in the same file alone. As with `exasol`, the client has to restart or reload before the tools appear.
- **Fix: `exakit status` took 27 seconds.** It verifies each bundled dataset against its marker tables, and the PowerShell path asked the database about **one table per query** — tpch, energy and weather carry seven markers between them, so a healthy machine paid seven exapump process starts, TLS handshakes and authentications just to answer "is the database up?". The shell side has always asked once (`SELECT TABLE_SCHEMA || '.' || TABLE_NAME FROM SYS.EXA_ALL_TABLES`); PowerShell now has that twin, matching the pairs in memory. A failure of the single query falls back to the per-table path rather than reporting an empty database off a failed lookup, and the manifest self-healing both keys is unchanged.
- **Fix: a fresh install showed `Version = unknown` for every marketplace add-on.** The table a first-time user sees is drawn by the SETUP script's closing offer, not the CLI — and it resolved the advertised version through `Get-ExakitComponentAvailable`, which is defined in `setup/exakit.ps1` and nowhere else. `setup-windows.ps1` never loads the CLI, so every row fell through to `unknown` in exactly the place the number matters most. It now uses `Get-ExakitAddonAdvertisedVersion`, which answers in both contexts. Same asymmetry an earlier fix closed for the add-on INSTALL path; the row rendering was missed. The shell side was never affected — `exakit_component_available` lives in common.sh and is always in scope.
- **Change: the marketplace table says less.** An installed row read `Installed. Update: exakit update dash-server`, selling a command back to someone who was only looking at what they have; it now reads `Installed`. The all-covered line drops its `Updates: exakit version` tail. And the last column is finally named for what it carries: `Status` when nothing is installable and every row is a state, `Description` while the column still holds each add-on's one-liner.
- **Change: the marketplace and autostart tables are drawn as panels**, the same framed card `exakit version` already used, so every table in the kit reads as one family instead of two of them wearing a bare dashed rule. The glyphs come from the ui palette — rounded where the terminal supports it, ASCII where it does not — so no other file spells a box character (every `.ps1` but `ui.ps1` must stay pure ASCII or PowerShell 5.1 reads it in the legacy codepage). The autostart table's name column is measured rather than fixed at 14, matching the shell twin, so a longer add-on id cannot push the column out of line.
- **Change: `exakit help` is the map, not the atlas.** It printed every command of every component inline, running well past a screenful and making the one thing it is for — finding the command you want — harder. The per-component lists move to `exakit help --all`, which is where a reader who wants everything already goes and which, absurdly, used to show LESS than the default screen. The trailing pointer line goes too; `exakit catalog` is listed on the screen already.
- **Fix: `exakit catalog` printed the `exakit` heading five times.** It started a new section whenever a row's tool differed from the PREVIOUS row — run-length grouping, not grouping — and since rows arrive in help-document order and nearly every component document contributes `exakit ...` commands, the heading recurred once per component, interleaved with the component sections. Rows are collected by tool and printed once per tool now, the kit's own command first. Deduping also keyed on the OPTIONS string, so `status [--json | -j]` from exakit.json and a bare `exakit status` mentioned in dash-server.json were treated as different commands and both printed; the key drops options, and where two documents describe the same command the tool's own document wins.
- **Change: automatic start is ON for a fresh install.** The kit's promise is a database that is simply there, and leaving it off meant a reboot quietly took it away and the next command failed with a connection error. Applied only when the manifest has no opinion yet, so `exakit autostart off` is remembered and survives every later run of the installer.
- **Fix: an add-on that installs a service was left stopped.** The marketplace registered it for boot and stopped there, which on Linux and Windows means nothing runs until the next login — so `exakit status` reported dash-server as `stopped` immediately after installing it. The install starts the service it just created. Best-effort and keyed on the add-on declaring a start hook, so this is about service add-ons generally rather than dash-server by name. PowerShell also gained the autostart registration its shell twin already had.

- **Feat: JSON Tables installs on Windows.** It was the one add-on Windows could not have, and the blocker was never the engine — the packaging workflow has been cross-building `exasol-json-tables-ingest-windows-x86_64.exe` all along. It was the *shim*. Upstream reaches its engine through exactly one call, `subprocess.run(["cargo", "run", ...])`, which lands in `CreateProcess`, and `CreateProcess` resolves a bare name by appending `.exe` **only** — it never consults `PATHEXT`. So the five-line `/bin/sh` `cargo` shim that makes this work on macOS and Linux is invisible on Windows, and a `cargo.cmd` or `cargo.bat` would be too. The answer is a real executable, so the kit now builds one: `setup/shim/json-tables-cargo` is a small no-dependency Rust crate whose binary is named `cargo`, and the `pkg / json-tables` workflow compiles it on `windows-latest`, unit-tests it, and publishes it beside the engine on the `mirror-json-tables` release. The Rust requirement moves to our build machine, which is the trade this add-on has always made. `json-tables.ps1` grows the Install / Update / Validate / Uninstall bodies its twin already had: digest-verified downloads of the wheel, the engine and the shim, a uv venv, a `.cmd` launcher that puts the shim in front of `PATH` for that process only, and a validation that pushes a real JSON document through the engine and checks Parquet comes out.
- Feat: `pkg / json-tables` takes a `force` input. The workflow only republished when UPSTREAM changed, but the Windows shim is *our* code and versions independently — without this, a shim fix could not reach the mirror until upstream happened to cut a release.
- **Fix: the PowerShell digest lookup could never match, so every download would have been refused.** `Get-JsonTablesMirrorDigest` took a `$Asset` parameter and looped with `foreach ($asset in ...)`. PowerShell identifiers are case-insensitive, so those are **the same variable**: the loop overwrote the name it was searching for and the comparison compared an object against itself. Every digest came back empty, and an empty digest means "refuse the artifact". Found by probing the live release rather than reading the code.
- **Fix: both platforms installed the wrong wheel.** The `mirror-json-tables` tag is rolling and accumulates assets, so it currently carries `exasol_json_tables-0.1.0` *and* `0.2.0`; both sides took "the first `.whl`", which is 0.1.0, while recording the version of the current build — a mismatch no update could ever close. Both now take the most recently uploaded wheel.
- Fix: a Windows box that refuses to run unsigned executables now says so. The prebuilt engine and shim are not code-signed, and a machine with WDAC enforcing (or Smart App Control on) rejects them with a bare `Access is denied` — indistinguishable from a corrupt download. Seen on a managed corporate machine, where a *signed* executable copied into the same directory ran fine while the engine, digest matching byte for byte, did not. The install now detects that policy and names it, with the two things that actually help: have the device manager allow the binary, or use WSL.
- **Fix: the add-on marketplace silently lost whichever add-on was listed last.** Every loop over the add-on registry read it on **stdin**, and the row for `exasol-vscode` asks VS Code what is installed. The `code` CLI reads and drains the stdin it inherits, so that one call swallowed the rest of the loop's input and every add-on after it disappeared — `json-tables` is last in the registry, so `json-tables` is what vanished, on any machine that had VS Code. Measured on WSL before the fix: a `while read` over three registry lines read **one**. That is the second half of why JSON Tables was missing there; the first half (the `wsl`/`linux` platform mapping) was fixed separately, and on its own it was not enough — the add-on was correctly *applicable* and still never reached the screen. It affected `exakit marketplace`, `exakit version`'s add-on rows and `exakit update all` alike. All six registry loops now read on **file descriptor 3**, so nothing a future add-on shells out to can eat the list, and the `code` CLI is additionally run with its stdin closed. CI never caught this because a runner has no VS Code, so the CLI is never found and never run — the new tests ship a stub that reproduces the drain without one, and they fail against the previous code.
- **Fix: every marketplace add-on install failed on Windows, at the exact moment the installer offered it.** `Install-ExasolVscode` and `Install-DashServer` open by resolving the advertised version through `Get-ExakitComponentAvailable` — which is defined in the CLI, `setup/exakit.ps1`, and nowhere else. The setup script never loads the CLI: `setup/setup-windows.ps1` sources `exakit-common.ps1`, the component modules and the add-on modules, then closes on the marketplace offer. Picking anything from that offer therefore died on a `CommandNotFoundException` before a single byte was downloaded, and because the offer runs best-effort the user saw only "The marketplace offer did not finish cleanly." macOS and Linux never saw it, and that asymmetry is the whole story: the shell twin, `exakit_component_available`, lives in `common.sh`, which every setup path sources. `Get-ExakitAddonAdvertisedVersion` now answers from both contexts — delegating to the CLI's policy walk when the CLI is loaded, and resolving env override -> `versions.json` -> the module's compiled-in fallback when it is not — and both Install functions go through it. A new `marketplace(addon_version_resolver)` twin check fails if either one reaches for the CLI-only function again.
- **Fix: JSON Tables was hidden on every WSL machine, and explained itself with something untrue.** `json_tables_engine_asset` mapped `macos` and `linux` and returned "no engine" for anything else — but `detect_os` reports WSL as a platform of its own (`wsl`), because the INSTALLER needs that distinction for Docker Desktop and `/mnt` paths. An artifact lookup does not. So the add-on was not merely absent from the marketplace: it was absent while reporting "no prebuilt ingest engine is published for this platform (wsl/x86_64)", about a platform the packaging workflow has always built for and which runs that engine natively. `wsl` folds into `linux` now — the same mapping `exapump_asset_name` has always used. **Native Windows is deliberately unchanged**: it stays not-applicable for the `cargo run` / CreateProcess reason `json-tables.ps1` documents at length, and the test that pins that split still holds.
- **Fix: the VS Code extension could not install from WSL.** On WSL the `code` on PATH is the *Windows* build, reached over `/mnt/c` interop — the normal arrangement, not an edge case, and one that makes the add-on look perfectly applicable. It then failed at the last step, because that launcher starts a Windows process and Windows parses every path in its argv: the `/tmp/exakit-....vsix` the kit had just downloaded and digest-verified arrived as `C:\tmp\exakit-....vsix`, and `code --install-extension` died with `ENOENT: no such file or directory`. The module now asks which CLI it is talking to and, when that CLI is the Windows one, translates paths with `wslpath -w` — which resolves to the UNC form Windows can open (`\\wsl.localhost\<distro>\tmp\...`), so no staging copy is needed: Windows reaches into the distro over that share. A host with no `wslpath` gets its original path back rather than a guess, so the call fails exactly as it did before rather than in some new way.
- Fix: autostart was refused on WSL, in the same shape as the two above. `_exakit_autostart_register` branched on `macos)` and `linux)`, so `wsl` fell to the catch-all and every add-on that starts at login (dash-server today) was told "automatic start is not supported on this platform" — on a WSL2 distro that has systemd enabled and supports it exactly as any other Linux does. WSL takes the linux arm now; a distro genuinely without `systemd --user` still gets the accurate "this session has no systemd --user" message the arm already had. Unregistering and the registered-check were never affected — both look for the unit file rather than asking the platform.

- **Change: `exakit update-check` is gone; `exakit version` answers the whole question.** Two commands each told half the story. `exakit version` listed what was installed and said, in a framed panel, that updates existed — without saying which. `exakit update-check` compared everything against the advertised set but re-listed what `version` had already shown. Answering "what have I got, and is any of it out of date?" meant running both and reading one screen against the other, and they could disagree: `version` deliberately skipped the network under a TTL while `update-check` always refreshed, so the panel could announce updates the table then reported as current. There is one screen now. `exakit version` keeps the Kit panel (version, level, source, install date) and follows it with one table: **Component**, **Version**, **Status**. The advertised version, the maintainer's severity and what to do about it all live in Status, because each is only interesting for a row that is behind — four mostly-empty columns pushed the card past 80 columns to say nothing. Add-ons appear as rows: an installed one reads like any other component, an uninstalled one reads `exakit marketplace`. `update-check` is not aliased or hidden — it exits `2` as an unknown command, like anything else that no longer exists.
- Change: the version screen promotes one command, `exakit update`. It used to close with up to three lines — a quick-updates hint, a runtime-stops-the-database warning and a staged-upgrade pointer — which said the same thing three ways, and a dim `Optional add-ons are available (...)` footer repeating a command the add-on rows already carried. `exakit update` knows a runtime change needs the database stopped and asks at the moment it matters; the screen only has to say something is waiting. Per-component commands (`exakit update mcp`) still work and the rows still name the components.
- Change: `exakit version` no longer takes a target. `exakit update-check mcp` had no equivalent worth keeping once the table fit on one screen, and the old target argument was the only way to render a row for a runtime the machine does not run — which offered to deploy Exasol Personal onto a Nano install, the one thing the kit refuses to do.
- Change: the Version column reports what is on the machine, and only that. It used to append `(kit installed 0.11.2)` when a component had been changed outside the kit; the annotation is about twice the width of the version it explains, so it widened every row and pushed the card past 80 columns — and it had to be stripped back off before each comparison the table makes, which is one more thing to forget on the next branch added.
- Fix: a row whose severity was empty shifted its own notes into the wrong columns. Rows were packed into one tab-separated string and split back apart with `set -- $row`, and word splitting collapses runs of IFS **whitespace** — a tab included. The old table escaped it only because its Severity cell was padded to a fixed width and could never be empty, an invariant the merged table drops (an install ahead of the tagged set carries no severity at all). The maintainer's note on such a row vanished silently. The table uses one array per column now, so nothing can shift.
- **Fix: a crashed database could not be recovered by any documented route.** SIGKILL the Exasol Personal runner and the launcher records the deployment as `interrupted`, after which every start fails with `local VM state contains invalid database port: 0` — the state file is rewritten on each attempt and never regains the port. `personal_status` collapsed that into `stopped`, so `exakit status` answered `Start it: exakit start`, which is the loop the reader was already in. Re-running the installer did not help either: `step_artifact_state` returned `unknown` for the runtime step, so it was skipped as "already done", the run failed at start, and the closing advice was to re-run — and `EXAKIT_REUSE_DB=0`, the documented escape, never got a say because the skip happened before the reuse decision. The deployment step already knew how to try a start, watch it fail and replace the deployment; nothing could reach it. `interrupted` is now its own status with its own remedy everywhere it is reported (prose, `status --json`'s `remedies.database`, `mcp-doctor`), the runtime step re-runs on that state instead of being skipped, and `exakit repair-runtime` is the one command that clears it — destructive, announced, and pre-answerable with `--yes` / `EXAKIT_CONFIRM_RUNTIME_REPAIR=1`.
- **Fix: `exakit status --json` reported three loaded datasets against a database with zero schemas.** `exakit_loaded_datasets` read the manifest and never asked the database, which is the worst possible answer for an agent rebuilding its bearings after a context reset: it goes straight to `object TPCH.LINEITEM not found` with the real cause recorded nowhere. Compounding it, the self-heal that *did* verify wrote a different key than status read — TPC-H's `dataset.conf` sets `flag=data.loaded` while status reads `data.datasets.tpch.loaded` — so the heal fired and status kept lying. Loaded datasets are now verified against the marker tables in one query, both keys are synced, and the manifest remains the fallback only when the database cannot be asked.
- **Fix: an installer run that replaced the database reported "already loaded" into an empty one, and exited 0.** `exakit_db_reachable` cached its answer for the whole process, including the "no" it got before the runtime step; every later dataset check then fell through to the manifest. Only a "yes" is cached now, and stopping the database drops it. Separately, `exakit_load_dataset` consulted the manifest flag directly rather than the verifying helper — it asks the database now.
- **Fix: the error translator was wired only into the kit's own internal SQL** — the one path no agent ever sees. Running SQL the documented way returned the raw engine text, so "every error message names its remedy" was true of the lifecycle commands and false of the SQL path the skill mandates for every validation. New `exakit sql '<statement>'` runs one statement through the translator (connection refused → `exakit start`; `FETCH FIRST`/`TOP` → `LIMIT`; object not found → describe it first), refuses anything that is not a single read statement without `--write`, and refuses a smuggled second statement. It is **not** a sandbox — it is the admin connection, like exapump — and it stays out of the allowlist so it still prompts. PowerShell had no translator at all, making the promise macOS-only; it has one now, wired into its SQL-file and upload paths too.
- **Fix: the read-only allowlist could not match the invocation the docs tell agents to use.** Rules named a bare `exakit`, while AGENTS.md tells agents in as many words that `~/.local/bin` is off a non-interactive `PATH` and to call the binary by absolute path — so every "pre-approved" read-only command kept prompting, and the deny on `uninstall` was sidestepped by typing the full path. All three spellings are covered now, on both the allow and the deny side.
- **Fix: `exakit mcp-doctor` never started the server it called `connected`.** Every stage inspected paperwork — config syntax read the client file, "connectivity" opened a TCP socket to the *database*, manifest consistency compared hashes. A missing `uvx` or a package that would not resolve was therefore a healthy report and an AI client with no Exasol tools in it. A `server_launch` stage now spawns the configured command and completes an `initialize` + `tools/list` handshake. It is deliberately absent from the default stage list so the hermetic suites never spawn a subprocess or reach the network, and `EXAKIT_MCP_SKIP_SERVER_PROBE=1` opts out.
- **Fix: `tests/marketplace.sh` deleted the developer's real exapump profiles.** It sandboxed `EXAKIT_HOME` and `EXAKIT_BIN_DIR` but not `HOME`, and the uninstall path spelled the profile directory `rm -rf "$HOME/.exapump"` inline — so running the suite broke `exapump` and `exakit sql` on the developer's own machine, surfacing much later as `Profile 'starter-kit' not found in config`. Same family as the uv-Python clobber above. The path is a shared overridable variable now, the suite sandboxes `HOME`, and — because re-running the installer is supposed to be the cure for this shape of damage — the exapump step's artifact check covers the profile and not just the binary, and says which artifact was missing.
- Fix: `exakit info --json` exited `0` with the database down, though AGENTS.md documented `0`/`3`/`4` for it. It returns `3` now. `version` and `update-check` never implemented the database-health code and should not — they report on versions — so the documented contract is corrected instead of faked.
- Fix: `mcp-doctor --json` returned three incompatible shapes (healthy, database-down, not-installed) with no key in common, so a parser that read `.status` off the healthy one broke on the two states worth branching on. `installed`, `status` and `remedy` are present in every `--json` answer from every state query now.
- Fix: bad input no longer records a failure. A rejected option or statement wrote `.last-failure`, which `exakit status --json` surfaces as `last_failure` — hanging a stale "failure" off a healthy machine for something the caller merely typed wrong. Usage errors exit `2` and record nothing.
- Fix: `exakit_dataset_loaded`'s manifest heal, `--force` and `EXAKIT_DATASETS` now compose: `EXAKIT_DATASETS=tpch,energy,weather exakit data-load --force` reloaded tpch alone and reported success, leaving no non-interactive way to reload the others short of a full re-install. The variable is documented on the command surface, not only in AGENTS.md.
- Feat: `exakit catalog --json` and `exakit logs --json`. The command catalog was the one discovery surface with no machine-readable form, so an agent told to "discover every command with `exakit catalog`" had to pattern-match a decorated screen.
- Fix: the manifest recorded `connection.schemas: ["STARTER_KIT"]`, which reads as "the MCP user can only see STARTER_KIT" — while it was in fact returning every loaded schema. `default_schema` and `read_scope` now say what it means. A `success_with_warnings` client setup also records the findings behind it, instead of keeping a permanent qualified status that names no warning.
- Fix: `install.sh` wrote an undated `.last-failure` (`status --json` reads the date off line 2), and `install.ps1` wrote none at all — so a Windows install that died before the kit existed left nothing to read in the next session. Both write reason + timestamp now.
- Fix: an unattended install no longer overwrites the user's clipboard with the suggested first prompt. `~/.exasol-starter-kit/workflows/` — the directory the skill's closing step tells agents to save approved SQL into — is created with the kit home rather than left for the agent to invent, and appears in the connection panel.
- Docs: AGENTS.md and the skills stop overstating two things and start stating one. The MCP tool gate is a keyword check, not a parser (`SELECT 1; DROP TABLE T` passes it and reaches the engine), so the privilege gate is named as the boundary; skill portability beyond Claude Code is described as a convention the kit writes to rather than a guarantee, with AGENTS.md as the floor; and the credential guardrail now covers the client configs, where `EXA_PASSWORD` sits in clear text in a file agents read routinely. AGENTS.md also says plainly that the client which ran the install cannot use the MCP tools until it restarts — expected, not a fault to diagnose.

- **Fix: concurrent manifest writes silently lost each other.** `manifest_set`, `manifest_del` and `exakit_unmark_step` are read-modify-writes with no lock, so two kit processes each read the same document, apply their own key, and the last save wins. Measured before the fix: **3 of 12** parallel writes survived, and every one of 30 mixed rounds lost something. Two kit processes at once is ordinary rather than exotic — `exakit start` brings up the database and every add-on service, autostart can fire at boot while another command runs, and an agent may issue two commands in parallel. The manifest is the kit's single source of truth for what is installed, so a lost write means `status`, `update-check` and `uninstall` all read a machine that is not the machine. All three writers now hold an exclusive lock across the whole read-modify-write (`flock` in bash, `FileShare::None` in PowerShell), and the fix is asserted by a test that fails against the previous code. `os.replace`/`Move-Item` already kept the document *valid* under concurrency, which is exactly why this was invisible: the file was never corrupt, only incomplete.
- Fix: no writer uses a shared `<manifest>.tmp` any more. Two writers sharing one temp file can interleave inside it, and the loser's atomic replace then publishes a half-written document — a corruption window that validity checks alone would not have caught. Each write now uses a unique temp name and cleans it up on failure.
- Fix: the manifest's permissions no longer depend on which function wrote it last. `manifest_del` and `exakit_unmark_step` chmod'd it to `0600` while `manifest_set` left it umask-dependent (`0644` in practice), so the mode flipped depending on the last operation. Every writer now settles on `0600`.

- **Fix: the test suite destroyed the developer's uv Python installation.** A uv-created venv's `bin/python` is a *symlink* to the shared managed interpreter, and `>` follows symlinks — so a fixture writing `#!/bin/sh\nexit 0` through one replaced the real 18 MB CPython with 17 bytes, breaking uv for that user system-wide. Every later `uv venv --python 3.12` then failed with `returned an invalid response: EOF while parsing`, which surfaced as an unrelated-looking "the virtual environment could not be created" during pyexasol and dash-server installs. That is one root cause behind four symptoms: a failed component install during a fresh setup, a remedy that looped, a red `marketplace-e2e`, and a recurrence minutes after a manual repair. All twelve such writes across two suites now `rm -f` the path first, and a lint fails any new one.
- Fix: `marketplace-e2e.sh` passes again (9/9). It was never a marketplace fault — it was downstream of the clobbered interpreter above.
- Fix: the uv-fault explanation now reaches every module that offers a retry. It was added to pyexasol only, so dash-server and json-tables still said "Retry with: …" for a fault where retrying loops forever. Guarded by a test that requires any module printing a retry hint to explain the underlying fault first.
- **Fix: three more test suites existed that CI never ran**, and one had rotted: `tests/test_sample_data_schema.py` asserted a data-load prompt wording that the JSON support changed on the bash side. Worth being explicit about what it revealed — the bash/PowerShell divergence there is *correct*: bash routes `.json` through JSON Tables, and that add-on is deliberately unavailable on Windows (`Test-JsonTablesApplicable` returns `$false` unconditionally), so the PowerShell menu must not offer it. The test now encodes that split and says why, so nobody "fixes" the Windows label into a promise it cannot keep. `test_sample_data_schema.py`, `reap-orphan-daemon.sh` and `smoke-test.sh` are now wired into CI, and a guard asserts every hermetic suite stays wired.

- **Fix: a test that only ever passed on a machine with the kit running.** `StaleVersionPinCLITests` drives the real MCP CLI in a *subprocess*, so unlike its in-process siblings it cannot mock `socket.create_connection` — and setup validates connectivity after applying. With the DSN hardcoded to `127.0.0.1:8563`, the outcome depended on whether the developer happened to have a database there: `success_with_warnings` on that machine, `failed_recoverable` with `error connectivity_failed` on a clean one or any CI runner. Nobody noticed because CI never ran the MCP tests; wiring them in is what surfaced it. The test now binds its own listener on an ephemeral port and writes that into its manifest, so it needs nothing installed — verified passing with the database stopped and nothing on 8563.
- Fix: `tests/agent-operability.sh` gained the `lacks` helper it never had. Calling it printed "command not found" to stderr and left the counters untouched, so a skipped assertion read as a pass — which is how one of this round's own new checks quietly did nothing. (A `command_not_found_handle` would be the general guard, but that is bash 4.0+ and this repo must run on the 3.2 that macOS ships.)

- **Fix: the test suite wrote into the developer's live installation.** `tests/dry-run-matrix.sh` exercises the launcher-downgrade guard, and that guard ends in `die`, which records a failure note under `$EXAKIT_HOME`. The fixture isolated the deployment dir, the bin dir and the logfile — but not `EXAKIT_HOME` — so every run planted `Refusing to install launcher 2.0.0 over a newer 2.1.0 deployment` in the real `~/.exasol-starter-kit`. That bogus record is what an agent-operability audit spent its first twenty minutes trying to explain on a machine whose advertised and deployed versions were both 2.2.0 and where the guard could not have fired. It matters more now that `exakit status --json` surfaces `last_failure`: the suite was manufacturing evidence of a broken install. Isolated, and the suite now asserts it left the real kit home clean.
- Fix: a flaky test that was failing `main`. The docker-hang case stubs a `docker` that never returns and expects the probe to give up, but `detect_container_runtime` falls back to **podman** and the fixture masked only docker — so on a host with a working podman, "podman" is the correct answer and the assertion scored it as a failure. It passed locally and on macOS (neither engine present) and failed intermittently on Linux CI, where podman is installed. Both engines are stubbed now.
- Fix: the MCP subsystem's own tests were never run by CI, so nothing exercised `mcp/` at all — a `NameError` in that package could ship green. They now run alongside the shell suites, and they caught exactly that in the change below before it landed.
- Feat: `exakit mcp-doctor` hands back the remedies its findings already carry. It returned `next_actions: []` next to a non-empty `findings` list, and `next_actions` is the field an unattended caller branches on — an empty one reads as "nothing to do" on a machine with problems. Blocking findings are ordered first and duplicate remedies collapse.
- Feat: a kit self-update refreshes the installed AI skills. `exakit update` replaces the whole kit copy, so a release that adds or rewords a skill left the agents' discovery folders holding the previous text; `exakit skills` could report that drift but nothing resolved it.
- Feat: the failure note records **when** it happened, and `exakit status --json` exposes it as `last_failure_at`. A reason with no date cannot be told from a current one, which is precisely how a note that outlived its cause made a healthy machine look broken.
- Feat: `exakit status` reports superseded launchers the kit set aside during an upgrade (`exasol.backup-<epoch>`). Each is a full ~130 MB binary; nothing reported them, so they accumulated invisibly and no command ever reclaimed the disk.
- Fix: `exakit`'s library-not-found error named `~/.exasol-starter-kit/kit` even when `EXAKIT_HOME` pointed elsewhere, sending the reader to a directory the code had never looked in.

- **Fix: the AI skills never reached an installed machine.** The kit-staging step copies an explicit allow-list of paths into `~/.exasol-starter-kit/kit/`, and `skills/` was not on it — on either platform. That is not a benign omission: `exakit_repo_root` *prefers* the staged copy once `kit/mcp` exists, so the copy without skills **shadowed** the checkout that had them. Every install ended with `exakit skills` reporting "no skills/ directory in this kit build", `exakit skills-install` — the first thing AGENTS.md tells an agent to run after installing — failing outright, and not one skill in `~/.claude/skills` or `~/.agents/skills`. It stayed invisible because a missing `skills/` made the post-install step return *success*: no skill installed, nothing reported. Staging now copies `skills/`, the missing-directory case is a recorded soft failure, and `tests/agent-operability.sh` asserts both.
- Fix: the read-only allowlist is no longer collateral damage of that bug. It was applied only from inside the skills copy, so when no skill was placed, every approval prompt the documentation promises to remove kept being asked. It now applies independently, and covers the read-only surface it claims: `catalog`, `preflight`, `update-check`, `guide`, `mcp-status`, `mcp-validate`, `help` and the `skills` listing join the original five. `exakit catalog` — the command AGENTS.md names for discovery — was among those prompting. `exapump sql` and every mutating command stay absent by design, and the `skills` entries are exact forms rather than `skills:*`, because that prefix would also match `skills-install`, which writes the very settings file being granted.
- **Fix: a named remedy that could only loop.** A component install that failed because uv's managed CPython was corrupt reported `reinstall it with: exakit update pyexasol` — and that command failed identically, advising `Retry with: exakit update pyexasol`. The actual repair, `uv python install <ver> --reinstall`, was sitting in the kit's own log and was never named. The uv fault is now translated where the failure is printed, ahead of the retry line.
- Fix: `insufficient privileges` (SQL state 42500) is translated. A write refused for the read-only user is the guardrail working, and the tempting next move — re-running it through `exapump -p starter-kit`, which connects as **admin** and is not sandboxed — is the one thing that breaks the trust model. The remedy now says so at the point of failure instead of only in the docs.
- **Fix: `--json` returned empty stdout on the not-installed path.** `info --json` and `mcp-doctor --json` printed a human line to stderr and nothing to stdout, so a caller piping either into a parser got `Expecting value: line 1 column 1` on exactly the path where structured signal decides the next action — while `status --json` answered correctly, leaving the three state queries disagreeing. All three now answer with an object in both states, through one shared helper on each platform.
- Fix: exit codes match the documented contract. `mcp-doctor` returned 1 rather than 4 when nothing was installed (its exit-3 stopped-database path was already correct), and `version` and `update-check` returned **0** — so an agent using `version` as a cheap liveness probe read success off a bare machine. All four return 4.
- Feat: `exakit status --json` carries the remedy the prose already had. It reported `"pyexasol": null` while the human screen printed `pyexasol: not installed — repair: exakit update pyexasol`, leaving the agent's own channel as the one without the actionable half. The JSON now carries a `remedies` map (component to exact repair command) and `last_failure`, the most recent recorded reason still pending — the record that previously sat on disk unread, capable of misleading a resuming agent indefinitely.
- Fix: a failure on the not-installed path produced a note and no log, because every caller ran the install check *before* initialising logging — leaving `exakit logs`, the diagnostic AGENTS.md points at, with nothing to show. Logging now starts first. `install.sh`'s own early failures (platform detection, before kit logging exists at all) record a note too, instead of leaving no artifact whatsoever.
- Docs: three things an agent could not derive. `~/.local/bin` is absent from a bare non-interactive `PATH`, so `exakit: command not found` does not mean "not installed" — the skill's recovery table said "reinstall", which on a working machine is wrong; it now probes the absolute path first. The bundled datasets' 91 `COMMENT ON` statements are readable from `SYS.EXA_ALL_TABLES.TABLE_COMMENT` and `SYS.EXA_ALL_COLUMNS.COLUMN_COMMENT` (sub-100ms, returning units and FK targets) — previously the only system table named anywhere was `SYS.EXA_USER_SYS_PRIVS`, and the kit itself warns that guessing them fails. And `setsid`, offered as the detach recipe, does not exist on macOS.

- Feat: **one AI skill per component and add-on**, so an agent driving the kit has guidance for whatever it is actually asked to do. Until now the kit shipped a single skill covering install-and-first-query, and it mentioned none of the components by name — an agent asked to load a JSON file, build a dashboard, connect Python or repair MCP had nothing to load and improvised, which `skills/reducing-agent-prompts.md` itself names as the main source of approval-prompt noise. Eight new skills fill that in: `exasol-runtime` (Personal vs Nano, start/stop/status/autostart, and the exit codes to branch on), `exasol-exapump` (SQL, bulk loading, and the fact that the `starter-kit` profile is the **admin**, unsandboxed connection), `exasol-mcp` (the eight clients, doctor/repair, and how to *prove* the read-only user is read-only), `exasol-pyexasol` (the venv interpreter, the TLS setting the self-signed certificate needs, and that pandas is not preinstalled), `exasol-marketplace`, `dash-server`, `json-tables` and `exasol-vscode`. Each carries its own trigger list, so progressive disclosure loads exactly one.
- Feat: `exakit skills` (and `--json`) lists what the kit carries — a one-line summary per skill and whether each has reached the agents' discovery folders as `installed`, `partial` (in some folders only: a half-finished install or a hand deletion) or `available`. The registry behind it is the **filesystem**, not a hardcoded list: identity comes from each `SKILL.md`'s own frontmatter, so adding a skill stays a one-folder change with no code edit on either shell, and `tests/skills.sh` fails if a skill name is ever hardcoded back into the shell layer. Frontmatter that does not parse is skipped by the listing *and* the install, so the two can never disagree.
- Feat: the skill set is versioned (`components.skills` in versions.json) and the install records which version it placed, so copies that predate a kit update are detectable — `exakit skills` says which set is installed, which one the kit carries, and the one command that refreshes them. Previously a kit update silently left stale skills in place.
- Fix: uninstall no longer relies on a hardcoded skill-name list that had gone wrong in both directions — it named `trusted-ai-workflow`, which has never shipped a `SKILL.md`, and knew nothing of any skill added since. Both shells now take the live list from the kit copy and fall back to what the install recorded in the manifest. Enumerating the discovery folders is deliberately *not* the fallback: they also hold skills the user installed themselves, and the kit removes only what it placed — now asserted by both `tests/skills.sh` and `tests/uninstall.sh`.
- Fix: AGENTS.md documented only two of the three marketplace add-ons; json-tables shipped without ever being described to the agents that read that file.

- Feat: the kit is operable by an unattended agent, end to end (the agent-operability audit's gap list, all "this repo" items). `exakit status` now carries its answer in the exit code (0 running, 3 installed-but-stopped, 4 not installed) and shows which datasets are loaded; `exakit status --json`, `exakit mcp-doctor --json` and the existing `exakit info --json` give every state query a machine-readable form with nothing else on stdout. `exakit mcp-doctor` checks the database is running before anything that needs it, so a stopped database is diagnosed as "run exakit start" (exit 3) instead of a failed read-only-user creation pointing at the wrong subsystem. `exakit skills-install` now actually applies the read-only allowlist that skills/reducing-agent-prompts.md documents — additively and idempotently merged into ~/.claude/settings.json, never clobbering existing settings (uninstall stays deny-listed). The three raw database errors every agent hits first are translated where the kit runs SQL (connection refused → exakit start; FETCH FIRST/TOP → LIMIT; object not found → describe it first), and AGENTS.md scopes the "every error names its remedy" claim honestly, carries the same translation table for the paths the kit cannot intercept, and inlines the trust guardrails (ASK→INSPECT→RUN→VALIDATE, exapump-is-admin, the SYS.EXA_USER_SYS_PRIVS privilege probe) so a harness that loads only AGENTS.md keeps them. Bundled datasets now ship COMMENT ON TABLE/COLUMN semantics, so an agent's MCP describe call returns what a column means (units, value domains, FK targets), not just its type. Every subcommand answers `--help` from the catalog; `exakit start`/`stop` route launcher output to the logfile instead of interleaving JSON with the result lines.
- Feat: **JSON Tables** is the third marketplace add-on — ingest, query and reshape JSON-shaped data in Exasol (exasol-labs/exasol-json-tables). The upstream tool needs a Rust toolchain (its CLI runs the ingest engine with `cargo run`, and its wheel ships no crate source), so the kit removes that requirement entirely: a packaging workflow (`.github/workflows/pkg-json-tables.yml`) cross-builds the ingest engine for every platform plus the wheel, publishes them to the kit repository's `mirror-json-tables` release, and the install downloads the prebuilt pair (digest-verified against the release API) and puts a tiny `cargo` shim in front of the CLI — visible only inside the kit's launcher — that answers upstream's one call shape with the prebuilt engine. Validation is a real round trip: a JSON document in, Parquet out, no toolchain anywhere. Hidden on platforms with no published engine (Intel macOS; Windows until the shim has an .exe answer), and a copy the user installed themselves (pip/pipx) is respected, never re-offered or managed.
- Feat: nothing is advertised before it is built. When upstream releases, the packaging workflow (daily, change-gated) builds first and publishes the artifacts; only after a successful publish does its `advertise` job open a pull request moving `versions.json` and the fallback constants to the new build. Until that merges, installed kits keep being offered the last version that really is downloadable — `exakit update-check` can never show a json-tables update that `exakit update` cannot install. The module resolves "latest" from the mirror release itself (a generic `<id>_latest` hook any future add-on can use), and records the mirror's own `version=` line in the manifest, so what is recorded always equals what is on disk.
- Feat: `exakit data-load` understands JSON. The local-file and remote-URL loaders read the file's kind first (`.json` / `.ndjson` / `.jsonl`, compressed variants included); a JSON file is routed through the JSON Tables add-on instead of being handed to exapump to fail on. Not installed yet? A panel explains why JSON needs the add-on (one prebuilt download, nothing to compile) and offers to install it right there — pre-selected, so Enter alone proceeds; `EXAKIT_MARKETPLACE_ADDONS` answers for scripts — and then **the load finishes by itself**: the file is ingested to Parquet and pushed into the database through the same verified exapump path CSV uses. One table gets the familiar SCHEMA.TABLE prompt; a nested document that legitimately yields several tables loads all of them into one chosen schema. A declined install, an unsupported platform, or a failed ingest each say exactly what happened and leave the database untouched. CSV and Parquet flows are byte-for-byte unchanged.
- **Changed:** the `exakit uninstall` menu now offers Skip, the kit-managed add-ons (each removable on its own), and EVERYTHING — the built-in components are no longer individual rows. They are one working installation: removing just the MCP configs or just pyexasol leaves a kit that looks installed and does not work, a state the menu should not put one keystroke away. (An earlier version of this entry said a single component could still be removed by name with `exakit uninstall mcp_configs`; that form has never been accepted by the argument parser, and the claim has been withdrawn from the menu hint and the help text.) New add-ons appear in the menu automatically — it is registry-driven, so an add-on that ships tomorrow is removable with zero uninstall wiring.
- Feat: manual installs are detected for every add-on, whatever its command is called. The system-present probe now also checks the basename of the module's launcher (`EXAKIT_<ID>_BIN`), so a `pip install exasol-json-tables` — whose command is not named after the add-on id — reads as "on this system": the marketplace shows it as covered instead of offering a second copy, and the kit never manages or removes it. A module can still sharpen the answer with its own `<id>_system_present` hook (json-tables adds an import probe of the ambient Python for PATH-less pip installs).
- Feat: every command that speaks SQL now self-heals the database first. A shared helper (`exakit_ensure_runtime_running` / `Confirm-ExakitRuntimeRunning`) starts a stopped runtime and health-checks it before `exakit mcp-setup` and `exakit data-load` touch the database, and `exakit start` gains full self-heal semantics — a missing deployment or container is (re)created, a stopped one started, a running one reported as already running.
- **Changed:** the closing marketplace offer is a selection, not a typed question. It opens the marketplace menu directly — the same cursor menu every other kit choice uses (Space selects, Enter installs) — with Cancel pre-selected, so Enter alone skips everything.
- Fix: re-running the macOS installer over a deployment that exists but is stopped (after `exakit stop`, or a reboot — the Personal runtime does not auto-start) now starts the database and waits for it, instead of skipping the step and failing minutes later with "Connection refused" when the MCP read-only user is created. The Nano paths already restarted a non-running container; macOS was the odd one out, and a parity guard now holds all three installers to it.
- Feat: `exakit marketplace` — optional add-ons, discovered after the install instead of lengthening it. The screen wears the kit's established looks: the state of every add-on as the same aligned table `exakit update-check` prints (Add-on / Status / Version / Action), then the same tree-checkbox the data-load menu uses — a group row with the installable add-ons hanging off connectors; Space selects, Enter installs (`EXAKIT_MARKETPLACE_ADDONS=<ids|all|none>` answers non-interactively for agents and CI). Installed add-ons join `exakit update` / `exakit update-check` like every other component; ones you never picked are never touched by `update all`. The install flow itself is unchanged — the marketplace is advertised as one line in the closing panel, `exakit info`, and `exakit guide`.
- Feat: the install ends with a marketplace offer. Once every step ran, an interactive install says "Your Starter Kit installation is done and working", lists the tools still on offer one line each, and asks — add them now, or maybe later? Yes opens the multi-select; maybe later prints the one command to come back with. The offer is dynamic: a tool already on the machine — installed by the kit *or* found on the system outside it — is never advertised (a system install is respected, not managed), when nothing is left the question disappears entirely, a run with soft failures gets a plain hint instead of a victory lap, and non-interactive runs are never blocked (`EXAKIT_MARKETPLACE_ADDONS` pre-answers).
- Feat: the component registry handles marketplace add-ons generically — every registry function (version block, env override, fallback, upstream lookup, installed probe, update targets and dispatch) resolves a registered add-on through one convention-driven arm on both the bash and PowerShell sides. Adding a future tool is three additive changes: its module pair (which carries its own version constants), a `components.<id>` block in versions.json (whose `repo`/`package` field names the upstream), and one registry line.
- Feat: **dash-server** is the first marketplace add-on — an agent-operated Dash hosting server for live, query-backed dashboards on the local Exasol database (exasol-labs/dash-server, MCP control plane at `http://127.0.0.1:5100/mcp`). Installed tag-pinned from its GitHub release into a kit-managed venv, with a launcher at `~/.local/bin/dash-server` that bootstraps the kit's connection profile from the credential store at run time (the password itself is never written into the launcher). Validation proves the control plane answers over HTTP before the add-on is reported ready, `exakit update dash-server` repairs or updates it, and `exakit uninstall` sweeps the venv, state and launcher with everything else.
- Feat: **Exasol for VS Code** is the second marketplace add-on — the editor extension (exasol-labs/exasol-vscode, extension id `exasol.exasol-vscode`), installed tag-pinned from its GitHub release with the vsix checksum-verified through the same three-tier chain exapump uses (versions.json digest → the pinned fallback → the release API; CI asserts the advertised digest matches the release asset, and the auto-bump re-hashes it). VS Code's `code` CLI is discovered even when the shell command was never registered (PATH, then the app bundle). A copy already installed from the VS Code Marketplace reads as "on this system" and is never offered, managed, or uninstalled; a kit-installed copy is removed through the add-on's own uninstall hook. Proved the add-a-new-add-on recipe: module pair, versions.json block, one registry line each side — zero registry surgery.
- Feat: an add-on that extends a host application is only offered where that application exists. The VS Code extension is listed only on a machine with VS Code — otherwise it is hidden everywhere (no marketplace row, no table line, no closing-offer mention, no discovery line), and naming it explicitly says the host app is missing instead of failing deep in the installer. A copy the kit already installed stays visible even if VS Code is removed later, so it can still be updated or uninstalled. Add-ons declare this with one optional `<id>_applicable` hook (`ApplicableFn` on the PowerShell side).
- Fix: a port held by something else is no longer mistaken for a running dash-server. The probe asked "does anything answer HTTP on 5100", so any web server there made `exakit status` report `running` and `exakit start` decline as "already running" — while dash-server was not running at all. Ownership is now matched on the venv path, exactly how the real console script is recognised: status says `stopped (port 5100 is held by another process: pid N (name))`, start refuses and names the holder, and validation will not claim health on someone else's server. An install with no port named steps past a busy 5100 to the next free port and records it, so every later command agrees; a port you named explicitly is refused rather than silently moved, with `EXAKIT_DASH_SERVER_PORT=<port> exakit update dash-server` as the way to change it. The generated launcher tells the two cases apart too.
- Feat: `exakit logs` reaches every log the kit can show instead of printing one path. With no argument it lists the targets — the installer run, the database container's own output, each add-on service, and what the boot entries wrote at login — with size and last-updated; `exakit logs <target>` tails one, `-f` follows it live, `--lines N` sets how much, and `--path` prints just the path for piping. An unknown name lists what exists, and a log nothing has written yet says so rather than showing an empty screen. Add-ons opt in with one `<id>_log_path` hook (`LogFn` in the PowerShell registry entry). **Changed:** bare `exakit logs` now prints the overview table; the old scriptable behaviour is `exakit logs setup --path`.
- Feat: the kit runs its services like services. `exakit status` reports each one as `running` / `stopped` / `not installed` (an HTTP probe, so a server started by launchd, by hand, or by exakit all read the same), `exakit start` brings up the database *and* every add-on service in one command, `exakit stop` takes the services down before the database, and dash-server gained a real lifecycle — background start with a pidfile and log under the kit home, bounded stop that also catches a copy the kit did not start, and both idempotent.
- Feat: everything comes back after a restart. `exakit autostart on|off` (on by default from a fresh install) registers the platform's own supervisor — a LaunchAgent per service on macOS, a systemd --user unit on Linux, the container's restart policy for Nano, a Startup entry on Windows — so the database and every add-on service are up again after a reboot without anyone thinking about it. `exakit autostart` with no argument prints the state per service, a platform without a supervisor says so instead of pretending, and the full uninstall sweeps every boot entry so nothing is left pointing at deleted files. A service add-on installed from the marketplace joins the boot set the moment it is installed.
- **Changed:** `exakit uninstall` is now a selection, not all-or-nothing. Skip is the pre-selected safe default, then the components actually on the machine (database + data, MCP client configs, AI skills, exapump, pyexasol), then the kit-managed add-ons — each removable on its own — then EVERYTHING (the full teardown). What was picked is shown back in a summary panel, the irreversibility is spelled out, and the typed UNINSTALL gate stays. `--dry-run` still previews the full plan and `--yes` remains the scripted full uninstall. Partial removals clear their manifest records and step flags, so `exakit status`, update-check and an installer re-run all read the machine honestly afterwards. Add-ons plug in through one `<id>_uninstall` hook in their own module — the menu and the full teardown pick it up with no other wiring.
- Fix: the dash-server venv is created seeded with pip and self-repairs a pip-less one. dash-server installs each app's dependencies (including its built-in demo's) by shelling out to `python -m pip`, and a bare uv venv has no pip — every app build failed with "Dependency install failed before import smoke check". The venv is now created with `--seed`, and both install paths verify `python -m pip` actually runs, adding pip in place when a venv predates the seed or was supplied by the user.
- Docs: [MARKETPLACE.md](MARKETPLACE.md) — the marketplace contract and the complete add-a-new-add-on walkthrough with skeleton code for both platforms; [MARKETPLACE-FLOWS.md](MARKETPLACE.md#at-a-glance) (since folded into MARKETPLACE.md) — every user scenario (fresh install, existing kit via the update path, browsing, updating, removal) as linked flowcharts; a marketplace section in the README and the agent runbook (AGENTS.md), and the add-on conventions in CLAUDE.md so coding agents follow them without being told.
- Verified: `tests/marketplace.sh` (63 offline checks: registry, generic-arm behaviour for unregistered ids, update-target gating, the non-interactive contract, launcher generation, pip self-repair, system-install detection, the closing offer's no-TTY / pre-answered / all-present / soft-failure behaviours, soft-fail accounting) and `tests/marketplace-e2e.sh` (a sandboxed end-to-end run: real release install, live control-plane probe, update flow, uninstall sweep) join the suites; CI now also runs `tests/marketplace.sh` and `tests/uninstall.sh`.
- Fix: Docker Desktop on Windows is no longer reported as missing when only the shell's PATH is stale. Docker Desktop adds its `bin` directory to the machine PATH at install time, and an already-open PowerShell keeps the environment it started with — so `docker.exe` sat on disk, worked inside WSL (`wsl -l` even listed the `docker-desktop` distro), and the Windows installer still said "No container runtime found. Install Docker Desktop". The kit now looks for the real `docker.exe` in every location Docker Desktop installs it, including the path the installer recorded in the registry, uses it directly, puts it on PATH for the rest of the run, and says to open a new terminal to fix the shell itself.
- Fix: "Docker is installed but not running" is now three distinct diagnoses instead of one guess — the CLI is off PATH, the engine is still starting (Docker Desktop is running), or Docker Desktop is installed with its WSL backend registered but its engine did not answer. Each carries the remedy that matches it, and none of them tells a user with Docker Desktop installed to go and install it.
- Fix: the free-disk guard now checks the filesystems the install actually writes to instead of one directory. On Windows that is Docker's real storage location (with the WSL2 backend everything lands in a virtual disk under `%LOCALAPPDATA%\Docker\wsl`, which users can relocate to another drive) plus the kit home. On Linux it adds the container engine's data root, which is frequently a different filesystem from `$HOME`. Under WSL it adds the Windows system drive: `df` inside a distro reports the virtual disk's nominal size, so a Windows machine with 3 GB free happily passed a 10 GB check and then failed mid-pull with "no space left on device". When space is short, the engine's own `system df` is shown alongside the `prune` command that reclaims it.
- Fix: a failed step can no longer end the install. `pyexasol`'s live validation ran outside its soft-step wrapper on both platforms, so the step was soft in name only; the Windows data-load, MCP client setup and skills steps caught only the kit's own failure type, so any other error (a cmdlet error, a bad path) aborted a run whose database was already up. Every step is now isolated, and `EXAKIT_DATASETS` naming no bundled dataset warns instead of ending the run.
- Fix: steps that fail are all accounted for at the end. The sample-data load, the AI client (MCP) setup and the skills copy previously failed silently as far as the closing summary was concerned. Each now appears in it, and the summary itself moved below the connection panel — so the last thing on screen is what is missing, why, and the one command that installs it (`pyexasol is not installed: ... / reinstall it with: exakit update pyexasol`).
- **Changed default:** `EXAKIT_VERSION_POLICY` is now `manifest`. An install takes the version set the maintainers tested together, published as `versions.json` at the root of this repository, instead of resolving each component from its own upstream. `latest` keeps the old behaviour as an escape hatch, and any other value installs the built-in fallbacks with no network at all.
- Feat: `versions.json` as the update mechanism — maintainers change a version by merging a pull request; installers and `exakit update-check` / `exakit update` read it. Component bumps no longer need a kit release. Resolution degrades env override → fresh fetch → cached copy → the copy that shipped with the kit → compiled-in fallbacks, so no command can fail because a version lookup did not answer.
- Feat: `exakit update-check` compares installed against advertised versions per component, with a Severity column, the maintainer's note under the row it belongs to, `min_kit_version` gating, and the exact command for each row. It is the only command that prints the table: `exakit version` shows what is installed plus a short hint, and `exakit update` prints just the work it is about to do.
- Feat: `exakit update` applies the quick components (kit scripts, exapump, MCP server, pyexasol) in seconds, and offers the database update in place instead of handing it back as a second command: on a terminal it asks `Stop the database and update the runtime now? [y/N]` — saying what goes down, for roughly how long, and that the data volume is kept — and on yes it stops the database, updates the runtime, brings it back up and reports. `exakit update runtime` still works standalone and runs the same implementation. A run with no terminal is never asked and never stops a database: it defers exactly as before, and opts in only with `exakit update --yes` or `EXAKIT_CONFIRM_RUNTIME_UPDATE=1` (`=0` is a deliberate no). An Exasol Personal **major** upgrade is a data migration and is never started from a prompt; it keeps its backup-gated `--plan` / `--backup` / `--apply` route.
- Change: the kit never moves a component backwards, by any route. An install ahead of the advertised set is reported with an action of `none` and left alone; naming it explicitly succeeds and does nothing. The earlier advisory-rollback flow, its confirmation and `EXAKIT_ALLOW_DOWNGRADE=1` are gone — to withdraw a faulty release, publish a higher version.
- Feat: `pyexasol` is a full update target and its own repair command. Its install step no longer ends a run: a failure warns, records `validated=false`, and leaves the step unmarked, so the database, exapump, MCP server and the `exakit` command itself still finish installing. `exakit status` names the repair.
- Feat: kit self-update from `main` (what `install.sh` fetches), with the release tags kept as fallbacks. The staged copy is validated before it replaces anything, `versions.json` is on that list, and the version recorded is the one that actually landed. Windows is no longer warn-only: `Update-ExakitSelf` does the same work through `Expand-Archive`, deferring the directory swap to just after the command exits when Windows will not replace files that are open.
- Feat: `exakit upgrade-kit2`, `exakit rollback-kit2` and `exakit update kit2` bring the Kit 2 (Trusted AI Workflow) add-on into the CLI. It stays invisible until `versions.json` carries a `kit2` block — that absence is the launch switch.
- Feat: a severity-gated update notice. Only `recommended` or `critical` changes ever interrupt an unrelated command, at most once a day, on stderr, only on a terminal, and `EXAKIT_NO_UPDATE_NOTICE=1` silences it for good. The wording carries the cost: light changes offer `exakit update`, a database change points at `exakit update-check`.
- Feat: exapump downloads verify against the digests in `versions.json` when the version being installed is the advertised one, then the digests shipped with the kit, then the release API. An env override never borrows another release's digest, and the refuse-to-install bar is unchanged.
- Fix: `setup/exakit.ps1` no longer redefines the upstream lookup helpers. Its copies won over the library's because it is dot-sourced later, and its docker-tag lookup was not architecture-aware — an x86_64 host could be told an arm64 tag was the newest one.
- Fix: `exakit update` and `exakit update-check` with no argument failed on Windows with "Unknown update target".
- Fix: a completed step is re-verified before it is skipped. A manifest that recorded the launcher step as done while the launcher binary was gone made every re-run skip the one step that could repair it and then fail the deployment step that needs it — for ever. Steps whose artifact can be checked with a file test (launcher, `exakit` command, exapump) now re-run when it is missing; a step whose state cannot be proven (the database runtime above all) is still skipped, because re-running it on a guess would stop a working database. An empty artifact counts as missing: `[ -x ]` is true of a 0-byte file with mode 755, so the truncated launcher an interrupted or out-of-space install leaves behind used to read as installed and skip the step that would have replaced it.
- Feat: an installer run that moves the kit version ends with a "What's new" box, under the connection details and before the closing `Next:` line, listing the headline points of every version it crossed — one box for a 0.1.0 -> 0.3.0 jump, not one per hop. A first install and a re-run at the same version print nothing. The version installed before the run is recorded in `manifest.json`, so a run that dies partway still gets its box next time and never twice. The panel is cosmetic throughout: a missing or unparseable `WHATS-NEW.md`, a version with no recorded notes, or a downgrade all print nothing and none of them can fail, block or slow an install.
- Docs: "Staying up to date" in the README, per-OS update sections in the quickstarts, the update model and its environment variables in AGENTS.md, and a new `MAINTAINERS.md` runbook for publishing a bump, rolling one back, and enabling Kit 2 (that document has since been retired; its material lives in [MARKETPLACE.md](MARKETPLACE.md) and AGENTS.md).
- Docs: README quick answer for installing over a database you already have — it is adopted, never silently replaced.
- Verified: 189 checks in `tests/versions-manifest.sh` plus the existing suites, run on real bash 3.2 (macOS), on Linux, and against a native PowerShell for every mirrored function. The repository's first CI workflow validates `versions.json` on every pull request, downloads the advertised exapump assets to verify all five digests whenever that file changes, and runs the shell suites on Linux and macOS.

## 0.1.0

- First public release of the Exasol Personal Local Starter Kit.
- Feat: one-command installers for macOS (native Exasol Personal), Linux/WSL, and Windows (Exasol Nano container): `install.sh` and `install.ps1`, unattended-safe, with resume on re-run and a check-only preflight mode (`EXAKIT_PREFLIGHT=1`).
- Feat: the `exakit` lifecycle CLI: `status`, `info`, `start`/`stop`, `data-load`, MCP setup and maintenance (`mcp-setup`, `mcp-doctor`, `mcp-repair`, `mcp-remove`, `mcp-restore`), `logs`, `catalog`, and a guarded `uninstall`.
- Feat: MCP integration with a dedicated read-only database login, validated during setup and re-validated by `exakit mcp-doctor`. Supported clients: Claude (desktop and Claude Code), Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue.
- Feat: three bundled sample datasets (TPC-H retail, smart-meter energy, daily city weather), loaded and verified during install, each in its own schema.
- Feat: the `local-agent-ready-starter` agent skill, so a coding agent can drive the full setup and the inspect-before-run query loop.
- Docs: end-user README, QUICKSTART, per-OS quickstarts, an AGENTS.md runbook, data dictionary, example questions, and a guided first workflow.
- Verified: full test and evaluation runs on macOS (native), Windows (Docker Desktop), and WSL (Podman): 82/82 read-only security probes passed, byte-exact dataset counts on every platform, idempotent re-runs, clean uninstall.
