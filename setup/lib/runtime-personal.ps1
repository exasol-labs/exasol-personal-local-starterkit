# runtime-personal.ps1 - Exasol Personal local runtime module (Windows).
#
# Twin of setup/lib/runtime-personal.sh, at the eleven-function contract the
# rest of the kit actually calls - not a line-for-line port of its 1,200 lines.
# Dot-sourced by exakit-common.ps1 consumers after that file has loaded; every
# helper this module leans on (Info/Ok/Warn2/Fail, the manifest, credentials,
# bounded probes, downloads) lives there.
#
# Launcher facts, from the same release this module downloads:
#   - first try the raw Windows EXE in Exasol S3, pinned by versions.json;
#     fall back to exasol-personal_Windows_x86_64.zip + release checksums;
#     there is NO Windows arm64 local deployment
#   - from 2.4 the database runs on Docker (Engine 29+, Linux containers) or
#     through HOST Podman inside Podman's default machine; the kit picks Docker
#     when it is usable, else Podman, and passes the choice (see the container
#     engine block below). A missing Podman is offered for install by the
#     launcher itself (winget, possibly with an administrator prompt) - the kit
#     never installs either engine
#   - that default machine is shared host-wide: the launcher never reconfigures
#     an existing one and leaves it running after stop and destroy, so this
#     module owns the DEPLOYMENT and nothing else
#   - deployment state: the kit's database is the deployment named
#     starter-kit-local, %LOCALAPPDATA%\exasol\launcher\deployments\starter-kit-local
#     from 2.5.0, ~\.exasol\personal\deployments\<name> before it (a 0.3.0
#     kit's was `default` there); 2.5.0 moves the old ones itself (see
#     Update-PersonalDeployDir), and says where its deployments are with
#     `deployments list --json` (Get-PersonalLauncherDeployments)
#   - from 2.3, non-interactive host preparation FAILS without --auto-approve;
#     the flag is probed per subcommand exactly as the sh side does

$script:PersonalRepo            = "exasol/exasol-personal"
# 2.5.0, published 2026-11-18. Always a published release, never a candidate:
# rc2 and rc3 of 2.3 were both removed upstream while pinned here, and rc3
# reached a user as a 404 mid-install.
# Twin of EXAKIT_PERSONAL_VERSION_FALLBACK in common.sh; both move together,
# and both were checked against the upstream release before being written.
$script:PersonalVersionFallback = "2.5.0"
$script:PersonalPort            = 8563
$script:PersonalProbeTimeout    = if ($env:EXAKIT_PERSONAL_PROBE_TIMEOUT) { [int]$env:EXAKIT_PERSONAL_PROBE_TIMEOUT } else { 10 }
$script:PersonalMinRamGb        = if ($env:EXAKIT_PERSONAL_MIN_RAM_GB)  { [int]$env:EXAKIT_PERSONAL_MIN_RAM_GB }  else { 8 }
$script:PersonalMinDiskGb       = if ($env:EXAKIT_PERSONAL_MIN_DISK_GB) { [int]$env:EXAKIT_PERSONAL_MIN_DISK_GB } else { 20 }
# Set by Repair-PersonalSlcDns: a Docker language container image was linked
# under a database started before it was - only its next start sees it.
$script:PersonalSlcDnsNeedsStart = $false
$script:PersonalBinPath         = Join-Path $script:BinDir "exasol.exe"
# The kit's own launcher, a separate program in the kit's home, never on PATH
# (Krishna, 24 Nov): every new install (K, and S next to a 2.4 of the
# user's, whose exasol.exe is never touched) puts it there, and an update of
# a 0.3.0 kit's launcher at %USERPROFILE%\.local\bin moves it there.
# Get-PersonalCli answers it once the run decided so, or once the kit's
# launcher receipt names it (Sync-PersonalBinPath).
$script:PersonalSeparateBinPath = [IO.Path]::Combine($script:ExakitHome, "personal", "bin", "exasol.exe")
# Get-PersonalSeparateBinPath - that path, also where only the functions are
# loaded (the variable above is set when the file loads).
function Get-PersonalSeparateBinPath {
    if ($script:PersonalSeparateBinPath) { return $script:PersonalSeparateBinPath }
    if (-not $script:ExakitHome) { return "" }
    return [IO.Path]::Combine($script:ExakitHome, "personal", "bin", "exasol.exe")
}
$script:PersonalSeparate        = $false
# Mode S of this run (Install-PersonalLauncher). A later run reads it from the
# manifest (Test-PersonalModeS).
$script:PersonalModeS           = $false
$script:PersonalUpdateMoveFrom  = ""
$script:PersonalUpdateMoveSha   = ""
$script:PersonalUpdateKitCopy   = ""
$script:PersonalUpdateTheirs    = ""
$script:PersonalBinSynced       = $false
# The launcher an older kit's record names, when it is another one than the
# kit's own in its folder: run until this kit's update, never written.
$script:PersonalReceiptLauncher = ""
# Resolve-PersonalDeployDir (exakit-common.ps1, dot-sourced before this file)
# spells the launcher's folders; Get-ExakitProfileHome there, not $HOME: on a
# domain-joined machine PowerShell's $HOME is the account's home-directory
# attribute (H:\, \\server\share\user), and the deployment cannot live there.
$script:PersonalDeployDir       = (Resolve-PersonalDeployDir -Path ("" + $env:EXAKIT_PERSONAL_DEPLOY_DIR)).Dir
$script:PersonalDeployFollowed  = ""
$script:PersonalRebuildNoted    = $false
# Seconds between the waits' looks at the container's own error (see
# Test-PersonalContainerRefused): two podman calls each, so not every 5 s.
$script:PersonalContainerLookEvery = 15

# The one rule of Get-ExakitPersonalDbState (exakit-common.ps1). A caller
# that loaded this file without exakit-common.ps1 (a test of one function)
# gets a guard that lets everything through, as before the rule;
# exakit-common.ps1, loaded first or later, defines the real one.
# Assigned, not declared: a suite that loads this file's function
# definitions one by one must never take these for the real ones.
if (-not (Get-Command Test-ExakitKitDatabaseGuard -ErrorAction SilentlyContinue)) {
    ${function:Test-ExakitKitDatabaseGuard} = { param([switch]$Json) return $true }
}
if (-not (Get-Command Get-ExakitPersonalDbState -ErrorAction SilentlyContinue)) {
    ${function:Get-ExakitPersonalDbState} = { return "" }
}

# Sync-PersonalBinPath - the kit's launcher is the program in the kit's folder
# when the kit's own launcher receipt names it, and when a file is there and
# no receipt names another launcher that exists: a file there is the kit's by
# its place (an install cut short before its receipt, a lost manifest, a
# launcher an uninstall left there). Every kit command (start, stop, status,
# update, uninstall) then runs it. Only a 0.3.0 install not yet updated has a
# receipt that names another launcher: it runs that one until its update, also
# beside a file an undone update could not take away. Read once per process.
# Twin of personal_cli.
function Sync-PersonalBinPath {
    if ($script:PersonalSeparate -or $script:PersonalBinSynced) { return }
    $script:PersonalBinSynced = $true
    $path = ""
    $owner = ""
    try {
        $path = "" + (Get-ExakitManifestValue "components.personal.ownership_path")
        $owner = "" + (Get-ExakitManifestValue "components.personal.ownership")
    } catch { return }
    $sep = "" + (Get-PersonalSeparateBinPath)
    if (-not $sep) { return }
    $script:PersonalReceiptLauncher = ""
    if ($owner -eq "kit" -and $path -and $path -eq $sep) { Use-PersonalSeparateLauncher; return }
    if (-not $path) { try { $path = "" + (Get-ExakitManifestValue "runtime.launcher") } catch { $path = "" } }
    $there = ($path -and $path -ne $sep -and (Test-Path -LiteralPath $path -PathType Leaf))
    if ($there) { $script:PersonalReceiptLauncher = $path; return }
    if (Test-Path -LiteralPath $sep -PathType Leaf) { Use-PersonalSeparateLauncher }
}

# Test-PersonalKitFolderVerified - is the file in the kit's folder the release
# this run installs, by the checksum the kit pins for it?
function Test-PersonalKitFolderVerified {
    $sep = "" + (Get-PersonalSeparateBinPath)
    if (-not $sep -or -not (Test-Path -LiteralPath $sep -PathType Leaf)) { return $false }
    $source = Get-PersonalS3Source -Version (Get-PersonalTargetVersion)
    if (-not $source -or -not $source.Sha256) { return $false }
    try { return ((Get-FileHash -LiteralPath $sep -Algorithm SHA256).Hash -eq $source.Sha256) } catch { return $false }
}

# Get-PersonalUserLauncher - a launcher of the user's on this machine: the one
# at %USERPROFILE%\.local\bin\exasol.exe, else the one on PATH. Never the one
# in the kit's folder. "" for none. Twin of personal_user_launcher.
function Get-PersonalUserLauncher {
    $own = Join-Path $script:BinDir "exasol.exe"
    if (Test-Path -LiteralPath $own -PathType Leaf) { return $own }
    $onPath = Get-Command exasol -ErrorAction SilentlyContinue
    if ($onPath -and $onPath.Source -and $onPath.Source -ne (Get-PersonalSeparateBinPath)) { return "" + $onPath.Source }
    return ""
}

# Test-PersonalModeS - is this install a mode S one (the kit's own 2.5 next to
# an Exasol Personal of the user's it does not use)? This run's own decision,
# or the one Step 1/4 recorded (components.personal.mode), so an install
# resumed in a new process knows it. NEVER $script:PersonalSeparate: the kit
# runs its own program from its folder in every mode (K and U too), and only
# mode S leaves the user's databases out of the one question.
function Test-PersonalModeS {
    if ($script:PersonalModeS) { return $true }
    $mode = ""
    try { $mode = "" + (Get-ExakitManifestValue "components.personal.mode") } catch { $mode = "" }
    return ($mode -eq "S")
}

# Set-PersonalModeS <on> - this run's mode S decision, recorded with it.
function Set-PersonalModeS {
    param([bool]$On)
    $script:PersonalModeS = $On
    try {
        if ($On) { Set-ExakitManifestValue "components.personal.mode" "S" }
        elseif ($null -ne (Get-ExakitManifestValue "components.personal.mode")) { Remove-ExakitManifestValue "components.personal.mode" }
    } catch { }
}

# Use-PersonalSeparateLauncher - from here on the kit runs its own separate
# program, in its own folder (every mode).
function Use-PersonalSeparateLauncher {
    $sep = "" + (Get-PersonalSeparateBinPath)
    if (-not $sep) { return }
    $script:PersonalSeparate = $true
    $script:PersonalBinSynced = $true
    $script:PersonalBinPath = $sep
}

# Get-PersonalTargetVersion - the launcher version this kit installs or updates
# to: the env override, the advertised manifest, the fallback - the same
# resolution order the sh side gets from exakit_resolve_install_versions.
function Get-PersonalTargetVersion {
    if ($env:EXAKIT_PERSONAL_VERSION) { return $env:EXAKIT_PERSONAL_VERSION }
    $advertised = Get-ExakitComponentAvailable "personal"
    if ($advertised) { return $advertised }
    return $script:PersonalVersionFallback
}

# Get-PersonalCli - the kit-managed launcher when it exists, a launcher on PATH
# otherwise, and the kit-managed path as the answer either way when neither
# runs (so error messages name where it WOULD be). Twin of personal_cli.
function Get-PersonalCli {
    Sync-PersonalBinPath
    # The kit's own separate program is the only launcher the kit runs, even
    # before it is installed: never the user's on PATH (mode S).
    if ($script:PersonalSeparate) { return $script:PersonalBinPath }
    # The one an older kit's record names, on PATH or not.
    if ($script:PersonalReceiptLauncher -and (Test-Path -LiteralPath $script:PersonalReceiptLauncher -PathType Leaf)) { return $script:PersonalReceiptLauncher }
    if (Test-Path $script:PersonalBinPath) { return $script:PersonalBinPath }
    $onPath = Get-Command exasol -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $script:PersonalBinPath
}

# Get-PersonalLauncherDeployments [-Again] [-TimeoutSeconds <n>] - the
# launcher's own deployments, in the launcher's order (by name), as objects
# with Path, Status, Name and Infrastructure: `exasol deployments list --json`
# (launcher 2.5.0 and later), bounded by a short timeout and read with
# ConvertFrom-Json, never a pattern. THE ONE PLACE the PowerShell side asks the
# launcher where its deployments are. The answer goes to
# Resolve-PersonalDeployDir ($script:PersonalLauncherListed,
# $script:PersonalLauncherDeployments), so detection, the installer's one
# question, the follow of a moved folder, status and the uninstall see the
# folders the launcher sees. Nothing ($script:PersonalLauncherListed stays
# $false), and the resolver keeps the two roots the kit knows, when there is no
# answer: a launcher without the command (2.4.x), one that
# fails, hangs or prints anything but that list. Asked once per process;
# -Again asks anew (the one question asks with a longer -TimeoutSeconds: the
# launcher probes every deployment it lists). No row is sorted first any more:
# the launcher's `default` is a deployment of the user's like any other.
# Twin of personal_launcher_deployments.
$script:PersonalListTimeout = 6
if ($env:EXAKIT_PERSONAL_LIST_TIMEOUT -match '^[0-9]+$') { $script:PersonalListTimeout = [int]$env:EXAKIT_PERSONAL_LIST_TIMEOUT }
$script:PersonalLauncherAsked = $false
$script:PersonalLauncherListed = $false
$script:PersonalLauncherDeployments = @()
$script:PersonalDeployRec = ""
# Get-PersonalFirstJsonValue <text> - the first complete JSON array or object
# at the start of <text>, cut where its closing bracket is (brackets inside
# strings and escaped quotes are skipped), or "" when it never closes. What
# Python's json.JSONDecoder().raw_decode reads: anything after the value is
# not part of it. Twin of the raw_decode in personal_launcher_deployments.
function Get-PersonalFirstJsonValue([string]$Text) {
    if (-not $Text -or ($Text[0] -ne '[' -and $Text[0] -ne '{')) { return "" }
    $depth = 0
    $inString = $false
    $escaped = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true }
        elseif ($c -eq '[' -or $c -eq '{') { $depth++ }
        elseif ($c -eq ']' -or $c -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring(0, $i + 1) }
        }
    }
    return ""
}

function Get-PersonalLauncherDeployments {
    param([switch]$Again, [int]$TimeoutSeconds = 0)
    if ($script:PersonalLauncherAsked -and -not $Again) {
        if (-not $script:PersonalLauncherListed) { return }
        return $script:PersonalLauncherDeployments
    }
    $script:PersonalLauncherAsked = $true
    $script:PersonalLauncherListed = $false
    $script:PersonalLauncherDeployments = @()
    $timeout = $script:PersonalListTimeout
    if ($TimeoutSeconds -gt 0) { $timeout = $TimeoutSeconds }
    try {
        $cli = Get-PersonalCli
        if (-not $cli -or -not (Test-Path -LiteralPath $cli)) { return }
        $out = Invoke-ExakitBounded -FilePath $cli -Arguments @("deployments", "list", "--json") -TimeoutSeconds $timeout
        if ($null -eq $out) { return }
        # A JSON array, from the first line that opens one (a launcher notice
        # may come before it). Anything else is no answer.
        $lines = @(("" + $out) -split "`r?`n")
        $doc = $null
        $parsed = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (-not $lines[$i].TrimStart().StartsWith("[")) { continue }
            # Only the first complete JSON value: a launcher notice AFTER the
            # list ("A new version ... is available") made ConvertFrom-Json
            # refuse the whole answer, where the shell and Python twins read
            # the list with raw_decode and ignore what follows (OWN-05).
            $value = Get-PersonalFirstJsonValue (($lines[$i..($lines.Count - 1)] -join "`n").TrimStart())
            if (-not $value) { continue }
            try {
                $doc = $value | ConvertFrom-Json -ErrorAction Stop
                $parsed = $true
                break
            } catch { continue }
        }
        if (-not $parsed) { return }
        $rows = @()
        foreach ($item in @($doc)) {
            if ($null -eq $item) { continue }
            if ($item -isnot [System.Management.Automation.PSCustomObject]) { return }
            $path = $item.path
            if ($path -isnot [string] -or -not $path -or -not [System.IO.Path]::IsPathRooted($path)) { continue }
            $status = ""
            if ($item.status -is [string]) { $status = $item.status }
            # The name is the folder's: the launcher prints it, and a list
            # without it is read from the path, as the launcher derives it.
            $name = ""
            if ($item.name -is [string] -and $item.name) { $name = $item.name } else { $name = Split-Path -Leaf $path }
            $infra = ""
            if ($item.infrastructure -is [string]) { $infra = $item.infrastructure }
            $rows += [pscustomobject]@{ Path = $path; Status = $status; Name = $name; Infrastructure = $infra }
        }
        $script:PersonalLauncherDeployments = @($rows)
        $script:PersonalLauncherListed = $true
        return $script:PersonalLauncherDeployments
    } catch {
        return
    }
}

# Update-PersonalDeployDir - point $script:PersonalDeployDir at the folder the
# deployment is in NOW, and make the kit's record follow it. Launcher 2.5.0
# moves a stopped deployment from %USERPROFILE%\.exasol\personal to
# %LOCALAPPDATA%\exasol\launcher on its next command, so a path computed once
# at load is wrong after the first `exasol status` of a run, and every reader
# of the folder calls this first. A folder the user chose is kept.
# THE RECORD FOLLOWS THE MOVE: when the folder the manifest names is gone and
# the deployment it held is found again by its id (moved by the launcher from
# one root to the other, or renamed to starter-kit-local, whatever the
# recorded name), runtime.deployment_dir and the ownership receipt
# runtime.ownership_path are rewritten in place, owner kept, and
# runtime.deployment_name names it. A second deployment that appears while the
# recorded one is still on disk is not a move and changes nothing.
# ONLY THE KIT'S OWN DEPLOYMENT IS FOLLOWED: the record follows only when the
# moved folder's deployment id is the one the kit recorded
# (runtime.deployment_id, through Resolve-PersonalDeployDir -Recorded).
# Another id, or none recorded, leaves the record as it is: that deployment is
# the user's, and Get-ExakitPersonalKitMissing names both folders. A kit that
# never recorded the id (before 0.3.1) gets it here, once per process, from
# its recorded folder while that is still where the record says. Never
# throws. Twin of personal_deploy_dir_refresh, which says more.
function Update-PersonalDeployDir {
    try {
        # WHERE THE LAUNCHER KEEPS ITS DEPLOYMENTS, asked once per process
        # (Get-PersonalLauncherDeployments), unless the folder the kit recorded
        # is on disk: the kit addresses its own deployment by it, with
        # --deployment-dir, and needs no launcher for it: that recorded
        # folder is then the folder, below. Twin of the same step in
        # personal_deploy_dir_refresh.
        # A folder the user chose (naming neither of the two the kit knows) is
        # the folder: nothing to ask either.
        $known = Resolve-PersonalDeployDir -Path ""
        $cur = "" + $script:PersonalDeployDir
        $curDefault = (-not $cur) -or ($known.New -and $cur -eq $known.New) -or ($cur -eq $known.Legacy)
        if (-not $curDefault) { $script:PersonalLauncherDecided = $true }
        if (-not $script:PersonalLauncherDecided) {
            $script:PersonalLauncherDecided = $true
            $rec = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
            if ($rec -and (Test-Path -LiteralPath $rec -PathType Container)) {
                $script:PersonalDeployRec = $rec
            } else {
                $null = Get-PersonalLauncherDeployments
            }
        }
        # THE KIT'S OWN FOLDER WHILE IT IS THERE, even beside another
        # deployment in the launcher's roots: a 0.3.0 database the launcher
        # could not move stays the kit's, and start, stop, status and the
        # sidecars act on it, never on the user's. Twin of the same step in
        # personal_deploy_dir_refresh.
        $rec = "" + $script:PersonalDeployRec
        if ($rec -and ($curDefault -or $cur -eq $rec) -and (Test-Path -LiteralPath $rec -PathType Container)) {
            $r = Resolve-PersonalDeployDir -Path $rec -Recorded
        } else {
            $r = Resolve-PersonalDeployDir -Path ("" + $script:PersonalDeployDir)
            # A RECORDED FOLDER THAT IS GONE, whatever its name: the kit's own
            # deployment found again by its id is the folder (the record
            # follows it, below). Not found by its id, the deployment of the
            # same name in the launcher's other root (or listed under that
            # name) is the one found, and it is not the kit's: kit 0.3.0 kept
            # no id, and a hand-installed 2.5 that moved its `default` leaves
            # the kit's own missing until the installer asks the one question
            # (Get-ExakitPersonalKitMissing names both folders). Twin of the
            # same step in personal_deploy_dir_refresh.
            $gone = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
            if (($curDefault -or $cur -eq $gone) -and $gone -and -not (Test-Path -LiteralPath $gone)) {
                $followed = Resolve-PersonalDeployDir -Path $gone -Recorded
                $goneParent = Split-Path -Parent $gone
                $goneLauncher = ($goneParent -and ($goneParent -eq $known.NewRoot -or $goneParent -eq $known.LegacyRoot)) -or
                    (@(@($script:PersonalLauncherDeployments) | Where-Object { $_ -and $_.Path -and ($_.Path -eq $gone -or (Split-Path -Parent $_.Path) -eq $goneParent) }).Count -gt 0)
                if ($followed.Dir -and $followed.Dir -ne $gone -and (Test-Path -LiteralPath $followed.Dir -PathType Container)) {
                    $r = $followed
                } elseif ($goneLauncher -and -not (Test-Path -LiteralPath $r.Dir -PathType Container)) {
                    # Only from one of the launcher's folders: a folder the
                    # user chose stands for no deployment of the launcher's.
                    $leaf = Split-Path -Leaf $gone
                    $twins = @()
                    foreach ($root in @($known.NewRoot, $known.LegacyRoot)) { if ($root) { $twins += (Join-Path $root $leaf) } }
                    $twins += @(@($script:PersonalLauncherDeployments) | Where-Object { $_ -and $_.Path -and (Split-Path -Leaf $_.Path) -eq $leaf } | ForEach-Object { "$($_.Path)" })
                    foreach ($twin in $twins) {
                        if ($twin -eq $gone -or -not (Test-PersonalDeploymentFolder $twin)) { continue }
                        $r = Resolve-PersonalDeployDir -Path $twin
                        break
                    }
                }
            }
        }
        $script:PersonalDeployDir = $r.Dir
        # The id, from the folder the record names, while it is still there.
        # Once per process, from the first refresh that sees a recorded folder.
        if (-not $script:PersonalDeployIdSeen -and
            (Get-Command Get-ExakitPersonalKitDir -ErrorAction SilentlyContinue) -and
            ("" + (Get-ExakitManifestValue "runtime.deployment_dir"))) {
            $script:PersonalDeployIdSeen = $true
            if (-not ("" + (Get-ExakitManifestValue "runtime.deployment_id"))) {
                $kitDir = "" + (Get-ExakitPersonalKitDir)
                if ($kitDir -and (Test-Path -LiteralPath $kitDir -PathType Container)) {
                    $kitId = "" + (Get-PersonalDeploymentId -Dir $kitDir)
                    if ($kitId) { $null = Set-ExakitManifestValue "runtime.deployment_id" $kitId }
                }
            }
        }
        # Only into one of the launcher's folders (Resolve-PersonalDeployDir
        # -Recorded follows into nothing else): a folder the user chose is
        # never a move's target. From whichever folder the record names that
        # is gone, whatever its name.
        if ($script:PersonalDeployFollowed -eq $r.Dir) { return }
        if (-not (Test-Path -LiteralPath $r.Dir -PathType Container)) { return }
        foreach ($key in @("runtime.deployment_dir", "runtime.ownership_path")) {
            $old = "" + (Get-ExakitManifestValue $key)
            if (-not $old -or $old -eq $r.Dir -or (Test-Path -LiteralPath $old)) { continue }
            # Only once the old one is gone: a running deployment the launcher
            # has not moved yet keeps its folder until a later call.
            $script:PersonalDeployFollowed = $r.Dir
            # Not the kit's deployment (another id, or none recorded): no follow.
            if ((Resolve-PersonalDeployDir -Path $old -Recorded).Dir -ne $r.Dir) { continue }
            Update-PersonalDeploymentRecord -From $old -To $r.Dir
            return
        }
    } catch { }
}

# Update-PersonalDeploymentRecord -From <old folder> -To <new folder> - the
# kit's record of its database moved from one folder to another in one step:
# runtime.deployment_dir, the ownership receipt runtime.ownership_path and the
# MCP sidecar's components.mcp_server.sidecar_dir, each where it names <old>,
# rewritten to <new>, owner kept; runtime.deployment_name names <new>'s
# folder; and the kit's current folder is <new>. Used by the follow above (the
# launcher moved it), by the installer's rename of the user's chosen database,
# and by `exakit update`'s rename of a 0.3.0 kit's `default` and its undo
# (both directions). Never throws. Twin of personal_rename_records in
# runtime-personal.sh (which rewrites the first two keys).
function Update-PersonalDeploymentRecord {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$From, [Parameter(Mandatory)][string]$To)
    try {
        foreach ($key in @("runtime.deployment_dir", "runtime.ownership_path", "components.mcp_server.sidecar_dir")) {
            $value = "" + (Get-ExakitManifestValue $key)
            if ($From -and $value -eq $From) { $null = Set-ExakitManifestValue $key $To }
        }
        if (("" + (Get-ExakitManifestValue "runtime.deployment_dir")) -eq $To) {
            $null = Set-ExakitManifestValue "runtime.deployment_name" (Split-Path -Leaf $To)
        }
    } catch { }
    $script:PersonalDeployDir = $To
    $script:PersonalDeployFollowed = ""
    $script:PersonalDeployRec = ""
    if (Test-Path -LiteralPath $To -PathType Container) { $script:PersonalDeployRec = $To }
}

# Get-PersonalDeployDirArgs - the kit's own deployment, named on every launcher
# call that acts on one. A launcher run without it acts on ITS default, which
# next to the user's own launcher is the user's own deployment. Twin of the
# --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" the sh side passes. The folder
# comes from Update-PersonalDeployDir, so it is where the deployment is NOW.
function Get-PersonalDeployDirArgs {
    Update-PersonalDeployDir
    return @("--deployment-dir", $script:PersonalDeployDir)
}

# Get-PersonalDbPort - the port THIS deployment is on, which is not necessarily
# $script:PersonalPort: from 2.3 the launcher selects and persists a concrete
# port. deployment.json is the answer; until one exists, the port this run
# picked for a new starter-kit-local (Select-PersonalDbPort), else the
# constant. Twin of personal_db_port, regex and all - no JSON parser on the
# status path.
$script:PersonalPortPicked = 0
function Get-PersonalDbPort {
    Update-PersonalDeployDir
    $file = Join-Path $script:PersonalDeployDir "deployment.json"
    if (Test-Path $file) {
        try {
            $raw = [System.IO.File]::ReadAllText($file)
            if ($raw -match '"dbPort"\s*:\s*(\d+)') { return [int]$Matches[1] }
        } catch { }
    }
    if ($script:PersonalPortPicked) { return [int]$script:PersonalPortPicked }
    return $script:PersonalPort
}

# Get-PersonalSavedDbPorts -Dir <deployment folder> - the database port a
# deployment has saved, as the launcher keeps it: `dbPort` in deployment.json
# and `ports: db:<n>` in infrastructure\infrastructure.yaml (the local
# preset's ports). Read from files only, no launcher. Twin of
# personal_saved_db_port.
function Get-PersonalSavedDbPorts {
    param([AllowEmptyString()][AllowNull()][string]$Dir = "")
    $ports = @()
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $ports }
    $json = Join-Path $Dir "deployment.json"
    if (Test-Path -LiteralPath $json -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($json)
            if ($raw -match '"dbPort"\s*:\s*(\d+)') { $ports += [int]$Matches[1] }
        } catch { }
    }
    $yaml = [IO.Path]::Combine($Dir, "infrastructure", "infrastructure.yaml")
    if (Test-Path -LiteralPath $yaml -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($yaml)
            foreach ($m in [regex]::Matches($raw, '(?m)^[ \t]*ports[ \t]*:[^\r\n]*?\bdb[ \t]*:[ \t]*(\d+)')) {
                $p = [int]$m.Groups[1].Value
                if ($ports -notcontains $p) { $ports += $p }
            }
        } catch { }
    }
    return $ports
}

# Test-PersonalPortFree <port> - can a new database have <port> now? Nothing
# answers on it (Test-ExakitPortInUse), and it can be bound on 127.0.0.1 the
# way the launcher binds it: a port Windows keeps for Hyper-V or WSL (an
# excluded port range) answers nothing and still cannot be bound.
function Test-PersonalPortFree {
    param([Parameter(Mandatory)][int]$Port)
    if (Test-ExakitPortInUse -Port $Port) { return $false }
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.ExclusiveAddressUse = $true
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

# Select-PersonalDbPort - the database port a NEW starter-kit-local is given
# (`install local --ports db:<n>`, CONTRACT section 3, D3), so it runs next
# to the user's own databases. Reserved: the port every other deployment the
# kit can see has saved (Get-PersonalSavedDbPorts: both of the launcher's
# roots, and wherever it lists one), and every port that is not free now
# (Test-PersonalPortFree). 8563 when it is not reserved, else the first free
# one of 8564..8663; 0 when none is. The launcher's own `auto` skips only the
# ports in use now, never the port a stopped deployment has saved, so it
# could hand the kit the port a stopped database of the user's comes back on.
# Twin of personal_pick_port.
function Select-PersonalDbPort {
    $reserved = @{}
    foreach ($dir in @(Get-PersonalOtherDeployments)) {
        foreach ($p in @(Get-PersonalSavedDbPorts -Dir $dir)) { $reserved[[int]$p] = $true }
    }
    for ($port = 8563; $port -le 8663; $port++) {
        if ($reserved.ContainsKey($port)) { continue }
        if (-not (Test-PersonalPortFree -Port $port)) { continue }
        return $port
    }
    return 0
}

# Get-PersonalLauncherVersion - the version of the launcher BINARY on this
# machine, asked of the binary itself ("exasol version" prints it bare). The
# deployment's version and the launcher's are two different facts; conflating
# them made a completed update advertise itself forever. Twin of
# personal_launcher_version.
function Get-PersonalLauncherVersion {
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("version") -TimeoutSeconds $script:PersonalProbeTimeout
    if (-not $out) { return $null }
    $raw = ($out -split "`n")[0].Trim() -replace '^v', ''
    if ($raw -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { return $null }
    return $raw
}

# Get-PersonalDeployedVersion - the launcher version that created the deployment
# on disk; $null when there is no deployment or its state cannot say. Read from
# STATE, never by executing a launcher - the decision this feeds is made before
# any binary is installed. Twin of personal_deployed_version.
function Get-PersonalDeployedVersion {
    Update-PersonalDeployDir
    if (-not (Test-Path $script:PersonalDeployDir)) { return $null }
    $bare = Join-Path $script:PersonalDeployDir ".exasolLauncher.version"
    $raw = ""
    if (Test-Path $bare) {
        try { $raw = ([System.IO.File]::ReadAllText($bare)).Trim() } catch { }
    }
    if (-not $raw) {
        $state = Join-Path $script:PersonalDeployDir ".exasolLauncherState.json"
        if (Test-Path $state) {
            try {
                $text = [System.IO.File]::ReadAllText($state)
                if ($text -match '"deploymentVersion"\s*:\s*"([^"]*)"') { $raw = $Matches[1] }
            } catch { }
        }
    }
    $raw = $raw -replace '^v', ''
    # Only answer with something that looks like a version: garbage must read as
    # "unknown" and let the install proceed, never as a version that blocks it.
    if ($raw -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { return $null }
    return $raw
}

# Test-PersonalLauncherSupports <token> - does the launcher's TOP-LEVEL help
# name this subcommand? Line-anchored like personal_help_names_token: a help row
# reading "stop   Stop a running local deployment" must not satisfy "local".
function Test-PersonalLauncherSupports {
    param([Parameter(Mandatory)][string]$Token)
    $help = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("--help") -TimeoutSeconds $script:PersonalProbeTimeout
    if (-not $help) { return $false }
    $anchored = '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?' + [regex]::Escape($Token) + '(\s|,|$)'
    return [bool]($help -match $anchored)
}

# Get-PersonalAutoApproveFlag <subcommand> - "--auto-approve" when this launcher
# takes it there, $null when it does not. Probed on the SUBCOMMAND's help: a
# subcommand's flags never appear at the top level, so the probe above would
# answer "no" for every launcher including the 2.3 ones that need this most.
# A launcher that does not know the flag is never handed it - an unknown flag
# is a hard failure and 2.2 deployments stay supported. Twin of
# personal_auto_approve_flag.
function Get-PersonalAutoApproveFlag {
    param([Parameter(Mandatory)][string]$Subcommand)
    $help = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @($Subcommand, "--help") -TimeoutSeconds $script:PersonalProbeTimeout
    if (-not $help) { return $null }
    if ($help -match '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?--auto-approve(\s|,|$)') { return "--auto-approve" }
    return $null
}

function Test-PersonalDeploymentExists {
    Update-PersonalDeployDir
    if (-not (Test-Path $script:PersonalDeployDir)) { return $false }
    $answer = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments (@("info") + (Get-PersonalDeployDirArgs)) -TimeoutSeconds $script:PersonalProbeTimeout
    return ($null -ne $answer)
}

# Test-PersonalDbAnswers - is the thing on the SQL port actually Exasol? A real
# SELECT through the kit's exapump profile when that module is loaded (it is,
# in the CLI and the installer); without it, a completed TLS handshake
# (Test-PersonalTlsAnswers). A port that is merely open is never the answer
# (see Get-PersonalStatus for why) - and under rootless Podman the open port
# is pasta's, there from the moment the container starts and a minute or more
# before the database inside it accepts a connection. Twin of
# personal_db_answers.
function Test-PersonalDbAnswers {
    # THE HANDSHAKE ALONE, for a deployment that is ours. Asking exapump for a
    # SELECT here made the database's liveness depend on a second tool: when a
    # virus scanner held the freshly installed exapump.exe, every probe said
    # "not running" about a database that was up, and the installer went on to
    # "self-heal" it. Proving WHOSE database answers is a different question,
    # asked only where it arises - see Test-PersonalDeploymentRunning.
    return (Test-PersonalTlsAnswers)
}

# Test-PersonalTlsAnswers - does the database complete a TLS handshake on its
# port? The one probe that tells a database apart from the process publishing
# its port: pasta (rootless Podman) and the launcher's own runner accept the
# TCP connection themselves and reset it when nothing answers behind them,
# which every SQL client reports as "tls handshake eof" - the launcher's own
# 27-second first-boot budget ran out on exactly that, and a port-open wait
# returned the instant the container started. The certificate is self-signed
# by design, so it is accepted, not validated. Twin of personal_tls_answers.
function Test-PersonalTlsAnswers {
    $port = Get-PersonalDbPort
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(700, $false)) { return $false }
        $client.EndConnect($async)
        $ms = $script:PersonalProbeTimeout * 1000
        $client.ReceiveTimeout = $ms
        $client.SendTimeout = $ms
        $accept = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $accept)
        try {
            $ssl.AuthenticateAsClient("localhost")
            return $true
        } finally {
            $ssl.Dispose()
        }
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Get-PersonalForeignDbHint - one sentence for a port that answers like Exasol
# but is not this kit's deployment; empty when nothing completes a handshake.
# Windows and WSL share one network stack, so a database deployed on either
# side holds 8563 for both; naming that spares the reader a hunt for an
# application that is not there. Twin of personal_foreign_db_hint.
function Get-PersonalForeignDbHint {
    if (-not (Test-PersonalTlsAnswers)) { return "" }
    # NAME WHAT IS ACTUALLY THERE. A recorded container of this machine's own
    # previous kit is the commonest holder of this port, and telling that user
    # to go and stop something in WSL sends them looking for a database that
    # does not exist. The crossing is the road out of it. Twin of
    # personal_foreign_db_hint.
    if ((Get-Command Test-LegacyDbRecorded -ErrorAction SilentlyContinue) -and (Test-LegacyDbRecorded) -and
        ((Get-LegacyContainerState) -eq "running")) {
        $c = Get-LegacyContainer
        return " It is the container database of your previous starter kit ($c), which this kit no longer manages. Stop it ($(Get-LegacyEngineName) stop $c) and re-run the installer, which then offers to copy its data across."
    }
    return " It answers like an Exasol database this kit did not deploy: stop that database first, then re-run. Windows and WSL share this port, so one deployed inside WSL holds it here too (stop it there with: exakit stop)."
}

# Get-PersonalLauncherState - the LAUNCHER'S OWN WORD for this deployment
# ("stopped", "database_ready", ...), empty when it cannot say. The port is not
# the owner: a stopped deployment can leave its runner alive and still
# answering, and calling that "running" makes `exakit start` refuse to start a
# database the user cannot otherwise recover. Twin of personal_launcher_state.
function Get-PersonalLauncherState {
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments (@("status", "--json") + (Get-PersonalDeployDirArgs)) -TimeoutSeconds $script:PersonalProbeTimeout
    if ($out -and $out -match '"status"\s*:\s*"([^"]*)"') { return $Matches[1].ToLowerInvariant() }
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments (@("status") + (Get-PersonalDeployDirArgs)) -TimeoutSeconds $script:PersonalProbeTimeout
    if ($out -and $out -match '(?m)^\s*Status:\s*([A-Za-z_]+)') { return $Matches[1].ToLowerInvariant() }
    return ""
}

function Test-PersonalDeploymentRunning {
    if (-not (Test-ExakitPortInUse (Get-PersonalDbPort))) { return $false }
    if (Test-PersonalDeploymentExists) {
        # THE LAUNCHER'S WORD OUTRANKS THE PORT. "stopped" can leave a runner
        # answering (see Get-PersonalStatus); "deployment_failed" is a first
        # boot the launcher gave up on - reconciled by Install-PersonalDeployment,
        # never adopted as running, or its stop and start stay no-ops for good.
        $state = Get-PersonalLauncherState
        if ($state -eq "stopped" -or $state -eq "deployment_failed") { return $false }
        return (Test-PersonalDbAnswers)
    }
    # NO DEPLOYMENT OF OURS: whatever answers on the port is not the kit's
    # database. Windows and WSL share one network stack, so a database
    # deployed on either side holds the port for both - and adopting the other
    # side's database here handed the rest of the install a password that
    # could never work against it. Nothing is adopted by its port any more,
    # not even through a SELECT with the kit's own profile: the kit's database
    # is the deployment starter-kit-local, on the port it picked for it
    # (CONTRACT section 3). Twin of personal_deployment_running.
    return $false
}

# Test-PersonalDeploymentWedged - a SIGKILLed runner leaves the launcher's
# workflow state "interrupted", after which start is refused until the launcher
# rebuilds the deployment. Read from the state file, the same key the sh probe
# reads. From 2.3 the launcher stops producing this state; installed 2.2
# deployments still do, so the probe stays.
function Test-PersonalDeploymentWedged {
    Update-PersonalDeployDir
    $state = Join-Path $script:PersonalDeployDir ".exasolLauncherState.json"
    if (-not (Test-Path $state)) { return $false }
    try {
        $doc = [System.IO.File]::ReadAllText($state) | ConvertFrom-Json
        $workflow = $doc.currentWorkflowState
        if ($workflow -and $workflow.PSObject.Properties["interrupted"] -and $workflow.interrupted) { return $true }
    } catch { }
    return $false
}

# Get-PersonalStatus - the kit's documented status vocabulary, one word.
# A BUSY port is not a running database: with the database stopped and another
# program listening on the port, "running" here sent `exakit start` to say
# "already running" and exit 0 - a loop with no exit. When the port answers,
# ask the launcher; busy-but-not-Exasol is "conflict", its own state with its
# own remedy. Twin of personal_status.
function Get-PersonalStatus {
    if (-not (Test-Path -LiteralPath (Get-PersonalCli) -PathType Leaf)) { return "not installed" }
    if (Test-PersonalDeploymentExists) {
        if (Test-ExakitPortInUse (Get-PersonalDbPort)) {
            # The launcher owns the lifecycle, so its word outranks the port:
            # a stopped deployment whose runner is still up is stopped, not
            # running, or it could never be started again.
            if ((Get-PersonalLauncherState) -eq "stopped") { return "stopped" }
            if (Test-PersonalDbAnswers) { return "running" }
            return "conflict"
        }
        if (Test-PersonalDeploymentWedged) { return "interrupted" }
        return "stopped"
    }
    return "not deployed"
}

# Test-PersonalGuestRebuildExpected / Show-PersonalGuestRebuildNote - from 2.3 a
# deployment runs the VM guest belonging to its launcher's runner, so the first
# start after the launcher changes rebuilds that guest: data kept, far longer
# than the ordinary readiness budget. Said BEFORE the start - silence through a
# long start is the failure mode - and once per run.
function Test-PersonalGuestRebuildExpected {
    $deployed = Get-PersonalDeployedVersion
    if (-not $deployed) { return $false }
    # The launcher actually installed, not the one the kit advertises: before an
    # update those differ, and announcing a rebuild for a launcher this machine
    # does not have yet is a promise about the wrong event.
    $launcher = Get-PersonalLauncherVersion
    if (-not $launcher) { $launcher = Get-PersonalTargetVersion }
    if (-not $launcher) { return $false }
    if ($deployed -eq $launcher) { return $false }
    # ONCE, not forever: a deployment keeps the version that created it, so this
    # comparison stays true after the rebuild has already happened. The
    # completed start records the launcher it completed under.
    return ((Get-ExakitManifestValue "runtime.guest_rebuilt_for") -ne $launcher)
}

function Show-PersonalGuestRebuildNote {
    if (-not (Test-PersonalGuestRebuildExpected)) { return }
    if ($script:PersonalRebuildNoted) { return }
    $script:PersonalRebuildNoted = $true
    Info "This deployment was created by an earlier launcher, so the first start rebuilds its VM guest - slower than usual, once. Your data is kept."
}

# Wait-PersonalReady - a WALL-CLOCK ceiling on the launcher answering, with the
# guest rebuild given its own budget: the ordinary one turned a successful
# upgrade into a reported crash. An explicitly set EXAKIT_PERSONAL_READY_TIMEOUT
# still wins - a number the user chose is never overridden by a guess. Twin of
# personal_wait_ready.
function Test-PersonalReadyProbe {
    Info "Checking deployment health"
    $budget = 150
    $raise = "EXAKIT_PERSONAL_READY_TIMEOUT"
    if ($env:EXAKIT_PERSONAL_READY_TIMEOUT) {
        $budget = [int]$env:EXAKIT_PERSONAL_READY_TIMEOUT
    } elseif (Test-PersonalGuestRebuildExpected) {
        Show-PersonalGuestRebuildNote
        $budget = 900
        if ($env:EXAKIT_PERSONAL_REBUILD_TIMEOUT) { $budget = [int]$env:EXAKIT_PERSONAL_REBUILD_TIMEOUT }
        $raise = "EXAKIT_PERSONAL_REBUILD_TIMEOUT"
    }
    $t0 = [DateTime]::UtcNow
    $script:PersonalContainerError = ""
    $lastLook = $t0
    while (([DateTime]::UtcNow - $t0).TotalSeconds -lt $budget) {
        # A HANDSHAKE, NOT AN OPEN PORT. Under rootless Podman the port is
        # pasta's from the moment the container starts, and `exasol info`
        # answers from the deployment directory - together they declared
        # "reachable" a database that was still a minute from accepting a
        # connection, and the next step's SELECT 1 paid for it six times.
        if (Test-PersonalTlsAnswers) {
            Ok "Deployment is reachable"
            Set-PersonalFirstBootPending $false
            # The database answered under this launcher, so whatever rebuild that
            # first start owed is paid - recorded so the notice retires itself.
            $done = Get-PersonalLauncherVersion
            if (-not $done) { return $true }
            # [void], because THIS FUNCTION'S OUTPUT IS NOW ITS ANSWER. It
            # used to return nothing and a stray object from the manifest write
            # cost nobody anything; it is a $true/$false probe now, and anything
            # else it emits joins that answer.
            [void](Set-ExakitManifestValue "runtime.guest_rebuilt_for" $done)
            return $true
        }
        # A CONTAINER THAT REFUSED TO START WILL NOT ANSWER LATER. Asked every
        # 15 s rather than every 5 (PersonalContainerLookEvery): it costs two
        # podman calls, and the point is to stop a 150 s wait early, not to
        # race it.
        if (([DateTime]::UtcNow - $lastLook).TotalSeconds -ge $script:PersonalContainerLookEvery) {
            $lastLook = [DateTime]::UtcNow
            if (Test-PersonalContainerRefused) { break }
        }
        Start-Sleep -Seconds 5
    }
    $script:PersonalReadySpent  = [int]([DateTime]::UtcNow - $t0).TotalSeconds
    $script:PersonalReadyBudget = $budget
    $script:PersonalReadyRaise  = $raise
    return $false
}

# Show-PersonalPodmanRootfulHint - A REMEDY, NOT A CHECK. Podman Desktop creates
# the default machine ROOTFUL, and a rootful container publishes its port as an
# iptables rule inside the machine - no listener, so neither WSL's localhost
# relay nor gvproxy forwards it to Windows: the database answers inside the
# machine and never on 127.0.0.1:8563. The kit no longer probes or switches the
# machine (new users deploy on Docker, Podman is the fallback); it names the fix
# where a Podman deployment failed or never answered. Silent on Docker.
# Windows-only: the sh side has no WSL relay in front of the published port.
function Show-PersonalPodmanRootfulHint {
    $engine = "" + $script:PersonalEngine
    if (-not $engine) {
        try { $engine = "" + (Get-PersonalEngineRecorded) } catch { $engine = "" }
    }
    if ($engine -ne "podman") { return }
    Info "If Podman's default machine is rootful, the database port is not reachable from Windows. Make it rootless: podman machine stop; podman machine set --rootful=false; podman machine start"
}

# Wait-PersonalReady - the probe, and the end of the run when it fails. Every
# caller outside the install still reaches this one; the install's callers use
# Wait-PersonalReadyOrDeploy below, which tries the repair first and hands a
# refusal back instead of ending the run. Twin of personal_wait_ready.
function Wait-PersonalReady {
    if (Test-PersonalReadyProbe) { return }
    $spent  = $script:PersonalReadySpent
    $budget = $script:PersonalReadyBudget
    $raise  = $script:PersonalReadyRaise
    if ($script:PersonalContainerError) {
        $cause = Show-PersonalFailureCause
        Fail "The database could not start$cause. Read the state with 'exakit status'; once the cause is fixed: exakit start"
    }
    Show-PersonalPodmanRootfulHint
    Fail "The deployment did not answer within ${spent} seconds (the ceiling is ${budget}s; raise it with ${raise}). Read the state with 'exakit status', then 'exakit start' to retry - a deployment stuck in 'interrupted' is repaired with 'exakit repair-runtime' (destructive, it asks first)."
}

# Wait-PersonalReadyOrDeploy - A START THAT REPORTED SUCCESS IS NOT A DATABASE.
# The launcher's start exits 0 and does nothing at all in more than one state:
# "deployment_failed" is the one the kit already knew about, and "initialized
# but not deployed yet" is the one that cost a whole install - start said OK,
# the kit said it was reusing the deployment, and then waited its entire
# 150-second budget for a database nobody had asked to exist.
#
# So this stops reading the state and reads the DATABASE. Whatever the launcher
# called it, a deployment that does not answer after a start it accepted was
# never started, and the launcher's own deploy is what brings it up - about
# twenty seconds. Asking the database rather than the record means the next
# spelling of this state needs no new case arm.
#
# $true when the database answers, $false when it never did. Never ends the
# run: the caller records it and carries on. Twin of
# personal_wait_ready_or_deploy.
#
# A DEPLOY THAT MET THE WSL KERNEL is said as that: on WSL older than 2.7 the
# launcher's start can exit 0 doing nothing, and then this deploy is what hits
# netavark's nftables error. The callers' "repair with: exakit repair-runtime"
# was the wrong next step there - a rebuild meets the same kernel. The reason
# names wsl --update, and $script:PersonalStartNetworkBlocked tells a caller
# that ends the run to end it with Stop-PersonalStartNetworkBlocked instead.
$script:PersonalStartNetworkBlocked = $false
function Wait-PersonalReadyOrDeploy {
    $script:PersonalStartNetworkBlocked = $false
    # Its deploy goes to the kit's own deployment only (Get-ExakitPersonalDbState).
    if (-not (Test-ExakitKitDatabaseGuard)) { return $false }
    if (Test-PersonalReadyProbe) { return $true }
    # A CONTAINER THAT REFUSED TO START is not fixed by deploying it again: the
    # deploy would recreate it and the same error would refuse it the same way.
    # Its cause is the answer.
    if ($script:PersonalContainerError) {
        $cause = Show-PersonalFailureCause
        Set-ExakitFailureReason "The database never answered$cause"
        return $false
    }
    Warn2 "The database did not answer after the launcher accepted the start."
    Info "In some states the launcher's start does nothing and its deploy is the fix - running that now."
    $deployArgs = @("deploy")
    $flag = Get-PersonalAutoApproveFlag "deploy"
    if ($flag) { $deployArgs += $flag }
    $deployArgs += Get-PersonalDeployDirArgs
    $script:ExakitActiveLabel = "Deploying the existing database"
    $logOffset = Get-PersonalLogOffset
    $rc = Invoke-ExakitLogged (Get-PersonalCli) @deployArgs
    $script:ExakitActiveLabel = ""
    if ($rc -ne 0) {
        if (Test-PersonalStartNetworkBlocked -LogOffset $logOffset) {
            $script:PersonalStartNetworkBlocked = $true
            # One short line here: a caller that ends the run says the whole
            # sentence (Stop-PersonalStartNetworkBlocked), and the install
            # summary prints the reason.
            Warn2 "The launcher's deploy failed: this WSL kernel cannot create the deployment network (run wsl --update, then wsl --shutdown, then exakit start)."
            Set-ExakitFailureReason (Get-PersonalStartNetworkText)
            return $false
        }
        Show-PersonalPodmanRootfulHint
        $cause = Show-PersonalFailureCause
        Set-ExakitFailureReason "The database never answered, and the launcher's deploy could not bring it up$cause"
        return $false
    }
    if (Test-PersonalReadyProbe) {
        Ok "The database answered after the launcher's deploy"
        return $true
    }
    if ($script:PersonalContainerError) {
        $cause = Show-PersonalFailureCause
        Set-ExakitFailureReason "The database never answered, even after the launcher deployed it again$cause"
        return $false
    }
    Show-PersonalPodmanRootfulHint
    Set-ExakitFailureReason "The database never answered, even after the launcher deployed it again"
    return $false
}

# Test-PersonalRequirements - the compatibility gate. Windows arm64 is refused
# by NAME: the launcher publishes no Windows arm64 local deployment, and this is
# the one machine class where the old container runtime is the only local
# database - the refusal says which knob keeps it. The hardware is asked, not
# PROCESSOR_ARCHITECTURE, which reports the emulated x64 shell on ARM devices.
# Twin of personal_check_requirements.
function Test-PersonalRequirements {
    # -Preflight: `exakit preflight`, which only reports. An old WSL under a
    # planned Podman deployment is then its failure, as in preflight_report.
    param([switch]$Preflight)
    $arch = Get-ExakitHostArch
    if ($arch -ne "amd64") {
        Fail "Exasol Personal supports macOS, native Linux and Windows x86_64 - it does not support Windows '$arch'. Nothing was installed. For the full kit on this machine, use a native Linux machine or VM."
    }
    $ramGb = 0
    try {
        $ramGb = [int][math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB)
    } catch { }
    if ($env:EXAKIT_FORCE -ne "1") {
        if ($ramGb -gt 0 -and $ramGb -lt $script:PersonalMinRamGb) {
            Fail "This machine is not compatible: Exasol Personal needs at least $($script:PersonalMinRamGb) GB RAM and this machine has ${ramGb} GB. Nothing was installed (or force at your own risk with EXAKIT_FORCE=1)."
        }
        $freeGb = 0
        try {
            $drive = (Get-Item (Get-ExakitProfileHome)).PSDrive
            if ($drive -and $drive.Free) { $freeGb = [int][math]::Round($drive.Free / 1GB) }
        } catch { }
        if ($freeGb -gt 0 -and $freeGb -lt $script:PersonalMinDiskGb) {
            Fail "This machine is not compatible right now: the database needs at least $($script:PersonalMinDiskGb) GB free disk and the home drive has ${freeGb} GB. Free up space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
        }
    }
    # Nothing is said here about the container runtime the launcher brings with
    # it. On Windows the launcher installs what it needs itself, and the deploy
    # step names the one administrator prompt that can appear at the moment it
    # can appear - which is where a reader can act on it. A line at the gate
    # was an announcement about a step that had not started.
    #
    # NO PODMAN-MACHINE CHECK HERE, rootful or otherwise. New Windows users
    # deploy on Docker and Podman is the fallback, so the gate does not probe
    # or reconfigure a machine it may never use. A rootful default machine
    # (the port is an iptables rule inside it, which nothing forwards to
    # Windows) is named as the remedy where it shows: a Podman deployment
    # that fails or never answers (Show-PersonalPodmanRootfulHint).
    #
    # THE WSL CHECK, before any Podman work: on a WSL kernel without nftables
    # the deploy is refused anyway, so nothing should be downloaded or started
    # for it. Only for a fresh deployment that will run through Podman. The
    # verdict is kept for the deploy step, so the refusal is said once (see
    # Install-PersonalDeployment).
    #
    # QUIETLY, THOUGH: -Probe never asks, so a stopped Docker reads podman
    # here while the deploy step may still offer to wait for it and deploy on
    # Docker. A refusal said here was then followed by a Docker install; the
    # deploy step says it, once the engine is known to be Podman.
    $script:PersonalWslVerdict = $null
    $script:PersonalWslUnread = $false
    $script:PersonalWslRefusal = ""
    if ((-not (Test-PersonalDeploymentExists)) -and ((Resolve-PersonalEngine -Probe) -eq "podman")) {
        $script:PersonalWslVerdict = [bool](Test-PersonalWslPodmanNetworkOk -Quiet)
        # A PASS ON A RELEASE THAT COULD NOT BE READ is still worth its warning:
        # the deploy step uses the pass as it is, so it says the line then.
        $script:PersonalWslUnread = ($script:PersonalWslVerdict -and $null -eq $script:PersonalWslReleaseSeen)
        if ($Preflight) {
            # A REPORT MUST NOT SAY "passed" AFTER A REFUSAL. The planned
            # engine is Podman, so an old WSL is a failure here - the
            # shell's preflight line, same words.
            if (-not $script:PersonalWslVerdict) {
                # A STOPPED MACHINE WAS NOT ASKED (preflight starts nothing):
                # its iptables setting, if it has one, is named as unread.
                $stoppedNote = ""
                if ($script:PersonalPodmanMachineStopped) {
                    $stoppedNote = ". Podman's machine is stopped, so its firewall driver could not be read: if it uses iptables, start it (podman machine start) and re-run"
                }
                Fail "WSL $($script:PersonalWslReleaseSeen): Podman on this WSL kernel cannot create the network Exasol Personal 2.4 needs (no nftables) - run 'wsl --update' then 'wsl --shutdown', or start Docker Desktop so the install deploys on Docker$stoppedNote"
            }
            if ($null -eq $script:PersonalWslReleaseSeen) {
                Info "The WSL release could not be read - Exasol Personal 2.4 on Podman needs WSL 2.7 or newer; check with 'wsl --version'"
            }
        }
    }
    Ok "Compatibility check passed (windows $arch, ${ramGb} GB RAM)"
}

# Install-PersonalLauncher - download the launcher release, verify it against
# the release's checksums file, and place exasol.exe under the kit's bin dir. A
# launcher already on PATH that knows the 'local' preset is kept as it always
# was. Twin of personal_install_launcher.
function Get-PersonalS3Source {
    param([Parameter(Mandatory)][string]$Version)
    # The pin is for the raw Windows executable, not the GitHub ZIP. An
    # override/latest target must never reuse the manifest's older digest.
    # EXAKIT_PERSONAL_S3=0: the network blocks the bucket, or the release path
    # is wanted for its own sake; the GitHub download is as verified.
    if ($env:EXAKIT_PERSONAL_S3 -eq "0") { return $null }
    # The kit copy's own pins, never the fetched document (SEC-13).
    if ((Get-ExakitVersionsPin -Path "components.personal.version") -ne $Version) { return $null }
    $base = Get-ExakitVersionsPin -Path "components.personal.s3.base_url"
    $sha = Get-ExakitVersionsPin -Path "components.personal.s3.sha256.windows-x86_64"
    if (-not $base -or $base -notmatch '^https://' -or $sha -notmatch '^[0-9a-f]{64}$') { return $null }
    return @{ Url = "$($base.TrimEnd('/'))/windows/x86_64/$Version/exasol.exe"; Sha256 = $sha }
}

# Test-PersonalVersionOutranks <a> <b> - true ONLY when version a is
# demonstrably higher than b (dotted numeric components, a missing one is 0, a
# pre-release suffix dropped). Anything it cannot decide is false: this answer
# refuses an install. Twin of personal_deployment_outranks.
function Test-PersonalVersionOutranks {
    param([string]$A, [string]$B)
    $a = ("" + $A) -replace '^v', '' -replace '[^0-9.].*$', ''
    $b = ("" + $B) -replace '^v', '' -replace '[^0-9.].*$', ''
    if (-not $a -or -not $b) { return $false }
    $pa = @($a.Split('.')); $pb = @($b.Split('.'))
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count -and $pa[$i]) { if ($pa[$i] -notmatch '^[0-9]+$') { return $false }; $x = [int64]$pa[$i] }
        if ($i -lt $pb.Count -and $pb[$i]) { if ($pb[$i] -notmatch '^[0-9]+$') { return $false }; $y = [int64]$pb[$i] }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    return $false
}

# Test-PersonalLauncherNewer - is the launcher the kit would drive
# (Get-PersonalCli), whoever installed it, on a newer release line than the
# one this kit pins (a 2.6.x next to a 2.5.0 pin)? $true when it is, with its
# version in $script:PersonalLauncherNewerVersion. A patch ahead on the pinned
# line is not newer: that is the kit's own update path. Only `version` is
# asked; nothing is started, stopped or moved. Twin of personal_launcher_newer.
$script:PersonalLauncherNewerVersion = ""
function Test-PersonalLauncherNewer {
    $script:PersonalLauncherNewerVersion = ""
    $pin = Get-PersonalTargetVersion
    if (-not $pin) { return $false }
    $cli = Get-PersonalCli
    if (-not $cli -or -not (Test-Path -LiteralPath $cli)) { return $false }
    $version = ""
    $out = Invoke-ExakitBounded -FilePath $cli -Arguments @("version") -TimeoutSeconds $script:PersonalProbeTimeout
    if ($out) {
        $raw = ($out -split "`n")[0].Trim() -replace '^v', ''
        if ($raw -match '^[0-9][0-9A-Za-z.+_-]*$') { $version = $raw }
    }
    if (-not $version) { return $false }
    # The release line: 2.5.3 is 2.5, 2.6.0 is 2.6.
    $lineOf = { param($v) $p = @("$v".Split('.')); if ($p.Count -ge 2) { "$($p[0]).$($p[1]).0" } else { "$v" } }
    if (-not (Test-PersonalVersionOutranks (& $lineOf $version) (& $lineOf $pin))) { return $false }
    $script:PersonalLauncherNewerVersion = $version
    return $true
}

# Write-PersonalLauncherNewerWarning - the one line the installer says about
# such a launcher before its first step. The install goes on with it: the
# launcher stays the user's, never replaced or downgraded. Only for an install
# the kit already records (Get-PersonalLauncherPlan answers no mode): a new
# install next to a newer launcher stops at Step 1/4 instead (mode A6), so
# this line would promise what it does not do. Twin of
# personal_warn_launcher_newer.
function Write-PersonalLauncherNewerWarning {
    if ((Get-PersonalLauncherPlan).Mode) { return }
    if (-not (Test-PersonalLauncherNewer)) { return }
    Warn2 "Exasol Personal $($script:PersonalLauncherNewerVersion) is on this computer. This kit is tested with Exasol Personal $(Get-PersonalTargetVersion) and uses the launcher it found."
}

# Test-PersonalInstallRecorded - does the kit record an Exasol Personal of its
# own here: a launcher receipt (components.personal), the launcher it ran
# (runtime.launcher), or a database of the personal runtime? Such an install
# keeps the launcher and the database it has (CONTRACT section 2: an existing
# install never changes mode). A 0.2.x container record is not one.
# THE USER'S LAUNCHER ALONE IS NOT ONE: a 0.3.0 kit that was answered "No"
# (no database) recorded only the launcher it found, theirs. With no database
# recorded, that install follows the new-user rules when the installer runs
# again (SPEC, the existing users' table): next to their 2.4 or a newer line
# the A6 stop, with their 2.5 the launcher as it is and the one question. A
# launcher of the kit's own, recorded with no database, keeps the launcher.
# NEITHER IS A DATABASE THAT IS GONE, run by a launcher of theirs (a 0.3.0 kit's
# own on their launcher, or one of theirs it used, deleted by hand): the new
# database is a new install's, and the kit never makes it with their launcher.
# Twin of personal_kit_has_record launcher and personal_launcher_mode_decide.
function Test-PersonalInstallRecorded {
    if (Test-PersonalDatabaseRecorded) {
        if (Test-ExakitComponentManaged "personal") { return $true }
        if (("" + (Get-ExakitManifestValue "components.personal.ownership")) -ne "user") { return $true }
        $recorded = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
        if (-not $recorded) { return $true }
        Update-PersonalDeployDir
        $recorded = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
        return (Test-Path -LiteralPath $recorded)
    }
    $owner = "" + (Get-ExakitManifestValue "components.personal.ownership")
    if ($owner -eq "user") { return $false }
    return ([bool]$owner -or [bool]("" + (Get-ExakitManifestValue "runtime.launcher")))
}

# Test-PersonalDatabaseRecorded - does the kit record a database of the
# personal runtime: its folder (runtime.deployment_dir), its launcher id
# (runtime.deployment_id, written the moment `install local` made it), or an
# ownership receipt beside runtime.type personal? Without one, the install is
# new to the database, and the installer's one question decides which it
# uses (Select-PersonalDatabase). Twin of personal_kit_has_record.
function Test-PersonalDatabaseRecorded {
    if (("" + (Get-ExakitManifestValue "runtime.deployment_dir")) -or ("" + (Get-ExakitManifestValue "runtime.deployment_id"))) { return $true }
    return ((("" + (Get-ExakitManifestValue "runtime.type")) -eq "personal") -and [bool]("" + (Get-ExakitManifestValue "runtime.ownership")))
}

# Get-PersonalVersionLine <version> - "2.5" for 2.5.3, the release line the
# kit compares launchers by. "" for nothing readable.
function Get-PersonalVersionLine {
    param([AllowEmptyString()][AllowNull()][string]$Version = "")
    $m = [regex]::Match(("" + $Version).Trim().TrimStart("v"), '^(\d+)\.(\d+)')
    if (-not $m.Success) { return "" }
    return "$($m.Groups[1].Value).$($m.Groups[2].Value)"
}

# Get-PersonalLauncherPlan - which Exasol Personal launcher a NEW install
# drives (CONTRACT section 2, Windows), decided once per process, before Step
# 1/4 acts on it:
#   K  - no launcher of the user's, and no deployment of theirs in the older
#        root: the kit installs its own 2.5 in its folder
#        (Get-PersonalSeparateBinPath)
#   U  - the user's launcher is on the pinned release line (2.5.x): the kit
#        installs its own 2.5 in its folder and runs that one, theirs stays as
#        it is, and the one question offers their databases
#   S  - the user's launcher is 2.4 or older, or its version cannot be read
#        (Krishna, Q2): the kit installs its own 2.5 as a separate program in
#        its home, never on PATH ((Get-PersonalSeparateBinPath)), with the
#        real USERPROFILE (Podman needs it), and deploys starter-kit-local
#        with it. Their launcher is never touched. Known and accepted: the
#        kit's 2.5 moves their STOPPED 2.4 deployments into the 2.5 root
#        Also S: no launcher of theirs, but deployments of theirs sit in
#        %USERPROFILE%\.exasol\personal\deployments
#   A6 - the user's launcher is newer than the pinned line (2.6: not checked
#        yet, so not run next to). The install
#        stops at Step 1/4 (Stop-PersonalLauncherPlan). Windows has no private
#        home for a launcher of the kit's own: the profile that would hide
#        their deployments also holds Podman's machine
#   "" - an install the kit already records keeps its launcher
# Launcher is the user's launcher ("" for none: with no record of the kit's,
# any launcher found is the user's, at the kit's own path too), Version its
# `version` ("" unread), Why the reason for S (older, unread, legacy) or A6
# (newer), and Legacy the folders of theirs in the older root. Only `version`
# is asked. Twin of personal_launcher_mode_decide, whose mode P (a private home
# for the kit's own launcher) is S here, and A6 next to a newer line.
$script:PersonalLauncherPlan = $null
function Get-PersonalLauncherPlan {
    $plan = [pscustomobject]@{ Mode = ""; Launcher = ""; Version = ""; Why = ""; Legacy = @() }
    # Asked first, every time (manifest reads only): once the kit records the
    # launcher it installed or found, the install is no longer new.
    if (Test-PersonalInstallRecorded) { return $plan }
    if ($null -ne $script:PersonalLauncherPlan) { return $script:PersonalLauncherPlan }
    $cli = "" + (Get-PersonalCli)
    # A file in the kit's folder with no record of the kit's is the kit's, not
    # a launcher of the user's: theirs is looked for beside it.
    $beside = ($cli -eq (Get-PersonalSeparateBinPath))
    if ($beside) { $cli = "" + (Get-PersonalUserLauncher) }
    if ($cli -and (Test-Path -LiteralPath $cli -PathType Leaf)) {
        $plan.Launcher = $cli
        if ($beside) {
            $raw = (("" + (Invoke-ExakitBounded -FilePath $cli -Arguments @("version") -TimeoutSeconds $script:PersonalProbeTimeout)) -split "`n")[0].Trim() -replace '^v', ''
            if ($raw -match '^[0-9][0-9A-Za-z.+_-]*$') { $plan.Version = $raw }
        } else {
            $plan.Version = "" + (Get-PersonalLauncherVersion)
        }
    }
    $roots = Resolve-PersonalDeployDir -Path ""
    if ($roots.LegacyRoot -and (Test-Path -LiteralPath $roots.LegacyRoot -PathType Container)) {
        foreach ($e in @(Get-ChildItem -LiteralPath $roots.LegacyRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-PersonalDeploymentFolder $e.FullName) { $plan.Legacy += $e.FullName }
        }
    }
    $pinLine = Get-PersonalVersionLine (Get-PersonalTargetVersion)
    $line = Get-PersonalVersionLine $plan.Version
    if ($plan.Launcher) {
        if (-not $line -or -not $pinLine) { $plan.Mode = "S"; $plan.Why = "unread" }
        elseif ($line -eq $pinLine) { $plan.Mode = "U" }
        elseif (Test-PersonalVersionOutranks "$line.0" "$pinLine.0") { $plan.Mode = "A6"; $plan.Why = "newer" }
        else { $plan.Mode = "S"; $plan.Why = "older" }
    } elseif (@($plan.Legacy).Count -gt 0) {
        # Deployments of theirs in the older root, no launcher of theirs:
        # mode S too (Krishna, 24 Nov). Accepted: the kit's 2.5 moves their
        # stopped ones into the 2.5 root.
        $plan.Mode = "S"; $plan.Why = "legacy"
    } else {
        $plan.Mode = "K"
    }
    Write-ExakitLog "INFO" "Exasol Personal launcher plan: mode $($plan.Mode) $($plan.Why) launcher '$($plan.Launcher)' version '$($plan.Version)' older deployments $(@($plan.Legacy).Count)"
    $script:PersonalLauncherPlan = $plan
    return $plan
}

# Stop-PersonalLauncherPlan <plan> - the A6 stop: Step 1/4 ends with one
# sentence and a non-zero exit (Fail, the installer's "cannot continue" path),
# nothing installed for the runtime. Only a launcher newer than the pinned line
# (Why "newer") reaches it: older, unread and legacy are mode S. Windows only:
# macOS and Linux run the kit's own launcher in a private home there (mode P).
function Stop-PersonalLauncherPlan {
    param([Parameter(Mandatory)]$Plan)
    $pinLine = Get-PersonalVersionLine (Get-PersonalTargetVersion)
    if ($Plan.Why -eq "newer") {
        $kit = "" + (Get-ExakitManifestValue "kit.version")
        $kitName = "The starter kit"
        if ($kit) { $kitName = "The starter kit $kit" }
        Fail "This Exasol Personal is newer than the starter kit supports. $kitName needs Exasol Personal $pinLine."
    }
    if ($Plan.Why -eq "unread") {
        Fail "An Exasol Personal launcher is on this computer, and its version could not be read. Update it to Exasol Personal $pinLine, then run this installer again."
    }
    $line = Get-PersonalVersionLine $Plan.Version
    if (-not $line) {
        # No launcher: the version the deployments in the older root were made with.
        foreach ($dir in @($Plan.Legacy)) {
            $file = Join-Path $dir ".exasolLauncher.version"
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            try { $line = Get-PersonalVersionLine ([System.IO.File]::ReadAllText($file)) } catch { $line = "" }
            if ($line) { break }
        }
    }
    if (-not $line) { $line = "2.4" }
    Fail "Exasol Personal $line is on this computer. Update it to Exasol Personal $pinLine, then run this installer again."
}

# Get-PersonalKitLauncherBehind <path> - the version of the launcher at <path>
# when it is the KIT'S OWN (at $script:PersonalBinPath, with the kit's receipt
# and digest: Test-ExakitComponentManaged) and older than the version this run
# installs; "" otherwise. A launcher of the user's, one ahead of the pin or at
# it, and every launcher in an installer that `exakit update` started answer
# "", and keep the reuse they always had. The kit's launcher while the kit's
# own database is missing (Get-ExakitPersonalDbState) answers its version too:
# the 0.3.0 kit whose `default` a hand-installed 2.5 moved keeps launcher
# 2.4.0, which cannot list that `default` for the installer's one question.
# Its caller then replaces the launcher only, with nothing stopped, and
# nothing acts on the deployment in the kit's place (Install-PersonalLauncher).
# Twin of personal_kit_launcher_behind (MAC-01).
function Get-PersonalKitLauncherBehind {
    param([string]$Path)
    if (-not $Path -or $Path -ne $script:PersonalBinPath) { return "" }
    $pin = Get-PersonalTargetVersion
    if (-not $pin) { return "" }
    if ((Get-Command Test-ExakitCoreRerunActive -ErrorAction SilentlyContinue) -and (Test-ExakitCoreRerunActive)) { return "" }
    if (-not (Test-ExakitComponentManaged "personal")) { return "" }
    $out = Invoke-ExakitBounded -FilePath $Path -Arguments @("version") -TimeoutSeconds $script:PersonalProbeTimeout
    if (-not $out) { return "" }
    $version = ($out -split "`n")[0].Trim() -replace '^v', ''
    if ($version -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { return "" }
    if (-not (Test-ExakitVersionNewer $pin $version)) { return "" }
    return $version
}

# Write-PersonalUpdateExplanation -Installed <v> -Advertised <v> - what the
# user is about to see happen, before it happens: the database goes down, comes
# back up, and keeps its data. The words of Write-ExakitRuntimeUpdateExplanation
# (exakit.ps1, which the installer does not load), for the installer run again
# and for the update of a user's own launcher. Twin of
# exakit_runtime_update_explain.
function Write-PersonalUpdateExplanation {
    param([string]$Installed = "", [string]$Advertised = "")
    Warn2 "personal $Installed -> $Advertised needs the database stopped."
    Info "The launcher is replaced; the database is checked afterwards and started again if it ends up down - usually under a minute."
    Info "Your data is kept: this update neither deletes nor migrates the tables in your database."
    # Said: the update that stops it does not say it again.
    $script:ExakitRuntimeUpdateSaid = $true
}

# Update-PersonalBehindLauncher <installed> - the kit's own launcher, behind
# the pin, over a deployment the kit records: the installer brings it to the
# pin the way `exakit update` does (Update-Personal: a 0.3.0 `default`
# renamed to starter-kit-local, the launcher swap, the folder the 2.5.0
# launcher moves, the 20-session limit, in one restart). A running database is
# stopped, updated and started again with no question, as `exakit update` does
# (Invoke-ExakitRuntimeUpdateOffer, which lives in exakit.ps1 and so is not
# loaded here: its steps and its words are the ones below). Only
# EXAKIT_CONFIRM_RUNTIME_UPDATE=0 keeps the launcher as it is. Twin of
# personal_update_behind_launcher.
function Update-PersonalBehindLauncher {
    param([string]$Installed)
    $advertised = Get-PersonalTargetVersion
    $majorOf = { param($v) $m = [regex]::Match("$v".TrimStart("v"), '^\d+'); if ($m.Success) { $m.Value } else { "" } }
    $haveMajor = & $majorOf $Installed
    $wantMajor = & $majorOf $advertised
    if ($haveMajor -and $wantMajor -and $haveMajor -ne $wantMajor) {
        Warn2 "personal $Installed -> $advertised is a major upgrade: it needs a backup and a data migration, so a routine update does not start it."
        return
    }
    # A deliberate no, whatever state the database is in: the update renames
    # and starts a stopped one too.
    if (("" + [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")) -cmatch '^(0|n|N|no|NO|No)$') {
        Warn2 "personal $Installed -> $advertised was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update --yes"
        return
    }
    $status = ""
    try { $status = "" + (Get-PersonalStatus) } catch { $status = "" }
    $wasRunning = (@("running", "starting") -contains $status)
    if ($wasRunning) { Write-PersonalUpdateExplanation -Installed $Installed -Advertised $advertised }
    Update-Personal -Advertised $advertised
    $script:ExakitRuntimeUpdateSaid = $false
    # NOT UPDATED is never reported as updated: Update-Personal said why and
    # put back what it had changed, and the next update tries again.
    if ($script:PersonalUpdateResult -eq "undone") { return }
    if (-not $wasRunning) { return }
    $status = ""
    try { $status = "" + (Get-PersonalStatus) } catch { $status = "" }
    # Started again by the update itself, once: never a second time here.
    if (-not $script:PersonalUpdateRestarted -and $status -and $status -ne "running" -and $status -ne "starting") {
        Info "Bringing the database back up"
        Start-Personal
        [void](Wait-PersonalReadyOrDeploy)
        try { $status = "" + (Get-PersonalStatus) } catch { $status = "" }
    }
    if ($status -eq "running") {
        Ok "Runtime updated and the database is running again."
    } elseif ($status -eq "starting") {
        Ok "Runtime updated; the database is still coming up - check it with: exakit status"
    } elseif (-not $status) {
        Ok "Runtime updated."
    } else {
        Warn2 "Runtime updated, but the database reports '$status' - start it with: exakit start"
    }
}

# Get-PersonalLauncherDownload -Version <v> -TmpDir <folder> - the pinned
# Exasol Personal release, downloaded into <folder> and checked: the S3
# executable against the checksum the kit pins, else the GitHub release
# archive against its checksums file. Answers the path of the checked
# exasol.exe (the last thing it puts on the pipeline). Ends with Fail when it
# cannot be had or does not match: nothing is installed by it.
# Install-PersonalLauncher installs it as the kit's (the same lines, in the
# same order, as when they were part of it); the update of a user's own
# launcher (Update-PersonalUser) puts it in the kit's folder. Twin of
# personal_launcher_download.
function Get-PersonalLauncherDownload {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$TmpDir)
    $script:ExakitActiveLabel = "Downloading Exasol launcher v$version"
    $source = Get-PersonalS3Source -Version $version
    $binaryPath = Join-Path $tmpDir "exasol.exe"
    $verifiedS3 = $false
    if ($env:EXAKIT_PERSONAL_S3 -eq "0") {
        Info "Exasol S3 skipped (EXAKIT_PERSONAL_S3=0); using the verified GitHub release"
    } elseif ($source) {
        Info "Downloading Exasol launcher v$version from Exasol S3"
        if (Get-ExakitFile -Url $source.Url -Dest $binaryPath -Soft) {
            $actual = $null
            try {
                $actual = Get-ExakitSha256 -Path $binaryPath
            } catch {
                Warn2 "Could not check the launcher from Exasol's server, so it was discarded; getting it from the verified GitHub release instead."
                Write-ExakitLog "WARN" "S3 launcher hashing failed: $_"
            }
            if ($actual -and $actual -eq $source.Sha256) {
                $verifiedS3 = $true
                Ok "S3 launcher SHA-256 verified"
            } elseif ($actual) {
                # A mismatch is not a missing file (SEC-03): nothing is
                # installed and the person decides. Twin of personal_install_launcher.
                Write-ExakitLog "ERROR" "S3 launcher SHA-256 expected $($source.Sha256), got $actual"
                Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue
                Info "That is either a changed file on the server or a wrong pin: report it (exakit logs setup has both checksums)."
                Info "To install from the GitHub release instead, checked against its own checksums file: `$env:EXAKIT_PERSONAL_S3 = '0' and re-run the installer."
                Fail "The Exasol launcher from Exasol's server does not match the checksum this kit pins for v$version, so it was not installed."
            }
        } else {
            Warn2 "Could not download the launcher from Exasol's server; getting the same version from the verified GitHub release instead."
        }
    } else {
        Info "Launcher v$version is not the version versions.json pins for Exasol's server; using the verified GitHub release"
    }

    if (-not $verifiedS3) {
        Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue
        $asset = "exasol-personal_Windows_x86_64.zip"
        $base = "https://github.com/$($script:PersonalRepo)/releases/download/v$version"
        Info "Downloading Exasol launcher v$version ($asset)"
        Get-ExakitFile -Url "$base/$asset" -Dest (Join-Path $tmpDir $asset)
        Get-ExakitFile -Url "$base/exasol-personal_${version}_checksums.txt" -Dest (Join-Path $tmpDir "checksums.txt")

        # The GitHub checksum is for the ZIP, never the S3 executable.
        $expected = $null
        foreach ($line in (Get-Content (Join-Path $tmpDir "checksums.txt"))) {
            if ($line -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($asset) + '\s*$')) {
                $expected = $Matches[1].ToLowerInvariant()
                break
            }
        }
        if (-not $expected) {
            Fail "The release's checksums file does not name $asset; refusing to install an unverified launcher."
        }
        Test-ExakitSha256 -Path (Join-Path $tmpDir $asset) -Expected $expected

        # Into a folder of its own: the search below must never be able to
        # pick a discarded S3 candidate that a scanner kept locked.
        $releaseDir = Join-Path $tmpDir "release"
        Expand-Archive -Path (Join-Path $tmpDir $asset) -DestinationPath $releaseDir -Force
        $extracted = Get-ChildItem -Path $releaseDir -Filter "exasol.exe" -Recurse | Select-Object -First 1
        if (-not $extracted) {
            Fail "The launcher archive did not contain exasol.exe - the download looks wrong. Re-run the installer."
        }
        $binaryPath = $extracted.FullName
    }
    return $binaryPath
}

# Install-PersonalKitCopy -Version <v> - the kit's own launcher in the kit's
# folder for a database that so far ran on the user's own launcher, already at
# <v> (nothing for Update-PersonalUser to update): `exakit update` puts it
# there, as the installer does, so the kit runs only its own from then on. The
# pinned release, checksum checked. Theirs is left as it is, recorded as
# components.personal.user_launcher, and the database keeps its owner. $true
# when it is in place, $false when there is nothing to do or it could not be
# done (said in the log; the kit then runs theirs as before). Twin of
# personal_kit_copy_ensure.
function Install-PersonalKitCopy {
    param([string]$Version = "")
    $kitBin = "" + (Get-PersonalSeparateBinPath)
    # A file there without the kit's receipt is not there yet (a run cut short
    # between the two): it is the kit's by its place, and is installed over.
    if (-not $Version -or -not $kitBin -or $script:PersonalSeparate -or (Test-PersonalKitBinPlaced)) { return $false }
    if (("" + (Get-ExakitManifestValue "runtime.type")) -ne "personal") { return $false }
    if (@("user", "kit") -notcontains ("" + (Get-ExakitManifestValue "runtime.ownership"))) { return $false }
    # ("unknown" is that receipt cut short while it was written.)
    if (@("user", "unknown") -notcontains ("" + (Get-ExakitManifestValue "components.personal.ownership"))) { return $false }
    $state = ""
    try { $state = "" + (Get-ExakitPersonalDbState) } catch { $state = "" }
    if ($state) { return $false }
    Update-PersonalDeployDir
    $dir = "" + $script:PersonalDeployDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    $bin = "" + (Get-PersonalCli)
    if (-not $bin -or -not (Test-Path -LiteralPath $bin -PathType Leaf)) { return $false }
    # Its id first, while its folder is where the record says: their
    # launcher's first command can move a stopped one (as in Update-PersonalUser).
    [void](Save-PersonalUpdateDeploymentId)
    $have = "" + (Get-PersonalLauncherVersion)
    if (-not $have -or -not (Test-ExakitVersionSame $have $Version)) { return $false }
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-personal-$([guid]::NewGuid().ToString('N'))"
    $prevQuiet = $script:ExakitQuietDetail
    $placed = $false
    $receipt = @{}
    foreach ($key in @("ownership", "ownership_path", "ownership_sha256", "user_launcher")) { $receipt[$key] = Get-ExakitManifestValue "components.personal.$key" }
    try {
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
        if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }
        $downloaded = "" + @(Get-PersonalLauncherDownload -Version $Version -TmpDir $tmpDir)[-1]
        if (-not $downloaded -or -not (Test-Path -LiteralPath $downloaded -PathType Leaf)) { throw "the download is not there" }
        Info "Installing launcher to $(Get-ExakitTilde $kitBin)"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $kitBin) | Out-Null
        # Theirs recorded first, then the file in one step, then the receipt:
        # cut short anywhere, the next update finishes it.
        Set-ExakitManifestValue "components.personal.user_launcher" $bin
        Move-Item -LiteralPath $downloaded -Destination "$kitBin.new" -Force -ErrorAction Stop
        Move-Item -LiteralPath "$kitBin.new" -Destination $kitBin -Force -ErrorAction Stop
        $placed = $true
        Set-ExakitComponentOwnership "personal" "kit" $kitBin
    } catch {
        Write-ExakitLog "WARN" "the kit's own launcher could not be put in $(Split-Path -Parent $kitBin): the kit still runs ${bin}: $($_.Exception.Message)"
        if ($placed) { Remove-Item -LiteralPath $kitBin -Force -ErrorAction SilentlyContinue }
        foreach ($key in @($receipt.Keys)) {
            if ($receipt[$key]) { try { Set-ExakitManifestValue "components.personal.$key" $receipt[$key] } catch { } }
        }
        if (-not $receipt["user_launcher"]) {
            try { if ($null -ne (Get-ExakitManifestValue "components.personal.user_launcher")) { Remove-ExakitManifestValue "components.personal.user_launcher" } } catch { }
        }
        Remove-Item -LiteralPath "$kitBin.new" -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        $script:ExakitQuietDetail = $prevQuiet
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
    Use-PersonalSeparateLauncher
    Reset-PersonalDeployFollow
    OkStep "Exasol launcher v$Version installed to $(Get-ExakitTilde $kitBin)"
    return $true
}

function Install-PersonalLauncher {
    # A NEW INSTALL FIRST DECIDES WHICH LAUNCHER (Get-PersonalLauncherPlan):
    # the kit's own 2.5 in its folder where there is none (K), next to the
    # user's 2.5 (U) or next to a 2.4 of theirs (S), or a stop here (A6) next
    # to a newer line of theirs, before anything is downloaded. An install the
    # kit already records has no mode.
    # Twin of the same gate in personal_install_launcher.
    $plan = Get-PersonalLauncherPlan
    if ($plan.Mode -eq "A6") { Stop-PersonalLauncherPlan $plan }
    # The kit's own launcher never lives on PATH (Krishna, 24 Nov): a new
    # install with no launcher of the user's (K) puts it in the kit's folder
    # too, and every kit command calls it by its full path.
    if ($plan.Mode -eq "K") { Set-PersonalModeS $false; Use-PersonalSeparateLauncher }
    # Their 2.5 (U): the kit runs its own pinned 2.5 from its folder too,
    # checksum checked, never theirs, which stays as it is and is recorded as
    # theirs (Krishna, 24 Nov).
    if ($plan.Mode -eq "U") {
        Set-PersonalModeS $false
        Use-PersonalSeparateLauncher
        try { Set-ExakitManifestValue "components.personal.user_launcher" ("" + $plan.Launcher) } catch { }
    }
    if ($plan.Mode -eq "S") {
        # The same line as macOS and Linux (mode P), without "in its own
        # folder": on Windows the kit's program shares their 2.5 root.
        $theirs = "An Exasol Personal launcher"
        if ($plan.Version) { $theirs = "Exasol Personal $($plan.Version)" }
        elseif (-not $plan.Launcher) { $theirs = "An Exasol Personal deployment" }
        Info "$theirs is on this computer. The starter kit uses its own Exasol Personal $(Get-PersonalTargetVersion), so yours is not changed."
        Set-PersonalModeS $true
        Use-PersonalSeparateLauncher
        # Theirs, recorded as theirs: the uninstall asks its version before it
        # decides whether the kit's own program stays for their deployments (D4).
        if ($plan.Launcher) { try { Set-ExakitManifestValue "components.personal.user_launcher" ("" + $plan.Launcher) } catch { } }
    }
    # THE LAUNCHER THE KIT RUNS (Get-PersonalCli), the one the newer-launcher
    # warning just named: the kit's own path first, else the one on PATH
    # (OWN-03, #41). Twin of personal_install_launcher, which says more.
    $existingPath = "" + (Get-PersonalCli)
    # Mode S: only the kit's own separate program counts, never theirs.
    if ($script:PersonalSeparate) { $existingPath = "" + $script:PersonalBinPath }
    if (-not $existingPath -or -not (Test-Path -LiteralPath $existingPath -PathType Leaf)) { $existingPath = "" }
    $kitFolder = "" + (Get-PersonalSeparateBinPath)
    if ($existingPath -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") { Save-PersonalLegacyReceipts }
    if ($existingPath -and $existingPath -eq $kitFolder) {
        # A FILE IN THE KIT'S FOLDER IS THE KIT'S BY ITS PLACE, never recorded
        # as the user's. With the kit's own receipt it is kept as it is. With
        # none (an install cut short, a lost record, a copy an undone update
        # left) it is the kit's launcher once its checksum is the pinned
        # release's, and is installed again otherwise.
        $receiptOk = (("" + (Get-ExakitManifestValue "components.personal.ownership")) -eq "kit") -and
            (("" + (Get-ExakitManifestValue "components.personal.ownership_path")) -eq $kitFolder) -and (Test-ExakitComponentManaged "personal")
        if (-not $receiptOk) {
            if ($env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1" -and (Test-PersonalKitFolderVerified)) {
                Set-ExakitComponentOwnership "personal" "kit" $existingPath
            } else { $existingPath = "" }
        }
    } elseif ($existingPath) { Set-ExakitReusedOwnership "personal" $existingPath }
    # A DATABASE THE USER LET THE 0.3.0 KIT USE, run by their own launcher
    # behind the pin: re-running the installer gives the kit its own launcher
    # and renames the database, as `exakit update` does (Update-PersonalUser).
    # Theirs is not touched.
    # Done, or kept as it is and said: the launcher step is over. Never in an
    # installer that `exakit update` started (that update decided it). Twin of
    # the same hook in personal_install_launcher.
    if ($existingPath -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1" -and
        (@("user", "kit") -contains ("" + (Get-ExakitManifestValue "runtime.ownership"))) -and
        -not (Test-ExakitComponentManaged "personal") -and
        -not ((Get-Command Test-ExakitCoreRerunActive -ErrorAction SilentlyContinue) -and (Test-ExakitCoreRerunActive))) {
        $null = Update-PersonalUser -Installed ("" + (Get-ExakitManifestValue "runtime.version")) -Advertised (Get-PersonalTargetVersion)
        if ($script:PersonalUpdateResult -ne "skipped") { return }
    }
    # THE KIT'S OWN LAUNCHER, BEHIND THE PIN (MAC-01): over a deployment the
    # kit records it is updated as `exakit update` does it, and with none it
    # is replaced like a first install. A user's launcher never gets here.
    # THE KIT'S OWN DATABASE MISSING (Get-ExakitPersonalDbState) is "none": a
    # hand-installed 2.5 moved a 0.3.0 kit's `default`, or another deployment
    # sits in the kit's folder. The launcher is replaced and nothing is
    # stopped or started: the deployment found is not the kit's, and the one
    # question of the deploy step needs a launcher that lists it.
    # Twin of the same block in personal_install_launcher.
    # THE KIT'S OWN LAUNCHER LEAVES .local\bin HERE TOO (Krishna, 24 Nov): one a
    # 0.3.0 kit put there, replaced with no database to update, is installed in
    # the kit's folder, and the old file goes after it when it is still the one
    # the kit recorded. Twin of personal_retire_bin_launcher.
    $moveFrom = ""
    $moveSha = ""
    $leavePath = {
        if (-not $kitFolder -or $existingPath -eq $kitFolder) { return }
        Set-Variable -Name moveFrom -Value $existingPath -Scope 1
        Set-Variable -Name moveSha -Value (Get-PersonalRetireSha) -Scope 1
        Use-PersonalSeparateLauncher
    }
    $behind = ""
    if ($existingPath -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") { $behind = "" + (Get-PersonalKitLauncherBehind $existingPath) }
    if ($behind) {
        Update-PersonalDeployDir
        $behindState = ""
        try { $behindState = "" + (Get-ExakitPersonalDbState) } catch { $behindState = "" }
        if (-not $behindState -and ("" + (Get-ExakitManifestValue "runtime.type")) -eq "personal" -and
            (Test-Path -LiteralPath $script:PersonalDeployDir -PathType Container)) {
            Update-PersonalBehindLauncher $behind
            return
        }
        & $leavePath
        Info "Replacing the kit's launcher at $(Get-ExakitTilde $script:PersonalBinPath) with v$(Get-PersonalTargetVersion)"
    } elseif ($env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1" -or -not (Test-ExakitComponentManaged "personal")) {
        # ONLY THE KIT'S OWN LAUNCHER IS KEPT. One of the user's (a 0.3.0 kit
        # that used theirs, current already) is never the one the kit runs: the
        # kit's own goes into its folder, and theirs stays as it is, recorded
        # as theirs. Only one on the pinned line: one behind it waits for its
        # update (Update-PersonalUser), and the kit's 2.5 would not drive what
        # a newer one made. Twin of the same rule in personal_install_launcher.
        if ($existingPath -and $kitFolder -and $existingPath -ne $kitFolder -and -not (Test-ExakitComponentManaged "personal") -and
            (Get-PersonalVersionLine ("" + (Get-PersonalLauncherVersion))) -and
            (Get-PersonalVersionLine ("" + (Get-PersonalLauncherVersion))) -eq (Get-PersonalVersionLine (Get-PersonalTargetVersion)) -and
            -not (Test-PersonalVersionOutranks ("" + (Get-PersonalDeployedVersion)) ("" + (Get-PersonalTargetVersion)))) {
            try { Set-ExakitManifestValue "components.personal.user_launcher" $existingPath } catch { }
            Use-PersonalSeparateLauncher
            $existingPath = ""
            if (Test-PersonalKitFolderVerified) {
                Set-ExakitComponentOwnership "personal" "kit" $kitFolder
                Reset-PersonalDeployFollow
                $existingPath = $kitFolder
            }
        }
        if ($existingPath) {
            if ($existingPath -ne $kitFolder) { Set-ExakitReusedOwnership "personal" $existingPath }
            $help = Invoke-ExakitBounded -FilePath $existingPath -Arguments @("install", "--help") -TimeoutSeconds $script:PersonalProbeTimeout
            if ($help -and ($help -match '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?local(\s|,|$)')) {
                if ($existingPath -ne $kitFolder) { Set-ExakitReusedOwnership "personal" $existingPath }
                Ok "Exasol launcher already installed: $existingPath"
                return
            }
            if (-not (Test-ExakitComponentManaged "personal")) {
                Fail "The user-owned Exasol launcher is incompatible. Update it outside the kit; it was not replaced."
            }
            Warn2 "The installed Exasol launcher ($existingPath) does not support the 'local' preset (too old)."
            # Say what happens to it (#41): the kit's own launcher at the same path is replaced; one anywhere
            # else is only shadowed, never touched.
            if ($existingPath -eq $script:PersonalBinPath) {
                & $leavePath
                Info "Replacing the kit's launcher at $(Get-ExakitTilde $script:PersonalBinPath) with v$(Get-PersonalTargetVersion)"
            } else {
                Info "Installing launcher v$(Get-PersonalTargetVersion) to $(Get-ExakitTilde $script:PersonalBinPath) - your launcher at $(Get-ExakitTilde $existingPath) is left untouched"
            }
        }
    }

    # What is installed goes into the kit's folder, whatever led here: the kit
    # never writes a launcher anywhere else (#41).
    if ($kitFolder -and -not $script:PersonalSeparate) { Use-PersonalSeparateLauncher }
    $version = Get-PersonalTargetVersion
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-personal-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    # ONE LINE FOR THIS STEP, as on every other platform. The step label is
    # already animated and re-labelled per phase, so the download line, the
    # checksum verdict and the unpack line underneath were the second telling -
    # and they were the visible difference between a Windows install and a
    # macOS one. Piped or redirected, the detail stays, exactly as the shell
    # side behaves. Twin of the bracket in personal_install_launcher.
    $prevQuiet = $script:ExakitQuietDetail
    if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }

    try {
        $binaryPath = "" + @(Get-PersonalLauncherDownload -Version $version -TmpDir $tmpDir)[-1]

        $script:ExakitActiveLabel = "Installing launcher to $(Get-ExakitTilde $script:PersonalBinPath)"
        Info "Installing launcher to $(Get-ExakitTilde $script:PersonalBinPath)"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:PersonalBinPath) | Out-Null
        # Stop, whatever the caller's preference: a launcher file Windows will
        # not replace (a program runs from it) must end the swap, never be
        # recorded as installed.
        # Under a name of its own first, then in place in one step: a run cut
        # short never leaves half a launcher there.
        $newBin = "$($script:PersonalBinPath).new"
        try {
            Move-Item -Force $binaryPath $newBin -ErrorAction Stop
            Move-Item -Force $newBin $script:PersonalBinPath -ErrorAction Stop
        } finally { Remove-Item -LiteralPath $newBin -Force -ErrorAction SilentlyContinue }
        if ($moveFrom) { Save-PersonalRetireNote -Path $moveFrom -Sha $moveSha }
        Set-ExakitComponentOwnership "personal" "kit" $script:PersonalBinPath
        if ($moveFrom -and (Remove-PersonalRetired -Path $moveFrom -Sha $moveSha)) { Clear-PersonalRetireNote }
        # The receipt names a file this run checked: no longer one written from
        # an older kit's record.
        if ($null -ne (Get-ExakitManifestValue "components.personal.ownership_legacy")) { Remove-ExakitManifestValue "components.personal.ownership_legacy" }
        # WHAT THE OLD LAUNCHER ANSWERED IS DROPPED. The list of deployments
        # is asked once per process (Get-PersonalLauncherDeployments), and a
        # reader before this step asked it before this launcher was here: no
        # launcher yet (a first install), or a 2.4.0 without the command. The
        # next reader asks the launcher just installed. Twin of the same drop
        # in personal_install_launcher.
        Reset-PersonalDeployFollow
        OkStep "Exasol launcher v$version installed to $(Get-ExakitTilde $script:PersonalBinPath)"
    } finally {
        # The flag is restored in the SAME finally that cleans the temp dir:
        # a leaked quiet flag silences every step after this one, and a Fail
        # inside the try is the path that would leak it.
        $script:ExakitQuietDetail = $prevQuiet
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

# Clear-PersonalStaleRecord - drop the old container's keys from runtime.*.
#
# An install that crossed from the Docker-era kit kept runtime.engine,
# container, image and volume from the nano record, so status read "personal
# (docker)" - and the record named a container that is not this deployment's -
# while the database ran in Podman. Those keys describe the OLD database, and
# legacy.* is where the kit keeps it: migrate and the restore read it from
# there (Get-LegacyRecordValue). Copied across first when legacy.* has none, so
# a record saved before Save-LegacyRecord existed loses nothing. Called when
# the runtime is recorded and on every resumed install, so an install already
# carrying the stale keys heals on its next run. Twin of
# personal_clear_stale_record.
#
# RUNTIME.ENGINE IS TWO KEYS IN ONE NAME. In a nano record it is the OLD
# container's engine and sits beside runtime.container; in a Personal record
# (kit 0.2.4+) it is THIS deployment's engine and stands alone. So it moves to
# legacy.* only when runtime.container says the record is a nano one. Dropping
# it unconditionally made every resumed install (setup-windows.ps1 calls this
# on its own) forget a Docker deployment's engine.
function Clear-PersonalStaleRecord {
    $nano = "" + (Get-ExakitManifestValue "runtime.container")
    foreach ($key in @("container", "engine", "volume")) {
        if ($key -eq "engine" -and -not $nano) { continue }
        $old = Get-ExakitManifestValue "runtime.$key"
        if ($null -eq $old -or "$old" -eq "") { continue }
        if (-not (Get-ExakitManifestValue "legacy.$key")) { Set-ExakitManifestValue "legacy.$key" $old }
    }
    $keys = @("runtime.container", "runtime.image", "runtime.volume")
    if ($nano) { $keys += "runtime.engine" }
    foreach ($key in $keys) {
        if ($null -ne (Get-ExakitManifestValue $key)) { Remove-ExakitManifestValue $key }
    }
}

# Set-PersonalManifest [status] [-Fresh] - the connection details this kit hands
# to every client, plus the runtime state and the database's TLS pin. The deployment directory has everything a
# client needs: deployment.json (host, dbPort, username) and secrets.json
# (dbPassword). The keys are the contract every add-on reads - identical to the
# sh side's personal_record_manifest.
function Set-PersonalManifest {
    # -Fresh: the kit has just deployed this database itself (see the TLS pin
    # at the end). Every other caller adopted, started or updated one.
    param([string]$Status = "", [switch]$Fresh)
    Update-PersonalDeployDir
    # Said by $script:PersonalRecordFresh on the line before, consumed here, so
    # the fresh deploy's record line reads like every other one.
    if ($script:PersonalRecordFresh) { $Fresh = $true; $script:PersonalRecordFresh = $false }
    Set-ExakitManifestValue "runtime.type" "personal"
    # Read before the clear below drops the key: what the deployment says
    # itself, then this run's own choice, then a record that already names its
    # engine, and one that never did is Podman (every deployment from before
    # kit 0.2.4).
    $engine = "" + (Get-PersonalEngineOwn)
    if ($engine -ne "docker" -and $engine -ne "podman") { $engine = $script:PersonalEngine }
    if (-not $engine) { $engine = Get-PersonalEngineRecorded }
    Clear-PersonalStaleRecord
    Set-ExakitManifestValue "runtime.engine" $engine
    # runtime.version is the COMPONENT the kit installs and compares against
    # versions.json, and that component is the LAUNCHER. The deployment's own
    # version - which decides whether a guest rebuild is still ahead - is
    # recorded beside it, never in its place. The advertised number is the last
    # resort, only when nothing on disk can answer.
    $deployed = Get-PersonalDeployedVersion
    $launcher = Get-PersonalLauncherVersion
    $recorded = $launcher
    if (-not $recorded) { $recorded = $deployed }
    if (-not $recorded) { $recorded = Get-PersonalTargetVersion }
    Set-ExakitManifestValue "runtime.version" $recorded
    if ($deployed) { Set-ExakitManifestValue "runtime.deployment_version" $deployed }
    Set-ExakitManifestValue "runtime.launcher" (Get-PersonalCli)
    # NOT OVER A DEPLOYMENT THAT IS NOT PROVABLY THE KIT'S. The id below is
    # what a moved folder must carry to be followed as the kit's, so it is
    # written only for a database the kit just deployed, for the folder the
    # kit's record names (where it is now), or when there is no record of the
    # kit's own at all. With the kit's own gone and the user's deployment in
    # the launcher's folder, neither the id nor the folder is rewritten.
    # Twin of _prm_mine in personal_record_manifest.
    $kitDir = ""
    if (Get-Command Get-ExakitPersonalKitDir -ErrorAction SilentlyContinue) { $kitDir = "" + (Get-ExakitPersonalKitDir) }
    $mine = $false
    if ($Fresh) { $mine = $true }
    elseif ($kitDir) { $mine = ((Resolve-PersonalDeployDir -Path $kitDir -Recorded).Dir -eq $script:PersonalDeployDir) }
    elseif (-not ("" + (Get-ExakitManifestValue "runtime.deployment_id"))) { $mine = $true }
    if ($mine -or -not $kitDir -or (Test-Path -LiteralPath $kitDir)) {
        Set-ExakitManifestValue "runtime.deployment_dir" $script:PersonalDeployDir
        # Its name beside it (starter-kit-local; a 0.3.0 kit's own says
        # `default` until `exakit update` renames it). runtime.launcher_home
        # is never written on Windows: the launcher always runs in the
        # user's own profile here (no private home, CONTRACT section 2).
        if ($script:PersonalDeployDir) { Set-ExakitManifestValue "runtime.deployment_name" (Split-Path -Leaf $script:PersonalDeployDir) }
    }
    # AND ITS ID. The uninstall checks that the deployment's container is gone
    # by this id, and it read it only from the folder: a folder already gone
    # left the container unchecked and "Database removed" unproven.
    # Twin of runtime.deployment_id in personal_record_manifest.
    $recordedId = "" + (Get-PersonalDeploymentId)
    # NOT ANOTHER DEPLOYMENT IN THE KIT'S FOLDER (MCU-02): one whose id is not
    # the one recorded is not the kit's, though it sits where the kit's was.
    # Its id is not taken, and it is recorded as the user's. Only a database
    # the kit just deployed itself takes a new id. Twin of _prm_rec_id.
    $knownId = "" + (Get-ExakitManifestValue "runtime.deployment_id")
    if ($mine -and -not $Fresh -and $recordedId -and $knownId -and $recordedId -cne $knownId) {
        $mine = $false
        try { Set-ExakitComponentOwnership "database" "user" $script:PersonalDeployDir } catch { }
    }
    if ($recordedId -and $mine) { Set-ExakitManifestValue "runtime.deployment_id" $recordedId }

    $dsn = "127.0.0.1:$(Get-PersonalDbPort)"
    $dbUser = "sys"
    $depFile = Join-Path $script:PersonalDeployDir "deployment.json"
    if (Test-Path $depFile) {
        try {
            $dep = [System.IO.File]::ReadAllText($depFile) | ConvertFrom-Json
            if ($dep.connection) {
                $depHost = $dep.connection.host
                if (-not $depHost) { $depHost = "127.0.0.1" }
                $depPort = $dep.connection.dbPort
                if (-not $depPort) { $depPort = Get-PersonalDbPort }
                $dsn = "${depHost}:${depPort}"
                if ($dep.connection.username) { $dbUser = $dep.connection.username }
            }
        } catch { }
    }
    Set-ExakitManifestValue "runtime.dsn" $dsn
    Set-ExakitManifestValue "runtime.user" $dbUser

    $password = ""
    $secFile = Join-Path $script:PersonalDeployDir "secrets.json"
    if (Test-Path $secFile) {
        try {
            $sec = [System.IO.File]::ReadAllText($secFile) | ConvertFrom-Json
            if ($sec.dbPassword) { $password = $sec.dbPassword }
        } catch { }
    }
    if ($password) {
        Set-ExakitCredential "personal_sys_password" $password
        Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "personal_sys_password")
    } else {
        Warn2 "Could not read the database password from the Exasol Personal secrets - the exapump profile and AI client configs will ask for it or need manual completion."
    }
    Set-ExakitManifestValue "runtime.tls" "self-signed"
    # Never assert health without either having just seen it or probing for it.
    if (-not $Status) { $Status = Get-PersonalStatus }
    Set-ExakitManifestValue "runtime.status" $Status
    # A database that has been seen healthy may hold data from now on.
    if ($Status -eq "healthy") {
        Set-PersonalFirstBootPending $false
        # And the rebuild that made it, if one did, is over.
        if ($null -ne (Get-ExakitManifestValue "runtime.rebuild_path")) { Remove-ExakitManifestValue "runtime.rebuild_path" }
    }
    # ITS TLS CERTIFICATE, PINNED (SEC-14). Trust on first use, taken while the
    # kit is looking at its own database: a deployment it has just made
    # replaces any earlier pin (a new deployment is a new certificate); one it
    # adopted, started or merely updated the launcher of records one only when
    # none is recorded yet. Clients that already exist hold the old value; a
    # first install writes them after this step. Never fatal. Twin of the end
    # of personal_record_manifest.
    if ($Status -eq "healthy" -or "$Status".StartsWith("running")) {
        if ($Fresh) {
            if (Register-ExakitTlsPin -Replace) { Update-ExakitTlsPinnedClients -ProfileOnly }
        } else {
            if (Register-ExakitTlsPin) { Update-ExakitTlsPinnedClients }
        }
    }
}

# Install-PersonalDeployment - run the local deployment, the long step. The
# ladder is the sh side's, step for step: which database comes first
# (Select-PersonalDatabase: the kit's own, a leftover starter-kit-local, the
# one question for a new install); a RUNNING one is then used, a stopped one
# is started and used, both with no question; only the explicit
# EXAKIT_REPLACE_DB consent ever reaches destroy, and only for the kit's own
# database - a failed start is not a licence to delete, a database of the
# user's is never offered for it, and the reap-and-retry that saves the common
# case lives on the sh side's macOS daemon, which Windows does not have. Twin
# of personal_deploy_local.
# Test-PersonalPodmanAnswers - the smallest question that needs all of podman
# to work. Invoke-ExakitBounded returns $null on a non-zero exit, so a null is
# the failure.
function Test-PersonalPodmanAnswers {
    param([Parameter(Mandatory)]$Podman)
    return ($null -ne (Invoke-ExakitBounded -FilePath $Podman.Source -TimeoutSeconds 30 `
        -Arguments @("info", "--format", "{{.Host.Arch}}")))
}

# Test-PersonalPodmanRunning - INSTALLED IS NOT RUNNING, and on Windows the gap
# between the two is a whole VM. Podman here is a Linux machine under WSL, and
# `podman.exe` on PATH says nothing about whether that machine is up: after a
# reboot it is not, and Podman Desktop being closed is enough. Every podman
# command then fails, so the launcher's deploy fails, minutes in, with an error
# that names neither podman nor the machine.
#
# A STOPPED MACHINE IS STARTED, not reported. Starting one is not reconfiguring
# it - the kit's promise about leaving an existing machine alone is about its
# settings and its containers, and a machine that is off is the one state in
# which it can do no work for anyone. Twin of personal_podman_running, which
# has no machine to start and so only asks.
function Test-PersonalPodmanRunning {
    $podman = Get-PersonalPodman
    # Not installed is a different failure, and the launcher's to fix.
    if (-not $podman) { return $true }
    if (Test-PersonalPodmanAnswers $podman) { return $true }

    $list = "" + (Invoke-ExakitBounded -FilePath $podman.Source -TimeoutSeconds 30 `
        -Arguments @("machine", "list", "--format", "{{.Name}} {{.Running}}"))
    if ($list -match "false") {
        Info "Podman's machine exists but is not running - starting it (this takes a minute)"
        $script:ExakitActiveLabel = "Starting Podman's machine"
        [void](Invoke-ExakitLogged $podman.Source "machine" "start")
        $script:ExakitActiveLabel = ""
        if (Test-PersonalPodmanAnswers $podman) {
            Ok "Podman's machine is running"
            return $true
        }
    }

    # THE WHOLE ERROR TO THE LOG, AND ITS LAST LINE TO THE SCREEN. The bounded
    # probe above keeps only the exit code, and "podman info failed" with
    # nothing else is not diagnosable. Twin of "What it said" in
    # personal_podman_running.
    $mark = Get-PersonalLogLineCount
    [void](Invoke-ExakitLogged $podman.Source "info")
    $said = @(Get-PersonalLogSince $mark) | Select-Object -Last 1
    Warn2 "Podman is installed, but it cannot run containers on this machine."
    if ($said) { Info "What it said: $(Get-PersonalShortText $said)" }
    Info "Check it with 'podman info' (and 'podman machine start' if its machine is off)."
    Info "Once that answers, re-run the installer to finish the install: $(Get-ExakitInstallCommand)"
    return $false
}

# Get-PersonalLogLineCount / Get-PersonalLogSince <line> - the log as a cursor.
# Invoke-ExakitLogged sends a command's whole output to the log and none of it
# to the screen, so showing or classifying what ONE command said means
# remembering where the log ended before it ran. The kit's own timestamped
# lines are left out: what is wanted is the tool's words.
function Get-PersonalLogLineCount {
    if ($script:LogFile -and (Test-Path $script:LogFile)) { return @(Get-Content -Path $script:LogFile).Count }
    return 0
}

function Get-PersonalLogSince {
    param([int]$Line = 0)
    if (-not $script:LogFile -or -not (Test-Path $script:LogFile)) { return @() }
    return @(Get-Content -Path $script:LogFile | Select-Object -Skip $Line |
        Where-Object { "$_".Trim() -and "$_" -notmatch '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ' })
}

# Get-PersonalShortText <text> - one line of foreign output, cut to a length a
# terminal row can carry. The pids error alone names a cgroup path 150
# characters deep.
function Get-PersonalShortText {
    param([AllowEmptyString()][string]$Text)
    $one = ("$Text" -split "`r?`n")[0].Trim()
    if ($one.Length -gt 240) { $one = $one.Substring(0, 237) + "..." }
    return $one
}

# Show-PersonalLauncherTail - the launcher's own last words after a failed
# deploy, in the dim gutter foreign output has always used here. The deploy's
# output goes to the log, so without this a failure was left with nothing but
# "Local deployment failed" and a log path. Twin of _personal_deploy_print_tail.
function Show-PersonalLauncherTail {
    $lines = @($script:PersonalLauncherOutput | Select-Object -Last 12)
    if ($lines.Count -eq 0) { return }
    $rule = $script:UiHr
    if (-not $rule) { $rule = "-" }
    Write-Host ("      {0}{1} last lines from the exasol launcher{2}" -f $script:UiDim, $rule, $script:UiReset)
    foreach ($line in $lines) {
        $shown = ConvertTo-PersonalKitWords ("$line".TrimEnd())
        if (-not $shown -and "$line".Trim()) { continue }
        if ($shown.Length -gt 300) { $shown = $shown.Substring(0, 297) + "..." }
        Write-Host ("      {0}{1} {2}{3}" -f $script:UiDim, $script:UiVB, $shown, $script:UiReset)
    }
}

# ConvertTo-PersonalKitWords <line> - one of the launcher's lines as a kit user
# reads it. The launcher speaks to its own users: "Run `start` to restart or
# `destroy` to delete resources" was shown verbatim in the kit's failure box,
# and for a kit user `destroy` deletes their database. Its `start` becomes the
# kit's `exakit start`, and a sentence that tells the reader to destroy is
# left out. Only the screen copy: the log keeps the launcher's own words.
# Twin of personal_launcher_words_for_kit.
function ConvertTo-PersonalKitWords([string]$Line) {
    $destroy = '`destroy`|''destroy''|exasol destroy'
    $t = $Line -creplace 'Run `start` to restart or `destroy` to delete resources', 'Run `exakit start` to restart'
    $t = $t -creplace ' or `destroy` to [^.]*', ''
    if ($t -cmatch $destroy) {
        $kept = @()
        foreach ($part in ($t -split '(?<=\.) ')) { if ($part -cnotmatch $destroy) { $kept += $part } }
        $t = $kept -join ' '
    }
    return ($t -creplace '`start`', '`exakit start`')
}

# ---------------------------------------------------------------------------
# WHAT WENT WRONG, SAID. A deploy or start that fails used to end in "Local
# deployment failed", or in 150 seconds of "never answered", with the real
# error - the one podman or docker recorded for the container - never shown.
# The helpers below read it (inspect --format {{.State.Error}}), name the cause
# when the kit recognises it, and change nothing: a fix is named, never
# applied - the kit does not switch or reconfigure a Podman machine on Windows.
# ---------------------------------------------------------------------------

$script:PersonalRegistryHost = "registry-1.docker.io"
$script:PersonalPidsIssue    = "podman-container-tools/podman#29909"

# Get-PersonalPodman - podman on PATH, or $null. The one question every helper
# below starts from, asked in one place.
function Get-PersonalPodman {
    return (Get-Command podman -ErrorAction SilentlyContinue)
}

# Get-PersonalEngineCommand - the command of the engine this deployment runs on
# (Get-PersonalEngineRecorded): docker for a Docker deployment, else podman;
# $null when it is not on PATH.
function Get-PersonalEngineCommand {
    if ((Get-PersonalEngineRecorded) -eq "docker") { return (Get-Command docker -ErrorAction SilentlyContinue) }
    return (Get-PersonalPodman)
}

# --- container engine ---------------------------------------------------------
# Exasol Personal 2.4 runs a local deployment on Docker or on Podman. The
# launcher keeps whatever engine a deployment first started on, and a
# deployment made by an earlier launcher keeps Podman - so the kit chooses only
# for a FRESH deployment, passes that choice explicitly, and records it as
# runtime.engine so every later health check reads one key.
#
# The kit's order is Docker when it is usable, else Podman. The launcher's own
# `auto` is the reverse (Podman first), which is why the flag is always passed
# rather than left to it. Usable means the daemon answers, runs Linux
# containers (Docker Desktop can be switched to Windows containers), and is
# Docker Engine 29 or newer - the launcher's floor. The kit never installs or
# starts Docker; the launcher installs Podman, as it always has, when neither
# engine is there. EXAKIT_CONTAINER_ENGINE=docker|podman names one outright.
# Twins of the personal_engine_* block in runtime-personal.sh.
$script:PersonalEngine = ""
$script:PersonalDockerSaid = ""
$script:PersonalDockerKind = ""
# The one line said when the launcher in use cannot be handed --container-engine.
$script:PersonalEngineUntold = "this Exasol launcher cannot be told which engine to use, so the database runs on Podman"

# Invoke-PersonalDockerInfo <docker> - run the bounded `docker info` probe and
# keep BOTH streams: @{ Out; Err }. Invoke-ExakitBounded returns $null on any
# failure, and the failure's words are what tell a stopped daemon from one that
# refuses this user.
function Invoke-PersonalDockerInfo {
    param([string]$Docker)
    $result = @{ Out = ""; Err = "" }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Docker
    $info.Arguments = 'info --format "{{.OSType}} {{.ServerVersion}}"'
    if ($Docker -match '\.(cmd|bat)$') {
        $comspec = $env:ComSpec
        if (-not $comspec) { $comspec = "cmd.exe" }
        $info.FileName = $comspec
        $info.Arguments = '/d /c ""' + $Docker + '" ' + $info.Arguments + '"'
    }
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        $outReader = $process.StandardOutput.ReadToEndAsync()
        $errReader = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            try { $process.Kill() } catch { }
            return $result
        }
        try { $result.Err = "" + $errReader.Result } catch { }
        if ($process.ExitCode -eq 0) { $result.Out = "" + $outReader.Result }
    } catch {
        $result.Err = "" + $_
    } finally {
        if ($process) { $process.Dispose() }
    }
    return $result
}

# Get-PersonalWindowsBuild - the Windows build number; 0 when it cannot say.
function Get-PersonalWindowsBuild {
    try { return [int][Environment]::OSVersion.Version.Build } catch { return 0 }
}

# Get-PersonalDnsRemedy - the fix for a machine that cannot resolve names, for
# THIS Windows: WSL's DNS tunneling exists from Windows 11 22H2 (build 22621);
# before it, the machine's user-mode networking is the road.
function Get-PersonalDnsRemedy {
    if ((Get-PersonalWindowsBuild) -ge 22621) {
        return "add 'dnsTunneling=true' under [wsl2] in %USERPROFILE%\.wslconfig, then run: wsl --shutdown; podman machine start"
    }
    return "switch Podman's machine to user-mode networking: podman machine stop; podman machine set --user-mode-networking; podman machine start"
}

# Get-PersonalKnownCause <text> - the cause and the fix for an error the kit
# recognises, in a container's State.Error or in the launcher's output; $null
# for anything else. Twin of personal_known_cause.
function Get-PersonalKnownCause {
    param([AllowEmptyString()][string]$Text)
    if ("$Text" -match "controller .pids. is not available") {
        return [pscustomobject]@{
            Kind   = "pids"
            Cause  = "Podman's machine gives the container no 'pids' cgroup controller, so the database cannot start ($($script:PersonalPidsIssue))"
            Remedy = "make the machine rootful, where the limit works: podman machine stop; podman machine set --rootful; podman machine start - then re-run the installer"
        }
    }
    if ("$Text" -match "Temporary failure in name resolution|lookup registry") {
        return [pscustomobject]@{
            Kind   = "dns"
            Cause  = "Podman's machine cannot resolve $($script:PersonalRegistryHost), so the database image cannot be downloaded"
            Remedy = (Get-PersonalDnsRemedy)
        }
    }
    return $null
}

# Get-PersonalContainers - this deployment's containers, as Name/State pairs.
# The launcher names them exasol-db-<id>.
function Get-PersonalContainers {
    $podman = Get-PersonalEngineCommand
    if (-not $podman) { return @() }
    $out = "" + (Invoke-ExakitBounded -FilePath $podman.Source -TimeoutSeconds 15 `
        -Arguments @("ps", "-a", "--filter", "name=exasol-db", "--format", "{{.Names}} {{.State}}"))
    $found = @()
    foreach ($line in @($out -split "`r?`n")) {
        $parts = @("$line".Trim() -split '\s+')
        if ($parts.Count -ge 2 -and $parts[0]) {
            $found += [pscustomobject]@{ Name = $parts[0]; State = $parts[1].ToLowerInvariant() }
        }
    }
    return $found
}

# Get-PersonalContainerError - the error podman recorded for a container that
# never ran ("created") or died ("exited"), first line only; "" otherwise. THE
# REAL ERROR, which the launcher never repeats: in the incident behind this, a
# container sat in "created" with "crun: controller 'pids' is not available"
# while the kit waited 150 seconds, three times, and then said "never
# answered". Nothing is reported while any of the containers runs: a stale
# one left by an earlier deployment is not this one's error. Twin of
# personal_container_error.
function Get-PersonalContainerError {
    $containers = @(Get-PersonalContainers)
    if (@($containers | Where-Object { $_.State -eq "running" }).Count -gt 0) { return "" }
    $podman = Get-PersonalEngineCommand
    foreach ($c in @($containers | Select-Object -First 3)) {
        if ($c.State -notmatch '^(created|exited|stopped)$') { continue }
        $err = "" + (Invoke-ExakitBounded -FilePath $podman.Source -TimeoutSeconds 15 `
            -Arguments @("inspect", "--format", "{{.State.Error}}", $c.Name))
        $first = @($err -split "`r?`n" | Where-Object { "$_".Trim() }) | Select-Object -First 1
        if ($first) { return "$first".Trim() }
    }
    return ""
}

# Test-PersonalDockerUsable - $true when the launcher could deploy on this
# Docker now; otherwise $false with the one-line reason in PersonalDockerSaid
# and its kind in PersonalDockerKind: missing, denied, down, type, version.
# Twin of personal_docker_usable.
#
# ASKED ONCE PER PROCESS. The compatibility gate, the engine choice, the
# adoption check and the deploy's own "is it running" all want this answer,
# and each `docker info` is bounded at 15 s: a Docker Desktop still starting
# held the gate silent for that long, twice. The verdict is kept in
# PersonalDockerCache and dropped only where Docker is expected to have
# changed: Wait-PersonalDocker's re-probes, and Clear-PersonalDockerCache.
$script:PersonalDockerCache = $null
function Test-PersonalDockerUsable {
    if ($null -ne $script:PersonalDockerCache) {
        $script:PersonalDockerSaid = $script:PersonalDockerCache.Said
        $script:PersonalDockerKind = $script:PersonalDockerCache.Kind
        return [bool]$script:PersonalDockerCache.Usable
    }
    $usable = [bool](Test-PersonalDockerUsableNow)
    $script:PersonalDockerCache = @{ Usable = $usable; Said = $script:PersonalDockerSaid; Kind = $script:PersonalDockerKind }
    return $usable
}

# Clear-PersonalDockerCache - forget the Docker verdict: the next
# Test-PersonalDockerUsable asks the daemon again.
function Clear-PersonalDockerCache {
    $script:PersonalDockerCache = $null
}

# Test-PersonalDockerUsableNow - the uncached question behind
# Test-PersonalDockerUsable.
function Test-PersonalDockerUsableNow {
    $script:PersonalDockerSaid = ""
    $script:PersonalDockerKind = ""
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { $script:PersonalDockerSaid = "Docker is not on PATH"; $script:PersonalDockerKind = "missing"; return $false }
    # One probe answers all three questions. STDERR IS KEPT: a user the daemon
    # refuses ("permission denied" on its pipe) must not be told to start it.
    $probe = Invoke-PersonalDockerInfo $docker.Source
    $line = ""
    if ($probe.Out) { $line = @(("" + $probe.Out) -split "`r?`n")[0].Trim() }
    $parts = @($line -split "\s+")
    if (-not $line -or $parts.Count -lt 2) {
        $said = ("" + $probe.Err + " " + $line).ToLowerInvariant()
        if ($said.Contains("permission denied") -or $said.Contains("access is denied")) {
            # THE FACT, NOT A REMEDY: joining the group after the deployment
            # exists does not move it. Resolve-PersonalEngine says the remedy
            # with its consequence, before the database is made.
            $script:PersonalDockerSaid = "Docker is running but your user cannot use it (access denied on its pipe)"
            $script:PersonalDockerKind = "denied"
        } else {
            $script:PersonalDockerSaid = "Docker is installed but not running ('docker info' did not answer)"
            $script:PersonalDockerKind = "down"
        }
        return $false
    }
    $script:PersonalDockerKind = "type"
    if ($parts[0] -ne "linux") {
        $script:PersonalDockerSaid = "Docker runs $($parts[0]) containers here, and Exasol Personal needs Linux containers (switch Docker Desktop to Linux containers)"
        return $false
    }
    $script:PersonalDockerKind = "version"
    $major = @($parts[1] -split "\.")[0]
    if ($major -notmatch '^\d+$') {
        $script:PersonalDockerSaid = "Docker Engine version '$($parts[1])' could not be read"
        return $false
    }
    if ([int]$major -lt 29) {
        $script:PersonalDockerSaid = "Docker Engine $($parts[1]) is older than 29, the oldest Exasol Personal 2.4 runs on"
        return $false
    }
    $script:PersonalDockerKind = ""
    return $true
}

# Test-PersonalLauncherTakesEngine - $true when the launcher that will deploy
# can be told the engine. One that is not there yet will be the kit's own
# download, which can; a kept older exasol.exe on PATH cannot, and run without
# the flag it deploys on Podman whatever the kit chose. Twin of
# personal_launcher_takes_engine.
#
# ONE `install --help` PER LAUNCHER: the gate, the engine choice and the
# deploy's flag all ask, and each answer costs a launcher start. The verdict is
# kept against the launcher's path, size and write time, so the launcher step
# replacing or downloading one is a new question and nothing else is.
$script:PersonalLauncherCache = $null
function Test-PersonalLauncherTakesEngine {
    $cli = Get-PersonalCli
    if (-not (Test-Path $cli)) { return $true }
    $key = "" + $cli
    try {
        $item = Get-Item -LiteralPath $cli -ErrorAction Stop
        $key = $key + "|" + $item.Length + "|" + $item.LastWriteTimeUtc.Ticks
    } catch { }
    if ($null -ne $script:PersonalLauncherCache -and $script:PersonalLauncherCache.Key -eq $key) {
        return [bool]$script:PersonalLauncherCache.Takes
    }
    $takes = $false
    $ports = $false
    # `install local --help`, NOT `install --help`: --container-engine is a
    # variable of the `local` preset and is listed only under that preset's
    # help. Twin of personal_launcher_takes_engine.
    $help = Invoke-ExakitBounded -FilePath $cli -Arguments @("install", "local", "--help") -TimeoutSeconds $script:PersonalProbeTimeout
    if ($help -and ($help -match '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?--container-engine(\s|,|$)')) { $takes = $true }
    # --ports, a variable of the same preset (launcher 2.5.0): the same help
    # answers it, so it costs no second launcher start.
    if ($help -and ($help -match '(?m)^\s*(-[-a-zA-Z0-9]+,\s*)?--ports(\s|,|=|$)')) { $ports = $true }
    $script:PersonalLauncherCache = @{ Key = $key; Takes = $takes; Ports = $ports }
    return $takes
}

# Test-PersonalLauncherTakesPorts - does this launcher's `install local` take
# --ports (2.5.0 does)? Read from the same kept `install local --help` as
# Test-PersonalLauncherTakesEngine. $false without a launcher, or when its
# help does not name the flag: an unknown flag is a hard failure, and such a
# launcher picks its own port as before. Twin of the help probe in
# personal_ports_flag.
function Test-PersonalLauncherTakesPorts {
    $cli = Get-PersonalCli
    if (-not $cli -or -not (Test-Path -LiteralPath $cli)) { return $false }
    [void](Test-PersonalLauncherTakesEngine)
    if ($null -eq $script:PersonalLauncherCache) { return $false }
    return [bool]$script:PersonalLauncherCache.Ports
}

# Test-PersonalPromptable - a person can answer a prompt here. Test-ExakitInteractive
# does not see -NonInteractive, under which Read-Host throws and ended the
# install at the database step; a console started that way has nobody to ask.
function Test-PersonalPromptable {
    if (-not (Test-ExakitInteractive)) { return $false }
    foreach ($arg in [Environment]::GetCommandLineArgs()) {
        if ("$arg" -match '^-noni') { return $false }
    }
    return $true
}

# Wait-PersonalDocker - after the user said Docker is starting: probe up to 3
# times over about 30 s. Docker Desktop answers tens of seconds after its
# window appears, and one early Enter used to mean Podman.
function Wait-PersonalDocker {
    $step = 10
    if ("$env:EXAKIT_DOCKER_WAIT_STEP" -match '^\d+$') { $step = [int]$env:EXAKIT_DOCKER_WAIT_STEP }
    for ($n = 1; $n -le 3; $n++) {
        # Afresh each time: the kept verdict is the "not running" this wait
        # exists to get past.
        Clear-PersonalDockerCache
        if (Test-PersonalDockerUsable) { return $true }
        if ($n -lt 3) {
            if ($n -eq 1) { Info "Docker did not answer yet - trying again for about 30 s." }
            Start-Sleep -Seconds $step
        }
    }
    $script:PersonalDockerSaid = "Docker still did not answer after about 30 s"
    return $false
}

# Get-PersonalPlannedEngine - the engine this run would reach, asking nobody
# and saying nothing: the compatibility gate's question. An existing
# deployment answers from Get-PersonalEngineExisting, a fresh one from
# Resolve-PersonalEngine -Probe. Twin of personal_engine_planned.
function Get-PersonalPlannedEngine {
    if (Test-PersonalDeploymentExists) { return (Get-PersonalEngineExisting -Quiet) }
    return ("" + (Resolve-PersonalEngine -Probe))
}

# Get-PersonalDeploymentId - the launcher's id for the deployment on disk, from
# whichever of its state files names it; "" when none does.
function Get-PersonalDeploymentId {
    param([string]$Dir = "")
    if (-not $Dir) { Update-PersonalDeployDir; $Dir = $script:PersonalDeployDir }
    return (Read-PersonalDeploymentId -Dir $Dir)
}

# Test-PersonalContainerRefused - has the database container failed for good?
# Asked from inside every wait, so a terminal error ends the wait at once
# instead of spending the rest of its budget; the error is kept for the
# failure reason and said once.
function Test-PersonalContainerRefused {
    $err = Get-PersonalContainerError
    if (-not $err) { return $false }
    $script:PersonalContainerError = $err
    Warn2 "The database container could not start: $(Get-PersonalShortText $err)"
    return $true
}

# Show-PersonalFailureCause - after a deploy or start that failed: the
# container's own error when it has one, and the cause and the fix when the kit
# recognises it there or in what the launcher said. Returns the cause as a
# suffix for the failure reason (": ..."), "" when nothing more is known.
function Show-PersonalFailureCause {
    $err = $script:PersonalContainerError
    $suffix = ""
    if (-not $err) {
        $err = Get-PersonalContainerError
        if ($err) { Warn2 "The database container could not start: $(Get-PersonalShortText $err)" }
    }
    if ($err) { $suffix = ": the database container could not start ($(Get-PersonalShortText $err))" }
    $known = Get-PersonalKnownCause ((@($err) + @($script:PersonalLauncherOutput)) -join "`n")
    if ($known) {
        Warn2 "$($known.Cause)."
        # InfoStep, not Info: this is printed from inside the deploy's quiet
        # bracket, and a fix nobody sees is no fix.
        InfoStep "Fix: $($known.Remedy)"
        if (-not $suffix) { $suffix = ": $($known.Cause)" }
    }
    return $suffix
}

# Test-PersonalFirstBootPending / Set-PersonalFirstBootPending - did the KIT
# create this deployment and never see its database answer? Recorded right
# before the kit's own `install local` and cleared the first time the database
# answers, so a deployment the kit did not make - or one that has EVER
# answered, and so may hold data - never reads as pending. The never-booted
# branch of Install-PersonalDeployment rests on it. Twin of
# personal_first_boot_pending.
function Test-PersonalFirstBootPending {
    return ("" + (Get-ExakitManifestValue "runtime.first_boot_pending")) -eq "true"
}

function Set-PersonalFirstBootPending {
    param([bool]$Pending)
    if (-not (Test-Path $script:ManifestPath)) { return }
    if ($Pending) {
        [void](Set-ExakitManifestValue "runtime.first_boot_pending" "true")
    } elseif ($null -ne (Get-ExakitManifestValue "runtime.first_boot_pending")) {
        [void](Remove-ExakitManifestValue "runtime.first_boot_pending")
    }
}

# Get-PersonalEngineExisting [-Quiet] - the engine an EXISTING deployment runs
# on. The record's word when it has one; a deployment the kit never recorded
# is asked of Docker: when Docker lists a container carrying the deployment's
# id it is Docker, otherwise Podman. Twin of personal_engine_existing.
#
# MADE BEFORE EXASOL PERSONAL 2.4, IT IS PODMAN, PERIOD: no launcher before
# 2.4 could deploy on Docker. The deployment's own version decides first (its
# state files, else the record's runtime.deployment_version), and a version
# that cannot be read with no engine in the launcher's state is Podman too -
# every deployment from before kit 0.2.4. Guessing Docker there recorded a
# Podman database as Docker for good, and let a replace skip the WSL check
# and destroy it.
#
# ONLY A 2.4+ DEPLOYMENT CAN BE DOCKER, AND ONLY ON EVIDENCE: an engine its
# state files name, or Docker listing its containers. A STOPPED DOCKER IS NOT
# AN ANSWER: Docker down (or refusing this user) cannot list anything. Then
# Podman is asked; if it does not list the deployment either, the engine is
# UNKNOWN: "" is returned, and the deploy step stops before any start,
# replace or record (Stop-PersonalEngineUnknown).
#
# THE DEPLOYMENT'S OWN RECORD FIRST, over the kit's (Get-PersonalEngineOwn): the
# launcher wrote it when it first prepared the deployment, and keeps to it. The
# kit's record can be another database's (the one before a picked one), or an
# older kit's guess. A record that cannot be read is "", as the launcher itself
# refuses it.
#
# A REBUILD NEVER GUESSES (exakit repair-runtime): where every other run takes
# Podman with nothing to say so, the rebuild of a database of the user's
# answers "" and nothing is destroyed. The kit's own record is the kit's word
# for a database the kit made, not for one it picked.
function Get-PersonalEngineExisting {
    param([switch]$Quiet)
    $own = "" + (Get-PersonalEngineOwn)
    if ($own -eq "unread") { return "" }
    if ($own) { return $own }
    # With nothing that names it: Podman, or "" in the rebuild of a database
    # of the user's.
    $none = "podman"
    $engine = ""
    if (Test-PersonalRebuildsUserDatabase) { $none = "" }
    else { $engine = "" + (Get-ExakitManifestValue "runtime.engine") }
    if (Get-ExakitManifestValue "runtime.container") { $engine = "" }
    if ($engine -eq "docker" -or $engine -eq "podman") { return $engine }
    $version = "" + (Get-PersonalDeployedVersion)
    if (-not $version) {
        $version = "" + (Get-ExakitManifestValue "runtime.deployment_version")
        if ($version -notmatch '^[0-9]') { $version = "" }
    }
    if ($version -and -not (Test-PersonalUpdateCrossesTo24 $version)) { return "podman" }
    $engine = Get-PersonalDeploymentEngine
    if ($engine) { return $engine }
    if (-not $version) { return $none }
    $id = Get-PersonalDeploymentId
    if (-not $id) { return $none }
    # The rebuild of a database of the user's asks Podman too: not listed by
    # Docker alone does not make it Podman.
    if (-not $none) {
        $podman = Get-Command podman -ErrorAction SilentlyContinue
        if ($podman -and (Test-PersonalNamesCarryId (Invoke-ExakitBounded -FilePath $podman.Source -TimeoutSeconds 15 -Arguments @("ps", "-a", "--format", "{{.Names}}")) $id)) { return "podman" }
    }
    if (Test-PersonalDockerUsable) {
        $docker = Get-Command docker -ErrorAction SilentlyContinue
        $names = Invoke-ExakitBounded -FilePath $docker.Source -TimeoutSeconds 15 -Arguments @("ps", "-a", "--format", "{{.Names}}")
        if (Test-PersonalNamesCarryId $names $id) {
            if (-not $Quiet) { Info "Adopting the existing deployment: Docker lists its containers, so it is recorded as running on Docker." }
            return "docker"
        }
        return $none
    }
    if ($script:PersonalDockerKind -eq "down" -or $script:PersonalDockerKind -eq "denied") {
        $podman = Get-Command podman -ErrorAction SilentlyContinue
        if ($podman) {
            $names = Invoke-ExakitBounded -FilePath $podman.Source -TimeoutSeconds 15 -Arguments @("ps", "-a", "--format", "{{.Names}}")
            if (Test-PersonalNamesCarryId $names $id) { return "podman" }
        }
        return ""
    }
    return $none
}

# Stop-PersonalEngineUnknown - the end of the database step for an existing
# 2.4+ deployment whose engine nothing could name (Get-PersonalEngineExisting
# returned ""). Nothing is started, replaced or recorded: a guess here either
# records the wrong engine for good or destroys a database the rebuild cannot
# follow. Twin of _personal_engine_unknown_stop.
function Stop-PersonalEngineUnknown {
    Warn2 "The existing deployment's engine cannot be read: it was made by Exasol Personal 2.4 or newer, its state does not name the engine, $($script:PersonalDockerSaid), and Podman does not list it."
    Info "Start Docker Desktop (if the deployment is on Docker) or the Podman machine ('podman machine start'), then re-run: $(Get-ExakitInstallCommand)"
    Info "Nothing was changed."
    Set-ExakitFailureReason "The existing deployment's engine could not be read (Docker did not answer and Podman does not list it)"
}

# Get-PersonalEngineOwn - the engine the deployment itself says, by the
# launcher's own rule (2.4 and later): local\runtime\container-engine.json,
# written when it was first prepared; database data (local\runtime\exa) without
# one was made before engines were recorded, on Podman. "unread" for a record
# that names neither engine (the launcher refuses it too); "" when neither is
# there. Twin of _personal_engine_own.
function Get-PersonalEngineOwn {
    Update-PersonalDeployDir
    if (-not $script:PersonalDeployDir) { return "" }
    $runtime = [IO.Path]::Combine("" + $script:PersonalDeployDir, "local", "runtime")
    $file = Join-Path $runtime "container-engine.json"
    if (Test-Path -LiteralPath $file) {
        $text = "" + (Get-Content -Raw -LiteralPath $file -ErrorAction SilentlyContinue)
        if ($text -cmatch '"engine"\s*:\s*"(docker|podman)"') { return $Matches[1] }
        return "unread"
    }
    if (Test-Path -LiteralPath (Join-Path $runtime "exa") -PathType Container) { return "podman" }
    return ""
}

# Save-PersonalEngineOwn - runtime.engine becomes what the deployment in use
# says itself (Get-PersonalEngineOwn): the record of the database before it, or
# an older kit's guess, is not its engine. Nothing when it does not say. Twin
# of personal_record_engine_own.
function Save-PersonalEngineOwn {
    $own = "" + (Get-PersonalEngineOwn)
    if ($own -ne "docker" -and $own -ne "podman") { return }
    try { Set-ExakitManifestValue "runtime.engine" $own } catch { Write-ExakitLog "WARN" "engine of the database: $_" }
}

# Get-PersonalDeploymentEngine - "docker" or "podman" when the launcher's state
# files name the deployment's engine; "" when none does.
function Get-PersonalDeploymentEngine {
    Update-PersonalDeployDir
    foreach ($name in @("deployment.json", ".exasolLauncherState.json")) {
        $file = Join-Path $script:PersonalDeployDir $name
        if (-not (Test-Path $file)) { continue }
        $text = "" + (Get-Content -Raw -Path $file -ErrorAction SilentlyContinue)
        if ($text -match '"(containerEngine|container_engine|engine)"\s*:\s*"(docker|podman)"') { return $Matches[2] }
    }
    return ""
}

# Test-PersonalNamesCarryId <names> <id> - a container name IS the
# deployment's id, or carries it as a whole leading or trailing segment
# (<id>-db-1, exasol_<id>). NOT A SUBSTRING: an id "exa" matched "exasol-nano".
# Twin of _personal_names_carry_id.
function Test-PersonalNamesCarryId {
    param($Names, [string]$Id)
    if (-not $Id -or -not $Names) { return $false }
    foreach ($line in @(("" + ($Names -join "`n")) -split "`r?`n")) {
        $n = $line.Trim()
        if (-not $n) { continue }
        if ($n -eq $Id) { return $true }
        if ($n.StartsWith("$Id-") -or $n.StartsWith("$Id" + "_")) { return $true }
        if ($n.EndsWith("-$Id") -or $n.EndsWith("_" + $Id)) { return $true }
    }
    return $false
}

# Resolve-PersonalEngine [-Probe] - the engine for a FRESH deployment, "docker"
# or "podman", also kept in PersonalEngine. "" only when EXAKIT_CONTAINER_ENGINE
# names docker and docker is not usable: a named engine is never silently
# swapped for the other one. -Probe answers without a question or a line - what
# the install would reach if nobody intervened - for the compatibility gate.
#
# DOCKER ONLY WHEN THE LAUNCHER CAN BE TOLD (Test-PersonalLauncherTakesEngine):
# an older exasol.exe kept on PATH deploys on Podman whatever the kit decides,
# so it means Podman, said in one line - and a named Docker stops the step.
#
# Docker that is installed and not running is the one case worth a second
# look, and only where someone can act on it: a console is asked to start
# Docker and, after Enter, the probe runs up to 3 times over about 30 s.
# Without one (an agent, a piped install, CI, -NonInteractive) there is nobody
# to start it, so Podman it is - said, not silently.
function Resolve-PersonalEngine {
    param([switch]$Probe)
    $script:PersonalEngine = ""
    $named = "" + $env:EXAKIT_CONTAINER_ENGINE
    if ($named -eq "podman") { $script:PersonalEngine = "podman"; return "podman" }
    if ($named -eq "docker") {
        if ($Probe) { $script:PersonalEngine = "docker"; return "docker" }
        if (-not (Test-PersonalDockerUsable)) {
            Warn2 "EXAKIT_CONTAINER_ENGINE=docker, but $($script:PersonalDockerSaid)."
            Info "Fix Docker and re-run the installer, or drop EXAKIT_CONTAINER_ENGINE to let the kit use Podman: $(Get-ExakitInstallCommand)"
            Set-ExakitFailureReason "EXAKIT_CONTAINER_ENGINE=docker but $($script:PersonalDockerSaid)"
            return ""
        }
        # A LAUNCHER THAT CANNOT BE TOLD deploys on Podman whatever the kit
        # says, so a named Docker it cannot honour stops the step.
        if (-not (Test-PersonalLauncherTakesEngine)) {
            Warn2 "EXAKIT_CONTAINER_ENGINE=docker, but $($script:PersonalEngineUntold)."
            Info "Update the launcher ('exakit update personal'), or drop EXAKIT_CONTAINER_ENGINE: $(Get-ExakitInstallCommand)"
            Set-ExakitFailureReason "EXAKIT_CONTAINER_ENGINE=docker but $($script:PersonalEngineUntold)"
            return ""
        }
        $script:PersonalEngine = "docker"
        return "docker"
    }
    if ($named) { Fail "EXAKIT_CONTAINER_ENGINE must be docker or podman, not '$named'." }
    $usable = Test-PersonalDockerUsable
    if (-not $usable -and -not $Probe -and $script:PersonalDockerKind -eq "denied") {
        # SAID BEFORE THE DATABASE EXISTS, WITH ITS CONSEQUENCE: an existing
        # deployment keeps its engine, so joining the group afterwards and
        # re-running leaves it on Podman. Twin of personal_resolve_engine.
        Info "$($script:PersonalDockerSaid), so this install continues on Podman."
        Info "Joining the docker-users group and re-running will not move this deployment to Docker. To use Docker: stop now, add your user to the docker-users group (sign out and back in) and re-run - or later, 'exakit uninstall' and reinstall with EXAKIT_CONTAINER_ENGINE=docker."
        $saidDenied = $true
    } else {
        $saidDenied = $false
    }
    if (-not $usable -and -not $Probe -and $script:PersonalDockerKind -eq "down" -and (Test-PersonalPromptable)) {
        # NEVER THROWS. A host that cannot prompt after all (Read-Host under
        # -NonInteractive, a console that went away) takes the no-terminal path.
        $answer = $null
        try {
            Info "Docker is installed but not running. Start Docker Desktop to deploy on it."
            $answer = "" + (Read-ExakitPrompt "Press Enter once Docker is running, or type p to use Podman instead" "")
        } catch {
            $answer = $null
        }
        if ($null -ne $answer) {
            # Chosen, so nothing more to say about Docker.
            if ($answer -match '^(p|P|podman)$') { $script:PersonalDockerKind = "chosen" }
            else { $usable = Wait-PersonalDocker }
        }
    }
    if ($usable) {
        if (Test-PersonalLauncherTakesEngine) { $script:PersonalEngine = "docker"; return "docker" }
        if (-not $Probe) { Info "Docker is usable, but $($script:PersonalEngineUntold)." }
    } elseif (-not $Probe -and -not $saidDenied -and $script:PersonalDockerKind -ne "missing" -and $script:PersonalDockerKind -ne "chosen") {
        Info "$($script:PersonalDockerSaid) - the database will run on Podman."
    }
    $script:PersonalEngine = "podman"
    return "podman"
}

# Get-PersonalEngineRecorded - the engine the deployment runs on: what it says
# itself (Get-PersonalEngineOwn), else the kit's record; "podman" when neither
# has one, which is every deployment made before kit 0.2.4. A record still
# carrying the nano kit's container names the OLD database's engine, not this
# deployment's, and is ignored.
function Get-PersonalEngineRecorded {
    $own = "" + (Get-PersonalEngineOwn)
    if ($own -eq "docker" -or $own -eq "podman") { return $own }
    $engine = "" + (Get-ExakitManifestValue "runtime.engine")
    if (Get-ExakitManifestValue "runtime.container") { $engine = "" }
    if ($engine -eq "docker" -or $engine -eq "podman") { return $engine }
    return "podman"
}

# Get-PersonalEngineFlag <engine> - @("--container-engine", <engine>) when this
# launcher's `install` takes it, an empty array otherwise. Same shape, and the
# same reason, as Get-PersonalAutoApproveFlag: a 2.3 launcher handed an unknown
# flag fails outright, and 2.3 deployments are still supported.
function Get-PersonalEngineFlag {
    param([string]$Engine)
    if (-not $Engine) { return @() }
    # The launcher's answer is Test-PersonalLauncherTakesEngine's, kept per
    # launcher; one that is not there yet takes no flag.
    if (-not (Test-Path (Get-PersonalCli))) { return @() }
    if (Test-PersonalLauncherTakesEngine) { return @("--container-engine", $Engine) }
    return @()
}

# Test-PersonalEngineRunning <engine> - the engine can run a container right
# now. Podman's answer is Test-PersonalPodmanRunning, unchanged; Docker's is the
# probe above, with the failure said the same way.
function Test-PersonalEngineRunning {
    param([string]$Engine)
    if ($Engine -eq "docker") {
        if (Test-PersonalDockerUsable) { return $true }
        Warn2 "The deployment runs on Docker, and $($script:PersonalDockerSaid)."
        Info "Start Docker, then re-run: $(Get-ExakitInstallCommand)"
        Set-ExakitFailureReason "Docker is not usable: $($script:PersonalDockerSaid)"
        return $false
    }
    return (Test-PersonalPodmanRunning)
}

# The WSL verdict Test-PersonalRequirements reached for a fresh Podman
# deployment, for Install-PersonalDeployment to use: $null when it did not ask.
$script:PersonalWslVerdict = $null
$script:PersonalWslUnread = $false
$script:PersonalWslRefusal = ""

# Get-PersonalWslRelease - the WSL release ("2.6.1.0") from `wsl --version`.
# $null whenever no release could be READ: wsl.exe not on this machine, one
# that fails to run, exits non-zero or times out, and one that answers without
# a dotted release - the inbox WSL that predates the Store release has no
# --version and prints its usage text. The caller must read $null as
# "unknown", never as a version: a probe that failed is not evidence of an old
# WSL. Twin of detect_wsl_release.
#
# -ArgumentString, NOT -Arguments: -Arguments quotes every element, wsl.exe
# matches its options against the raw token quotes included, and a quoted
# "--version" ran as a Linux command named "--version" - so the release read
# failed on every machine. wsl.exe writes UTF-16 even through a pipe, so the
# NULs are dropped first; the label is localized and, read as 8-bit text,
# leaves stray digits behind (Katakana is 0x30xx), so the release is taken only
# as a number with at least two dots.
function Get-PersonalWslRelease {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) { return $null }
    $said = Invoke-ExakitBounded -FilePath $wsl.Source -ArgumentString "--version" -TimeoutSeconds 20
    if ($null -eq $said) { return $null }
    $line = @(((("" + $said) -replace "`0", "") -replace ("^" + [string][char]0xFEFF), "") -split "`r?`n")[0]
    if ($line -match '(\d+\.\d+\.\d+(?:\.\d+)*)') { return $Matches[1] }
    return $null
}

# Test-PersonalWslPodmanNetworkOk [re-run command] - Podman's machine on this
# WSL can build the network a 2.4 deployment needs.
#
# Exasol Personal 2.4 puts every local deployment on its own bridge network,
# and Podman builds it through netavark with the nftables firewall driver. The
# kernel WSL 2.6 and older ship has no nftables - and Podman's machine on
# Windows runs on that kernel - so the deploy, or for a deployment made by 2.3
# the first start after the launcher update, fails with:
#   Error: netavark: nftables error: "nft" did not return successfully while applying ruleset
# Found here, before anything is downloaded or swapped, with the fix named.
# Only a release READ below 2.7 refuses: a wsl.exe that is missing, fails,
# times out or answers no release is warned about and let through - a guess
# must never be the thing that blocks a working install. Docker is not
# affected and never asks. Twin of personal_wsl_podman_network_ok.
#
# A MACHINE ON IPTABLES PASSES. The error is netavark's nftables driver, and
# a Podman machine whose containers.conf sets firewall_driver = "iptables"
# never uses it - measured on a Windows machine on WSL 2.5.10, where the 2.4
# deployment network came up on iptables. On Windows that setting lives inside
# Podman's machine, so it is read through `podman machine ssh`
# (Test-PersonalPodmanMachineIptables), and only once the release has already
# said no: a WSL on 2.7 or newer never pays for the ssh. An ssh that fails
# answers "not iptables" and the release decides as before. A STOPPED machine
# is started first on the deploy path (-StartMachine), where the deploy would
# start it moments later anyway; elsewhere the refusal says to start it
# (podman machine start) so the kit can read the setting. The answer is kept
# for the process. The shell twin reads the same setting, by the same rule,
# from the distro's own files.
#
# -Replace IS THE DESTRUCTIVE PATH, AND THERE UNKNOWN REFUSES: replacing a
# deployment destroys it before its fresh deploy runs, which on a WSL that is
# in fact 2.6 fails after the data is gone. EXAKIT_WSL_CHECKED=1 says the
# user read 'wsl --version' themselves. -Quiet reaches the same verdict and
# says nothing, for a caller that only needs to know (the compatibility gate,
# before the engine is final). The release read is kept in
# $script:PersonalWslReleaseSeen for that caller.
$script:PersonalWslReleaseSeen = $null
# Write-PersonalWslUnreadWarning - the one line for a release that could not be
# read on the install path: said by the check itself, or by the deploy step
# when the compatibility gate reached that verdict quietly.
function Write-PersonalWslUnreadWarning {
    Warn2 "Could not read the WSL release (wsl.exe is missing, did not run, or answered no version), so it is unknown. Exasol Personal 2.4 on Podman needs WSL 2.7 or newer - check with 'wsl --version'."
}
# Test-PersonalFirewallDriverIptables <containers.conf text> - true when the
# text sets firewall_driver to iptables, read the way Podman reads it:
#   - only a firewall_driver key inside the [network] table counts: the same
#     key under another table is not the network's driver;
#   - comments are ignored, double or single quotes are accepted; a value
#     that is not a quoted string is not one Podman reads, so it still counts
#     as the last setting and never as "iptables";
#   - the LAST setting wins, because the caller hands the files in Podman's
#     order (system, its drop-ins, the user's, the user's drop-ins) and a
#     later file overrides an earlier one.
# The text is several files run together: a line "#@file" (what the
# machine-side command prints before each file) starts the next one, so the
# table one file ended in does not carry over into the next. Pure, so it is
# tested on its own. Same rule as detect_podman_iptables_driver.
function Test-PersonalFirewallDriverIptables {
    param([string]$Text)
    # Case-sensitive throughout (-c operators), as TOML and Podman are.
    $driver = ""
    $section = ""
    foreach ($line in (("" + $Text) -split "`r?`n")) {
        if ($line.Trim() -eq "#@file") { $section = ""; continue }
        $bare = ($line -replace '#.*$', '').Trim()
        if (-not $bare) { continue }
        if ($bare.StartsWith("[")) {
            $section = "other"
            if (($bare -replace '\s', '') -ceq "[network]") { $section = "network" }
            continue
        }
        if ($section -ne "network") { continue }
        if (-not ($bare -cmatch '^firewall_driver\s*=\s*(.*)$')) { continue }
        $value = $Matches[1]
        if ($value -match '^"([^"]*)"$') { $driver = $Matches[1] }
        elseif ($value -match "^'([^']*)'$") { $driver = $Matches[1] }
        else { $driver = "unquoted:$value" }
    }
    return ($driver -ceq "iptables")
}

# The one command run inside the machine: every containers.conf Podman reads,
# in its order, each behind a "#@file" line (see above). Missing files are
# skipped and the command always exits 0, so only a machine that could not be
# asked answers $null: `cat` of two named files exited 1 when either was
# missing, and that refused a machine whose only setting was in /etc. No
# double quote, %, & or redirect: it travels as ONE quoted argument, through
# cmd.exe when podman is a .cmd shim. $HOME is root's on a rootful machine
# (podman machine ssh logs in as root there), which is whose files its
# netavark reads.
$script:PersonalPodmanConfCommand = 'for f in /usr/share/containers/containers.conf /etc/containers/containers.conf /etc/containers/containers.conf.d/*.conf ${XDG_CONFIG_HOME:-$HOME/.config}/containers/containers.conf ${XDG_CONFIG_HOME:-$HOME/.config}/containers/containers.conf.d/*.conf; do if [ -f $f ]; then echo ''#@file''; cat $f; echo; fi; done; true'

# The machine's verdict, kept for the process. ONLY A DEFINITE ANSWER IS KEPT -
# the machine ran the command - so a machine that could not be asked (stopped,
# ssh failed or timed out) is asked again, by which time the deploy may have
# started it. The compatibility gate and the deploy step both ask, and each
# ssh can take up to 30 seconds.
$script:PersonalPodmanIptablesCache = $null
# $true when the last ask found the machine stopped: its setting was then
# never read, and the refusal says how to let the kit read it.
$script:PersonalPodmanMachineStopped = $false

function Read-PersonalPodmanMachineConf {
    param([Parameter(Mandatory)]$Podman)
    return (Invoke-ExakitBounded -FilePath $Podman.Source -TimeoutSeconds 30 -Arguments @("machine", "ssh",
        $script:PersonalPodmanConfCommand))
}

function Test-PersonalPodmanMachineStopped {
    param([Parameter(Mandatory)]$Podman)
    $list = "" + (Invoke-ExakitBounded -FilePath $Podman.Source -TimeoutSeconds 30 `
        -Arguments @("machine", "list", "--format", "{{.Name}} {{.Running}}"))
    return ($list -match "false")
}

# Test-PersonalPodmanMachineIptables [-StartMachine] - true when Podman's
# machine on Windows routes its firewall through iptables, so a WSL kernel
# without nftables does not stop the 2.4 deployment network. Read through
# `podman machine ssh`, which needs no root for these files; bounded, so a
# machine that hangs cannot stall the check. Anything but a clear "iptables"
# (no podman, machine stopped, ssh failed, timed out) is false: the WSL release
# then decides, as it did before.
#
# -StartMachine: the deploy step, which starts a stopped machine moments later
# anyway (Test-PersonalPodmanRunning). A machine is stopped after every reboot,
# and asking it stopped told the very user this pass exists for - on iptables,
# unable to update WSL - to run wsl --update. So there a stopped machine is
# started first, then asked. The compatibility gate and preflight never start
# it: they only report.
function Test-PersonalPodmanMachineIptables {
    param([switch]$StartMachine)
    if ($null -ne $script:PersonalPodmanIptablesCache) { return $script:PersonalPodmanIptablesCache }
    $script:PersonalPodmanMachineStopped = $false
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    if (-not $podman) { return $false }
    $said = Read-PersonalPodmanMachineConf $podman
    if ($null -eq $said) {
        $stopped = Test-PersonalPodmanMachineStopped $podman
        if ($stopped -and $StartMachine) {
            Info "Podman's machine is not running - starting it to read its firewall driver (this takes a minute)"
            [void](Invoke-ExakitBounded -FilePath $podman.Source -TimeoutSeconds 300 -Arguments @("machine", "start"))
            $said = Read-PersonalPodmanMachineConf $podman
            if ($null -eq $said) { $stopped = Test-PersonalPodmanMachineStopped $podman }
        }
        if ($null -eq $said) {
            $script:PersonalPodmanMachineStopped = [bool]$stopped
            return $false
        }
    }
    $script:PersonalPodmanIptablesCache = [bool](Test-PersonalFirewallDriverIptables ("" + $said))
    return $script:PersonalPodmanIptablesCache
}

# Write-PersonalPodmanMachineStoppedNote - the line a refusal adds when the
# machine could not be asked because it is stopped.
function Write-PersonalPodmanMachineStoppedNote {
    if (-not $script:PersonalPodmanMachineStopped) { return }
    Info "Podman's machine is stopped, so its firewall driver could not be read. If it uses iptables, start it (podman machine start) and re-run: the kit reads the setting then."
}

function Test-PersonalWslPodmanNetworkOk {
    param([string]$Rerun = "", [switch]$Replace, [switch]$Quiet, [switch]$StartMachine)
    if (-not $Rerun) {
        if ($Replace) { $Rerun = "exakit start" } else { $Rerun = Get-ExakitInstallCommand }
    }
    $release = Get-PersonalWslRelease
    $parts = @(("" + $release) -split "\.")
    if ($null -eq $release -or $parts.Count -lt 2 -or $parts[0] -notmatch '^\d+$' -or $parts[1] -notmatch '^\d+$') {
        $script:PersonalWslReleaseSeen = $null
        if ($Replace -and $env:EXAKIT_WSL_CHECKED -ne "1") {
            if (Test-PersonalPodmanMachineIptables -StartMachine:$StartMachine) { return $true }
            if (-not $Quiet) {
                Warn2 "Could not read the WSL release (wsl.exe is missing, did not run, or answered no version), so replacing this Podman deployment is refused: its fresh deploy needs WSL 2.7 or newer, and on an older WSL it fails after the data is gone."
                Info "Nothing was deleted: the deployment and its data stay. Run 'wsl --version'; once it shows 2.7 or newer, re-run the replace with EXAKIT_WSL_CHECKED=1 set."
                Write-PersonalPodmanMachineStoppedNote
                Set-ExakitFailureReason "The WSL release could not be read, so replacing the Podman deployment was refused ('wsl --version' must show 2.7 or newer)"
            }
            return $false
        }
        if (-not $Quiet -and -not $Replace) { Write-PersonalWslUnreadWarning }
        return $true
    }
    $script:PersonalWslReleaseSeen = $release
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -gt 2 -or ($major -eq 2 -and $minor -ge 7)) { return $true }
    if (Test-PersonalPodmanMachineIptables -StartMachine:$StartMachine) { return $true }
    if ($Quiet) { return $false }
    $shown = $release
    Warn2 "Podman on WSL $shown cannot create the network Exasol Personal 2.4 needs: this WSL kernel has no nftables, so Podman fails with 'nft did not return successfully while applying ruleset'."
    Set-ExakitFailureReason "WSL $shown is older than 2.7, so Podman cannot create the deployment network (run: wsl --update)"
    if ($Replace) {
        # ONE NEXT STEP: the deployment is intact, so after the update it
        # starts as it is - nothing needs replacing.
        Info "Nothing was deleted: the deployment and its data stay. Run 'wsl --update' then 'wsl --shutdown', then: $Rerun"
        Write-PersonalPodmanMachineStoppedNote
        return $false
    }
    Info "Run:  wsl --update   then:  wsl --shutdown   - then re-run: $Rerun"
    Write-PersonalPodmanMachineStoppedNote
    Info "Nothing was changed."
    return $false
}

# Test-PersonalUpdateCrossesTo24 <version> - a launcher update to <version> is
# the one that brings the 2.4 deployment network. Twin of
# _personal_update_crosses_to_24.
function Test-PersonalUpdateCrossesTo24 {
    param([string]$Version)
    if ($Version -match '^(0|1)\.' -or $Version -match '^2\.[0-3](\.|$)') { return $false }
    return $true
}

# Invoke-PersonalInstallLocal <args> - `exasol install local`, retried when it
# failed on a Windows file lock rather than on anything about the deployment.
#
# The launcher writes runtime-artifacts\index.json as a temp file renamed over
# the old one, and Windows refuses that rename while any other process holds
# the target open - Defender or another scanner inspecting the file it just
# wrote, the search indexer. Measured on a Nano-to-Personal upgrade:
#   rename ...\runtime-artifacts\index.json.tmp-1356456713 ...\index.json: Access is denied.
# a second after the deploy began, with nothing deployed, and the very next
# installer run went through untouched. The lock is gone within seconds, so the
# retry is short and only fires on that signature: any other failure is real and
# goes straight back to the caller. Nothing to undo in between - the launcher
# failed in initialisation, before creating a deployment.
# What the last attempt said is kept in $script:PersonalLauncherOutput, for the
# failure's tail and its diagnosis.
# Windows only: POSIX rename replaces an open file, so the sh side has no twin.
function Invoke-PersonalInstallLocal {
    param([string[]]$InstallArgs)
    $attempts = 3
    $script:PersonalLauncherOutput = @()
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $logBefore = Get-PersonalLogLineCount
        $rc = Invoke-ExakitLogged (Get-PersonalCli) @InstallArgs
        $script:PersonalLauncherOutput = @(Get-PersonalLogSince $logBefore)
        if ($rc -eq 0) { return 0 }
        if ($attempt -eq $attempts -or -not $script:LogFile) { return $rc }
        if (Test-PersonalDeploymentExists) { return $rc }
        $output = $script:PersonalLauncherOutput -join "`n"
        if ($output -notmatch 'Access is denied|being used by another process') { return $rc }
        Write-ExakitLog "WARN" "exasol install local hit a file lock (attempt $attempt of $attempts) - retrying"
        Start-Sleep -Seconds (3 * $attempt)
    }
    return $rc
}

# --- which database: the installer's one question (CONTRACT section 4) -----
# A NEW install (no database the kit records, or the kit's own missing) uses
# a starter-kit-local of its own, unless the user picks one of their own
# databases in the one question, which renames it to starter-kit-local. A
# starter-kit-local already there with no record of the kit's (kept by an
# earlier uninstall) is used with no question. Stop, rename and restart are
# automatic; a database of the user's is never deleted.

# Set-PersonalDeploymentTarget <folder> - the folder every later launcher call
# names, with the refresh state of a new process (the record is read again).
function Set-PersonalDeploymentTarget {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Dir)
    $script:PersonalDeployDir = $Dir
    $script:PersonalDeployFollowed = ""
    $script:PersonalDeployRec = ""
    $script:PersonalLauncherDecided = $false
}

# Clear-PersonalDatabaseRecord - forget the database the kit recorded, when
# the kit's own is missing and the installer makes another one the kit's
# (a new starter-kit-local, or one of the user's renamed): its folder, id,
# name, ownership receipt and what was done to that database. Nothing on
# disk is touched. (The sh side points the record at the new folder instead,
# personal_point_record_at; either way the old claim is gone.)
#
# THE OWNER FIRST, AND LAST. The receipt says `user` before any other key goes,
# and goes after all of them: a run killed in between leaves a record that says
# the user's, never one that reads a database of theirs as the kit's (the
# folder without the id that tells them apart), which an uninstall would remove.
function Clear-PersonalDatabaseRecord {
    if ("" + (Get-ExakitManifestValue "runtime.ownership")) {
        try { $null = Set-ExakitManifestValue "runtime.ownership" "user" } catch { return }
    }
    foreach ($key in @(Get-PersonalDatabaseRecordKeys)) {
        try { if ($null -ne (Get-ExakitManifestValue $key)) { Remove-ExakitManifestValue $key } } catch { }
    }
}

# Get-PersonalDatabaseRecordKeys - the keys of the kit's record of its
# database that Clear-PersonalDatabaseRecord forgets.
function Get-PersonalDatabaseRecordKeys {
    return @("runtime.deployment_dir", "runtime.deployment_id", "runtime.deployment_name",
             "runtime.ownership_path", "runtime.ownership_sha256", "runtime.session_limit", "runtime.session_limit_lifted_at",
             "runtime.guest_rebuilt_for", "runtime.rebuild_path", "runtime.ownership")
}

# Get-PersonalDatabaseRecord / Restore-PersonalDatabaseRecord <saved> - those
# keys as they are now, and put back as they were (a key that was not there
# is removed): a record the installer could not write in full is never left
# half rewritten. Never throws.
function Get-PersonalDatabaseRecord {
    $saved = @{}
    foreach ($key in @(Get-PersonalDatabaseRecordKeys)) {
        try { $saved[$key] = Get-ExakitManifestValue $key } catch { $saved[$key] = $null }
    }
    return $saved
}
function Restore-PersonalDatabaseRecord {
    param([hashtable]$Saved = @{})
    foreach ($key in @(Get-PersonalDatabaseRecordKeys)) {
        try {
            if ($null -eq $Saved[$key]) {
                if ($null -ne (Get-ExakitManifestValue $key)) { Remove-ExakitManifestValue $key }
            } else {
                $null = Set-ExakitManifestValue $key $Saved[$key]
            }
        } catch { }
    }
}

# Set-PersonalUserDatabaseRecord <folder> - the record of a database of the
# user's the kit now uses: runtime.type, its folder and name, its launcher id,
# and the ownership receipt `user` for that folder (never destroyed, never
# replaced). Twin of personal_point_record_at with exakit_record_ownership
# database user.
function Set-PersonalUserDatabaseRecord {
    param([Parameter(Mandatory)][string]$Dir)
    Set-ExakitManifestValue "runtime.type" "personal"
    # The owner before the folder and the id: a run killed in between never
    # leaves a folder of theirs on record with no receipt that says so.
    Set-ExakitComponentOwnership "database" "user" $Dir
    Set-ExakitManifestValue "runtime.deployment_dir" $Dir
    Set-ExakitManifestValue "runtime.deployment_name" (Split-Path -Leaf $Dir)
    $id = "" + (Read-PersonalDeploymentId -Dir $Dir)
    if ($id) { Set-ExakitManifestValue "runtime.deployment_id" $id }
}

# Set-PersonalMadeIn -OldId -NewId -OldDir -Name - the kit's database becomes
# another one (one of the user's, picked or found): what the kit's records say
# it made (its logins and roles) was made in the old one. Each record with no
# made_in yet gets the old database's id ("unknown" for none), so an uninstall
# never drops a login or role of that name in this one. Nothing when it is the
# same database: the same id, or no id on record and the old folder moved to
# the one picked. Called before the new id is recorded. Twin of
# personal_stamp_made_in.
function Set-PersonalMadeIn {
    param([string]$OldId = "", [string]$NewId = "", [string]$OldDir = "", [string]$Name = "")
    if ($OldId) {
        if ($OldId -ceq $NewId) { return }
    } elseif ($OldDir -and -not (Test-Path -LiteralPath $OldDir) -and (Split-Path -Leaf $OldDir) -ceq $Name) {
        return
    }
    $stamp = $OldId
    if (-not $stamp) { $stamp = "unknown" }
    foreach ($block in @("mcp_server.connection", "exasol_scheduler", "semantic_views", "preprocessor")) {
        try {
            if ($null -eq (Get-ExakitManifestValue "components.$block")) { continue }
            if ("" + (Get-ExakitManifestValue "components.$block.made_in")) { continue }
            Set-ExakitManifestValue "components.$block.made_in" $stamp
        } catch { Write-ExakitLog "WARN" "the record of where components.$block was made: $_" }
    }
}

# Get-PersonalDeploymentVersionIn <folder> - the Exasol Personal version that
# made the deployment in <folder>, "" for unknown. As Get-PersonalDeployedVersion,
# which reads the folder in use.
function Get-PersonalDeploymentVersionIn {
    param([Parameter(Mandatory)][string]$Dir)
    $raw = ""
    try { $raw = ([System.IO.File]::ReadAllText((Join-Path $Dir ".exasolLauncher.version"))).Trim() } catch { $raw = "" }
    if (-not $raw) {
        try { if ([System.IO.File]::ReadAllText((Join-Path $Dir ".exasolLauncherState.json")) -match '"deploymentVersion"\s*:\s*"([^"]*)"') { $raw = $Matches[1] } } catch { $raw = "" }
    }
    $raw = $raw -replace '^v', ''
    if ($raw -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { return "" }
    return $raw
}

# Test-PersonalKitMade -Dir <folder> - the starter-kit-local in <folder>,
# found with no database record of the kit's, is one the kit made itself: its
# first deploy was interrupted before the receipt was written. The kit's
# records say so: runtime.first_boot_pending (written right before the kit's
# own `install local`, Test-PersonalFirstBootPending), or runtime.deployment_id
# naming the id in <folder>. Twin of _personal_kit_made (Windows has no
# private home, mode P).
function Test-PersonalKitMade {
    param([Parameter(Mandatory)][string]$Dir)
    if (Test-PersonalFirstBootPending) { return $true }
    $want = "" + (Get-ExakitManifestValue "runtime.deployment_id")
    if (-not $want) { return $false }
    return ((Read-PersonalDeploymentId -Dir $Dir) -ceq $want)
}

# Set-PersonalKitDatabaseRecord <folder> - the record of the kit's own
# database in <folder>: runtime.type, its folder and name, its launcher id, and
# the ownership receipt `kit` for that folder. Twin of personal_point_record_at
# with exakit_record_ownership database kit.
function Set-PersonalKitDatabaseRecord {
    param([Parameter(Mandatory)][string]$Dir)
    Set-ExakitManifestValue "runtime.type" "personal"
    Set-ExakitManifestValue "runtime.deployment_dir" $Dir
    Set-ExakitManifestValue "runtime.deployment_name" (Split-Path -Leaf $Dir)
    $id = "" + (Read-PersonalDeploymentId -Dir $Dir)
    if ($id) { Set-ExakitManifestValue "runtime.deployment_id" $id }
    Set-ExakitComponentOwnership "database" "kit" $Dir
}

# Get-PersonalEligibleDeployments - the user's databases the one question
# offers, sorted by name: what the launcher lists (`deployments list --json`,
# given longer than usual: it probes each one), local ones only, never
# starter-kit-local, and only one that is running (database_ready, running,
# database_connection_failed: "running") or stopped ("stopped"). A deployment
# that never finished deploying (initialized, deployment_failed, interrupted,
# operation_in_progress) is never offered. One the list calls not_initialized
# (it gives each 5 s) is asked again on its own, with 30 s, before it is left
# out. Each as Name, Path, Status (the launcher's word) and State. Twin of
# personal_reuse_candidates.
function Get-PersonalEligibleDeployments {
    $out = @()
    $kitName = Get-PersonalDeploymentName
    foreach ($row in @(Get-PersonalLauncherDeployments -Again -TimeoutSeconds 60)) {
        if (-not $row -or -not $row.Path) { continue }
        $name = "" + $row.Name
        if (-not $name) { $name = Split-Path -Leaf $row.Path }
        if ($name -ceq $kitName -or (Split-Path -Leaf $row.Path) -ceq $kitName) { continue }
        $status = ("" + $row.Status).ToLowerInvariant()
        if ($status -eq "not_initialized" -and (Test-PersonalDeploymentFolder $row.Path)) {
            $again = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("status", "--json", "--timeout", "30", "--deployment-dir", $row.Path) -TimeoutSeconds 45
            $status = ""
            if ($again -and ("" + $again) -match '"status"\s*:\s*"([^"]*)"') { $status = $Matches[1].ToLowerInvariant() }
        }
        # Local only (the preset the launcher names), never a cloud one. A row
        # that came back without the preset is local when its folder holds
        # the local runtime or the local preset's settings.
        $infra = "" + $row.Infrastructure
        if (-not $infra) {
            $yaml = [IO.Path]::Combine($row.Path, "infrastructure", "infrastructure.yaml")
            $isLocal = Test-Path -LiteralPath (Join-Path $row.Path "local") -PathType Container
            if (-not $isLocal -and (Test-Path -LiteralPath $yaml -PathType Leaf)) {
                try { $isLocal = ([System.IO.File]::ReadAllText($yaml) -match '(?m)^local\s*:') } catch { $isLocal = $false }
            }
            if ($isLocal) { $infra = "local" }
        }
        if ($infra -ne "local") { continue }
        $state = ""
        if (@("database_ready", "running", "database_connection_failed") -contains $status) { $state = "running" }
        elseif ($status -eq "stopped") { $state = "stopped" }
        if (-not $state) { continue }
        $out += [pscustomobject]@{ Name = $name; Path = "" + $row.Path; Status = $status; State = $state }
    }
    # BYTE ORDER, as the sh twin's `LC_ALL=C sort`: the same databases get the
    # same numbers in the one question on every platform. Sort-Object compares
    # by culture (case folded, punctuation weighed apart), so the same answer
    # picked another database on Windows than on macOS. By the name, then the
    # rest of the row, as the sh side breaks a tie on the whole line.
    # The non-generic Array.Sort, its arguments cast to it: the generic one
    # is handed copies of the arrays and sorts those.
    $rows = [object[]]@($out)
    if ($rows.Count -lt 2) { return @($rows) }
    $keys = [string[]]@($rows | ForEach-Object { "$($_.Name)`t$($_.State)`t$($_.Path)" })
    [Array]::Sort([Array]$keys, [Array]$rows, [System.Collections.IComparer][StringComparer]::Ordinal)
    return @($rows)
}

# Test-PersonalReuseDbNew - EXAKIT_REUSE_DB asks for a new database: 0, n,
# no or new (`exakit repair-runtime` sets 0). For the kit's own database that
# means it is replaced (the DELETE question, owner kit only); a database of
# the user's is never replaced. Twin of _personal_reuse_declined.
function Test-PersonalReuseDbNew {
    return [bool](("" + $env:EXAKIT_REUSE_DB) -cmatch '^(0|n|N|no|NO|No|new)$')
}

# Resolve-PersonalReuseDbAnswer -Deployments <eligible> [-Value <text>] - what
# EXAKIT_REUSE_DB (or -Value) answers to the one question, with or without a
# terminal. Its own parser, not the yes/no one (Confirm-ExakitEnvPrompt):
#   unset or empty           Kind "ask" (the terminal, else a new database)
#   0, n, no, new            Kind "new"
#   1, y, yes (0.3.0 scripts) the user's `default` when it is offered, else
#                            the only one offered, else "reject"; with none
#                            offered, a new database (0.3.0 deployed one too)
#   a database's name        Kind "pick", when it is offered; else "reject"
# A reject's Message names what can be given. Twin of the EXAKIT_REUSE_DB
# half of personal_reuse_answer (and of its no-candidates arm in
# personal_choose_database).
function Resolve-PersonalReuseDbAnswer {
    param([object[]]$Deployments = @(), [AllowEmptyString()][AllowNull()][string]$Value = $null)
    if (-not $PSBoundParameters.ContainsKey('Value')) { $Value = "" + $env:EXAKIT_REUSE_DB }
    $v = "" + $Value
    $offered = @($Deployments | Where-Object { $_ })
    $names = (@($offered | ForEach-Object { "" + $_.Name })) -join ", "
    if (-not $v) { return [pscustomobject]@{ Kind = "ask"; Pick = $null; Message = "" } }
    if ($v -cmatch '^(0|n|N|no|NO|No|new)$') { return [pscustomobject]@{ Kind = "new"; Pick = $null; Message = "" } }
    if ($v -cmatch '^(1|y|Y|yes|YES|Yes)$') {
        if ($offered.Count -eq 0) { return [pscustomobject]@{ Kind = "new"; Pick = $null; Message = "" } }
        $default = @($offered | Where-Object { ("" + $_.Name) -ceq "default" })
        if ($default.Count -eq 1) { return [pscustomobject]@{ Kind = "pick"; Pick = $default[0]; Message = "" } }
        if ($offered.Count -eq 1) { return [pscustomobject]@{ Kind = "pick"; Pick = $offered[0]; Message = "" } }
        return [pscustomobject]@{ Kind = "reject"; Pick = $null
            Message = "EXAKIT_REUSE_DB=$v does not say which of your databases the kit should use. Set it to one of these names: $names. Or set it to 0 for a new database." }
    }
    if ($offered.Count -eq 0) {
        return [pscustomobject]@{ Kind = "reject"; Pick = $null
            Message = "EXAKIT_REUSE_DB=$v is not a database the kit can use on this computer. Unset it, or set it to 0, for a new database." }
    }
    $hit = @($offered | Where-Object { ("" + $_.Name) -ceq $v })
    if ($hit.Count -eq 1) { return [pscustomobject]@{ Kind = "pick"; Pick = $hit[0]; Message = "" } }
    return [pscustomobject]@{ Kind = "reject"; Pick = $null
        Message = "EXAKIT_REUSE_DB=$v is not a database the kit can use. Set it to one of these names: $names. Or set it to 0 for a new database." }
}

# Read-PersonalDatabaseChoice -Deployments <eligible> - the one question on
# the terminal: a new database (1, the default on Enter) or one of theirs.
# The eligible row picked, or $null for a new database. With nobody to ask
# (no terminal, -NonInteractive), a new database (D1); after five answers
# that are no number of the list, a new database too. The words are the
# approved ones. Twin of the terminal half of personal_reuse_answer.
function Read-PersonalDatabaseChoice {
    param([object[]]$Deployments = @())
    $offered = @($Deployments | Where-Object { $_ })
    if ($offered.Count -eq 0 -or -not (Test-PersonalPromptable)) { return $null }
    $total = $offered.Count + 1
    Clear-ExakitPromptLine
    if ($script:UiFancy) {
        Write-Host ("    {0}?{1} {2}" -f $script:UiAsk, $script:UiReset, "Which database should the starter kit use?")
    } else {
        Write-Host "    ? Which database should the starter kit use?" -ForegroundColor Cyan
    }
    Write-Host "      1) A new database '$(Get-PersonalDeploymentName)' (recommended)"
    for ($i = 0; $i -lt $offered.Count; $i++) {
        Write-Host ("      {0}) {1} ({2})" -f ($i + 2), $offered[$i].Name, $offered[$i].State)
    }
    for ($try = 1; $try -le 5; $try++) {
        Write-Host "    Choose 1-$total [1]: " -NoNewline
        $raw = ("" + (Read-Host)) -replace '\s', ''
        if (-not $raw) { return $null }
        # AS A NUMBER, as the sh twin reads it: 01 is 1, 02 is 2. All zeros,
        # or a number too long to be a choice, is asked again (and never read
        # into an [int] it does not fit).
        $number = -1
        if ($raw -match '^\d+$') {
            $digits = $raw.TrimStart('0')
            $number = 0
            if ($digits -and $digits.Length -le 6) { $number = [int]$digits }
        }
        if ($number -eq 1) { return $null }
        if ($number -ge 2 -and $number -le $total) { return $offered[$number - 2] }
        if ($try -lt 5) { Write-Host "      Answer with a number from 1 to $total." }
    }
    return $null
}

# Rename-PersonalDeploymentFolder -From <folder> -To <folder> - a STOPPED
# deployment renamed in place: the launcher keeps no name inside its folder
# (the name is the folder's), so renaming the folder is the rename (R1 Q3).
# $true when it was renamed. $false, nothing changed, with the reason in
# $script:PersonalRenameError: missing (<From> is not a folder), exists (<To>
# is there), locked (a launcher command holds <From>: a .dirmutex marker, or a
# stale one `exasol diag unlock` clears) or failed (Windows refused: a program
# has a file open inside, no permission). The folder only: the record follows
# with Update-PersonalDeploymentRecord. Used by the installer's rename of the
# database the user picked, and by `exakit update`'s rename of a 0.3.0 kit's
# `default` and its undo. Twin of the folder half of personal_rename_deployment.
$script:PersonalRenameError = ""
function Rename-PersonalDeploymentFolder {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $script:PersonalRenameError = ""
    if (-not (Test-Path -LiteralPath $From -PathType Container)) { $script:PersonalRenameError = "missing"; return $false }
    if (Test-Path -LiteralPath $To) { $script:PersonalRenameError = "exists"; return $false }
    if (@(Get-ChildItem -LiteralPath $From -Force -Filter ".dirmutex*" -ErrorAction SilentlyContinue).Count -gt 0) {
        $script:PersonalRenameError = "locked"
        return $false
    }
    try {
        [System.IO.Directory]::Move($From, $To)
    } catch {
        Write-ExakitLog "WARN" "rename $From -> $To failed: $($_.Exception.Message)"
        $script:PersonalRenameError = "failed"
        return $false
    }
    Write-ExakitLog "INFO" "renamed the deployment folder $From to $To"
    return $true
}

# Undo-PersonalDeploymentRename -From <original> -To <renamed> - a rename put
# back: the folder renamed back and the record rewritten back
# (Update-PersonalDeploymentRecord). $true when the folder is back. Twin of
# personal_rename_deployment "<renamed>" "<original>".
function Undo-PersonalDeploymentRename {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    if (-not (Rename-PersonalDeploymentFolder -From $To -To $From)) { return $false }
    Update-PersonalDeploymentRecord -From $To -To $From
    return $true
}

# Start-PersonalDeploymentAt <folder> - start the deployment in <folder>
# again, after a rename that did not happen: the user's database, as it was.
function Start-PersonalDeploymentAt {
    param([Parameter(Mandatory)][string]$Dir)
    $flag = Get-PersonalAutoApproveFlag "start"
    if ($flag) { return ((Invoke-ExakitLogged (Get-PersonalCli) start $flag --deployment-dir $Dir) -eq 0) }
    return ((Invoke-ExakitLogged (Get-PersonalCli) start --deployment-dir $Dir) -eq 0)
}

# Get-PersonalStateOf -Dir <folder> - the launcher's own word for the deployment
# in <folder> (Get-PersonalLauncherState asks for the kit's own). "" when it
# does not say.
function Get-PersonalStateOf {
    param([Parameter(Mandatory)][string]$Dir)
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("status", "--json", "--deployment-dir", $Dir) -TimeoutSeconds $script:PersonalProbeTimeout
    if ($out -and $out -match '"status"\s*:\s*"([^"]*)"') { return $Matches[1].ToLowerInvariant() }
    $out = Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("status", "--deployment-dir", $Dir) -TimeoutSeconds $script:PersonalProbeTimeout
    if ($out -and $out -match '(?m)^\s*Status:\s*([A-Za-z_]+)') { return $Matches[1].ToLowerInvariant() }
    return ""
}

# Get-PersonalMovedFolder -Dir <folder> -Id <id> - <folder> while it is there,
# else the folder of its name in the launcher's 2.5 root that carries <id>: a
# 2.5 launcher moves a stopped one there by its first command. <folder> again
# when neither is.
function Get-PersonalMovedFolder {
    param([Parameter(Mandatory)][string]$Dir, [AllowEmptyString()][string]$Id = "")
    if ((Test-Path -LiteralPath $Dir) -or -not $Id) { return $Dir }
    $root = "" + (Resolve-PersonalDeployDir -Path "").NewRoot
    if (-not $root) { return $Dir }
    $moved = Join-Path $root (Split-Path -Leaf $Dir)
    if ((Test-Path -LiteralPath $moved -PathType Container) -and (("" + (Read-PersonalDeploymentId -Dir $moved)) -ceq $Id)) { return $moved }
    return $Dir
}

# Rename-PersonalUserDatabase -Pick <eligible row> - the database the user
# picked becomes the kit's starter-kit-local (REN): stopped when it runs, its
# folder renamed in place to <same root>\starter-kit-local, recorded as the
# user's (Set-PersonalUserDatabaseRecord), and the 20-session limit of a 2.4
# deployment lifted while it is stopped. The install's own ladder starts it
# again, once. $true when it is renamed. Any step that fails puts it back as
# it was (renamed back, started again if it ran), says why, and answers
# $false: nothing of theirs changed. The words are the sh side's.
# -Replace: the kit records a database of its own that is missing
# (kit_database_missing), and that record is replaced by this one only once
# the folder is renamed: a rename that does not happen leaves it as it was,
# so `exakit status` still says the kit's own is missing and the next run
# asks again. Twin of personal_reuse_rename.
function Rename-PersonalUserDatabase {
    param([Parameter(Mandatory)]$Pick, [switch]$Replace)
    $name = "" + $Pick.Name
    $from = "" + $Pick.Path
    $kitName = Get-PersonalDeploymentName
    $to = Join-Path (Split-Path -Parent $from) $kitName
    if (Test-Path -LiteralPath $to) {
        Warn2 "Your database '$name' was not renamed, because $(Get-ExakitTilde $to) already exists. Nothing was changed."
        Set-ExakitFailureReason "Your database '$name' was not renamed, because $to already exists"
        return $false
    }
    # A DATABASE NEWER THAN THE KIT'S LAUNCHER is refused by it (its own rule),
    # so it is not stopped and not renamed. Against the version this run
    # installs, never asked of the launcher: any command of a 2.5 moves a
    # stopped folder out of the older root before the rename. Twin of the same
    # rule in personal_reuse_rename.
    $madeBy = Get-PersonalDeploymentVersionIn $from
    $kitVersion = "" + (Get-PersonalTargetVersion)
    if ($madeBy -and $kitVersion -and (Test-PersonalVersionOutranks $madeBy $kitVersion)) {
        $newer = "The Exasol Personal deployment on this machine is version $madeBy, which is newer than the launcher version this kit advertises ($kitVersion)."
        Warn2 $newer
        Set-ExakitFailureReason $newer
        return $false
    }
    $oldId = "" + (Get-ExakitManifestValue "runtime.deployment_id")
    $oldDir = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
    # WHAT THE LAUNCHER SAYS NOW, not what it listed before the question: the
    # user can start it while the question waits, and a stop that answers 0 is
    # not "stopped". Only the launcher's own "stopped" or "initialized" is.
    $pickId = "" + (Read-PersonalDeploymentId -Dir $from)
    $state = "" + (Get-PersonalStateOf -Dir $from)
    $from = "" + (Get-PersonalMovedFolder -Dir $from -Id $pickId)
    $ran = ($Pick.State -eq "running") -or ($state -and @("stopped", "initialized") -notcontains $state)
    if (@("stopped", "initialized") -notcontains $state) {
        $script:ExakitActiveLabel = "Stopping your database '$name'"
        $stopped = ((Invoke-ExakitLogged (Get-PersonalCli) stop --deployment-dir $from) -eq 0)
        $script:ExakitActiveLabel = ""
        if ($stopped) {
            # Asked twice: a 2.5 launcher moves a stopped folder out of the
            # older root by the command that asks.
            $stopped = $false
            for ($try = 1; $try -le 2 -and -not $stopped; $try++) {
                $stopped = (@("stopped", "initialized") -contains ("" + (Get-PersonalStateOf -Dir $from)))
                $from = "" + (Get-PersonalMovedFolder -Dir $from -Id $pickId)
            }
        }
        if (-not $stopped) {
            Warn2 "Your database '$name' did not stop, so it was not renamed. Nothing was changed."
            # One that went down without stopping as asked is started again.
            if ($ran -and (@("database_ready", "running", "database_connection_failed") -notcontains ("" + (Get-PersonalStateOf -Dir $from))) -and
                -not (Start-PersonalDeploymentAt $from)) {
                Warn2 "Your database '$name' did not start again. Start it with: exasol start -d $name"
            }
            Set-ExakitFailureReason "Your database '$name' did not stop, so it was not renamed"
            return $false
        }
    }
    $to = Join-Path (Split-Path -Parent $from) $kitName
    $why = ""
    if (-not (Rename-PersonalDeploymentFolder -From $from -To $to)) {
        switch ($script:PersonalRenameError) {
            "exists" { $why = "$(Get-ExakitTilde $to) already exists" }
            "locked" { $why = "another Exasol Personal command is using it" }
            default  { $why = "its folder could not be renamed" }
        }
    } else {
        # The record as it was, put back when the new one cannot be written
        # in full (none on a new install: then none again).
        $before = Get-PersonalDatabaseRecord
        try {
            if ($Replace) { Clear-PersonalDatabaseRecord }
            Set-PersonalMadeIn -OldId $oldId -NewId ("" + (Read-PersonalDeploymentId -Dir $to)) -OldDir $oldDir -Name $name
            Set-PersonalUserDatabaseRecord -Dir $to
            Update-PersonalDeploymentRecord -From $from -To $to
        } catch {
            Write-ExakitLog "WARN" "record of the renamed database failed: $_"
            $why = "the kit could not write its record"
            Restore-PersonalDatabaseRecord -Saved $before
            [void](Rename-PersonalDeploymentFolder -From $to -To $from)
        }
    }
    if ($why) {
        Warn2 "Your database '$name' was not renamed to '$kitName', because $why. Nothing was changed."
        if ($ran -and (Test-Path -LiteralPath $from -PathType Container) -and -not (Start-PersonalDeploymentAt $from)) {
            Warn2 "Your database '$name' did not start again. Start it with: exasol start -d $name"
        }
        Set-ExakitFailureReason "Your database '$name' was not renamed to '$kitName', because $why"
        $script:PersonalLauncherAsked = $false
        return $false
    }
    # The launcher's list names the old folder: asked anew when it is needed.
    $script:PersonalLauncherAsked = $false
    Save-PersonalEngineOwn
    # Lifted now, while it is stopped: the start below applies it, once. Said
    # only when the file could not be changed, as the sh twin says it.
    try { [void](Remove-PersonalSessionLimit -Quiet) } catch { Write-ExakitLog "WARN" "session limit of the renamed database: $_" }
    # Its saved port, held now by another database of the user's (Q12): the
    # deploy step's start would fail on it. While it is stopped, it gets the
    # next free port (Select-PersonalDbPort: neither in use nor saved by
    # another deployment), set by the launcher itself.
    try { [void](Set-PersonalReuseFreePort -Dir $to) } catch { Write-ExakitLog "WARN" "port of the renamed database: $_" }
    # A 0.3.0 kit's own `default` that a 2.5 of the user's moved, picked here
    # (kit_database_missing): the MCP server that kit set up in it is recorded
    # as the kit's when that is provable (Save-PersonalUpdateSidecarRecord).
    # Nothing for a database the kit never set one up in.
    try { Save-PersonalUpdateSidecarRecord } catch { Write-ExakitLog "WARN" "MCP sidecar record of the renamed database: $_" }
    Ok "Your database '$name' is now '$kitName'. The kit uses it and never deletes it."
    return $true
}

# Set-PersonalReuseFreePort -Dir <folder> - the stopped database in <folder>,
# picked in the one question, moved off a saved port that something else
# holds now (Q12): to the next free one, with `exasol config set --ports
# db:<n>`, which the launcher allows on a stopped deployment. One line says
# the new port. Nothing done when the port is free, or when no other port is
# (the start then names the port held, as before). Twin of
# personal_reuse_free_port.
function Set-PersonalReuseFreePort {
    param([Parameter(Mandatory)][string]$Dir)
    $saved = @(Get-PersonalSavedDbPorts -Dir $Dir)
    if ($saved.Count -eq 0) { return $true }
    $port = [int]$saved[0]
    if (-not (Test-ExakitPortInUse -Port $port)) { return $true }
    $prev = $script:PersonalDeployDir
    $script:PersonalDeployDir = $Dir
    $pick = 0
    try { $pick = [int](Select-PersonalDbPort) } finally { $script:PersonalDeployDir = $prev }
    if (-not $pick) { return $false }
    if ((Invoke-ExakitLogged (Get-PersonalCli) config set --ports "db:$pick" --deployment-dir $Dir) -eq 0) {
        Info "Port $port is in use by another database, so your database '$(Split-Path -Leaf $Dir)' now uses port $pick."
        return $true
    }
    return $false
}

# Select-PersonalDatabase - which database this install uses, before the
# deploy step acts on any (CONTRACT section 4). Twin of
# personal_choose_database. "recorded": the database the
# kit records (its own, or one recorded as the user's), as before, with no
# question. "chosen": the folder the user named in EXAKIT_PERSONAL_DEPLOY_DIR,
# as before, with no question either. Otherwise (a new install, or the kit's
# own missing) the target is starter-kit-local in the launcher's root:
#   - the kit's own, its first deploy interrupted before its receipt
#     (Test-PersonalKitMade): "recorded", resumed and repaired as the kit's,
#     no question, no line (a new install only);
#   - one already there that the kit has no record of: "leftover", used as
#     the user's with no question (an earlier uninstall kept it, D5). With the
#     kit's own missing, it is a database of the user's under the kit's name
#     (the kit's own destroyed, theirs made under the same name): neither a
#     new database nor a rename could have that name, so it is used the same
#     way, and its own line says why;
#   - else, with databases of the user's to offer, the one question
#     (EXAKIT_REUSE_DB, the terminal, else a new database): one of theirs is
#     renamed (Rename-PersonalUserDatabase), "renamed";
#   - else "new": a new starter-kit-local of the kit's own.
# "" when the rename of the one picked did not happen (said, nothing of
# theirs changed). An answer in EXAKIT_REUSE_DB the kit cannot use refuses
# the install (exit 2) before anything is changed. Twin of
# personal_select_database.
function Select-PersonalDatabase {
    $state = ""
    try { $state = "" + (Get-ExakitPersonalDbState) } catch { $state = "" }
    if ((Test-PersonalDatabaseRecorded) -and -not $state) {
        # THE RECORDED FOLDER IS GONE, NOTHING IN ITS PLACE, UNDER A NAME THAT
        # IS NOT THE KIT'S: a 0.3.0 kit's `default` (its own, or one of the
        # user's it used) destroyed by hand. The new database goes where a
        # first install puts it (the resolver's target with no usable record),
        # and the record says so before the deploy, as the kit's own and
        # without the gone database's id: an interrupted deploy is then
        # resumed as the kit's, never taken for one of the user's. A folder
        # the user chose, outside the launcher's roots, is kept. Twin of
        # _personal_record_gone_elsewhere in personal_choose_database.
        $rec = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
        if ($rec -and -not ("" + $env:EXAKIT_PERSONAL_DEPLOY_DIR) -and -not (Test-Path -LiteralPath $rec) -and
            (Split-Path -Leaf $rec) -ne (Get-PersonalDeploymentName)) {
            $roots = Resolve-PersonalDeployDir -Path ""
            $recParent = Split-Path -Parent $rec
            $target = "" + $roots.Dir
            if ($recParent -and ($recParent -eq $roots.NewRoot -or $recParent -eq $roots.LegacyRoot) -and
                $target -and -not (Test-Path -LiteralPath $target)) {
                # The user's, when a rebuild of theirs makes it or was cut short
                # (Get-PersonalNewDatabaseOwner), and its note follows.
                $goneOwner = "kit"
                if (("" + (Get-ExakitManifestValue "runtime.rebuild_path")) -eq $rec -or ("" + (Get-PersonalNewDatabaseOwner)) -eq "user") { $goneOwner = "user" }
                Set-PersonalDeploymentTarget $target
                Set-ExakitManifestValue "runtime.deployment_dir" $target
                Set-ExakitManifestValue "runtime.deployment_name" (Split-Path -Leaf $target)
                if ($goneOwner -eq "user") { Set-ExakitManifestValue "runtime.rebuild_path" $target }
                Set-ExakitComponentOwnership "database" $goneOwner $target
                if ($null -ne (Get-ExakitManifestValue "runtime.deployment_id")) { Remove-ExakitManifestValue "runtime.deployment_id" }
            }
        }
        return "recorded"
    }
    # A folder the user named is the folder, whatever is recorded: never a
    # target in the launcher's root instead.
    if ("" + $env:EXAKIT_PERSONAL_DEPLOY_DIR) { return "chosen" }
    $target = "" + (Resolve-PersonalDeployDir -Path "").Dir
    if (Test-PersonalDeploymentFolder $target) {
        if (-not $state -and (Test-PersonalKitMade -Dir $target)) {
            # THE KIT'S OWN, INTERRUPTED: its first deploy ended before the
            # receipt (Ctrl-C, a closed window). Resumed and repaired as the
            # kit's, never taken for one an earlier install kept: the deploy
            # step then retries or replaces it as its own. Twin of the same
            # arm in personal_choose_database.
            Set-PersonalDeploymentTarget $target
            Set-PersonalKitDatabaseRecord -Dir $target
            return "recorded"
        }
        $oldId = "" + (Get-ExakitManifestValue "runtime.deployment_id")
        $oldDir = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
        if ($state) { Clear-PersonalDatabaseRecord }
        Set-PersonalDeploymentTarget $target
        Set-PersonalMadeIn -OldId $oldId -NewId ("" + (Read-PersonalDeploymentId -Dir $target)) -OldDir $oldDir -Name (Split-Path -Leaf $target)
        if ($state) {
            Info "A database of yours is named '$(Get-PersonalDeploymentName)', the name of the kit's own database. The kit uses it and never deletes it."
        } else {
            Info "Found the database '$(Get-PersonalDeploymentName)' from an earlier install. The kit uses it and never deletes it."
        }
        Set-PersonalUserDatabaseRecord -Dir $target
        return "leftover"
    }
    $offered = @(Get-PersonalEligibleDeployments)
    # Mode S: the kit's own 2.5 next to their 2.4. Their databases are
    # theirs, never offered: a new starter-kit-local, nothing asked.
    if (Test-PersonalModeS) { $offered = @() }
    $answer = Resolve-PersonalReuseDbAnswer -Deployments $offered
    if ($answer.Kind -eq "reject") { Deny-ExakitInput $answer.Message }
    $pick = $null
    if ($offered.Count -gt 0) {
        $line = Get-PersonalVersionLine (Get-PersonalLauncherVersion)
        if (-not $line) { $line = Get-PersonalVersionLine (Get-PersonalTargetVersion) }
        $count = "$($offered.Count) databases"
        if ($offered.Count -eq 1) { $count = "1 database" }
        Info "Exasol Personal $line is on this computer, with $count of yours."
        if ($answer.Kind -eq "pick") { $pick = $answer.Pick }
        elseif ($answer.Kind -eq "ask") { $pick = Read-PersonalDatabaseChoice -Deployments $offered }
    }
    if ($null -eq $pick) {
        # The kit's own missing: its record goes, for the new one's.
        if ($state) { Clear-PersonalDatabaseRecord }
        Set-PersonalDeploymentTarget $target
        # Next to an Exasol Personal of the user's (their databases, their
        # launcher, or any deployment the launcher lists), the deploy says
        # theirs is not changed (approved line 4).
        # A launcher of theirs is the one Step 1/4 recorded as theirs, or mode
        # S: the receipt names the kit's own since the kit always runs its own.
        $script:PersonalNewNextToTheirs = ($offered.Count -gt 0) -or ((Get-ExakitComponentOwnership "personal") -eq "user") -or
            (Test-PersonalModeS) -or [bool]("" + (Get-ExakitManifestValue "components.personal.user_launcher")) -or
            (@(Get-PersonalLauncherDeployments).Count -gt 0)
        return "new"
    }
    # The kit's own missing: its record is replaced only once the one picked
    # is renamed (-Replace). A rename that does not happen leaves it as it was.
    if (-not (Rename-PersonalUserDatabase -Pick $pick -Replace:([bool]$state))) { return "" }
    return "renamed"
}

# Test-PersonalRebuildsUserDatabase - is this run `exakit repair-runtime` over
# a database of the user's, which they just confirmed (Krishna, Q19)? Set by
# that command for its own process only ($global:ExakitRebuildOwner, never an
# environment variable, so nothing outside can set it), and the record is never
# changed for it: an interruption at any point leaves the database recorded as
# the user's. Twin of EXAKIT_REBUILD_OWNER.
function Test-PersonalRebuildsUserDatabase {
    return ((("" + (Get-Variable -Name ExakitRebuildOwner -Scope Global -ValueOnly -ErrorAction SilentlyContinue)) -eq "user") -and
            (("" + (Get-ExakitManifestValue "runtime.ownership")) -eq "user"))
}

# Test-PersonalDatabaseReplaceable - may the deploy step replace the database
# it found? The kit's own, as ever. One of the user's only in the rebuild they
# confirmed, and only the one the record names: the recorded folder, with the
# recorded id.
function Test-PersonalDatabaseReplaceable {
    if (Test-ExakitComponentManaged "database") { return $true }
    if (-not (Test-PersonalRebuildsUserDatabase)) { return $false }
    $recorded = "" + (Get-ExakitManifestValue "runtime.deployment_dir")
    if (-not $recorded) { return $false }
    $recorded = "" + (Resolve-PersonalDeployDir -Path $recorded -Recorded).Dir
    if ($recorded -ne ("" + $script:PersonalDeployDir)) { return $false }
    $want = "" + (Get-ExakitManifestValue "runtime.deployment_id")
    $has = "" + (Read-PersonalDeploymentId -Dir ("" + $script:PersonalDeployDir))
    return (-not $want -or -not $has -or ($has -ceq $want))
}

# Set-PersonalRebuildOwner - the rebuild of a database of the user's is about to
# destroy it: runtime.rebuild_path names its folder, so the next database there
# is theirs, in this run or in the one that finishes it, and the old id goes,
# which the next one does not have. Nothing outside that rebuild. Dropped once a database
# of the record answers (Set-PersonalManifest).
function Set-PersonalRebuildOwner {
    if (-not (Test-PersonalRebuildsUserDatabase)) { return }
    $null = Set-ExakitManifestValue "runtime.rebuild_path" ("" + $script:PersonalDeployDir)
    if ($script:PersonalEngine) { $null = Set-ExakitManifestValue "runtime.engine" $script:PersonalEngine }
    if ($null -ne (Get-ExakitManifestValue "runtime.deployment_id")) { Remove-ExakitManifestValue "runtime.deployment_id" }
}

# Test-PersonalRebuildNoted - $true when a rebuild of a database of the user's
# in this very folder was begun and has not brought a new one up yet
# (runtime.rebuild_path, Set-PersonalRebuildOwner): whoever deploys there next,
# the installer run again included, makes the USER's database. Twin of
# _personal_rebuild_noted.
function Test-PersonalRebuildNoted {
    $rebuilt = "" + (Get-ExakitManifestValue "runtime.rebuild_path")
    return ([bool]$rebuilt -and $rebuilt -eq ("" + $script:PersonalDeployDir))
}

# Get-PersonalNewDatabaseOwner - who owns the database a deploy just made: the
# kit, or the user when their own was rebuilt (in this run, or in an earlier
# one that did not finish): it stays theirs, never deleted by uninstall. Twin
# of _personal_new_database_owner.
function Get-PersonalNewDatabaseOwner {
    if (Test-PersonalRebuildNoted) { return "user" }
    if (("" + (Get-Variable -Name ExakitRebuildOwner -Scope Global -ValueOnly -ErrorAction SilentlyContinue)) -eq "user") { return "user" }
    return "kit"
}

$script:PersonalNewNextToTheirs = $false
function Install-PersonalDeployment {
    $script:PersonalPortPicked = 0
    $script:PersonalNewNextToTheirs = $false
    # WHICH DATABASE, before anything acts on one (CONTRACT section 4): the
    # one the kit records, or for a new install a starter-kit-local of its own
    # or of the user's choosing. A rename that did not happen ends the step
    # here, with nothing of theirs changed. Twin of the same first step in
    # personal_deploy_local.
    $choice = "" + (Select-PersonalDatabase)
    if (-not $choice) { $script:PersonalNoDatabase = $true; return }
    $deployed = Test-PersonalDeploymentExists
    if ($deployed) { Set-ExakitReusedOwnership "database" $script:PersonalDeployDir }
    # WHICH ENGINE, BEFORE ANYTHING ELSE IN THIS STEP. A deployment that already
    # exists keeps the engine it was made on - the launcher's rule, and every
    # deployment from before 2.4 is Podman - so the kit only chooses for a
    # fresh one (see Resolve-PersonalEngine). A named engine the machine
    # cannot provide ends this STEP and not the run. Twin of the same gate in
    # personal_deploy_local.
    #
    # A "NOT USABLE" FROM THE COMPATIBILITY GATE IS MINUTES OLD by now (the
    # launcher download ran in between), and Docker Desktop still starting
    # then is often up now: that stale answer made a Podman deployment for
    # good. Asked again here; a "usable" answer stays kept.
    if ($null -ne $script:PersonalDockerCache -and -not $script:PersonalDockerCache.Usable) {
        Clear-PersonalDockerCache
    }
    if (Test-PersonalDeploymentExists) {
        # The record's engine, the deployment's own version or state, or what
        # Docker or Podman lists (Get-PersonalEngineExisting). "" when none can
        # say: then nothing is started, replaced or recorded.
        $script:PersonalEngine = Get-PersonalEngineExisting
        if (-not $script:PersonalEngine) {
            Stop-PersonalEngineUnknown
            $script:PersonalNoDatabase = $true
            return
        }
        # A DOCKER DEPLOYMENT WITH DOCKER DOWN STOPS HERE, before its start,
        # the replace question and the destroy: checked only after them, a
        # consented replace deleted the data and then could not redeploy.
        # Twin of personal_engine_running at the top of personal_deploy_local.
        if ($script:PersonalEngine -eq "docker" -and -not (Test-PersonalEngineRunning "docker")) {
            $script:PersonalNoDatabase = $true
            return
        }
    } elseif ((Test-PersonalRebuildNoted) -and -not ("" + $env:EXAKIT_CONTAINER_ENGINE) -and
              (@("docker", "podman") -contains ("" + (Get-ExakitManifestValue "runtime.engine")))) {
        # The user's, destroyed for a rebuild that was cut short: on the engine
        # it had, written down before the destroy.
        $script:PersonalEngine = "" + (Get-ExakitManifestValue "runtime.engine")
    } elseif (-not (Resolve-PersonalEngine)) {
        $script:PersonalNoDatabase = $true
        return
    }
    if (Test-PersonalDeploymentRunning) {
        # THE DATABASE THIS INSTALL USES, RUNNING: used, with no question.
        # Only `exakit repair-runtime` (EXAKIT_REUSE_DB=0, a new database) on
        # the kit's own declines it, as before: a running database is not
        # replaced, it is stopped first. A database of the user's is replaced
        # only in the rebuild they confirmed (Test-PersonalDatabaseReplaceable).
        # Said first on every reuse, as the sh twin says it.
        Info "An Exasol database is already running on port $(Get-PersonalDbPort)."
        if ($choice -eq "recorded" -and (Test-PersonalReuseDbNew) -and (Test-PersonalDatabaseReplaceable)) {
            # NOT THE END OF THE RUN. The user declined a database, not the kit:
            # nothing has been written and nothing is half made. Same shape as a
            # declined Podman install, and the same flag carries it out.
            Info "Stop it first ('exakit stop'), then re-run the installer to deploy a fresh one - port $(Get-PersonalDbPort) stays in use while it is running: $(Get-ExakitInstallCommand)"
            Set-ExakitFailureReason "Declined to reuse the database already running on port $(Get-PersonalDbPort)"
            $script:PersonalNoDatabase = $true
            return
        }
        Ok "Reusing the existing Exasol deployment"
        Set-PersonalManifest "healthy"
        return
    }

    $neverBootedReplaced = $false
    if ($deployed) {
        # This run's launcher output starts here: the evidence the replace
        # below reads before deleting anything (Test-PersonalStartNetworkBlocked).
        $startLogAt = Get-PersonalLogOffset
        # A FIRST BOOT THE LAUNCHER GAVE UP ON is not a stopped deployment. In
        # "deployment_failed" its start and stop do nothing, so the
        # start-and-reuse path below would report success over a record that
        # stays failed - and every later exakit start would wait on nothing.
        # The launcher's own retry is its deploy; when that gives up on a
        # first boot again, the kit's budget and reconcile take over. Only a
        # database that never answers reaches the ladder below.
        if ((Get-PersonalLauncherState) -eq "deployment_failed" -and -not (Test-PersonalDatabaseReplaceable) -and -not (Test-PersonalRebuildNoted)) {
            # ONLY THE KIT'S OWN DEPLOYMENT IS EVER DEPLOYED AGAIN OR OFFERED
            # FOR REMOVAL (OWN-06). Twin of the same arm in personal_deploy_local.
            Warn2 "The launcher records the deployment at $($script:PersonalDeployDir) as failed. It is not the kit's, so the kit does not deploy it again: repair it with its own launcher, then retry."
            Set-ExakitFailureReason "The deployment at $($script:PersonalDeployDir) is recorded as failed and is not the kit's: repair it with its own launcher, then re-run the installer"
            $script:PersonalNoDatabase = $true
            return
        }
        if ((Get-PersonalLauncherState) -eq "deployment_failed") {
            Info "The launcher records this deployment as failed - retrying its deploy."
            $deployArgs = @("deploy")
            $flag = Get-PersonalAutoApproveFlag "deploy"
            if ($flag) { $deployArgs += $flag }
            $deployArgs += Get-PersonalDeployDirArgs
            $script:ExakitActiveLabel = "Retrying the deployment"
            $script:PersonalContainerError = ""
            $mark = Get-PersonalLogLineCount
            if (((Invoke-ExakitLogged (Get-PersonalCli) @deployArgs) -eq 0) -or (Wait-PersonalSlowFirstBoot)) {
                Ok "Reusing the existing Exasol deployment (deployed again)"
                if (-not (Wait-PersonalReadyOrDeploy)) { $script:PersonalNoDatabase = $true; return }
                Set-PersonalManifest "healthy"
                return
            }
            $script:PersonalLauncherOutput = @(Get-PersonalLogSince $mark)
            Warn2 "The failed deployment could not be brought up.$(Get-PersonalForeignDbHint)"
            [void](Show-PersonalFailureCause)
            # A DEPLOYMENT THAT NEVER STARTED HOLDS NO DATA, so the ladder below
            # asks the wrong questions of it: "start it and keep its data" is a
            # no-op in this state, and "DELETE ... and its data" defaulting to
            # no left the user with nothing either way. The kit made it and has
            # never seen it answer (Test-PersonalFirstBootPending), so it is
            # offered for replacement, default yes - still a consent prompt,
            # still answered by EXAKIT_REPLACE_DB. A deployment that ever
            # answered, one the kit did not make, and an explicit
            # EXAKIT_REUSE_DB=1 all keep the ladder unchanged.
            $reuseAsked = ("" + $env:EXAKIT_REUSE_DB) -cmatch '^(1|y|Y|yes|YES|Yes)$'
            if ((Test-PersonalFirstBootPending) -and -not $reuseAsked -and (Test-PersonalDatabaseReplaceable)) {
                if (-not (Confirm-ExakitEnvPrompt "EXAKIT_REPLACE_DB" "This deployment never started, so it holds no data. Remove it and deploy a fresh one?" $true)) {
                    Info "Nothing was deleted. Diagnose it with 'exakit status', or re-run with EXAKIT_REPLACE_DB=1 to replace it: $(Get-ExakitInstallCommand)"
                    Set-ExakitFailureReason "A deployment that never started could not be brought up, and replacing it was declined"
                    $script:PersonalNoDatabase = $true
                    return
                }
                # A FRESH DEPLOY ON A WSL KERNEL WITHOUT NFTABLES FAILS, so a
                # Podman deployment is checked before its destroy, as the
                # replace below is (Test-PersonalWslPodmanNetworkOk -Replace).
                if ($script:PersonalEngine -ne "docker" -and -not (Test-PersonalWslPodmanNetworkOk -Replace -StartMachine)) {
                    $script:PersonalNoDatabase = $true
                    return
                }
                Info "Removing the deployment that never started, and deploying a fresh one."
                Update-PersonalDeployDir
                Set-PersonalRebuildOwner
                if ((Invoke-ExakitLogged (Get-PersonalCli) destroy --remove --auto-approve --deployment-dir $script:PersonalDeployDir) -ne 0) {
                    Warn2 "Could not fully remove the old deployment; the launcher will deploy over it."
                }
                $neverBootedReplaced = $true
            }
        }
    }
    if ($deployed -and -not $neverBootedReplaced) {
        # THE DATABASE THIS INSTALL USES, STOPPED: started with no question.
        # The kit's own resumes (the installer run again), and a database of
        # the user's (renamed a moment ago, or recorded earlier) is started as
        # it is. Only EXAKIT_REUSE_DB=0 (`exakit repair-runtime`) skips the
        # start of the kit's own, for the replace below.
        $userDatabase = -not (Test-PersonalDatabaseReplaceable)
        # Said after the one question's rename too, as the sh twin says it.
        Info "An Exasol deployment was found, not running."
        if ($userDatabase -or -not (Test-PersonalReuseDbNew)) {
            Show-PersonalGuestRebuildNote
            $startArgs = @("start")
            $flag = Get-PersonalAutoApproveFlag "start"
            if ($flag) { $startArgs += $flag }
            $startArgs += Get-PersonalDeployDirArgs
            if ((Test-PersonalLauncherSupports "start") -and ((Invoke-ExakitLogged (Get-PersonalCli) @startArgs) -eq 0)) {
                Ok "Reusing the existing Exasol deployment (started)"
                # NOT "started, therefore running": the launcher accepts a start
                # for a deployment it has only initialized, does nothing, and
                # the kit then waits its whole budget for it.
                if (-not (Wait-PersonalReadyOrDeploy)) { $script:PersonalNoDatabase = $true; return }
                Set-PersonalManifest "healthy"
                return
            }
            Warn2 "The existing deployment could not be started."
        }
        # NO PATH DESTROYS WITHOUT THIS CONSENT - not even a failed start. A
        # deployment that will not start today may hold months of data and be
        # one diagnosis away from starting tomorrow; deleting it is the user's
        # call, made with the consequence in front of them.
        #
        # AND NO DESTROY THAT THE REBUILD CANNOT FOLLOW. Replacing a Podman
        # deployment deploys afresh, and on a WSL kernel without nftables that
        # fresh deploy fails at its first network - after the data is gone.
        # So the WSL check runs here, before the question and the destroy
        # (exakit repair-runtime lands here too): refused, nothing is deleted.
        # Twin of the same check in personal_deploy_local. -Replace: a
        # release that cannot be read refuses here too, and the check says
        # the one "Nothing was deleted" line itself.
        # -StartMachine: a stopped Podman machine is started to read its
        # firewall driver when the release says no - still here, before the
        # question and the destroy.
        #
        # THE START'S OWN EVIDENCE FIRST. When this run's start (or deploy
        # retry) failed on netavark's nftables error, a rebuild meets the same
        # kernel whatever the release reads (a WSL 2.7 with a custom kernel, an
        # unreadable release cleared with EXAKIT_WSL_CHECKED=1): refused,
        # nothing deleted, the start's own next step named. Twin of the same
        # check in personal_deploy_local.
        if ($script:PersonalEngine -ne "docker" -and (Test-PersonalStartNetworkBlocked -LogOffset $startLogAt)) {
            Warn2 (Get-PersonalStartNetworkText)
            Info "Nothing was deleted: the deployment and its data stay."
            Set-ExakitFailureReason (Get-PersonalStartNetworkText)
            $script:PersonalNoDatabase = $true
            return
        }
        # NEVER ASKED ABOUT A DATABASE OF THE USER'S: the kit never deletes or
        # replaces one, so the replace question below is not put to them (the
        # start's own evidence above is still said first). The question used
        # to be asked first and refused after. Twin of the same arm in
        # personal_deploy_local.
        if ($userDatabase) {
            Info "Nothing was deleted. This database is yours, so the kit never deletes it. Start it with 'exakit start', or diagnose it with 'exakit status'."
            Set-ExakitFailureReason "A stopped deployment of yours could not be started. The kit never deletes it"
            $script:PersonalNoDatabase = $true
            return
        }
        # ONLY WHEN A REPLACE CAN HAPPEN. With no consent given
        # (EXAKIT_REPLACE_DB unset) and no console to ask on, the question
        # below answers no by itself, so a refusal for a replace nobody asked
        # for only hid the real advice ("Start it yourself ..."). With a
        # console the check stays BEFORE the question, by design: a yes it
        # would then refuse is not a question worth asking. Twin of
        # _pdl_consent_possible in personal_deploy_local.
        $replaceConsentPossible = $false
        $replacePreset = "" + $env:EXAKIT_REPLACE_DB
        if ($replacePreset -cmatch '^(1|y|Y|yes|YES|Yes)$') { $replaceConsentPossible = $true }
        elseif ($replacePreset -cmatch '^(0|n|N|no|NO|No)$') { $replaceConsentPossible = $false }
        elseif (Test-ExakitInteractive) { $replaceConsentPossible = $true }
        if ($replaceConsentPossible -and $script:PersonalEngine -ne "docker" -and -not (Test-PersonalWslPodmanNetworkOk "exakit start" -Replace -StartMachine)) {
            $script:PersonalNoDatabase = $true
            return
        }
        if (-not (Confirm-ExakitEnvPrompt "EXAKIT_REPLACE_DB" "DELETE the stopped deployment and its data, and deploy a fresh one? This cannot be undone." $false)) {
            Info "Nothing was deleted. Start it yourself with 'exakit start', diagnose with 'exakit status', repair with 'exakit repair-runtime' - or re-run with EXAKIT_REPLACE_DB=1 to replace it, deleting its data."
            Set-ExakitFailureReason "A stopped deployment could not be started, and deleting it was declined"
            $script:PersonalNoDatabase = $true
            return
        }
        if (-not (Test-PersonalDatabaseReplaceable)) {
            Fail "The user-owned deployment could not start. Repair it outside the kit; it was not replaced."
        }
        Info "Replacing the existing deployment - its previous data is not recoverable."
        # --auto-approve: destroy has its own [y/N] prompt, which a piped or
        # scripted install cannot answer; the consent came from the explicit
        # replace question (or EXAKIT_REPLACE_DB=1) just above.
        Set-PersonalRebuildOwner
        if (-not (Invoke-PersonalDestroy)) {
            Warn2 "Could not fully remove the old deployment (the launcher said: $($script:PersonalDestroyError)); it will deploy over it."
        }
    } elseif ($script:PersonalEngine -ne "docker") {
        # A FRESH Podman deployment on a WSL kernel without nftables fails at
        # its first network, after the download: refused here instead, with
        # the fix named - and BEFORE Test-PersonalPodmanRunning below, which
        # starts a stopped machine. The compatibility gate may already have
        # asked; its verdict is used, not
        # asked again. A replaced deployment was checked before its destroy.
        # -StartMachine: only when the release says no is the machine asked
        # for its firewall driver, and a stopped one (every reboot) is started
        # for that first - it could not answer stopped, and the gate does not
        # start it. A definite answer from the gate is kept, not asked again.
        # Twin of the same gate in personal_deploy_local.
        # The gate's verdict was reached quietly, before the engine was final
        # (a stopped Docker can still be started at the prompt): a pass is
        # used as it is, and a refusal is SAID here, once, now that the run
        # is known to deploy on Podman.
        $wslOk = $script:PersonalWslVerdict
        if ($wslOk -ne $true) {
            $wslOk = Test-PersonalWslPodmanNetworkOk -StartMachine
        } elseif ($script:PersonalWslUnread) {
            Write-PersonalWslUnreadWarning
        }
        $script:PersonalWslVerdict = $null
        $script:PersonalWslUnread = $false
        if (-not $wslOk) {
            $script:PersonalNoDatabase = $true
            return
        }
    }

    # THE NEW DATABASE'S OWN PORT (D3). A launcher that takes --ports (2.5.0)
    # is handed one the kit picked (Select-PersonalDbPort): 8563, or the next
    # free one when a database of the user's has it, running or stopped. So a
    # user's database on 8563 no longer stops the install, and nothing on the
    # port is ever taken for the kit's. A launcher without the flag picks its
    # own, and the check of the port it would prefer stays as it was. Twin of
    # the port pick in personal_deploy_local.
    $script:PersonalPortPicked = 0
    if (Test-PersonalLauncherTakesPorts) {
        $picked = Select-PersonalDbPort
        if (-not $picked) {
            Warn2 "No port from 8563 to 8663 is free for the starter kit's database: each is in use, or saved by another Exasol Personal database."
            Info "Free one of them (stop a database you do not need), then re-run the installer: $(Get-ExakitInstallCommand)"
            Set-ExakitFailureReason "No port from 8563 to 8663 is free for the starter kit's database"
            $script:PersonalNoDatabase = $true
            return
        }
        $script:PersonalPortPicked = $picked
    } elseif (Test-ExakitPortInUse (Get-PersonalDbPort)) {
        Warn2 "Port $(Get-PersonalDbPort) is in use by a process that is not a reachable Exasol Personal deployment.$(Get-PersonalForeignDbHint)"
        Info "Stop that application, then re-run the installer (EXAKIT_DB_PORT does not choose the port of a personal deployment): $(Get-ExakitInstallCommand)"
        Set-ExakitFailureReason "Port $(Get-PersonalDbPort) is held by something that is not an Exasol Personal deployment"
        $script:PersonalNoDatabase = $true
        return
    }

    # The progress bar narrates the deploy and the spinner narrates the health
    # probe, so the info/ok pairs underneath are the second telling. Twin of the
    # bracket in personal_deploy_local.
    $prevDeployQuiet = $script:ExakitQuietDetail
    if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }

    # try/finally, not a plain restore at the end: Fail throws, this runs
    # inside a step that can be soft, and a caught throw would leave the flag
    # set and silence every step after it. Same shape mcp.ps1 uses, for the
    # same reason.
    try {

    Info "Exasol Personal is free to use and ships under Exasol's own licence terms, not the kit's MIT licence. The launcher shows them below."
    # Next to an Exasol Personal of the user's: theirs is not touched. Twin of
    # the same line in personal_deploy_local.
    if ($script:PersonalNewNextToTheirs) { Info "Deploying the starter kit's own database '$(Get-PersonalDeploymentName)'. Your Exasol Personal is not changed." }
    # PODMAN IS NAMED WHEN IT IS MISSING, not in a clause on every deploy.
    # Windows does not install it the way the sh side does - the LAUNCHER does,
    # through winget, as part of `install local` - so the kit's job here is to
    # say what is about to happen and what to do if the machine refuses it.
    # That refusal is real: an unelevated winget on a managed laptop fails, and
    # the first the user heard of it was the launcher's own error, mid-deploy,
    # with no mention of Podman at all. Twin of personal_install_podman, which
    # does the installing itself where the kit owns that job.
    if ($script:PersonalEngine -eq "docker") {
        # Probed usable a moment ago by Resolve-PersonalEngine, or named by an
        # existing deployment's record: either way it has to answer now.
        if (-not (Test-PersonalEngineRunning "docker")) {
            $script:PersonalNoDatabase = $true
            return
        }
        Info "Deploying Exasol Personal locally - the database runs on Docker."
    } elseif (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        Warn2 "Podman is not installed on this machine, and the database runs through it."
        Info "The Exasol launcher installs it as part of this step, and Windows may ask for administrator approval."
        Info "If that is refused or fails: install it yourself with 'winget install RedHat.Podman' (a reboot may be needed), then re-run the installer."
    } elseif (-not (Test-PersonalPodmanRunning)) {
        # Installed, and still no database: same soft failure as a podman that
        # was never installed, because the user is in the same position - one
        # command away from a database, and better told now than after the
        # launcher has spent five minutes discovering it.
        Set-ExakitFailureReason "Podman is installed but not usable ('podman info' failed; its machine may be stopped)"
        $script:PersonalNoDatabase = $true
        return
    }
    if ($script:PersonalEngine -ne "docker") {
        # The WSL check already ran, before any Podman-machine work (above).
        Info "Deploying Exasol Personal locally - the database runs through Podman's default machine, which the launcher prepares."
    }

    $installArgs = @("install", "local")
    $flag = Get-PersonalAutoApproveFlag "install"
    if ($flag) { $installArgs += $flag }
    $installArgs += Get-PersonalEngineFlag $script:PersonalEngine
    if ($script:PersonalPortPicked) { $installArgs += @("--ports", "db:$($script:PersonalPortPicked)") }
    $installArgs += Get-PersonalDeployDirArgs
    $script:ExakitActiveLabel = "Deploying Exasol Personal locally"
    $script:PersonalContainerError = ""
    # Keep first-boot recovery and ownership as separate records: only a new
    # deployment created by this install becomes kit-owned.
    Set-PersonalFirstBootPending $true
    $freshDeployment = -not (Test-PersonalDeploymentExists)
    $installResult = Invoke-PersonalInstallLocal $installArgs
    if ($freshDeployment -and (Test-PersonalDeploymentExists)) {
        Set-ExakitComponentOwnership "database" (Get-PersonalNewDatabaseOwner) $script:PersonalDeployDir
        # With its id: the one a deployment in this folder must carry to be
        # the kit's (Get-ExakitComponentOwnership), even if the run ends here.
        $newId = "" + (Get-PersonalDeploymentId)
        if ($newId) { $null = Set-ExakitManifestValue "runtime.deployment_id" $newId }
    }
    if ($installResult -ne 0) {
        # A DEPLOYMENT THAT EXISTS IS GIVEN THE KIT'S OWN BUDGET FIRST: the
        # launcher waits 27 seconds for a first boot, and a first boot in a
        # fresh Podman machine takes longer. Twin of the same branch in
        # personal_deploy_local; see Wait-PersonalSlowFirstBoot.
        if (-not ((Test-PersonalDeploymentExists) -and (Wait-PersonalSlowFirstBoot))) {
            # THE LIKELIEST CAUSE FIRST. A deploy that fails with Podman still
            # missing failed at installing Podman, and "Local deployment
            # failed" sends the reader to look at the database instead.
            if (($script:PersonalEngine -ne "docker") -and -not (Get-Command podman -ErrorAction SilentlyContinue)) {
                # NOT Fail. This is the one deployment failure the install can
                # carry on from, and the twin of personal_deploy_local's single
                # non-zero return: nothing has been created, nothing is half
                # written, and the steps that do not need a database still have
                # value. The flag - not a return value - because this function
                # returns bare on four reuse paths, and an `if (Install-...)`
                # caller would read every one of them as a failure.
                Warn2 "Local deployment failed, and Podman is still not installed - that is what the launcher could not do."
                Info "Install it yourself with 'winget install RedHat.Podman' (a reboot may be needed), then re-run the installer: $(Get-ExakitInstallCommand)"
                Set-ExakitFailureReason "Podman is not installed and the launcher could not install it (winget install RedHat.Podman)"
                $script:PersonalNoDatabase = $true
                return
            }
            Warn2 "Local deployment failed.$(Get-PersonalForeignDbHint)"
            # WHAT ACTUALLY WENT WRONG, which "Local deployment failed" never
            # said: the launcher's last lines, the container's own error, and
            # the fix when the kit knows it. Twin of _personal_deploy_print_tail
            # and personal_explain_failure.
            Show-PersonalLauncherTail
            $cause = Show-PersonalFailureCause
            Show-PersonalPodmanRootfulHint
            # The INSTALLER, not `exakit update`: update only moves components
            # that have a newer advertised version, so a deployment that never
            # happened is "already current" to it - and on the Nano-to-Personal
            # crossing the manifest still names nano, which it skips outright.
            # A re-run resumes at this step. Twin of personal_deploy_local.
            Info "Retry it by re-running the installer - completed steps are skipped: $(Get-ExakitInstallCommand)"
            Set-ExakitFailureReason "The launcher could not deploy the database locally$cause"
            $script:PersonalNoDatabase = $true
            return
        }
    }

    if (-not (Wait-PersonalReadyOrDeploy)) {
        $script:PersonalNoDatabase = $true
        return
    }
    } finally {
        $script:ExakitQuietDetail = $prevDeployQuiet
    }
    Update-PersonalDeployDir
    Set-ExakitComponentOwnership "database" (Get-PersonalNewDatabaseOwner) $script:PersonalDeployDir
    Ok "Exasol Personal deployed and answering on 127.0.0.1:$(Get-PersonalDbPort)"
    $script:PersonalRecordFresh = $true
    Clear-PersonalDatabaseSteps
    Set-PersonalManifest "healthy"
}

# Clear-PersonalDatabaseSteps - drop the ticks of the two steps whose work lives
# in the database or is derived from its password: the exapump profile and the
# MCP read-only user. A fresh deployment is a new database with its own users
# and, from Exasol Personal 2.4, its own random sys password; a re-run over it
# used to skip both steps as "already done" and leave `exakit sql` answering
# "Authentication failed". Twin of personal_forget_database_steps.
function Clear-PersonalDatabaseSteps {
    if (-not (Get-Command Remove-ExakitStepDone -ErrorAction SilentlyContinue)) { return }
    foreach ($step in @("exapump", "mcp")) {
        try { Remove-ExakitStepDone $step } catch { }
    }
}

# The launcher gave up on a first boot that was merely slow: wait with the kit's
# budget and reconcile the launcher's record with its own `deploy` retry. When
# the launcher records deployment_failed, its stop and start do nothing, so a
# database that came up ten seconds too late read as a failed install and every
# later `exakit start` waited 150 s for nothing. $false only when the database
# never answered. Twin of personal_recover_slow_first_boot.
function Wait-PersonalSlowFirstBoot {
    $budget = 150
    if ($env:EXAKIT_PERSONAL_READY_TIMEOUT) { $budget = [int]$env:EXAKIT_PERSONAL_READY_TIMEOUT }
    Info "The launcher stopped waiting after its own short budget, but the deployment exists - waiting up to ${budget}s for the database"
    $t0 = [DateTime]::UtcNow
    $lastLook = $t0
    $script:PersonalContainerError = ""
    while (-not (Test-PersonalTlsAnswers)) {
        if (([DateTime]::UtcNow - $t0).TotalSeconds -ge $budget) { return $false }
        # The same early exit as Test-PersonalReadyProbe: a container that
        # refused to start is not slow.
        if (([DateTime]::UtcNow - $lastLook).TotalSeconds -ge $script:PersonalContainerLookEvery) {
            $lastLook = [DateTime]::UtcNow
            if (Test-PersonalContainerRefused) { return $false }
        }
        Start-Sleep -Seconds 5
    }
    Ok "The database answered after $([int]([DateTime]::UtcNow - $t0).TotalSeconds)s"
    Set-PersonalFirstBootPending $false
    # THE RECONCILE IS THE OWNERSHIP PROOF. A handshake says a database answers
    # on the port, not whose: with Windows and WSL sharing one network stack it
    # may be the other side's. The launcher's deploy connects with this
    # deployment's own credentials, so its success is the one signal that the
    # database that answered is this one - and its failure is a failure, not a
    # database "the kit can reach".
    $deployArgs = @("deploy")
    $flag = Get-PersonalAutoApproveFlag "deploy"
    if ($flag) { $deployArgs += $flag }
    $deployArgs += Get-PersonalDeployDirArgs
    $script:ExakitActiveLabel = "Reconciling the launcher's record"
    if ((Invoke-ExakitLogged (Get-PersonalCli) @deployArgs) -eq 0) {
        Ok "The launcher's record agrees with the running database"
        return $true
    }
    Warn2 "The launcher still records this deployment as failed although something answers on port $(Get-PersonalDbPort).$(Get-PersonalForeignDbHint)"
    return $false
}

# Start-Personal / Stop-Personal - launcher start/stop with the same say-what-
# to-do-next failure messages as the sh twins. Stop leaves Podman's machine
# alone by design: it is shared host-wide and not this kit's to manage.
# Test-PersonalStartNetworkBlocked [log offset] - a failed start (or deploy)
# failed because WSL cannot build the 2.4 deployment network: the deployment
# runs on Podman through its WSL machine AND the launcher's output since
# <log offset> carries netavark's own nftables failure. Twin of
# _personal_start_network_blocked.
#
# EVIDENCE, NOT A GUESS. A WSL release below 2.7 alone used to be enough, and
# a stopped Podman machine, a held port or a 2.3 deployment that never needed
# nftables was then told to update WSL, past the arms that name the real
# cause. A Hyper-V Podman machine never runs on the WSL kernel, and a benign
# "nftables not available, falling back" line is not the failure.
function Test-PersonalStartNetworkBlocked {
    param([int]$LogOffset = -1)
    if ((Get-PersonalEngineRecorded) -ne "podman") { return $false }
    if ("$env:CONTAINERS_MACHINE_PROVIDER" -eq "hyperv") { return $false }
    if ($LogOffset -lt 0 -or -not $script:LogFile -or -not (Test-Path -LiteralPath $script:LogFile)) { return $false }
    try {
        $since = @(Get-Content -LiteralPath $script:LogFile -ErrorAction Stop | Select-Object -Skip $LogOffset)
        foreach ($line in $since) {
            if ("$line" -match '(?i)nft.*(did not return successfully|applying ruleset)') { return $true }
        }
    } catch { }
    return $false
}

# Get-PersonalStartNetworkText - the one wording for every caller of the check
# above: the Fail below, and the callers that record it without ending the run
# (Wait-PersonalReadyOrDeploy, the replace refusal in Install-PersonalDeployment).
# NOT repair-runtime: it destroys the deployment first and its fresh deploy
# meets the same kernel. The iptables alternative is named where it lives on
# Windows: inside Podman's machine. "wsl --update" and "cannot create the
# deployment network" stay in it - status and the update remedy key on both.
# Twin of _personal_start_network_text.
function Get-PersonalStartNetworkText {
    return "This WSL kernel cannot create the deployment network: run wsl --update, then wsl --shutdown, then exakit start. Without updating WSL: set firewall_driver = `"iptables`" under [network] in the containers.conf inside Podman's machine (podman machine ssh), then exakit start. The deployment and its data are untouched; do not repair-runtime, a rebuild meets the same kernel."
}

# Stop-PersonalStartNetworkBlocked - the Fail for the check above, in
# Get-PersonalStartNetworkText's words. Twin of _personal_start_network_die.
#
# THE NOTE IS WRITTEN HERE, NOT LEFT TO Fail: Fail notes only inside the
# installer, and `exakit start` is not one - so status --json answered
# "exakit start" after this very refusal, and the agent looped on it. The
# shell's die always notes.
function Stop-PersonalStartNetworkBlocked {
    $msg = Get-PersonalStartNetworkText
    if (-not $script:ExakitRecordFailureNotes) { Write-ExakitFailureNote $msg }
    Fail $msg
}

function Get-PersonalLogOffset {
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        try { return @(Get-Content -LiteralPath $script:LogFile -ErrorAction Stop).Count } catch { }
    }
    return -1
}

# Set-PersonalStartedRecord - what a start the launcher took changes in the
# record: runtime.status (Stop-Personal writes "stopped"). Not
# runtime.deployment_version: a deployment keeps the version that created it,
# after its first start under a newer launcher too (live re-test F-02). Never
# fails the start. Twin of _personal_record_started.
function Set-PersonalStartedRecord {
    try {
        Set-ExakitManifestValue "runtime.status" "running"
    } catch { }
    Clear-PersonalStartOwed
}

function Start-Personal {
    Update-PersonalDeployDir
    # NEVER ANOTHER DEPLOYMENT: with the kit's own gone, the folder in use can
    # be the user's (Get-ExakitPersonalDbState). Refused before any launcher call.
    if (-not (Test-ExakitKitDatabaseGuard)) { return }
    # A DOCKER DEPLOYMENT NEEDS DOCKER UP. Without it the launcher's start
    # fails, and the failure arm below used to name repair-runtime - which
    # destroys the data and still cannot start Docker. Twin of the same check
    # at the top of personal_start.
    if ((Get-PersonalEngineRecorded) -eq "docker" -and -not (Test-PersonalDockerUsable)) {
        Fail "The database runs on Docker, and $($script:PersonalDockerSaid). Start Docker Desktop, then: exakit start"
    }
    $logOffset = Get-PersonalLogOffset
    if (-not (Test-PersonalLauncherSupports "start")) {
        Info "This launcher version has no explicit start command."
        Info "Check the database with: $(Get-PersonalCli) info --deployment-dir $($script:PersonalDeployDir)"
        return
    }
    # PODMAN FIRST. After a reboot its machine is off, and a start against it
    # fails inside the launcher naming neither: Test-PersonalPodmanRunning
    # starts a machine that is merely stopped, so `exakit start` (and
    # autostart) names a Podman that cannot run instead of waiting on it.
    # Docker was checked above. Twin of the same check in personal_start.
    if ((Get-PersonalEngineRecorded) -ne "docker" -and (Get-PersonalPodman) -and -not (Test-PersonalPodmanRunning)) {
        Fail "Podman is installed but not usable ('podman info' failed; its machine may be stopped). Once that is fixed: exakit start"
    }
    # In "deployment_failed" the launcher's start (and stop) do nothing and
    # exit 0, so this reported "Database started" over a database that was
    # never asked to start and then waited its whole budget for it. The
    # launcher's own retry for that state is its deploy.
    if ((Get-PersonalLauncherState) -eq "deployment_failed") {
        # Only the kit's own is deployed again (OWN-06): one the user adopted
        # is named and left to its own launcher. Twin of personal_start.
        if (-not (Test-ExakitComponentManaged "database") -and -not (Test-PersonalRebuildNoted)) {
            Fail "The launcher records the deployment at $($script:PersonalDeployDir) as failed. It is not the kit's, so the kit does not deploy it again: repair it with its own launcher, then: exakit start"
        }
        Info "The launcher records this deployment as failed - retrying its deploy instead of a start it would ignore."
        $deployArgs = @("deploy")
        $flag = Get-PersonalAutoApproveFlag "deploy"
        if ($flag) { $deployArgs += $flag }
        $deployArgs += Get-PersonalDeployDirArgs
        $mark = Get-PersonalLogLineCount
        $script:PersonalContainerError = ""
        if ((Invoke-ExakitLogged (Get-PersonalCli) @deployArgs) -eq 0) {
            Ok "Database started"
            Set-PersonalStartedRecord
            return
        }
        if (Test-PersonalStartNetworkBlocked -LogOffset $logOffset) { Stop-PersonalStartNetworkBlocked }
        Show-PersonalPodmanRootfulHint
        $script:PersonalLauncherOutput = @(Get-PersonalLogSince $mark)
        Show-PersonalLauncherTail
        $cause = Show-PersonalFailureCause
        Fail "The deployment could not be brought up$cause.$(Get-PersonalForeignDbHint) Check the log; if it fails the same way, repair with: exakit repair-runtime"
    }
    Show-PersonalGuestRebuildNote
    $startArgs = @("start")
    $flag = Get-PersonalAutoApproveFlag "start"
    if ($flag) { $startArgs += $flag }
    $startArgs += Get-PersonalDeployDirArgs
    # Docker mounts a language container read-only: its DNS links go into the
    # image, before the start that mounts it - see Initialize-PersonalSlcDns.
    try { Initialize-PersonalSlcDns } catch { Write-ExakitLog "WARN" "language container DNS before the start: $_" }
    if ((Invoke-ExakitLogged (Get-PersonalCli) @startArgs) -ne 0) {
        # THE NETWORK FIRST: the arms below would send the reader to
        # repair-runtime, which cannot fix a WSL kernel without nftables.
        if (Test-PersonalStartNetworkBlocked -LogOffset $logOffset) { Stop-PersonalStartNetworkBlocked }
        if (Test-PersonalDeploymentWedged) {
            Fail "The database is interrupted and cannot be started - the launcher has to rebuild it. Repair it with: exakit repair-runtime (this rebuilds the database from empty; its data is not recoverable)."
        }
        if ((Get-PersonalStatus) -eq "conflict") {
            Fail "Port $(Get-PersonalDbPort) is held by another process, so the database cannot start. Stop that process, then: exakit start"
        }
        Show-PersonalPodmanRootfulHint
        $script:PersonalContainerError = ""
        $cause = Show-PersonalFailureCause
        Fail "Failed to start the database$cause. Check the log, then retry with 'exakit start'; if it fails the same way, repair with: exakit repair-runtime"
    }
    Ok "Database started"
    Set-PersonalStartedRecord
    # Every start rebuilds the language containers from their images, and with
    # them their empty DNS files - see Repair-PersonalSlcDns.
    $script:PersonalSlcDnsNeedsStart = $false
    try { [void](Repair-PersonalSlcDns) } catch { Write-ExakitLog "WARN" "language container DNS repair: $_" }
    if ($script:PersonalSlcDnsNeedsStart) {
        # Docker, and an image the launcher pulled during this start: it is
        # linked now, and only a start mounts it. Once - the next one finds it
        # linked before it starts.
        Info "Restarting the database once, so Java in it can resolve host names"
        if ((Invoke-ExakitLogged (Get-PersonalCli) stop --deployment-dir $script:PersonalDeployDir) -ne 0 -or (Invoke-ExakitLogged (Get-PersonalCli) @startArgs) -ne 0) {
            Fail "The database did not come back from its restart. Start it with: exakit start"
        }
        try { [void](Repair-PersonalSlcDns) } catch { Write-ExakitLog "WARN" "language container DNS repair: $_" }
    }
}

# Get-PersonalSlcInstalledFlavors - the official language containers the
# launcher reports installed (java-17, python-3.12, ...). Twin of
# personal_slc_installed_flavors.
function Get-PersonalSlcInstalledFlavors {
    Update-PersonalDeployDir
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $text = (& (Get-PersonalCli) slc list --json --deployment-dir $script:PersonalDeployDir 2>$null) -join "`n"
    } catch { return @() } finally { $ErrorActionPreference = $previous }
    $at = $text.IndexOf("[")
    if ($at -lt 0) { return @() }
    try { $rows = @($text.Substring($at) | ConvertFrom-Json) } catch { return @() }
    $flavors = @()
    foreach ($row in $rows) {
        foreach ($item in @($row)) {
            if ($item.installed -and $item.type -eq "official" -and $item.flavor) { $flavors += "$($item.flavor)" }
        }
    }
    return $flavors
}

# Get-PersonalSlcContainerId - the deployment id the launcher names its
# database container by (exasol-db-<id>), trimmed; "" when no state file names
# one. The launcher's own state first: ContainerName reads
# .exasolLauncherState.json, and deployment.json can be older than it, or say
# "local" (what the launcher writes there when it cannot read its state). Read
# as JSON, the top-level key only. Twin of personal_slc_container_id.
function Get-PersonalSlcContainerId {
    Update-PersonalDeployDir
    return (Read-PersonalDeploymentId -Dir $script:PersonalDeployDir)
}

# Get-PersonalSlcDnsEngine - the engine the repair asks: the RECORD first (a
# nano record's engine - runtime.container present, even null - is the old
# database's), then this run's choice when nothing is recorded (an install
# that has not recorded it yet), then Podman, every deployment before kit
# 0.2.4. Twin of personal_slc_dns_engine.
function Get-PersonalSlcDnsEngine {
    $engine = ""
    $runtime = $null
    try { $doc = Read-ExakitManifest; if ($doc) { $runtime = $doc.runtime } } catch { $runtime = $null }
    if ($runtime -and -not ($runtime -is [string])) {
        $recorded = $runtime.PSObject.Properties["engine"]
        if ($recorded) { $engine = "" + $recorded.Value }
        $nano = $runtime.PSObject.Properties["container"]
        if ($nano -and (($null -eq $nano.Value) -or (("" + $nano.Value) -ne ""))) { $engine = "" }
    }
    if ($engine -ne "docker" -and $engine -ne "podman") { $engine = "" + $script:PersonalEngine }
    if ($engine -eq "docker") { return "docker" }
    return "podman"
}

# Initialize-PersonalSlcDns [-Pull] - before a start on Docker: link every
# official language container IMAGE the launcher state lists (installedSlcs)
# through setup/lib/personal-slc-dns.py --prepare. Docker mounts an image
# read-only, so the links Repair-PersonalSlcDns writes into the running
# container on Podman have to be in the image the start mounts; the image is
# committed back under the tag the launcher mounts, once, and labelled, so a
# later start asks one `docker image inspect` and nothing more. -Pull first
# pulls an image that is not here yet (the Java install, whose start would
# otherwise pull it and mount it unlinked). Podman: nothing - its mount is
# writable and repaired after the start. Best effort: logged, and never fails
# the start. Twin of personal_slc_dns_prepare.
function Initialize-PersonalSlcDns {
    param([switch]$Pull)
    Update-PersonalDeployDir
    if ((Get-PersonalSlcDnsEngine) -ne "docker") { return }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
    $state = Join-Path $script:PersonalDeployDir ".exasolLauncherState.json"
    if (-not (Test-Path -LiteralPath $state)) { return }
    $helper = Join-Path $PSScriptRoot "personal-slc-dns.py"
    $helperArgs = @("--engine", "docker", "--prepare", $state)
    if ($Pull) { $helperArgs += "--pull" }
    # The helper's own budget: nothing bounds it from outside on Windows, and
    # it ends - its containers removed - within it (a pull is outside it).
    $helperArgs += @("--budget", "240")
    $result = Invoke-ExakitPythonFile -Path $helper -Arguments $helperArgs
    $answered = $false
    foreach ($line in @($result.Lines)) {
        if ($line -match '^EXAKIT_SLC_DNS (\S+) (\S+)$') {
            $answered = $true
            Write-ExakitLog "INFO" "language container DNS (before the start): $($Matches[1]):$($Matches[2])"
            if ($Matches[2] -eq "derived") { Info "Gave the $($Matches[1]) language container image the deployment's DNS" }
        }
    }
    # It always answers ("- none" when nothing is installed): silence is a run
    # that did not happen or died - one line with the reason, as the repair
    # leaves. Twin of the same line in personal_slc_dns_prepare.
    if (-not $answered) {
        $first = @(@($result.Lines) | Where-Object { "$_".Trim() }) | Select-Object -First 1
        if (-not $first) { $first = "no output (its stderr is in the PY lines above)" }
        $first = "$first"
        if ($first.Length -gt 200) { $first = $first.Substring(0, 200) }
        Write-ExakitLog "WARN" "language container DNS before the start did not run (exit $($result.Code)): $first"
    }
}

# Repair-PersonalSlcDns - give every installed official language container the
# deployment's DNS. The official containers ship etc/resolv.conf and etc/hosts
# empty, so Java code in the database - every virtual schema adapter - can
# reach an IP address and resolve no name; the database mounts the real files
# at /conf, and setup/lib/personal-slc-dns.py points the container's at them
# through the deployment's own engine (Get-PersonalSlcDnsEngine): Podman's CLI
# cannot see a Docker container. Only this deployment's database container is
# written to: exasol-db-<id> (Get-PersonalSlcContainerId), or without an id a
# lone exasol-db-* that is not a sidecar. Every start rebuilds the
# containers, so this runs after every start. Best effort: returns $false and
# logs when it cannot. On Docker, an image linked (or found linked) under a
# database started before it was - also beside another flavor that failed -
# returns $false and sets
# $script:PersonalSlcDnsNeedsStart: the fix is in the image, and the database
# sees it from its next start - the caller restarts it, or says so. Twin of
# personal_slc_dns_repair (its exit 2).
function Repair-PersonalSlcDns {
    $script:PersonalSlcDnsNeedsStart = $false
    # Its restart and its writes go to the kit's own deployment only.
    if (-not (Test-ExakitKitDatabaseGuard)) { return $false }
    $flavors = @(Get-PersonalSlcInstalledFlavors)
    if ($flavors.Count -eq 0) { return $true }
    $engine = Get-PersonalSlcDnsEngine
    if (-not (Get-Command $engine -ErrorAction SilentlyContinue)) {
        Write-ExakitLog "WARN" "language container DNS: no $engine on PATH"
        return $false
    }
    $helper = Join-Path $PSScriptRoot "personal-slc-dns.py"
    # No empty argument: Windows PowerShell 5.1 drops it on the way to python.
    # The id in the = form: one that starts with "-" is still a value.
    # The helper's own budget, the shell's bound (300 s Docker, 90 s Podman)
    # less 60: Docker links an image (240 s), Podman writes into the
    # container (30 s).
    $budget = "30"
    if ($engine -eq "docker") { $budget = "240" }
    $helperArgs = @("--engine", $engine, "--budget", $budget)
    $id = "" + (Get-PersonalSlcContainerId)
    if ($id) { $helperArgs += @("--deployment-id=$id") }
    $result = Invoke-ExakitPythonFile -Path $helper -Arguments (@($helperArgs) + @($flavors))
    $ok = ($result.Code -eq 0)
    $answered = $false
    $derived = $false
    foreach ($line in @($result.Lines)) {
        if ($line -match '^EXAKIT_SLC_DNS (\S+) (\S+)$') {
            $answered = $true
            Write-ExakitLog "INFO" "language container DNS: $($Matches[1]):$($Matches[2])"
            if ($Matches[2] -eq "repaired") { Info "Gave the $($Matches[1]) language container the deployment's DNS" }
            if ($Matches[2] -eq "derived") {
                $derived = $true
                Info "Gave the $($Matches[1]) language container image the deployment's DNS; the database sees it from its next start"
            }
            if ($Matches[2] -eq "failed") { Write-ExakitLog "WARN" "language container DNS could not be given to $($Matches[1])" }
            if ($Matches[2] -eq "nocontainer") { $ok = $false }
        }
    }
    # A repair that never answered leaves one line with the reason: every
    # caller ignores the result. Twin of the same line in personal_slc_dns_repair.
    if (-not $answered) {
        $first = @(@($result.Lines) | Where-Object { "$_".Trim() }) | Select-Object -First 1
        if (-not $first) { $first = "no output (its stderr is in the PY lines above)" }
        $first = "$first"
        if ($first.Length -gt 200) { $first = $first.Substring(0, 200) }
        Write-ExakitLog "WARN" "language container DNS repair did not run (exit $($result.Code)): $first"
        $ok = $false
    }
    # A linked image wins over another flavor's failure: only a start mounts
    # it, and without that restart Java has no DNS (the failure is logged).
    if ($derived) {
        $script:PersonalSlcDnsNeedsStart = $true
        return $false
    }
    return $ok
}

function Stop-Personal {
    Update-PersonalDeployDir
    if (-not (Test-ExakitKitDatabaseGuard)) { return }
    if (-not (Test-PersonalLauncherSupports "stop")) {
        Info "This launcher version has no explicit stop command."
        return
    }
    if ((Invoke-ExakitLogged (Get-PersonalCli) stop --deployment-dir $script:PersonalDeployDir) -ne 0) {
        Fail "Failed to stop the database."
    }
    Set-ExakitManifestValue "runtime.status" "stopped"
    Clear-PersonalStartOwed
    Ok "Database stopped"
}

# The launcher's words for a deployment whose lock another run holds.
$script:PersonalLockedText = "locked by another operation"
$script:PersonalDestroyError = ""

# Invoke-PersonalDestroyOnce - one `destroy --remove --auto-approve`; returns
# @(exit code, output lines). The output also goes to the log. Twin of
# _personal_destroy_once.
function Invoke-PersonalDestroyOnce {
    Update-PersonalDeployDir
    $cli = Get-PersonalCli
    Write-ExakitLog "CMD" "$cli destroy --remove --auto-approve --deployment-dir $($script:PersonalDeployDir)"
    $previous = $ErrorActionPreference
    $spinLabel = if ($script:ExakitActiveLabel) { $script:ExakitActiveLabel } else { "working" }
    Start-ExakitSpinner $spinLabel
    try {
        $ErrorActionPreference = "Continue"
        $lines = @(& $cli destroy --remove --auto-approve --deployment-dir $script:PersonalDeployDir 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.Exception.Message)" } else { "$_" }
        })
        $code = $LASTEXITCODE
    } catch {
        $lines = @("$_")
        $code = 1
    } finally {
        $ErrorActionPreference = $previous
        Stop-ExakitSpinner
    }
    if ($script:LogFile -and $lines.Count) { $lines | Add-Content -Path $script:LogFile }
    return ,@($code, $lines)
}

# Unlock-PersonalStale - release the deployment's lock when no launcher holds
# it (a launcher that crashed or was killed leaves it behind, and then even
# destroy refuses). A running launcher keeps its lock; the database daemon runs
# under another image name and does not count. Twin of personal_unlock_stale.
function Unlock-PersonalStale {
    Update-PersonalDeployDir
    $image = [System.IO.Path]::GetFileNameWithoutExtension((Get-PersonalCli))
    if (Get-Process -Name $image -ErrorAction SilentlyContinue) {
        Write-ExakitLog "WARN" "the deployment is locked and a launcher is running: not unlocking"
        return $false
    }
    return ((Invoke-ExakitLogged (Get-PersonalCli) diag unlock --auto-approve --deployment-dir $script:PersonalDeployDir) -eq 0)
}

# Invoke-PersonalDestroy - destroy the deployment and remove its folder; a stale
# lock is released and the destroy tried once more. When it still fails,
# $script:PersonalDestroyError holds the launcher's own last error line. Twin
# of personal_destroy.
function Invoke-PersonalDestroy {
    $script:PersonalDestroyError = ""
    $first = Invoke-PersonalDestroyOnce
    if ($first[0] -eq 0) { return $true }
    $lines = $first[1]
    if ((($lines -join "`n") -like "*$($script:PersonalLockedText)*") -and (Unlock-PersonalStale)) {
        $again = Invoke-PersonalDestroyOnce
        if ($again[0] -eq 0) { return $true }
        $lines = $again[1]
    }
    $said = @($lines | Where-Object { $_ -match '(?i)error|fail|cannot|could not|denied' } | Select-Object -Last 1)
    if (-not $said.Count) { $said = @($lines | Where-Object { "$_".Trim() } | Select-Object -Last 1) }
    $text = if ($said.Count) { "$($said[0])".Trim() } else { "nothing more" }
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
    $script:PersonalDestroyError = $text
    return $false
}

# Remove-Personal - destroy the deployment and its data. The Podman machine is
# deliberately untouched: it is shared host-wide, the launcher never
# reconfigures an existing one, and it stays running after destroy - this
# module owns the deployment, nothing else. Twin of personal_teardown.
#
# THE END STATE IS CHECKED, NOT ASSUMED. A destroy that failed, exited 0 and
# left the deployment behind, or never ran (Test-PersonalDeploymentExists asks
# `exasol info`, which a "deployment_failed" deployment refuses) used to end
# the same way as a clean one, and uninstall printed "Database removed" over a
# database that was still there. What remains is left in
# $script:PersonalTeardownLeftovers (one line per item, empty when clean) and
# the command that removes it in $script:PersonalTeardownRemedy.
function Remove-Personal {
    Update-PersonalDeployDir
    $script:PersonalTeardownLeftovers = @()
    $script:PersonalTeardownRemedy = ""
    # Read BEFORE the destroy, which deletes the state file that names it.
    $deploymentId = "" + (Get-PersonalDeploymentId)
    # The folder can already be gone while the container is not: the id the
    # kit recorded at install then names it.
    if (-not $deploymentId) { $deploymentId = "" + (Get-ExakitManifestValue "runtime.deployment_id") }
    if ((Test-Path -LiteralPath $script:PersonalDeployDir) -or (Test-PersonalDeploymentExists)) {
        Warn2 "An Exasol Personal deployment keeps the database software and your data together - removing it deletes every table you loaded."
        # --auto-approve: the launcher's destroy prompts for confirmation by
        # itself; the caller (uninstall) has already asked its own question.
        if (-not (Invoke-PersonalDestroy)) {
            Warn2 "The launcher could not fully remove the deployment (it said: $($script:PersonalDestroyError)). If its folder $($script:PersonalDeployDir) or a database process is still there, restart the computer and delete the folder."
        }
    }
    Find-PersonalTeardownLeftovers -Id $deploymentId
    if (@($script:PersonalTeardownLeftovers).Count -gt 0) { return }
    Set-ExakitManifestValue "runtime.status" "removed"
}

# Find-PersonalTeardownLeftovers -Id <deployment-id> - what of the deployment
# is still on this machine after a destroy: a container carrying its id (Docker
# or Podman, whichever answers) and its directory. Fills
# $script:PersonalTeardownLeftovers and $script:PersonalTeardownRemedy. Twin of
# personal_teardown_leftovers (which also checks the macOS runner on the port;
# on Windows the port is held by the engine's relay, not by a kit process).
function Find-PersonalTeardownLeftovers {
    param([string]$Id = "")
    Update-PersonalDeployDir
    $left = @()
    $steps = @()
    # An engine that hangs or refuses answers $null: a warning with the command
    # to check by hand, never a leftover (it alone does not fail the run).
    # Twin of EXAKIT_TEARDOWN_WARNINGS in personal_teardown_leftovers.
    $warnings = @()
    # ONLY THE ENGINE THE DEPLOYMENT IS RECORDED ON. A Docker deployment on a
    # machine that also has Podman, its machine stopped, used to end with
    # "Could not confirm the database container is gone (podman refused: exit
    # 125)": an engine this deployment never ran on cannot hold its container.
    # Both are asked only when the record names neither (or still carries the
    # nano kit's container, whose engine is the OLD database's), as before.
    # Twin of _ptl_engines in personal_teardown_leftovers.
    $engines = @("docker", "podman")
    $recorded = "" + (Get-ExakitManifestValue "runtime.engine")
    if (Get-ExakitManifestValue "runtime.container") { $recorded = "" }
    if ($recorded -eq "docker" -or $recorded -eq "podman") { $engines = @($recorded) }
    if ($Id) {
        foreach ($engineName in $engines) {
            $engineCmd = Get-Command $engineName -ErrorAction SilentlyContinue
            if (-not $engineCmd) { continue }
            $script:ExakitBoundedOutcome = ""
            $names = Invoke-ExakitBounded -FilePath $engineCmd.Source -TimeoutSeconds 15 -Arguments @("ps", "-a", "--format", "{{.Names}}")
            if ($null -eq $names) {
                # Why, where Invoke-ExakitBounded says: a hang and a refusal
                # are different things to check. Twin of _ptl_why.
                $why = "$engineName did not answer within 15s, or refused"
                $outcome = "" + $script:ExakitBoundedOutcome
                if ($outcome -eq "timeout") { $why = "$engineName did not answer within 15s" }
                elseif ($outcome -like "exit *") { $why = "$engineName refused: $outcome" }
                elseif ($outcome -eq "error") { $why = "$engineName could not be run" }
                # Short enough for one console row: the full filter (the
                # deployment id) wrapped onto a second line. It goes to the log.
                if (Get-Command Write-ExakitLog -ErrorAction SilentlyContinue) { Write-ExakitLog "WARN" "Container check for deployment $Id unanswered ($why); check by hand: $engineName ps -a --filter name=$Id" }
                $warnings += "Could not confirm the database container is gone ($why). Check: $engineName ps -a"
                continue
            }
            foreach ($line in @(("" + ($names -join "`n")) -split "`r?`n")) {
                $n = $line.Trim()
                if (-not $n) { continue }
                if (Test-PersonalNamesCarryId $n $Id) {
                    $left += "the $engineName container $n"
                    $steps += "$engineName rm -f $n"
                }
            }
        }
    }
    if (Test-Path -LiteralPath $script:PersonalDeployDir) {
        $left += "the deployment directory $($script:PersonalDeployDir) (the database and ALL its data)"
        $steps += "Remove-Item -Recurse -Force '" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($script:PersonalDeployDir) + "'"
    }
    # THE SAME DEPLOYMENT IN ANOTHER FOLDER. A launcher can move a deployment
    # out of the folder the kit recorded (launcher 2.5 keeps its deployments
    # in %LOCALAPPDATA%\exasol\launcher\deployments), and the check above then
    # found nothing while the database was still on disk. A folder in the
    # launcher's deployment folders whose state names this deployment's id is
    # that deployment: named, with the command that removes it, and never
    # removed by the kit, since it is outside the kit's recorded folder.
    # Twin of the same scan in personal_teardown_leftovers.
    if ($Id) {
        $self = [System.IO.Path]::GetFullPath($script:PersonalDeployDir).TrimEnd('\', '/')
        $roots = @()
        $parent = Split-Path -Parent $script:PersonalDeployDir
        if ($parent) { $roots += $parent }
        # The launcher's two deployment folders, as Resolve-PersonalDeployDir
        # spells them, and the folders of every deployment the launcher lists.
        $spelled = Resolve-PersonalDeployDir -Path ("" + $script:PersonalDeployDir)
        if ($spelled.Legacy) { $roots += (Split-Path -Parent $spelled.Legacy) }
        if ($spelled.New) { $roots += (Split-Path -Parent $spelled.New) }
        $listedAll = @()
        if (Get-Command Get-PersonalLauncherDeployments -ErrorAction SilentlyContinue) { $listedAll = @(Get-PersonalLauncherDeployments) }
        foreach ($listed in $listedAll) {
            if ($listed -and $listed.Path) { $roots += (Split-Path -Parent $listed.Path) }
        }
        $seen = @()
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            foreach ($e in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $full = $e.FullName.TrimEnd('\', '/')
                if ($full -eq $self -or $seen -contains $full) { continue }
                if (("" + (Get-PersonalDeploymentId -Dir $full)) -ne $Id) { continue }
                $seen += $full
                $left += "the deployment directory $full (the database and ALL its data)"
                $steps += "Remove-Item -Recurse -Force '" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($full) + "'"
            }
        }
    }
    $script:PersonalTeardownLeftovers = $left
    $script:PersonalTeardownRemedy = ($steps -join "; ")
    $script:PersonalTeardownWarnings = $warnings
}

# Get-PersonalLauncherCacheDir - the launcher's download cache (the Nano image,
# the runner, the presets; around 500 MB). The launcher is a Go binary and
# keeps it under os.UserCacheDir(), which on Windows is %LOCALAPPDATA%:
# exasol\launcher\resources from 2.5.0, which deletes the .exasol folder
# earlier launchers used at its first command. So the 2.5.0 folder is the
# answer, unless only the earlier one is on disk. Empty when LOCALAPPDATA is
# not set (Go fails there too, so there is no cache to name). Twin of
# personal_launcher_cache_dir.
function Get-PersonalLauncherCacheDir {
    if (-not $env:LOCALAPPDATA) { return "" }
    $current = Join-Path $env:LOCALAPPDATA "exasol\launcher\resources"
    $earlier = Join-Path $env:LOCALAPPDATA ".exasol"
    if (-not (Test-Path -LiteralPath $current) -and (Test-Path -LiteralPath $earlier)) { return $earlier }
    return $current
}

# Get-PersonalOtherDeployments - every entry in the launcher's deployments
# directories other than the kit's own deployment. Anything there keeps the
# shared cache and the state directories in place, and the ports saved there
# are taken: the database port (Select-PersonalDbPort) and the MCP server's
# (Get-McpSidecarSavedPorts). Twin of personal_other_deployments.
function Get-PersonalOtherDeployments {
    Update-PersonalDeployDir
    # Every place a deployment can live: beside the configured deploy dir, and
    # both of the launcher's default roots (2.5.0's and the one before it,
    # Resolve-PersonalDeployDir). The launcher cache is shared by all of them.
    $self = [System.IO.Path]::GetFullPath($script:PersonalDeployDir).TrimEnd('\', '/')
    $dirs = @()
    $parent = Split-Path -Parent $script:PersonalDeployDir
    if ($parent) { $dirs += [System.IO.Path]::GetFullPath($parent).TrimEnd('\', '/') }
    $roots = Resolve-PersonalDeployDir
    $listedDirs = @()
    if (Get-Command Get-PersonalLauncherDeployments -ErrorAction SilentlyContinue) {
        $listedDirs = @(@(Get-PersonalLauncherDeployments) | Where-Object { $_ -and $_.Path } | ForEach-Object { "$($_.Path)" })
    }
    foreach ($defaultDir in (@($roots.New, $roots.Legacy) + $listedDirs)) {
        if (-not $defaultDir) { continue }
        $default = [System.IO.Path]::GetFullPath((Split-Path -Parent $defaultDir)).TrimEnd('\', '/')
        if ($dirs -notcontains $default) { $dirs += $default }
    }
    $others = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
            if ($e.FullName.TrimEnd('\', '/') -ne $self) { $others += $e.FullName }
        }
    }
    return $others
}

# Get-PersonalPrunableStateDirs - the launcher's state directories that are
# empty once the kit's deployment is gone, bottom-up: deployments, launcher,
# exasol for a 2.5.0 deployment (under %LOCALAPPDATA%), and deployments,
# personal, .exasol for one from before it. The same answer before the destroy
# (what a dry run lists) and after it (what is removed). Twin of
# personal_prunable_state_dirs.
function Get-PersonalPrunableStateDirs {
    Update-PersonalDeployDir
    $out = @()
    $child = [System.IO.Path]::GetFullPath($script:PersonalDeployDir).TrimEnd('\', '/')
    $dir = Split-Path -Parent $child
    $names = @("deployments", "personal", ".exasol")
    $roots = Resolve-PersonalDeployDir
    # By the ROOT, not the exact folder: whatever the deployment's name
    # (starter-kit-local, or a 0.3.0 kit's `default`), one in 2.5.0's root
    # prunes 2.5.0's folders. Twin of personal_prunable_state_dirs.
    if ($roots.NewRoot -and $dir -and $dir -eq [System.IO.Path]::GetFullPath($roots.NewRoot).TrimEnd('\', '/')) { $names = @("deployments", "launcher", "exasol") }
    foreach ($name in $names) {
        if (-not $dir -or (Split-Path -Leaf $dir) -ne $name) { break }
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        if (-not $item -or -not $item.PSIsContainer) { break }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { break }
        $foreign = $false
        foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($e.FullName.TrimEnd('\', '/') -ne $child) { $foreign = $true; break }
        }
        if ($foreign) { break }
        $out += $dir
        $child = $dir
        $dir = Split-Path -Parent $dir
    }
    return $out
}

# Get-PersonalLauncherLeftovers - what a full uninstall removes beside the
# deployment: the launcher's download cache (Cache, with its size in
# CacheSize) and the state directories that are empty once the deployment is
# gone (Dirs, bottom-up). Nothing at all while another deployment shares them.
function Get-PersonalLauncherLeftovers {
    Update-PersonalDeployDir
    $plan = [pscustomobject]@{ Cache = ""; CacheSize = ""; Dirs = @() }
    # No deployment folder known: nothing proves which deployment is the
    # kit's, so the shared cache and folders stay.
    if (-not $script:PersonalDeployDir) { return $plan }
    if (@(Get-PersonalOtherDeployments).Count -gt 0) { return $plan }
    $cache = Get-PersonalLauncherCacheDir
    if ($cache) {
        $item = Get-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer -and -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $plan.Cache = $cache
            $bytes = 0
            foreach ($f in @(Get-ChildItem -LiteralPath $cache -Recurse -Force -File -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
            if ($bytes -ge 1GB) { $plan.CacheSize = "{0:N1} GB" -f ($bytes / 1GB) }
            else { $plan.CacheSize = "{0:N0} MB" -f ($bytes / 1MB) }
        }
    }
    $plan.Dirs = @(Get-PersonalPrunableStateDirs)
    return $plan
}

# Update-Personal - bring the kit-managed launcher to the advertised version and
# leave the record telling the truth about the deployment's state afterwards.
# The update prompt upstream of this call explains the one-time guest rebuild;
# the note here fires again right before the start that performs it.
# Update-PersonalChangedPassword <before> - "changed" when the database password
# on file is no longer <before>, after the records that depend on it were
# refreshed: the exapump profile is rewritten and the change is said. "same"
# when both were read and are equal; "unknown" when either could not be read
# (nothing on file before, or secrets.json unreadable now), and the caller then
# claims nothing about the password. Nothing here prints a password. Twin of
# personal_refresh_changed_password, which says why the check exists.
function Update-PersonalChangedPassword {
    param([AllowEmptyString()][string]$Before)
    if (-not $Before) { return "unknown" }
    $after = ("" + (Get-ExakitCredential "personal_sys_password")).TrimEnd("`r", "`n")
    if (-not $after) { return "unknown" }
    if ($after -ceq $Before) { return "same" }
    # New-ExapumpProfile reports failure by warning, not by throwing, so the
    # profile is read back: "now hold the new one" is said only when it does.
    $written = $false
    if (Get-Command New-ExapumpProfile -ErrorAction SilentlyContinue) {
        try { New-ExapumpProfile; $written = $true } catch { $written = $false }
        if ($written -and (Get-Command Test-ExapumpProfilePasswordStale -ErrorAction SilentlyContinue)) {
            $written = (Test-Path -LiteralPath $script:ExapumpConfigPath -PathType Leaf) -and (-not (Test-ExapumpProfilePasswordStale))
        }
    }
    if ($written) {
        Info "The database password changed with this update: the kit's stored credential and the exapump profile now hold the new one. The AI bridge user (mcp_readonly) keeps its own password and keeps connecting."
    } else {
        Warn2 "The database password changed with this update: the kit's stored credential holds the new one, but the exapump profile could not be rewritten - recreate it with: exapump profile init $($script:ExapumpProfile). The AI bridge user (mcp_readonly) keeps its own password and keeps connecting."
    }
    return "changed"
}

# Test-PersonalSecretsReadable - the deployment's secrets.json gives a database
# password now. Twin of _personal_update_secrets_readable.
function Test-PersonalSecretsReadable {
    Update-PersonalDeployDir
    $secFile = Join-Path $script:PersonalDeployDir "secrets.json"
    if (-not (Test-Path -LiteralPath $secFile)) { return $false }
    try {
        $sec = [System.IO.File]::ReadAllText($secFile) | ConvertFrom-Json
        return [bool]$sec.dbPassword
    } catch { return $false }
}

# --- the update from a 0.3.0 kit: one restart -------------------------------
# A 0.3.0 kit's database is the launcher's deployment `default`, run by
# Exasol Personal 2.4, which set its 20-session limit. The update makes it the
# deployment starter-kit-local on 2.5 without the limit, in ONE restart, and
# nothing 2.5 runs before its folder has its new name:
#   1. whether it runs is noted, its id recorded (the follow in 4 needs it), a
#      copy of the launcher kept, and the database stopped with the launcher
#      that runs it now, the old one (Stop-PersonalForUpdate);
#   2. its folder is renamed in the same root to starter-kit-local, the
#      records with it, said with approved line 5 (Rename-PersonalForUpdate);
#   3. the launcher is replaced (not when it is current already), its copy
#      kept until the new one has answered;
#   4. the new launcher's first command moves the folder from
#      %USERPROFILE%\.exasol\personal to %LOCALAPPDATA%\exasol\launcher, and
#      the kit's record follows it by its id (Update-PersonalDeployDir). A
#      folder the launcher leaves in the older root (a file open inside it,
#      the profile on another drive) keeps working there, and the record
#      follows it there. The MCP sidecar a 0.3.0 kit set up in a database of
#      the user's, which that kit kept no record of, is recorded as the kit's
#      when it proves it (Save-PersonalUpdateSidecarRecord);
#   5. the 20-session limit is lifted while it is stopped, and the database is
#      started once, only when it ran before (Start-PersonalAfterUpdate).
# A failure from 1 to the end of 3 puts back what was changed (the launcher,
# the folder's name, the records), starts the database again when it ran, and
# says why (Undo-PersonalUpdate): the next `exakit update` tries again.
# WINDOWS DOES NOT REPLACE A PROGRAM FILE WHILE IT RUNS: a launcher another
# program runs (an `exasol` command still at work, a shell left open) is found
# before anything stops, and the update says so and asks for `exakit update`
# again once it is closed; a swap that still meets it is put back the same
# way. The owner stays as recorded: a database the user let the 0.3.0 kit use
# stays theirs, renamed and upgraded with that permission, never destroyed.
# Update-Personal runs it for the kit's own launcher, Update-PersonalUser for
# the user's own, Update-PersonalCurrent with no launcher to replace. Twin of
# the same block in runtime-personal.sh.

# What the last update of the database did, for its callers (the update loop,
# the installer): "updated"; "undone" (not done: said, what it changed put
# back, and the next `exakit update` tries again); "kept"
# (EXAKIT_CONFIRM_RUNTIME_UPDATE=0); "skipped" (not this update); "" (nothing
# ran). $script:PersonalUpdateWhy is the reason an undone one gives (the
# update row's error); $script:PersonalUpdateRestarted is $true when the
# update started the database again itself, so no caller starts it a second
# time; $script:ExakitRuntimeUpdateSaid is $true once the stop line was said
# (Write-ExakitRuntimeUpdateExplanation, Write-PersonalUpdateExplanation), so
# the update does not say it twice. Twin of personal_update's return codes and
# of EXAKIT_RUNTIME_UPDATE_RESTARTED and EXAKIT_RUNTIME_UPDATE_SAID.
# $script:PersonalUpdateInUse is $true when an undone one was not done because
# another program runs the launcher (Windows only): the one put-back an
# explicit `exakit update personal` defers instead of failing.
$script:PersonalUpdateResult = ""
$script:PersonalUpdateWhy = ""
$script:PersonalUpdateInUse = $false
$script:PersonalUpdateRestarted = $false
$script:ExakitRuntimeUpdateSaid = $false
$script:PersonalUpdateRan = $false
$script:PersonalUpdateRenamed = $false
$script:PersonalUpdateLifted = $false
$script:PersonalUpdateFrom = ""
$script:PersonalUpdateTo = ""
$script:PersonalUpdateBin = ""
$script:PersonalUpdateCopy = ""
$script:PersonalUpdateReceipt = ""
$script:PersonalUpdateLegacy = $false
$script:PersonalUpdateOthers = @()
$script:PersonalRenameBlocker = ""

# Reset-PersonalDeployFollow - the refresh's memory of where the kit's folder
# was, dropped: the next Update-PersonalDeployDir reads the record anew, and
# asks the launcher where its deployments are when the recorded folder is
# gone (a rename, or the move the new launcher's first command made). Twin of
# _personal_forget_followed.
function Reset-PersonalDeployFollow {
    $script:PersonalLauncherAsked = $false
    $script:PersonalLauncherListed = $false
    $script:PersonalLauncherDeployments = @()
    $script:PersonalLauncherDecided = $false
    $script:PersonalDeployRec = ""
    $script:PersonalDeployFollowed = ""
}

# Test-PersonalSameFile <a> <b> - the two files hold the same bytes.
function Test-PersonalSameFile {
    param([AllowEmptyString()][string]$A = "", [AllowEmptyString()][string]$B = "")
    if (-not $A -or -not $B) { return $false }
    if (-not (Test-Path -LiteralPath $A -PathType Leaf) -or -not (Test-Path -LiteralPath $B -PathType Leaf)) { return $false }
    try {
        return ((Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash)
    } catch { return $false }
}

# Test-PersonalLauncherInUse -Path <launcher> - $true when a program runs from
# <launcher> now: Windows refuses to replace a program file while it runs.
# Asked of the process list, as Unlock-PersonalStale asks it; a process whose
# path cannot be read proves nothing, and the swap itself is the last word.
function Test-PersonalLauncherInUse {
    param([AllowEmptyString()][string]$Path = "")
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    $image = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    foreach ($process in @(Get-Process -Name $image -ErrorAction SilentlyContinue)) {
        $at = ""
        try { $at = "" + $process.Path } catch { $at = "" }
        if ($at -and [string]::Equals($at, $full, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Set-PersonalUpdateFailure <reason> - why an update of the database did not
# happen: kept for this run's update row ($script:PersonalUpdateWhy), and in
# the failure note, which `exakit status --json` reports until an update of
# the database goes through (Clear-ExakitUpdateFailureNote). Twin of the
# exakit_note_failure calls in the update block.
function Set-PersonalUpdateFailure {
    param([Parameter(Mandatory)][string]$Reason)
    $script:PersonalUpdateWhy = $Reason
    if (Get-Command Write-ExakitFailureNote -ErrorAction SilentlyContinue) { Write-ExakitFailureNote $Reason }
}

# Get-PersonalUpdateRenameSource - the folder of the kit's database while it
# is still a 0.3.0 kit's `default`, in one of the launcher's two roots: the
# folder the update renames. "" otherwise: a database named starter-kit-local
# already, a folder the user named (EXAKIT_PERSONAL_DEPLOY_DIR), one the kit
# may not act on (Get-ExakitPersonalDbState), or no record of one. Asks no
# launcher while the recorded folder is there. Twin of
# personal_update_rename_source.
function Get-PersonalUpdateRenameSource {
    if (("" + (Get-ExakitManifestValue "runtime.type")) -ne "personal") { return "" }
    if ("" + $env:EXAKIT_PERSONAL_DEPLOY_DIR) { return "" }
    Update-PersonalDeployDir
    $dir = "" + $script:PersonalDeployDir
    if (-not $dir -or (Split-Path -Leaf $dir) -ne "default" -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return "" }
    $roots = Resolve-PersonalDeployDir -Path ""
    $parent = Split-Path -Parent $dir
    if (-not $parent -or ($parent -ne $roots.NewRoot -and $parent -ne $roots.LegacyRoot)) { return "" }
    if (("" + (Get-ExakitManifestValue "runtime.deployment_dir")) -ne $dir) { return "" }
    $state = ""
    try { $state = "" + (Get-ExakitPersonalDbState) } catch { $state = "" }
    if ($state) { return "" }
    return $dir
}

# Test-PersonalUpdateRenameFree -From <folder> - $true when <folder> can be
# renamed to starter-kit-local now: no starter-kit-local in its root, nor in
# the 2.5 root the next launcher moves it to (launcher 2.5 never moves a
# folder onto one of the same name, it warns on every run instead), and no
# launcher command holds it (a .dirmutex marker). $false otherwise, the reason
# in $script:PersonalRenameError: exists (the folder in the way in
# $script:PersonalRenameBlocker) or locked. Twin of
# _personal_update_rename_check.
function Test-PersonalUpdateRenameFree {
    param([Parameter(Mandatory)][string]$From)
    $script:PersonalRenameError = ""
    $script:PersonalRenameBlocker = ""
    $targets = @(Join-Path (Split-Path -Parent $From) (Get-PersonalDeploymentName))
    $new = "" + (Resolve-PersonalDeployDir -Path "").New
    if ($new -and $targets -notcontains $new) { $targets += $new }
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        $script:PersonalRenameError = "exists"
        $script:PersonalRenameBlocker = $target
        return $false
    }
    if ((Test-Path -LiteralPath $From -PathType Container) -and
        @(Get-ChildItem -LiteralPath $From -Force -Filter ".dirmutex*" -ErrorAction SilentlyContinue).Count -gt 0) {
        $script:PersonalRenameError = "locked"
        return $false
    }
    return $true
}

# Write-PersonalUpdateNotRenamed - the database was not renamed
# ($script:PersonalRenameError says why): said, and started again when it ran.
# The update stops there, with nothing changed. Twin of
# _personal_update_not_renamed.
function Write-PersonalUpdateNotRenamed {
    $blocker = "" + $script:PersonalRenameBlocker
    if (-not $blocker) { $blocker = "" + $script:PersonalUpdateTo }
    switch ("" + $script:PersonalRenameError) {
        "exists"  { $why = "$(Get-ExakitTilde $blocker) already exists" }
        "locked"  { $why = "another Exasol Personal command is using it" }
        "noid"    { $why = "the kit could not read its id" }
        "records" { $why = "the kit could not write its record" }
        default   { $why = "its folder could not be renamed" }
    }
    $name = Split-Path -Leaf ("" + $script:PersonalUpdateFrom)
    $kitName = Get-PersonalDeploymentName
    Warn2 "The database '$name' was not renamed to '$kitName', because $why. Nothing was changed."
    Set-PersonalUpdateFailure "The database '$name' was not renamed to '$kitName', because $why"
    [void](Start-PersonalAfterUpdate)
    Info "The next exakit update tries again."
}

# Save-PersonalUpdateDeploymentId - runtime.deployment_id, read from the
# folder the kit's database is in now, when the record has none (a 0.3.0 kit
# kept no id, and kept none for a database of the user's): after the rename
# and the move the record follows the database by it. $false when none is
# recorded and none can be read. Twin of personal_update_record_id.
function Save-PersonalUpdateDeploymentId {
    if ("" + (Get-ExakitManifestValue "runtime.deployment_id")) { return $true }
    Update-PersonalDeployDir
    $id = "" + (Read-PersonalDeploymentId -Dir ("" + $script:PersonalDeployDir))
    if (-not $id) { return $false }
    try { Set-ExakitManifestValue "runtime.deployment_id" $id } catch { return $false }
    return (("" + (Get-ExakitManifestValue "runtime.deployment_id")) -ceq $id)
}

# AN UPDATE OWES A START (Q8) from its stop to the start at its end, on record
# (runtime.start_owed): one cut short in between left a stopped database that
# the next `exakit update` called current. The next one starts it
# (Complete-PersonalUpdateStart). A start, or a stop the user asks for, settles
# it. Twins of _personal_start_owed, _personal_start_owe and
# _personal_start_settled.
function Test-PersonalStartOwed { return [bool]("" + (Get-ExakitManifestValue "runtime.start_owed")) }
function Set-PersonalStartOwed {
    try { $null = Set-ExakitManifestValue "runtime.start_owed" "true" } catch { Write-ExakitLog "WARN" "runtime.start_owed: $_" }
}
function Clear-PersonalStartOwed {
    try { if ($null -ne (Get-ExakitManifestValue "runtime.start_owed")) { $null = Remove-ExakitManifestValue "runtime.start_owed" } } catch { }
}

# Complete-PersonalUpdateStart - the start an update that was cut short still
# owes. $true when there is none, or the database runs. $false when it did not
# start (said), or EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds it back
# ($script:PersonalUpdateKept is then $true). Twin of
# personal_update_finish_start.
function Complete-PersonalUpdateStart {
    $script:PersonalUpdateKept = $false
    if (-not (Test-PersonalStartOwed)) { return $true }
    $state = ""
    try { $state = "" + (Get-ExakitPersonalDbState) } catch { $state = "" }
    if ($state) { return $true }
    Update-PersonalDeployDir
    $dir = "" + $script:PersonalDeployDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container) -or (Test-PersonalUpdateRuns)) {
        Clear-PersonalStartOwed
        return $true
    }
    if (("" + [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")) -cmatch '^(0|n|N|no|NO|No)$') {
        $to = "" + $env:EXAKIT_PERSONAL_VERSION
        if (-not $to) { $to = "" + (Get-PersonalLauncherVersion) }
        Warn2 "personal $(Get-ExakitManifestValue 'runtime.version') -> $to was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update --yes"
        $script:PersonalUpdateKept = $true
        return $false
    }
    $script:PersonalUpdateRan = $true
    $script:PersonalUpdateLifted = $false
    return (@(Start-PersonalAfterUpdate)[-1] -eq $true)
}

# THE KIT'S OLD LAUNCHER, retired once the kit's own is in the kit's folder, is
# on record before anything changes (components.personal.retire_path and
# retire_sha256): an update cut short after that, or a file that could not be
# removed, is retired by a later one (Complete-PersonalRetire). Nothing noted
# without the file's sha256. Twins of personal_retire_note and
# personal_retire_forget.
function Save-PersonalRetireNote {
    param([AllowEmptyString()][string]$Path = "", [AllowEmptyString()][string]$Sha = "")
    if (-not $Path -or -not $Sha) { return }
    try {
        $null = Set-ExakitManifestValue "components.personal.retire_sha256" $Sha
        $null = Set-ExakitManifestValue "components.personal.retire_path" $Path
    } catch { Write-ExakitLog "WARN" "components.personal.retire_path: $_" }
}
function Clear-PersonalRetireNote {
    foreach ($key in @("components.personal.retire_path", "components.personal.retire_sha256")) {
        try { if ($null -ne (Get-ExakitManifestValue $key)) { $null = Remove-ExakitManifestValue $key } } catch { return }
    }
}

# Remove-PersonalRetired <old launcher> <its sha256> - removed when it is still
# the file the kit recorded. $false only when it is and could not be removed (a
# program runs from it): its note then stays. Nothing said: a log line. Twin of
# personal_retire_bin_launcher.
function Remove-PersonalRetired {
    param([AllowEmptyString()][string]$Path = "", [AllowEmptyString()][string]$Sha = "")
    if (-not $Path) { return $true }
    $same = $false
    try { $same = ((Test-Path -LiteralPath $Path -PathType Leaf) -and $Sha -and ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha)) } catch { $same = $false }
    if (-not $same) {
        Write-ExakitLog "INFO" "the launcher at $Path is not the file the kit recorded: left as it is"
        return $true
    }
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch {
        Write-ExakitLog "WARN" "the kit's old launcher at ${Path} stays: $($_.Exception.Message)"
        return $false
    }
    return $true
}

# Test-PersonalKitBinPlaced - $true when the kit's folder has a launcher with
# the kit's receipt on it. One without it is not there yet (an update or an
# install cut short between the file and its receipt). Twin of
# _personal_kit_bin_placed.
function Test-PersonalKitBinPlaced {
    $sep = "" + (Get-PersonalSeparateBinPath)
    return ([bool]$sep -and (Test-Path -LiteralPath $sep -PathType Leaf) -and
            (("" + (Get-ExakitManifestValue "components.personal.ownership")) -eq "kit") -and
            (("" + (Get-ExakitManifestValue "components.personal.ownership_path")) -eq $sep))
}

# Complete-PersonalRetire - the launcher noted is retired now: the kit's own is
# in the kit's folder, with the kit's receipt on it, and runs. Twin of
# personal_retire_pending.
function Complete-PersonalRetire {
    $old = "" + (Get-ExakitManifestValue "components.personal.retire_path")
    if (-not $old) { return }
    if (-not (Test-PersonalKitBinPlaced)) { return }
    if (-not ("" + (Get-PersonalLauncherVersion))) { return }
    if ($old -eq (Join-Path $script:BinDir "exasol.exe") -and
        -not (Remove-PersonalRetired -Path $old -Sha ("" + (Get-ExakitManifestValue "components.personal.retire_sha256")))) { return }
    Clear-PersonalRetireNote
}

# Test-PersonalUpdateRuns - $true while the kit's database runs, or comes up.
function Test-PersonalUpdateRuns {
    $status = ""
    try { $status = "" + (Get-PersonalStatus) } catch { $status = "" }
    return (@("running", "starting") -contains $status)
}

# Save-PersonalUpdateLauncherCopy -Path <launcher> - the copy step 3 puts
# back: the launcher file that runs the database now
# ($script:PersonalUpdateBin), copied into the kit's cache
# ($script:PersonalUpdateCopy) before anything changes, never next to a
# user's launcher. No file there is nothing to keep. $false when the copy
# cannot be made.
# A COPY ALREADY THERE, OTHER THAN THE LAUNCHER IN PLACE, IS NEVER WRITTEN
# OVER OR REMOVED: it is the only one left of a launcher an earlier update
# replaced and could not put back, at the path its undo named. This update
# keeps its own copy in a folder of its own beside it, so its undo puts back
# only what this update replaced. Twin of personal_update_keep_launcher.
function Save-PersonalUpdateLauncherCopy {
    param([AllowEmptyString()][string]$Path = "")
    $script:PersonalUpdateBin = $Path
    $script:PersonalUpdateCopy = ""
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    $cache = "" + $script:CacheDir
    if (-not $cache) { $cache = Join-Path $script:ExakitHome "cache" }
    $dir = Join-Path $cache "personal-launcher-before-update"
    $copy = Join-Path $dir (Split-Path -Leaf $Path)
    if ((Test-Path -LiteralPath $copy -PathType Leaf) -and -not (Test-PersonalSameFile -A $Path -B $copy)) {
        Write-ExakitLog "INFO" "the launcher copy an earlier update left at $copy is kept as it is"
        $dir = Join-Path $dir ("update-" + [guid]::NewGuid().ToString("N"))
        $copy = Join-Path $dir (Split-Path -Leaf $Path)
    }
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Force -ErrorAction Stop }
        Copy-Item -LiteralPath $Path -Destination $copy -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
        return $false
    }
    $script:PersonalUpdateCopy = $copy
    return $true
}

# Remove-PersonalUpdateLauncherCopy - the copy, once the new launcher has
# answered (or the old one is back). Only this update's: a copy an earlier
# update left stays (Save-PersonalUpdateLauncherCopy). Twin of
# personal_update_drop_launcher_copy.
function Remove-PersonalUpdateLauncherCopy {
    $copy = "" + $script:PersonalUpdateCopy
    if ($copy) {
        Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
        $dir = Split-Path -Parent $copy
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container) -and
            @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        }
    }
    $script:PersonalUpdateCopy = ""
}

# Test-PersonalUpdateLauncherAnswers - $true when the launcher in place has
# run: it answers `version` with a version. One whose bytes are still the
# copy's was not replaced, and nothing that is not there can be asked:
# neither has anything new to prove.
# ITS FIRST COMMAND IS SLOW, AND A SLOW ONE IS NOT A BROKEN ONE: Exasol
# Personal 2.5 first moves every deployment of the older root (a rename and a
# running check each, the old cache deleted, the SQL history moved), and
# Windows' real-time antivirus scans a program file before its first run. So
# this `version` gets 120 seconds, not the probes' few, and one that still
# runs out of time is asked once more (the move is done by then) before the
# update is put back: a timeout never undoes an update that went through.
# Twin of _personal_update_launcher_answers.
function Test-PersonalUpdateLauncherAnswers {
    $bin = "" + $script:PersonalUpdateBin
    if (-not $bin -or -not (Test-Path -LiteralPath $bin -PathType Leaf)) { return $true }
    if (Test-PersonalSameFile -A $bin -B ("" + $script:PersonalUpdateCopy)) { return $true }
    for ($try = 1; $try -le 2; $try++) {
        $script:ExakitBoundedOutcome = ""
        $out = Invoke-ExakitBounded -FilePath $bin -Arguments @("version") -TimeoutSeconds 120
        if (("" + $out) -match '^\s*v?[0-9]+\.[0-9]+') { return $true }
        if ($script:ExakitBoundedOutcome -ne "timeout") { return $false }
        Write-ExakitLog "WARN" "the new launcher's first command ran out of time: asked once more"
    }
    return $false
}

# Stop-PersonalForUpdate [-Line <text>] - step 1's stop.
# $script:PersonalUpdateRan is $true when the database ran: it is started
# again at the end, or after an undo (Start-PersonalAfterUpdate). A running
# one is stopped with the launcher that runs it now, after <line> (the
# caller's stop line, when it has one to say). $false when it did not stop:
# said, nothing changed, and one that went down without stopping as asked is
# started again. Twin of personal_update_stop.
# WITH A RENAME PENDING, ONLY THE LAUNCHER'S OWN "stopped" OR "initialized" IS
# STOPPED (UPG-14). On any other answer (a running database, one that holds its
# port and does not answer yet - "conflict", every Windows boot - or one the
# launcher cannot speak for) it is asked to stop, and must then be said to be
# stopped: a folder is never renamed under a container that may run from it.
function Test-PersonalUpdateSaysStopped {
    # Asked twice: a 2.5 launcher moves a stopped folder out of the older root
    # by the command that asks, so the first answer can be about the old place.
    for ($try = 1; $try -le 2; $try++) {
        if (@("stopped", "initialized") -contains (Get-PersonalLauncherState)) { return $true }
        Reset-PersonalDeployFollow
        Update-PersonalDeployDir
    }
    return $false
}
function Stop-PersonalForUpdate {
    param([AllowEmptyString()][string]$Line = "")
    $script:PersonalUpdateRan = $false
    $pending = [bool]("" + $script:PersonalUpdateFrom)
    if ($pending -and (Test-PersonalUpdateSaysStopped)) { Set-PersonalStartOwed; return $true }
    $status = ""
    try { $status = "" + (Get-PersonalStatus) } catch { $status = "" }
    $script:PersonalUpdateRan = (@("running", "starting", "conflict") -contains $status)
    if (-not $pending -and -not $script:PersonalUpdateRan) { Set-PersonalStartOwed; return $true }
    if ($Line) { Warn2 $Line }
    $stopped = $true
    try { $null = Stop-Personal } catch { $stopped = $false }
    if ($stopped) {
        if ($pending) { if (Test-PersonalUpdateSaysStopped) { Set-PersonalStartOwed; return $true } }
        elseif (-not (Test-PersonalUpdateRuns)) { Set-PersonalStartOwed; return $true }
    }
    Warn2 "The database did not stop, so it was not updated. Nothing was changed."
    Set-PersonalUpdateFailure "The database did not stop, so it was not updated"
    [void](Start-PersonalAfterUpdate)
    return $false
}

# Rename-PersonalForUpdate - step 2: the folder $script:PersonalUpdateFrom
# renamed to starter-kit-local in its root, and the kit's records with it
# (Update-PersonalDeploymentRecord), said with approved line 5.
# $script:PersonalUpdateRenamed is $true when done. Nothing to rename is
# $true. $false when it was not renamed: said, nothing changed, and the
# database started again when it ran. Twin of personal_update_rename.
function Rename-PersonalForUpdate {
    $script:PersonalUpdateRenamed = $false
    if (-not $script:PersonalUpdateFrom) { return $true }
    # Where it is now: a launcher 2.5 that runs it moves a stopped folder out
    # of the older root on its next command (the check after the stop), and
    # the record follows it there by its id.
    Reset-PersonalDeployFollow
    Update-PersonalDeployDir
    $now = "" + $script:PersonalDeployDir
    if ($now -and $now -ne $script:PersonalUpdateFrom -and (Split-Path -Leaf $now) -eq "default" -and
        (Test-Path -LiteralPath $now -PathType Container)) {
        $script:PersonalUpdateFrom = $now
        $script:PersonalUpdateTo = Join-Path (Split-Path -Parent $now) (Get-PersonalDeploymentName)
    }
    Info "Renaming the database to '$(Get-PersonalDeploymentName)'."
    $from = "" + $script:PersonalUpdateFrom
    $to = "" + $script:PersonalUpdateTo
    if ((Test-PersonalUpdateRenameFree -From $from) -and (Rename-PersonalDeploymentFolder -From $from -To $to)) {
        Update-PersonalDeploymentRecord -From $from -To $to
        if (("" + (Get-ExakitManifestValue "runtime.deployment_dir")) -eq $to) {
            $script:PersonalUpdateRenamed = $true
            return $true
        }
        # The record could not be written: the folder goes back, the record
        # with it, so both still name the same folder.
        [void](Rename-PersonalDeploymentFolder -From $to -To $from)
        Update-PersonalDeploymentRecord -From $to -To $from
        $script:PersonalRenameError = "records"
    }
    Write-PersonalUpdateNotRenamed
    return $false
}

# Initialize-PersonalUpdate [-Line <stop line>] - steps 1 and 2, before a
# launcher is replaced: a copy of the launcher kept ($script:PersonalUpdateBin,
# set by the caller), and, for a database of the kit's to act on, its id
# recorded, the database stopped when it runs (<line> said first, when not
# empty), and a 0.3.0 `default` renamed to starter-kit-local. A rename that
# cannot happen is found before anything stops. $false when the update cannot
# go on: said, nothing changed, the database running again when it ran. Twin
# of personal_update_prepare.
function Initialize-PersonalUpdate {
    param([AllowEmptyString()][string]$Line = "")
    $script:PersonalUpdateRan = $false
    $script:PersonalUpdateRenamed = $false
    $script:PersonalUpdateFrom = ""
    $script:PersonalUpdateTo = ""
    $script:PersonalUpdateOthers = @()
    if (-not (Save-PersonalUpdateLauncherCopy -Path ("" + $script:PersonalUpdateBin))) {
        Warn2 "Exasol Personal was not updated, because the kit could not keep a copy of the launcher it replaces. Nothing was changed."
        Set-PersonalUpdateFailure "Exasol Personal was not updated, because the kit could not keep a copy of the launcher it replaces"
        return $false
    }
    if (("" + (Get-ExakitManifestValue "runtime.type")) -ne "personal") { return $true }
    Update-PersonalDeployDir
    $dir = "" + $script:PersonalDeployDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $true }
    $script:PersonalUpdateFrom = "" + (Get-PersonalUpdateRenameSource)
    if ($script:PersonalUpdateFrom) {
        $script:PersonalUpdateTo = Join-Path (Split-Path -Parent $script:PersonalUpdateFrom) (Get-PersonalDeploymentName)
        if (-not (Test-PersonalUpdateRenameFree -From $script:PersonalUpdateFrom)) {
            Write-PersonalUpdateNotRenamed
            Remove-PersonalUpdateLauncherCopy
            return $false
        }
    }
    if (-not (Save-PersonalUpdateDeploymentId) -and $script:PersonalUpdateFrom) {
        $script:PersonalRenameError = "noid"
        Write-PersonalUpdateNotRenamed
        Remove-PersonalUpdateLauncherCopy
        return $false
    }
    if (-not (Stop-PersonalForUpdate -Line $Line) -or -not (Rename-PersonalForUpdate)) {
        Remove-PersonalUpdateLauncherCopy
        return $false
    }
    # The other deployments in the older root now, before any 2.5 command:
    # the new launcher's first one moves each stopped one into its own root,
    # and an undo does not bring them back (Get-PersonalUpdateMovedOthers).
    $legacy = "" + (Resolve-PersonalDeployDir -Path "").LegacyRoot
    if ($legacy -and (Test-Path -LiteralPath $legacy -PathType Container)) {
        foreach ($e in @(Get-ChildItem -LiteralPath $legacy -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($e.FullName -eq ("" + $script:PersonalUpdateTo) -or $e.FullName -eq ("" + $script:PersonalDeployDir)) { continue }
            if (Test-PersonalDeploymentFolder $e.FullName) { $script:PersonalUpdateOthers += $e.Name }
        }
    }
    return $true
}

# Get-PersonalUpdateMovedOthers - the deployments Initialize-PersonalUpdate
# found beside the kit's in the older root that are now in the 2.5 root
# instead: a new launcher that ran once before its undo moved them, and the
# old launcher, put back, does not look there. Their names quoted, in the
# order found. Twin of personal_update_moved_others.
function Get-PersonalUpdateMovedOthers {
    $roots = Resolve-PersonalDeployDir -Path ""
    $moved = @()
    foreach ($name in @($script:PersonalUpdateOthers)) {
        if (-not $name -or -not $roots.LegacyRoot -or -not $roots.NewRoot) { continue }
        if (Test-Path -LiteralPath (Join-Path $roots.LegacyRoot $name)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $roots.NewRoot $name) -PathType Container)) { continue }
        $moved += "'$name'"
    }
    return $moved
}

# Undo-PersonalUpdate -Why <why> [-InUse] - a launcher swap that did not
# work, put back: the old launcher from its copy (with the kit's receipt, when
# it is the kit's), the folder renamed back to its 0.3.0 name wherever the new
# launcher left it, and the records with it; the database started again when
# it ran. Said, with <why>, and with what could not be put back. -InUse: a
# program runs the launcher, and the last line says what to do about it.
# Twin of personal_update_undo.
function Undo-PersonalUpdate {
    param([Parameter(Mandatory)][string]$Why, [switch]$InUse)
    $whole = $true
    # The kit's own launcher that the update of a kit on the user's launcher put
    # in the kit's folder goes, the record names theirs again, and the kit runs
    # it as before. Theirs was never touched, so there is nothing of it to put
    # back.
    if ($script:PersonalUpdateKitCopy) {
        Remove-Item -LiteralPath $script:PersonalUpdateKitCopy -Force -ErrorAction SilentlyContinue
        $script:PersonalUpdateKitCopy = ""
        $script:PersonalSeparate = $false
        $script:PersonalBinPath = Join-Path $script:BinDir "exasol.exe"
        $script:PersonalReceiptLauncher = "" + $script:PersonalUpdateTheirs
        try {
            if (("" + (Get-ExakitManifestValue "components.personal.ownership")) -ne "user" -or
                ("" + (Get-ExakitManifestValue "components.personal.ownership_path")) -ne $script:PersonalUpdateTheirs) {
                Set-ExakitComponentOwnership "personal" "user" $script:PersonalUpdateTheirs
            }
            if ($null -ne (Get-ExakitManifestValue "components.personal.user_launcher")) { Remove-ExakitManifestValue "components.personal.user_launcher" }
        } catch { Write-ExakitLog "WARN" "the record of the user's launcher could not be put back: $_" }
    }
    # A launcher this update put in the kit's folder (the move off PATH) goes,
    # and the kit runs the old one again, where it was.
    if ($script:PersonalUpdateMoveFrom) {
        if ($script:PersonalBinPath -ne $script:PersonalUpdateMoveFrom) {
            Remove-Item -LiteralPath $script:PersonalBinPath -Force -ErrorAction SilentlyContinue
        }
        $script:PersonalSeparate = $false
        $script:PersonalBinPath = $script:PersonalUpdateMoveFrom
        $script:PersonalUpdateMoveFrom = ""
    }
    $copy = "" + $script:PersonalUpdateCopy
    $bin = "" + $script:PersonalUpdateBin
    if ($copy -and (Test-Path -LiteralPath $copy -PathType Leaf)) {
        # Its bytes still the copy's (the new launcher never got in): nothing
        # to put back, and nothing to write over a file that is in use.
        $back = (Test-PersonalSameFile -A $bin -B $copy)
        if (-not $back) {
            try {
                Copy-Item -LiteralPath $copy -Destination $bin -Force -ErrorAction Stop
                $back = $true
            } catch { $back = $false }
        }
        if ($back) {
            if ($script:PersonalUpdateReceipt -eq "kit") {
                try {
                    Set-ExakitComponentOwnership "personal" "kit" $bin
                    Clear-PersonalRetireNote
                    # A receipt written from an older kit's record proves the
                    # place, not the file, after the undo too (Get-PersonalRetireSha).
                    if ($script:PersonalUpdateLegacy) { $null = Set-ExakitManifestValue "components.personal.ownership_legacy" "true" }
                } catch { }
            }
            Remove-PersonalUpdateLauncherCopy
        } else {
            $whole = $false
            Warn2 "The launcher could not be put back. A copy of it is at $(Get-ExakitTilde $copy)."
        }
    }
    if ($script:PersonalUpdateRenamed) {
        $from = "" + $script:PersonalUpdateFrom
        $to = "" + $script:PersonalUpdateTo
        $at = $to
        if (-not (Test-Path -LiteralPath $at -PathType Container)) {
            # Moved by the new launcher's first command: into its own root,
            # under the same name, carrying the id the kit recorded.
            $at = "" + (Resolve-PersonalDeployDir -Path "").New
            $want = "" + (Get-ExakitManifestValue "runtime.deployment_id")
            if (-not ($at -and $want -and (Test-Path -LiteralPath $at -PathType Container) -and
                      ((Read-PersonalDeploymentId -Dir $at) -ceq $want))) { $at = "" }
        }
        $parent = Split-Path -Parent $from
        if ($at -and $parent -and -not (Test-Path -LiteralPath $parent)) {
            try { New-Item -ItemType Directory -Force -Path $parent | Out-Null } catch { }
        }
        $back = $false
        # Like every rename, only while the launcher, asked now, says stopped.
        $atStopped = ($at -and (@("stopped", "initialized") -contains ("" + (Get-PersonalStateOf -Dir $at))))
        if ($atStopped -and $at -eq $to) {
            $back = (Undo-PersonalDeploymentRename -From $from -To $to)
        } elseif ($atStopped -and (Rename-PersonalDeploymentFolder -From $at -To $from)) {
            Update-PersonalDeploymentRecord -From $to -To $from
            Update-PersonalDeploymentRecord -From $at -To $from
            $back = $true
        }
        if ($back) {
            $script:PersonalUpdateRenamed = $false
        } else {
            $whole = $false
            if ($at -and $at -ne $to) { Update-PersonalDeploymentRecord -From $to -To $at }
            Warn2 "The database could not be renamed back to '$(Split-Path -Leaf $from)'. It keeps the name '$(Get-PersonalDeploymentName)', and the kit uses it under that name."
        }
    }
    $version = "" + $env:EXAKIT_PERSONAL_VERSION
    if (-not $version) { $version = "the new version" }
    # THE USER'S OTHER DATABASES are not "as they were" when the new launcher
    # ran once before this undo: its first command moved each stopped one
    # from the older root into its own, and the old launcher, put back, does
    # not look there. Said where they are now. Twin of the same lines in
    # personal_update_undo.
    $moved = @(Get-PersonalUpdateMovedOthers)
    $kitDb = "" + $script:PersonalUpdateFrom
    if (-not $kitDb) { $kitDb = "" + $script:PersonalDeployDir }
    if ($whole -and $moved.Count -eq 0) {
        Warn2 "Exasol Personal was not updated to $version, because $Why. The launcher and the database are as they were."
    } elseif ($whole) {
        Warn2 "Exasol Personal was not updated to $version, because $Why. The launcher and the database '$(Split-Path -Leaf $kitDb)' are as they were."
    } else {
        Warn2 "Exasol Personal was not updated to $version, because $Why."
    }
    if ($moved.Count -gt 0) {
        $newRoot = Get-ExakitTilde ("" + (Resolve-PersonalDeployDir -Path "").NewRoot)
        if ($moved.Count -eq 1) {
            Info "Your other database $($moved[0]) is now in $newRoot, where Exasol Personal 2.5 keeps it."
        } else {
            $named = (@($moved | Select-Object -First ($moved.Count - 1)) -join ", ") + " and " + $moved[-1]
            Info "Your other databases $named are now in $newRoot, where Exasol Personal 2.5 keeps them."
        }
    }
    Set-PersonalUpdateFailure "Exasol Personal was not updated to $version, because $Why"
    [void](Start-PersonalAfterUpdate)
    if ($InUse) {
        $script:PersonalUpdateInUse = $true
        Info "Close that program, then run exakit update again."
    } else { Info "The next exakit update tries again." }
}

# Set-PersonalUpdateStartsDatabase - an update that went through starts the
# database at its end even when it was stopped before (Krishna, 24 Nov): the
# step-5 start below then runs, once. An undo still leaves a stopped database
# stopped, as it was. Twin of the same rule in personal_update_start_again.
function Set-PersonalUpdateStartsDatabase {
    if (("" + (Get-ExakitManifestValue "runtime.type")) -ne "personal") { return }
    $dir = "" + $script:PersonalDeployDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $script:PersonalUpdateRan = $true
    $script:PersonalUpdateRestarted = $true
}

# Start-PersonalAfterUpdate - step 5's start, and the one after an undo: the
# database started once, and waited for as `exakit start` does, only when it
# ran before the update ($script:PersonalUpdateRan) and does not run now. When
# this update lifted the 20-session limit ($script:PersonalUpdateLifted) and
# the start fails, the file is put back and the database started with it, as
# the lift itself does. A start that fails is said, with the command that
# starts it. Twin of personal_update_start_again.
function Start-PersonalAfterUpdate {
    if (-not $script:PersonalUpdateRan) { Clear-PersonalStartOwed; return $true }
    if (Test-PersonalUpdateRuns) { Clear-PersonalStartOwed; return $true }
    if (Invoke-PersonalSessionLimitStart) { Clear-PersonalStartOwed; return $true }
    # Said below when it does not come up, with the command that starts it.
    Clear-PersonalStartOwed
    if ($script:PersonalUpdateLifted) {
        $script:PersonalUpdateLifted = $false
        Restore-PersonalSessionLimitConf "$(Get-PersonalSessionLimitConf).before-session-limit"
        foreach ($key in @("runtime.session_limit", "runtime.session_limit_lifted_at")) {
            try { if ($null -ne (Get-ExakitManifestValue $key)) { Remove-ExakitManifestValue $key } } catch { }
        }
        if (Invoke-PersonalSessionLimitStart) {
            Warn2 "The 20-session limit was not removed, because the database did not start without it. The file is as it was, and the database is running again."
            return $true
        }
        Warn2 "The 20-session limit was not removed, because the database did not start without it. The file is as it was, but the database did not start again. Start it with: exakit start"
        return $false
    }
    Warn2 "The database did not start again. Start it with: exakit start"
    return $false
}

# Test-PersonalUpdateSidecarProof -Dir <folder> -Login <login> -Port <port> -
# the MCP sidecar of the kit's name saved in <folder>\sidecars.yaml is the
# one the kit writes: its EXA_USER is the literal <login> (the kit's
# read-only login, not a value taken from the deployment's secret, as the
# launcher's own MCP server signs in) and it publishes a port on host port
# <port>. Anything else proves nothing. Read as text (the block of that
# sidecar under `sidecars:`), never printed or logged: the file holds a
# password. Twin of `sidecar_definition.py is-kits`.
function Test-PersonalUpdateSidecarProof {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Login, [Parameter(Mandatory)][string]$Port)
    $file = Join-Path $Dir "sidecars.yaml"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    $name = "" + (Get-Variable -Name McpSidecarName -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if (-not $name) { $name = "mcp" }
    try { $lines = @([System.IO.File]::ReadAllLines($file)) } catch { return $false }
    $inSidecars = $false
    $at = -1
    $depth = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -match '^\S') { $inSidecars = ($line -match '^sidecars:\s*$'); continue }
        if ($inSidecars -and $line -match ('^(\s+)[''"]?' + [regex]::Escape($name) + '[''"]?:\s*$')) {
            $at = $i
            $depth = $Matches[1].Length
            break
        }
    }
    if ($at -lt 0) { return $false }
    $block = @()
    for ($i = $at + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*(#|$)') { continue }
        if (($line.Length - $line.TrimStart().Length) -le $depth) { break }
        $block += $line
    }
    $text = $block -join "`n"
    # EXA_USER with a literal value on the entry's next line (in either order):
    # a valueFrom there is no value.
    $users = @()
    foreach ($m in [regex]::Matches($text, '(?m)^\s*-?\s*name:\s*[''"]?EXA_USER[''"]?[ \t]*\n\s*value:[ \t]*[''"]?([^''"\n]*?)[''"]?[ \t]*$')) { $users += $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($text, '(?m)^\s*-?\s*value:[ \t]*[''"]?([^''"\n]*?)[''"]?[ \t]*\n\s*name:\s*[''"]?EXA_USER[''"]?[ \t]*$')) { $users += $m.Groups[1].Value }
    if (@($users | Where-Object { [string]::Equals($_, $Login, [StringComparison]::Ordinal) }).Count -eq 0) { return $false }
    $ports = @([regex]::Matches($text, '(?m)^\s*-?\s*hostPort:[ \t]*[''"]?([0-9]+)[''"]?[ \t]*$') | ForEach-Object { $_.Groups[1].Value })
    return ($ports -contains $Port.Trim())
}

# Save-PersonalUpdateSidecarRecord - the record a kit before 0.3.1 never
# wrote (components.mcp_server.sidecar_dir), written once the database is
# followed by its id, when the MCP sidecar of the deployment in use is
# provably the kit's: the kit's MCP server is recorded (backend "sidecar", its
# read-only login and its port), and the sidecar saved in the deployment's
# sidecars.yaml signs in with that login and publishes that port
# (Test-PersonalUpdateSidecarProof). Without it, a database the user let the
# 0.3.0 kit use kept the kit's MCP server running after `exakit uninstall`:
# Test-McpSidecarIsKits could not tell it was the kit's. Nothing is claimed
# for the kit's own database (its sidecar is the kit's without a record), a
# record already there, a database the kit may not act on, or when the proof
# cannot be read. A sidecar the user set up is never claimed. Twin of
# mcp_sidecar_claim.
function Save-PersonalUpdateSidecarRecord {
    if (("" + (Get-ExakitManifestValue "components.mcp_server.backend")) -ne "sidecar") { return }
    if ("" + (Get-ExakitManifestValue "components.mcp_server.sidecar_dir")) { return }
    if ((Get-ExakitComponentOwnership "database") -eq "kit") { return }
    $login = "" + (Get-ExakitManifestValue "components.mcp_server.connection.user")
    $port = "" + (Get-ExakitManifestValue "components.mcp_server.port")
    if (-not $login -or -not $port) { return }
    Update-PersonalDeployDir
    $dir = "" + $script:PersonalDeployDir
    if (-not $dir -or -not (Test-Path -LiteralPath (Join-Path $dir "sidecars.yaml") -PathType Leaf)) { return }
    $state = ""
    try { $state = "" + (Get-ExakitPersonalDbState) } catch { $state = "" }
    if ($state) { return }
    if (-not (Test-PersonalUpdateSidecarProof -Dir $dir -Login $login -Port $port)) { return }
    try { Set-ExakitManifestValue "components.mcp_server.sidecar_dir" $dir } catch { return }
    Write-ExakitLog "INFO" "the MCP sidecar in $dir is the kit's (set up by an earlier kit): recorded"
}

# Update-PersonalCurrent - the update with no launcher to replace: one at
# 2.5.0 or later over a database that is still a 0.3.0 kit's `default`
# (launcher 2.5 moved it into its own root, or it ran when the launcher was
# swapped). Steps 1, 2, 4 and 5 in one restart: stopped when it runs (a line
# says it first), renamed to starter-kit-local, its 20-session limit lifted
# while it is stopped, started again once. Nothing to rename, or a launcher
# before 2.5.0 (the rename waits for the launcher's own update): nothing done
# here, the limit is the caller's (Remove-PersonalSessionLimit). $true when
# done or nothing to do, $false when not done: said, nothing changed, the
# database running again when it ran. $script:PersonalUpdateKept is $true when
# EXAKIT_CONFIRM_RUNTIME_UPDATE=0 keeps the database as it is. Twin of
# personal_update_current.
$script:PersonalUpdateKept = $false
function Update-PersonalCurrent {
    $script:PersonalUpdateKept = $false
    $script:PersonalUpdateRan = $false
    $script:PersonalUpdateRenamed = $false
    $script:PersonalUpdateLifted = $false
    $script:PersonalUpdateFrom = "" + (Get-PersonalUpdateRenameSource)
    if ($script:PersonalUpdateFrom) {
        # Its id first, while its folder is where the record says: the
        # launcher's `version` below can move a stopped one.
        [void](Save-PersonalUpdateDeploymentId)
        $version = "" + (Get-PersonalLauncherVersion)
        if (-not $version -or (Test-PersonalVersionOutranks "2.5.0" $version)) { $script:PersonalUpdateFrom = "" }
    }
    if (-not $script:PersonalUpdateFrom) { return $true }
    # A deliberate no keeps the database as it is, as on every other arm
    # (`exakit update --yes` sets 1, `update --json` without it sets 0).
    if (("" + [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")) -cmatch '^(0|n|N|no|NO|No)$') {
        $to = "" + $env:EXAKIT_PERSONAL_VERSION
        if (-not $to) { $to = $version }
        Warn2 "personal $(Get-ExakitManifestValue 'runtime.version') -> $to was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update --yes"
        $script:PersonalUpdateKept = $true
        return $false
    }
    $script:PersonalUpdateTo = Join-Path (Split-Path -Parent $script:PersonalUpdateFrom) (Get-PersonalDeploymentName)
    if (-not (Test-PersonalUpdateRenameFree -From $script:PersonalUpdateFrom)) {
        Write-PersonalUpdateNotRenamed
        return $false
    }
    if (-not (Save-PersonalUpdateDeploymentId)) {
        $script:PersonalRenameError = "noid"
        Write-PersonalUpdateNotRenamed
        return $false
    }
    if (-not (Stop-PersonalForUpdate -Line "The database stops and starts again once, to rename it to '$(Get-PersonalDeploymentName)'.")) { return $false }
    if (-not (Rename-PersonalForUpdate)) { return $false }
    # Followed by its id, wherever the launcher has it now, and the MCP
    # sidecar a 0.3.0 kit set up in a database of the user's recorded as the
    # kit's when that is provable. The one start comes even when a step here
    # fails, as in Update-Personal.
    $afterRenameError = $null
    try {
    Reset-PersonalDeployFollow
    Update-PersonalDeployDir
    Save-PersonalEngineOwn
    Save-PersonalUpdateSidecarRecord
    [void](Remove-PersonalSessionLimit)
    $script:PersonalUpdateLifted = [bool]$script:PersonalSessionLimitLiftedNow
    } catch { $afterRenameError = $_ }
    if ($null -eq $afterRenameError) { Set-PersonalUpdateStartsDatabase }
    [void](Start-PersonalAfterUpdate)
    if ($null -ne $afterRenameError) { throw $afterRenameError }
    if (Get-Command Clear-ExakitUpdateFailureNote -ErrorAction SilentlyContinue) { Clear-ExakitUpdateFailureNote }
    return $true
}

# Update-PersonalUser -Installed <v> -Advertised <v> - the update of a 0.3.0
# kit whose database is run by the USER'S launcher, behind the pin: a database
# they let the kit use (runtime.ownership user), or the kit's own that the
# 0.3.0 kit deployed with their launcher (Q15). The same one restart as the
# kit's own (Update-Personal). THEIR LAUNCHER IS NEVER WRITTEN, MOVED OR
# DELETED (#41, Krishna, 24 Nov): it is run to read and to stop the database,
# and the kit's own 2.5, checksum checked, goes into the kit's folder and runs
# the database from then on. Who owns the database does not change. Accepted:
# the kit's 2.5 moves their other stopped 2.4 deployments into the 2.5 root.
# The pinned release is downloaded and checked before anything stops.
# $script:PersonalUpdateResult says what it did: "skipped" when this is not
# that update (another owner, the kit's own launcher, one at or past the pin,
# a major upgrade, no database), and the caller carries on as before;
# "updated"; "undone" when it did not happen (said, put back, the database
# running again when it ran: `exakit update` tries again next time); "kept"
# when EXAKIT_CONFIRM_RUNTIME_UPDATE=0 keeps the database as it is. Twin of
# personal_update_user.
function Update-PersonalUser {
    param([string]$Installed = "", [string]$Advertised = "")
    $script:PersonalUpdateResult = "skipped"
    $script:PersonalUpdateRestarted = $false
    $script:PersonalUpdateWhy = ""
    $script:PersonalUpdateInUse = $false
    $want = ("" + $Advertised).Trim()
    if (-not $want) { return }
    if (("" + (Get-ExakitManifestValue "runtime.type")) -ne "personal") { return }
    # Q15 (Krishna, 24 Nov): every 0.3.0 user goes to 2.5, also a kit's OWN
    # database that the 0.3.0 kit deployed with the user's launcher. The same
    # update, and the database receipt stays the kit's.
    $dbOwner = "" + (Get-ExakitManifestValue "runtime.ownership")
    if (@("user", "kit") -notcontains $dbOwner) { return }
    if (Test-ExakitComponentManaged "personal") { return }
    # For the kit's own database, only a launcher recorded as the USER'S: a
    # launcher of the kit's that changed since it was recorded is no one's to
    # replace (left as it is).
    # ("unknown" is that receipt cut short while it was written.)
    if ($dbOwner -eq "kit" -and @("user", "unknown") -notcontains ("" + (Get-ExakitManifestValue "components.personal.ownership"))) { return }
    $state = ""
    try { $state = "" + (Get-ExakitPersonalDbState) } catch { $state = "" }
    if ($state) { return }
    Update-PersonalDeployDir
    $dir = "" + $script:PersonalDeployDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $bin = "" + (Get-PersonalCli)
    if (-not $bin -or -not (Test-Path -LiteralPath $bin -PathType Leaf)) { return }
    # Its id first, while its folder is where the record says (a 0.3.0 kit
    # kept none for a database of the user's): the follow after the move
    # needs it, and so does a launcher they update themselves later.
    [void](Save-PersonalUpdateDeploymentId)
    $have = "" + (Get-PersonalLauncherVersion)
    if (-not $have) { return }
    if (-not (Test-PersonalVersionOutranks $want $have)) { return }
    $majorOf = { param($v) $m = [regex]::Match("$v".TrimStart("v"), '^\d+'); if ($m.Success) { $m.Value } else { "" } }
    $haveMajor = & $majorOf $have
    $wantMajor = & $majorOf $want
    if ($haveMajor -and $wantMajor -and $haveMajor -ne $wantMajor) { return }
    if (("" + [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")) -cmatch '^(0|n|N|no|NO|No)$') {
        Warn2 "personal $have -> $want was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update --yes"
        $script:PersonalUpdateResult = "kept"
        return
    }
    # Only the kit's own program file is written: one an undone update left, and
    # a program still runs, is found before anything stops.
    $kitBin = "" + (Get-PersonalSeparateBinPath)
    if (-not $kitBin) { return }
    if (Test-PersonalLauncherInUse -Path $kitBin) {
        Warn2 "Exasol Personal was not updated, because another program is using the launcher at $(Get-ExakitTilde $kitBin). Nothing was changed."
        Info "Close that program, then run exakit update again."
        Set-PersonalUpdateFailure "Exasol Personal was not updated, because another program is using the launcher at $kitBin"
        $script:PersonalUpdateInUse = $true
        $script:PersonalUpdateResult = "undone"
        return
    }
    Write-PersonalUpdateExplanation -Installed $have -Advertised $want
    $script:ExakitRuntimeUpdateSaid = $false
    $env:EXAKIT_PERSONAL_VERSION = $want
    # The pinned release, downloaded and checked before anything stops: a
    # download that fails, or fails its check, changes nothing.
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-personal-$([guid]::NewGuid().ToString('N'))"
    $downloaded = ""
    $prevQuiet = $script:ExakitQuietDetail
    try {
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
        if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }
        $downloaded = "" + @(Get-PersonalLauncherDownload -Version $want -TmpDir $tmpDir)[-1]
    } catch {
        $downloaded = ""
        Write-ExakitLog "WARN" "Exasol Personal ${want}: $($_.Exception.Message)"
    } finally {
        $script:ExakitQuietDetail = $prevQuiet
    }
    if (-not $downloaded -or -not (Test-Path -LiteralPath $downloaded -PathType Leaf)) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        Warn2 "Exasol Personal was not updated to $want, because the new launcher could not be installed. The launcher and the database are as they were."
        Set-PersonalUpdateFailure "Exasol Personal was not updated to $want, because the new launcher could not be installed"
        $script:PersonalUpdateResult = "undone"
        return
    }
    $theirPwBefore = ("" + (Get-ExakitCredential "personal_sys_password")).TrimEnd("`r", "`n")
    # Nothing of theirs is copied, and nothing of theirs is put back.
    $script:PersonalUpdateBin = ""
    $script:PersonalUpdateReceipt = "user"
    $script:PersonalUpdateLifted = $false
    $script:PersonalUpdateTheirs = $bin
    if (-not (Initialize-PersonalUpdate -Line "")) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        $script:PersonalUpdateResult = "undone"
        return
    }
    # It is started again here, once (Start-PersonalAfterUpdate), never a
    # second time by a caller.
    $script:PersonalUpdateRestarted = [bool]$script:PersonalUpdateRan
    # THE KIT'S OWN LAUNCHER, in the kit's folder. A file already there is the
    # kit's by its place, and is written over with the release just checked.
    $script:PersonalUpdateKitCopy = $kitBin
    # Theirs recorded first, then the file in one step, then the receipt: cut
    # short anywhere, the next update finishes it.
    $placed = $true
    try {
        Set-ExakitManifestValue "components.personal.user_launcher" $bin
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $kitBin) | Out-Null
        Move-Item -LiteralPath $downloaded -Destination "$kitBin.new" -Force -ErrorAction Stop
        Move-Item -LiteralPath "$kitBin.new" -Destination $kitBin -Force -ErrorAction Stop
    } catch {
        $placed = $false
        Remove-Item -LiteralPath "$kitBin.new" -Force -ErrorAction SilentlyContinue
        Write-ExakitLog "WARN" "the kit's own launcher at ${kitBin}: $($_.Exception.Message)"
    }
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    if (-not $placed) {
        if (Test-PersonalLauncherInUse -Path $kitBin) { Undo-PersonalUpdate -Why "another program is using the launcher at $(Get-ExakitTilde $kitBin)" -InUse }
        else { Undo-PersonalUpdate -Why "the new launcher could not be installed" }
        $script:PersonalUpdateResult = "undone"
        return
    }
    $script:PersonalUpdateBin = $kitBin
    $answers = Test-PersonalUpdateLauncherAnswers
    $script:PersonalUpdateBin = ""
    if (-not $answers) {
        Undo-PersonalUpdate -Why "the new launcher did not run on this computer"
        $script:PersonalUpdateResult = "undone"
        return
    }
    # The kit's launcher from now on (owner kit). Theirs stays theirs, recorded
    # as theirs, and the database stays whose it was.
    $recorded = $true
    try {
        Set-ExakitComponentOwnership "personal" "kit" $kitBin
    } catch {
        $recorded = $false
        Write-ExakitLog "WARN" "the kit's launcher record: $_"
    }
    if (-not $recorded) {
        Undo-PersonalUpdate -Why "the new launcher could not be installed"
        $script:PersonalUpdateResult = "undone"
        return
    }
    $script:PersonalUpdateKitCopy = ""
    Use-PersonalSeparateLauncher
    Info "The kit's Exasol launcher is now in $(Get-ExakitTilde (Split-Path -Parent $kitBin)). Run it with: exakit exasol"
    # The one start comes even when a step below fails, as in Update-Personal.
    $afterSwapError = $null
    try {
    # The new launcher's first command moved the folder: the record follows
    # it by its id, and says the launcher now runs it.
    Reset-PersonalDeployFollow
    Set-PersonalManifest
    Save-PersonalUpdateSidecarRecord
    try { Set-ExakitManifestValue "desired.runtime.personal" $want } catch { }
    $null = Update-PersonalChangedPassword $theirPwBefore
    [void](Remove-PersonalSessionLimit)
    $script:PersonalUpdateLifted = [bool]$script:PersonalSessionLimitLiftedNow
    } catch { $afterSwapError = $_ }
    if ($null -eq $afterSwapError) { Set-PersonalUpdateStartsDatabase }
    [void](Start-PersonalAfterUpdate)
    if ($null -ne $afterSwapError) { throw $afterSwapError }
    if (Get-Command Clear-ExakitUpdateFailureNote -ErrorAction SilentlyContinue) { Clear-ExakitUpdateFailureNote }
    $script:PersonalUpdateResult = "updated"
}

# Save-PersonalLegacyReceipts - a kit from before ownership receipts (0.2.4,
# 0.2.5) wrote none, and its launcher and database are the kit's only by the
# path it recorded for the launcher (Test-ExakitLegacyKitOwned). The update
# moves that launcher, and the proof goes with it: the missing receipts are
# written from it first, the database's before the launcher's, so the database
# stays the kit's and its session limit is lifted. A launcher receipt written
# here proves the place, not the file: the old file is retired only when it is
# the published 2.4.0 (those kits' own pin). $true when the launcher's was
# written. Twin of personal_legacy_receipts.
$script:PersonalPublished240Sha = "1dd3101d34e59c4e82b15dd1163e713b5e2afcb71239c4fc8411dc331bf0c0be"
function Save-PersonalLegacyReceipts {
    $launcher = ((-not ("" + (Get-ExakitManifestValue "components.personal.ownership"))) -and (Test-ExakitLegacyKitOwned "personal"))
    $database = ((-not ("" + (Get-ExakitManifestValue "runtime.ownership"))) -and (Test-ExakitLegacyKitOwned "database"))
    if ($database) {
        Update-PersonalDeployDir
        Set-ExakitComponentOwnership "database" "kit" ("" + $script:PersonalDeployDir)
    }
    if ($launcher) {
        Set-ExakitComponentOwnership "personal" "kit" (Get-ExakitLegacyKitPath "personal")
        Set-ExakitManifestValue "components.personal.ownership_legacy" "true"
    }
}

# Get-PersonalRetireSha - the checksum the launcher a 0.3.0 kit put at
# .local\bin must have to be removed once the kit's is in its folder: the one
# recorded with its receipt, and the published 2.4.0's when that receipt was
# written from an older kit's record.
function Get-PersonalRetireSha {
    if (("" + (Get-ExakitManifestValue "components.personal.ownership_legacy")) -eq "true") { return $script:PersonalPublished240Sha }
    return "" + (Get-ExakitManifestValue "components.personal.ownership_sha256")
}

function Update-Personal {
    param([string]$Advertised = "")
    $script:PersonalUpdateResult = ""
    $script:PersonalUpdateRestarted = $false
    $script:PersonalUpdateWhy = ""
    $script:PersonalUpdateInUse = $false
    if (-not (Test-ExakitComponentManaged "personal")) { Write-ExakitPreservedComponent "personal"; return }
    # The update restarts and re-records the deployment: only the kit's own.
    if (-not (Test-ExakitKitDatabaseGuard)) { return }
    if (-not $Advertised) { $Advertised = Get-PersonalTargetVersion }
    # A DELIBERATE NO HOLDS BACK EVERY WAY IN: `exakit update personal` by name
    # too, as `exakit update` does (Invoke-ExakitRuntimeUpdateOffer).
    if (("" + [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")) -cmatch '^(0|n|N|no|NO|No)$') {
        $installed = "" + (Get-ExakitManifestValue "runtime.version")
        if (-not $installed) { $installed = "unknown" }
        Warn2 "personal $installed -> $Advertised was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update --yes"
        $script:PersonalUpdateResult = "kept"
        return
    }
    Save-PersonalLegacyReceipts
    # NO WSL CHECK BEFORE THE SWAP, ON PURPOSE. A launcher swap changes no
    # data, and the WSL release is only a proxy for the real question (can
    # Podman build the 2.4 network?): a Podman machine on the iptables driver
    # runs 2.4 on WSL 2.5, and the first update from kit 0.2.3 runs 0.2.3's
    # code, which never asked anyway. So the update goes through, and the
    # evidence decides at the start: when the launcher's own output carries
    # netavark's nftables error, Stop-PersonalStartNetworkBlocked names
    # wsl --update, with the deployment and its data untouched. Twin of the
    # same note in personal_update.
    $pwBefore = ("" + (Get-ExakitCredential "personal_sys_password")).TrimEnd("`r", "`n")
    $env:EXAKIT_PERSONAL_VERSION = $Advertised
    # ONE RESTART, AND NOTHING 2.5 RUNS BEFORE THE RENAME (the update from a
    # 0.3.0 kit, see Get-PersonalUpdateRenameSource): a copy of the working
    # launcher kept, the database's id recorded, the database stopped with
    # the launcher that runs it now, and a 0.3.0 `default` renamed to
    # starter-kit-local. The stop is said first unless `exakit update` has
    # said it already (Write-ExakitRuntimeUpdateExplanation). A launcher file
    # that another program runs is found before any of it: Windows would
    # refuse the swap. Not done: said, nothing changed, the database running
    # again when it ran. Twin of the same step in personal_update.
    $script:PersonalUpdateBin = $script:PersonalBinPath
    $script:PersonalUpdateReceipt = "kit"
    $script:PersonalUpdateLegacy = (("" + (Get-ExakitManifestValue "components.personal.ownership_legacy")) -eq "true")
    $script:PersonalUpdateLifted = $false
    # THE KIT'S OWN LAUNCHER LEAVES PATH (Krishna, 24 Nov): one a 0.3.0 kit
    # put at %USERPROFILE%\.local\bin\exasol.exe gets its update in the kit's
    # folder. The old file goes once the new one has answered, and only when it
    # is still the file the kit recorded. An undo puts the old one back as the
    # kit's (Undo-PersonalUpdate).
    $script:PersonalUpdateMoveFrom = ""
    $script:PersonalUpdateMoveSha = ""
    if (-not $script:PersonalSeparate -and (Get-PersonalSeparateBinPath) -and $script:PersonalBinPath -ne (Get-PersonalSeparateBinPath)) {
        $script:PersonalUpdateMoveFrom = "" + $script:PersonalBinPath
        $script:PersonalUpdateMoveSha = Get-PersonalRetireSha
        Save-PersonalRetireNote -Path $script:PersonalUpdateMoveFrom -Sha $script:PersonalUpdateMoveSha
    }
    $installed = "" + (Get-ExakitManifestValue "runtime.version")
    if (-not $installed) { $installed = "unknown" }
    $stopLine = ""
    if (-not $script:ExakitRuntimeUpdateSaid) { $stopLine = "personal $installed -> $Advertised needs the database stopped." }
    $script:ExakitRuntimeUpdateSaid = $false
    if (Test-PersonalLauncherInUse -Path $script:PersonalBinPath) {
        Warn2 "Exasol Personal was not updated, because another program is using the launcher at $(Get-ExakitTilde $script:PersonalBinPath). Nothing was changed."
        Info "Close that program, then run exakit update again."
        Set-PersonalUpdateFailure "Exasol Personal was not updated, because another program is using the launcher at $($script:PersonalBinPath)"
        $script:PersonalUpdateInUse = $true
        $script:PersonalUpdateResult = "undone"
        return
    }
    if (-not (Initialize-PersonalUpdate -Line $stopLine)) {
        $script:PersonalUpdateResult = "undone"
        return
    }
    # It is started again here, once (Start-PersonalAfterUpdate), never a
    # second time by the caller (Invoke-ExakitRuntimeUpdateApply,
    # Update-PersonalBehindLauncher).
    $script:PersonalUpdateRestarted = [bool]$script:PersonalUpdateRan
    # The working launcher stays until the new one is verified (audit LCY-06),
    # and its copy until the new one has answered: a failure up to there puts
    # the launcher, the folder's name and the records back
    # (Undo-PersonalUpdate). Caught, so a Fail on a bad download or a full
    # disk, or a launcher file Windows will not replace, ends the swap only,
    # never the run between the rename and its undo.
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    $swapError = ""
    if ($script:PersonalUpdateMoveFrom) { Use-PersonalSeparateLauncher }
    try {
        Install-PersonalLauncher
    } catch {
        $swapError = "" + $_.Exception.Message
        if (-not $swapError) { $swapError = "" + $_ }
    } finally {
        Remove-Item Env:EXAKIT_FORCE_COMPONENT_INSTALL -ErrorAction SilentlyContinue
    }
    if ($swapError) {
        Write-ExakitLog "WARN" "the launcher swap did not happen: $swapError"
        if (Test-PersonalLauncherInUse -Path $script:PersonalBinPath) {
            Undo-PersonalUpdate -Why "another program is using the launcher at $(Get-ExakitTilde $script:PersonalBinPath)" -InUse
        } else {
            Undo-PersonalUpdate -Why "the new launcher could not be installed"
        }
        $script:PersonalUpdateResult = "undone"
        return
    }
    $answers = $false
    if ($script:PersonalUpdateMoveFrom) {
        # The new launcher is in the kit's folder: that one is asked.
        $script:PersonalUpdateBin = $script:PersonalBinPath
        $answers = Test-PersonalUpdateLauncherAnswers
        $script:PersonalUpdateBin = $script:PersonalUpdateMoveFrom
    } else { $answers = Test-PersonalUpdateLauncherAnswers }
    if (-not $answers) {
        Undo-PersonalUpdate -Why "the new launcher did not run on this computer"
        $script:PersonalUpdateResult = "undone"
        return
    }
    Remove-PersonalUpdateLauncherCopy
    # One an update cut short left to retire.
    if (-not $script:PersonalUpdateMoveFrom) { Complete-PersonalRetire }
    if ($script:PersonalUpdateMoveFrom) {
        if (Remove-PersonalRetired -Path $script:PersonalUpdateMoveFrom -Sha $script:PersonalUpdateMoveSha) { Clear-PersonalRetireNote }
        $script:PersonalUpdateMoveFrom = ""
        Info "The kit's Exasol launcher is now in $(Get-ExakitTilde (Split-Path -Parent $script:PersonalBinPath)). Run it with: exakit exasol"
    }
    # THE ONE START COMES EVEN WHEN A STEP BELOW FAILS (a manifest that cannot
    # be written, a password file another program holds): a database that ran
    # is never left stopped by the records after the swap. The step's error
    # still ends the run, after the start, as it did before it. Twin of the
    # record, claim and lift steps run apart in personal_update.
    $afterSwapError = $null
    try {

    # THE NEW LAUNCHER'S FIRST COMMAND MOVED THE FOLDER into its own root (or
    # left it in the older one): the record follows it by its id
    # (Update-PersonalDeployDir, through Set-PersonalManifest), asked of the
    # new launcher.
    Reset-PersonalDeployFollow
    # The launcher moved; the deployment did not. Status is PROBED, never
    # assumed healthy - updating a stopped database used to record it healthy
    # on the sh side, and anything reading the manifest was then simply wrong.
    Set-PersonalManifest
    # THE MCP SIDECAR A 0.3.0 KIT SET UP in a database the user let it use
    # (run by the kit's own launcher), which that kit kept no record of:
    # recorded as the kit's when it proves it, so an update refreshes it and
    # the uninstall removes it. Nothing to do for the kit's own database.
    Save-PersonalUpdateSidecarRecord
    # THE PASSWORD IS CHECKED, NOT ASSUMED. Set-PersonalManifest has just re-read
    # secrets.json; when the credential on file differs from the one before the
    # swap, the records that depend on it follow and the change is said.
    $pwState = "" + (Update-PersonalChangedPassword $pwBefore)
    # AN UNREADABLE secrets.json IS "unknown", NOT "same": Set-PersonalManifest
    # leaves the credential alone when it cannot read the password, so the
    # comparison read the old one twice. Twin of the same check in personal_update.
    if ($pwState -eq "same" -and -not (Test-PersonalSecretsReadable)) { $pwState = "unknown" }
    # WHAT STAYS THE SAME, said once, where the reader is wondering: 2.4 gives
    # new deployments a random password and a choice of engine, and neither
    # reaches a deployment that already exists. The one visible change is the
    # network move, and it happens at the next stop-and-start, not now. The
    # password is named only when both readings agree.
    if ((Test-PersonalUpdateCrossesTo24 $Advertised) -and (Test-PersonalDeploymentExists)) {
        if ($pwState -eq "same") {
            Info "The existing deployment keeps its engine ($(Get-PersonalEngineRecorded)) and its database password: the launcher changed neither."
        } else {
            Info "The existing deployment keeps its engine ($(Get-PersonalEngineRecorded))."
        }
        Info "Its next 'exakit stop' followed by 'exakit start' moves the containers onto the launcher's own deployment network, once."
    }
    # THE 20-SESSION LIMIT a launcher before 2.5.0 set on the kit's database
    # is removed now that 2.5.0 drives it (Remove-PersonalSessionLimit), before
    # the steps after this one use the database. A failure is said there and
    # leaves the database as it was: the launcher update itself stands. Twin
    # of the same call in personal_update.
    # The database is stopped by now (Initialize-PersonalUpdate), so the file
    # alone changes, and the one start below applies it.
    [void](Remove-PersonalSessionLimit)
    $script:PersonalUpdateLifted = [bool]$script:PersonalSessionLimitLiftedNow
    } catch { $afterSwapError = $_ }
    if ($null -eq $afterSwapError) { Set-PersonalUpdateStartsDatabase }
    [void](Start-PersonalAfterUpdate)
    if ($null -ne $afterSwapError) { throw $afterSwapError }
    # An earlier update's reason for not happening is history now.
    if (Get-Command Clear-ExakitUpdateFailureNote -ErrorAction SilentlyContinue) { Clear-ExakitUpdateFailureNote }
    $script:PersonalUpdateResult = "updated"
}

# Test-PersonalPortHeldByOwnRunner - twin of _personal_port_held_by_own_runner
# in runtime-personal.sh. On Windows the database port belongs to the
# engine's relay, not to a kit runner process, so ownership of the listener
# cannot be proven from here: the answer is always "not proven". mcp-doctor's
# stale-record check (Test-ExakitMcpDoctorFailedRecordAnswers) therefore keeps
# its plain behaviour on Windows, and `exakit start` remains the repair.
function Test-PersonalPortHeldByOwnRunner {
    return $false
}

# --- the 20-session limit of a database Exasol Personal 2.4 made ------------
# Launcher 2.5.0 makes local deployments with no session limit. A deployment an
# earlier launcher made keeps maxConnectionsLicenseLimit=20 (in [DB_PARAMS] of
# <deployment>\local\runtime\exa\exasol.conf) until that line is removed and the
# database restarted: `exasol stop`, delete the line, `exasol start` (the
# Exasol Personal 2.5 upgrade notes). Remove-PersonalSessionLimit does that for
# the kit's database (its own, or one the user let it use), once. Twin of the
# same block in runtime-personal.sh.

# Get-PersonalSessionLimitConf - the exasol.conf of the deployment in use.
# Twin of personal_session_limit_conf.
function Get-PersonalSessionLimitConf {
    Update-PersonalDeployDir
    return [IO.Path]::Combine($script:PersonalDeployDir, "local", "runtime", "exa", "exasol.conf")
}

# Test-PersonalSessionLimitSet - $true when the file carries the limit line.
# Twin of personal_session_limit_set.
function Test-PersonalSessionLimitSet([string]$Conf) {
    if (-not (Test-Path -LiteralPath $Conf -PathType Leaf)) { return $false }
    try { $text = [IO.File]::ReadAllText($Conf) } catch { return $false }
    return ($text -match '(?m)^[ \t]*maxConnectionsLicenseLimit[ \t]*=')
}

# Invoke-PersonalSessionLimitStart - the database started again and waited
# for, as `exakit start` does. Start-Personal's own Fail is this step's to
# handle. Twin of _personal_session_limit_start.
function Invoke-PersonalSessionLimitStart {
    try {
        Start-Personal
        if (-not (Wait-PersonalReadyOrDeploy)) { return $false }
    } catch { return $false }
    return ((Get-PersonalStatus) -eq "running")
}

# Restore-PersonalSessionLimitConf - the backup put back over the exasol.conf
# of the deployment in use (the folder may have moved during a start). Twin of
# _personal_session_limit_restore.
function Restore-PersonalSessionLimitConf([string]$Backup) {
    $conf = Get-PersonalSessionLimitConf
    $bak = Join-Path (Split-Path -Parent $conf) (Split-Path -Leaf $Backup)
    if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { $bak = $Backup }
    if (Test-Path -LiteralPath $bak -PathType Leaf) {
        try { Copy-Item -LiteralPath $bak -Destination $conf -Force } catch { }
    }
}

# Test-PersonalSessionLimitPending - $true when Remove-PersonalSessionLimit has
# work to do: the kit's database (runtime.type personal, never in
# kit_database_missing), the kit's own or one the user let the kit use
# (runtime.ownership user: the one the installer renamed at their choice, or a
# 0.3.0 kit's answer; permission to use it is permission to lift its limit,
# CONTRACT sections 4 and 6), not yet recorded as lifted, its exasol.conf
# still carrying the limit line, and launcher 2.5.0 or later driving it. Every
# check before the last one reads files only: with no line there, no launcher
# is asked anything. Twin of personal_session_limit_pending.
function Test-PersonalSessionLimitPending {
    if (("" + (Get-ExakitManifestValue "runtime.type")) -ne "personal") { return $false }
    if (("" + (Get-ExakitManifestValue "runtime.session_limit")) -eq "lifted") { return $false }
    $state = ""
    try { $state = "" + (Get-ExakitPersonalDbState) } catch { $state = "" }
    if ($state) { return $false }
    if (-not (Test-ExakitComponentManaged "database") -and ("" + (Get-ExakitManifestValue "runtime.ownership")) -ne "user") {
        return $false
    }
    # Nothing to remove: no launcher is asked anything.
    if (-not (Test-PersonalSessionLimitSet (Get-PersonalSessionLimitConf))) { return $false }
    $version = Get-PersonalLauncherVersion
    if (-not $version) { return $false }
    if (Test-PersonalVersionOutranks "2.5.0" $version) { return $false }
    return $true
}

# Remove-PersonalSessionLimit - remove the 20-session limit from the kit's
# database, when launcher 2.5.0 or later drives it and its exasol.conf still
# has the line. Only the kit's own deployment, or one the user let the kit use
# (Test-PersonalSessionLimitPending), never in kit_database_missing
# (Get-ExakitPersonalDbState). A backup of exasol.conf stays next to it, and
# only the limit line goes, every other byte (CRLF included) as it was. A
# running database is stopped with the launcher and started again, and waited
# for, as `exakit start` does. A stopped one stays stopped: its next start
# applies the change. Idempotent: no line, nothing to do and no restart. On success runtime.session_limit is
# "lifted" (with runtime.session_limit_lifted_at), so it never runs twice.
# $true when it lifted the limit or had nothing to do. $false when it failed:
# said, the file restored, and a database that was running before is started
# again. $false too when EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds back the restart
# of a running one: said, nothing changed, $script:PersonalUpdateKept is $true.
# $script:PersonalSessionLimitLiftedNow is $true when this call lifted
# it (the update's one start puts the file back when the database does not
# start without the line). Twin of personal_lift_session_limit.
# -Quiet: the one question's rename, which lifts it on the stopped database it
# just renamed, says nothing when that works, and one line when the file could
# not be changed, as the sh twin's personal_session_limit_remove there.
$script:PersonalSessionLimitLiftedNow = $false
function Remove-PersonalSessionLimit {
    param([switch]$Quiet)
    $script:PersonalUpdateKept = $false
    $script:PersonalSessionLimitLiftedNow = $false
    if (-not (Test-PersonalSessionLimitPending)) { return $true }
    # `version` under launcher 2.5.0 can move a stopped deployment's folder:
    # the file is read where it is now.
    $conf = Get-PersonalSessionLimitConf
    if (-not (Test-PersonalSessionLimitSet $conf)) { return $true }
    # "conflict" holds its port and does not answer yet (every Windows boot): its
    # file is not changed under it.
    $running = @("running", "starting", "conflict") -contains ("" + (Get-PersonalStatus))
    $remedy = "To remove the limit later, re-run the installer: $(Get-ExakitInstallCommand)"
    # A deliberate no holds back every restart, this one too.
    if ($running -and ("" + [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")) -cmatch '^(0|n|N|no|NO|No)$') {
        $to = "" + $env:EXAKIT_PERSONAL_VERSION
        if (-not $to) { $to = "" + (Get-PersonalLauncherVersion) }
        Warn2 "personal $(Get-ExakitManifestValue 'runtime.version') -> $to was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update --yes"
        $script:PersonalUpdateKept = $true
        return $false
    }
    if ($running) {
        Info "Removing the 20-session limit that Exasol Personal 2.4 set on this database. The database restarts once."
        $stopped = $true
        try { Stop-Personal } catch { $stopped = $false }
        if (-not $stopped) {
            Warn2 "The 20-session limit was not removed, because the database did not stop. Nothing was changed."
            if (("" + (Get-PersonalStatus)) -ne "running" -and -not (Invoke-PersonalSessionLimitStart)) {
                Warn2 "The database did not start again. Start it with: exakit start"
            }
            Info $remedy
            return $false
        }
        $conf = Get-PersonalSessionLimitConf
    } elseif (-not $Quiet) {
        Info "Removing the 20-session limit that Exasol Personal 2.4 set on this database. The change takes effect when the database next starts."
    }
    $bak = "$conf.before-session-limit"
    # Latin-1 maps every byte to one character and back, so the file is
    # written back byte for byte apart from the limit line.
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $edited = $false
    try {
        Copy-Item -LiteralPath $conf -Destination $bak -Force -ErrorAction Stop
        $text = $latin1.GetString([IO.File]::ReadAllBytes($conf))
        $kept = [regex]::Replace($text, '(?m)^[ \t]*maxConnectionsLicenseLimit[ \t]*=[^\r\n]*(\r\n|\n|\r)?', "")
        if ($kept -ne $text) {
            [IO.File]::WriteAllBytes($conf, $latin1.GetBytes($kept))
            $edited = $true
        }
    } catch { $edited = $false }
    if (-not $edited) {
        if (Test-Path -LiteralPath $bak -PathType Leaf) {
            try { Copy-Item -LiteralPath $bak -Destination $conf -Force } catch { }
        }
        if ($Quiet) {
            Warn2 "The 20-session limit of this database was not removed. Its file is as it was."
        } else {
            Warn2 "The 20-session limit was not removed, because $(Get-ExakitTilde $conf) could not be changed. The file is as it was."
        }
        if ($running -and -not (Invoke-PersonalSessionLimitStart)) {
            Warn2 "The database did not start again. Start it with: exakit start"
        }
        if (-not $Quiet) { Info $remedy }
        return $false
    }
    if ($running -and -not (Invoke-PersonalSessionLimitStart)) {
        Restore-PersonalSessionLimitConf $bak
        if (Invoke-PersonalSessionLimitStart) {
            Warn2 "The 20-session limit was not removed, because the database did not start without it. The file is as it was, and the database is running again."
        } else {
            Warn2 "The 20-session limit was not removed, because the database did not start without it. The file is as it was, but the database did not start again. Start it with: exakit start"
        }
        Info $remedy
        return $false
    }
    Set-ExakitManifestValue "runtime.session_limit" "lifted"
    Set-ExakitManifestValue "runtime.session_limit_lifted_at" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
    $script:PersonalSessionLimitLiftedNow = $true
    return $true
}
