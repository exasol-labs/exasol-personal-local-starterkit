# virtual-schemas.ps1 - `exakit connect` and `exakit source <action>`: query an
# external database from the local one through an Exasol virtual schema.
#
# Twin of virtual-schemas.sh. Dot-sourced by exakit.ps1 after
# exakit-common.ps1, runtime-personal.ps1 and pyexasol.ps1. The work is the
# shared Python engine in setup\virtual-schemas\engine, run with the kit's
# pyexasol interpreter; this file supplies the deployment, asks the questions,
# keeps secrets off the command line, and repairs what the engine reports but
# cannot fix from inside the database:
#
#   exit 20  Java in the database has no DNS resolver -> Repair-PersonalSlcDns, retry once
#   exit 21  the Java language container is missing   -> `exasol slc install java` (asked), retry once

function Get-ExakitVsDefs {
    $root = Get-ExakitRepoRoot
    if ($root) {
        $defs = Join-ExakitCorePath $root "setup" "virtual-schemas"
        if (Test-Path -LiteralPath (Join-Path $defs "catalog.json")) { return $defs }
    }
    $here = Join-Path (Split-Path -Parent $PSScriptRoot) "virtual-schemas"
    if (Test-Path -LiteralPath (Join-Path $here "catalog.json")) { return $here }
    return $null
}

# Test-ExakitVsAvailable - can a source be connected from here? Twin of
# exakit_vs_available: the definitions are present and the kit's pyexasol,
# which runs the engine, is installed.
function Test-ExakitVsAvailable {
    if (-not (Get-ExakitVsDefs)) { return $false }
    if (-not (Get-Command Get-PyexasolVenvPython -ErrorAction SilentlyContinue)) { return $false }
    return (Test-Path -LiteralPath (Get-PyexasolVenvPython))
}

# Invoke-ExakitVsEngine - the engine with this installation's context. The
# secret, when there is one, goes to its stdin base64-encoded (and
# --secret-stdin becomes --secret-stdin-base64): Windows PowerShell 5.1
# re-encodes what it pipes to a native program - measured on CI, a
# byte-order mark added and every non-ASCII character turned into '?' even
# with $OutputEncoding set to UTF-8 - and plain ASCII survives every code
# page. Returns @{ Code; Lines }.
function Invoke-ExakitVsEngine {
    param([string[]]$Arguments = @(), [string]$Secret = "")
    # Asked for JSON, the bridge's own failures come in the engine's shape too.
    $asJson = @($Arguments) -contains "--json"
    $defs = Get-ExakitVsDefs
    if (-not $defs) {
        if ($asJson) { return [pscustomobject]@{ Code = 2; Lines = @(New-ExakitVsFailureJson -Kind "setup" -Problem "this kit copy has no setup\virtual-schemas" -Remedy "update the kit: exakit update" -Command "exakit update") } }
        return [pscustomobject]@{ Code = 2; Lines = @("FAIL This kit copy has no setup\virtual-schemas. Update it: exakit update") }
    }
    $python = Get-PyexasolVenvPython
    if (-not (Test-Path -LiteralPath $python)) {
        if ($asJson) { return [pscustomobject]@{ Code = 2; Lines = @(New-ExakitVsFailureJson -Kind "setup" -Problem "virtual schemas run with the kit's pyexasol, which is not installed" -Remedy "repair it: exakit update pyexasol" -Command "exakit update pyexasol") } }
        return [pscustomobject]@{ Code = 2; Lines = @("FAIL Virtual schemas run with the kit's pyexasol, which is not installed. Repair it: exakit update pyexasol") }
    }
    $argv = @((Join-ExakitCorePath $defs "engine" "cli.py"), "--defs", $defs, "--kit-home", $script:ExakitHome)
    # An empty value is never passed: 5.1 drops it and the option before it
    # would swallow the next one.
    foreach ($pair in @(@("--deployment-dir", "runtime.deployment_dir"), @("--dsn", "runtime.dsn"),
                        @("--user", "runtime.user"), @("--password-file", "runtime.password_file"))) {
        $value = "" + (Get-ExakitManifestValue $pair[1])
        if ($value) { $argv += @($pair[0], $value) }
    }
    if ($Secret) {
        $argv += @($Arguments | ForEach-Object { if ($_ -eq "--secret-stdin") { "--secret-stdin-base64" } else { $_ } })
    } else {
        $argv += $Arguments
    }
    try { $errFile = [System.IO.Path]::GetTempFileName() }
    catch {
        if (-not $asJson) { throw }
        return [pscustomobject]@{ Code = 1; Lines = @(New-ExakitVsFailureJson -Kind "setup" -Problem "could not create a temporary file" -Remedy "check that the temporary folder exists, is writable and has space, then run the same command again") }
    }
    $previous = $ErrorActionPreference
    $previousEncoding = $OutputEncoding
    try {
        $ErrorActionPreference = "Continue"
        if ($Secret) {
            $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Secret))
            $lines = @($encoded | & $python @argv 2> $errFile)
            $encoded = $null
        } else {
            $lines = @(& $python @argv 2> $errFile)
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        $OutputEncoding = $previousEncoding
    }
    foreach ($line in @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)) {
        if ("$line".Trim()) { Write-ExakitLog "VS" "$line" }
    }
    Remove-Item -Force -LiteralPath $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $code; Lines = @($lines | ForEach-Object { "$_" }) }
}

# New-ExakitVsFailureJson - the engine's failure shape (cli.py) for what the
# bridge refuses or cannot run itself, so --json is one object of one shape
# whoever said no: what happened, its class, the fix in words, the one exakit
# command that is the fix or null; rejected and public_ip as the other
# refusals and plan/connect carry them. Twin of _exakit_vs_json_failure.
function New-ExakitVsFailureJson {
    param([string]$Kind, [string]$Problem, [string]$Remedy, [string]$Command = "")
    $cmd = $null
    if ($Command) { $cmd = $Command }
    $payload = [ordered]@{ ok = $false; error = $Problem; kind = $Kind; remedy = $Remedy; command = $cmd; rejected = $true; public_ip = $null }
    return ($payload | ConvertTo-Json -Depth 4)
}

# Deny-ExakitVsInput - the bridge says no before the engine runs: the message
# as Deny-ExakitInput says it (exit 2), with --json the failure object instead.
# Twin of _exakit_vs_refuse.
function Deny-ExakitVsInput {
    param([string]$Message, [string]$Problem, [string]$Remedy, [string]$Command = "")
    if ($script:ExakitVsJson) {
        if (Get-Command Write-ExakitLog -ErrorAction SilentlyContinue) { Write-ExakitLog "REJECT" $Message }
        Write-Output (New-ExakitVsFailureJson -Kind "input" -Problem $Problem -Remedy $Remedy -Command $Command)
        exit 2
    }
    Deny-ExakitInput $Message
}

# Invoke-ExakitVsAside - a step of the bridge's own (a DNS repair, a language
# container install) whose lines are for a person: on the console as always,
# with --json on stderr, where no parser reads them. Returns the step's answer.
function Invoke-ExakitVsAside {
    param([scriptblock]$Step)
    if (-not $script:ExakitVsJson) { return (& $Step) }
    $answer = $null
    & $Step 6>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord]) { [Console]::Error.WriteLine("$_") }
        else { $answer = $_ }
    }
    return $answer
}

# Show-ExakitVsLines - the engine's event lines in the kit's own marks; the
# RESULT object is returned, parsed, or $null.
function Show-ExakitVsLines {
    param([string[]]$Lines = @())
    $result = $null
    foreach ($line in $Lines) {
        if ($line -like "OK *") { Ok $line.Substring(3) }
        elseif ($line -like "INFO *") { Info $line.Substring(5) }
        elseif ($line -like "WARN *") { Warn2 $line.Substring(5) }
        elseif ($line -like "FAIL *") { Write-Host ("  {0} {1}" -f $script:UiCross, $line.Substring(5)) -ForegroundColor Red; Write-ExakitLog "ERROR" $line.Substring(5) }
        elseif ($line -like "RESULT *") { try { $result = $line.Substring(7) | ConvertFrom-Json } catch { } }
        elseif ("$line".Trim()) { Write-Host $line }
    }
    return $result
}

function Read-ExakitVsSecret {
    param([string]$Label, [string]$PasswordFile = "", [string]$Kind = "secret")
    if ($PasswordFile) {
        # A file that is there but cannot be read throws in Get-Content: that
        # is the same refusal as a missing one (with --json, the one object).
        $text = $null; $read = $false
        if (Test-Path -LiteralPath $PasswordFile -PathType Leaf) {
            try { $text = Get-Content -Raw -LiteralPath $PasswordFile -ErrorAction Stop; $read = $true } catch { $read = $false }
        }
        if (-not $read) { Deny-ExakitVsInput "Cannot read $PasswordFile" "cannot read $PasswordFile" "give a file this user can read with --password-file" }
        return ("$text" -replace "[\r\n]+$", "")
    }
    # --json never prompts: without --password-file there is no credential.
    if ($script:ExakitVsJson) { return "" }
    if (-not (Test-ExakitInteractive)) { Deny-ExakitInput "No $Label was given: use --password-file (a credential is never taken as an argument)." }
    if ($Kind -eq "secret-file") {
        # A key file is asked for by its path - nobody pastes a JSON key into a hidden prompt.
        $path = Read-ExakitPrompt "$Label - path to the file" ""
        if ($path -like "~*") { $path = $HOME + $path.Substring(1) }
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { Deny-ExakitInput "Cannot read $path" }
        return ((Get-Content -Raw -LiteralPath $path) -replace "[\r\n]+$", "")
    }
    return (Read-ExakitVsHidden $Label)
}

# Read-ExakitVsHidden - one line from the console, never echoed: the
# credential, and the connection string (it often holds one). Twin of
# exakit_read_hidden.
function Read-ExakitVsHidden {
    param([string]$Label)
    Write-Host ("    {0}?{1} {2} (input hidden): " -f $script:UiAsk, $script:UiReset, $Label) -NoNewline
    $secure = Read-Host -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# Get-ExakitVsSecretKind - the kind of a connector's credential input (secret
# or secret-file), empty when it has none. Twin of _exakit_vs_secret_kind.
function Get-ExakitVsSecretKind {
    param([string]$Connector)
    $defs = Get-ExakitVsDefs
    if (-not $defs -or -not $Connector) { return "" }
    $file = Join-ExakitCorePath $defs "connectors" $Connector "connector.json"
    if (-not (Test-Path -LiteralPath $file)) { return "" }
    $spec = @((Get-Content -Raw -LiteralPath $file | ConvertFrom-Json).inputs) | Where-Object { $_.kind -in @("secret", "secret-file") } | Select-Object -First 1
    if ($spec) { return "" + $spec.kind }
    return ""
}

function Confirm-ExakitVs {
    param([string]$Question)
    if ($script:ExakitVsAssumeYes) { return $true }
    # --json never asks: without --yes the answer is no.
    if ($script:ExakitVsJson) { return $false }
    if (-not (Test-ExakitInteractive)) { return $false }
    $answer = Read-ExakitPrompt "$Question [y/N]" "N"
    return ($answer -match '^(y|yes)$')
}

# Install-ExakitVsJava - the Java language container, with consent: about 250
# MiB and one restart, through the exakit command's own stop/start so add-on
# services come back. Twin of _exakit_vs_install_java.
# Install-ExakitVsRust - the Rust language container a native adapter
# (Profile D) runs in, with consent: the exasol-labs build pinned for this CPU
# in profiles\rust-native, size- and SHA-256-checked, registered as the RUST
# alias, then one restart. Twin of _exakit_vs_install_rust.
function Install-ExakitVsRust {
    $defs = Get-ExakitVsDefs
    $custom = (Get-Content -Raw -LiteralPath (Join-ExakitCorePath $defs "profiles" "rust-native" "profile.json") | ConvertFrom-Json).slc.custom
    $arch = "x86_64"
    if ("$env:PROCESSOR_ARCHITECTURE" -eq "ARM64") { $arch = "aarch64" }
    $pin = $custom.arch.$arch
    if (-not $pin) { Write-Host "  There is no Rust language container build for this CPU ($arch)." -ForegroundColor Red; return $false }
    Info "This source runs a native adapter inside the database, and its Rust language container is not installed."
    Info ("Installing it downloads {0} {1} (about {2} MiB, checksum-pinned) and restarts the database once (add-on services restart with it)." -f $custom.upstream, $custom.version, [int]([double]$pin.size / 1048576))
    if (-not (Confirm-ExakitVs "Install the Rust language container now?")) {
        Info "Nothing was installed. Run the same exakit connect again when you are ready."
        return $false
    }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-rust-" + [guid]::NewGuid().ToString("N"))
    $file = Join-Path $dir $pin.asset
    try {
        Get-ExakitFile -Url $pin.url -Dest $file
        $size = (Get-Item -LiteralPath $file).Length
        if ("$size" -ne "$($pin.size)") {
            Write-Host ("  The Rust language container download is {0} bytes, not the pinned {1}; nothing was installed." -f $size, $pin.size) -ForegroundColor Red
            return $false
        }
        if ((Get-ExakitSha256 -Path $file) -ne "$($pin.sha256)") {
            Write-Host "  The Rust language container download does not match its pinned checksum; nothing was installed." -ForegroundColor Red
            return $false
        }
        $slcArgs = @("slc", "custom", "install", "--source", $file, "--alias", "RUST", "--language", "rust", "--no-restart")
        $flag = Get-PersonalAutoApproveFlag "slc"
        if ($flag) { $slcArgs += $flag }
        if ((Invoke-ExakitLogged (Get-PersonalCli) @slcArgs) -ne 0) {
            Write-Host ("  {0} The Rust language container did not install. Details: exakit logs" -f $script:UiCross) -ForegroundColor Red
            return $false
        }
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue
    }
    $exakit = Join-Path $script:BinDir "exakit.cmd"
    $previousStop = $env:EXAKIT_STOP_ADDONS
    try {
        $env:EXAKIT_STOP_ADDONS = "1"
        & $exakit stop *> $null
    } finally { $env:EXAKIT_STOP_ADDONS = $previousStop }
    # Write-Host, not Out-Host: with --json, Invoke-ExakitVsAside moves these lines to stderr.
    & $exakit start | ForEach-Object { Write-Host "$_" }
    Ok "Rust language container installed"
    return $true
}

function Install-ExakitVsJava {
    Info "Virtual schemas run Java inside the database, and its Java language container is not installed."
    Info "Installing it downloads about 250 MiB and restarts the database once (add-on services restart with it)."
    if (-not (Confirm-ExakitVs "Install the Java language container now?")) {
        Info "Install it later with: exasol slc install java --no-restart, then exakit stop and exakit start"
        return $false
    }
    $slcArgs = @("slc", "install", "java", "--no-restart")
    $flag = Get-PersonalAutoApproveFlag "slc"
    if ($flag) { $slcArgs += $flag }
    if ((Invoke-ExakitLogged (Get-PersonalCli) @slcArgs) -ne 0) {
        Write-Host ("  {0} The Java language container did not install. Details: exakit logs" -f $script:UiCross) -ForegroundColor Red
        return $false
    }
    $exakit = Join-Path $script:BinDir "exakit.cmd"
    $previousStop = $env:EXAKIT_STOP_ADDONS
    try {
        $env:EXAKIT_STOP_ADDONS = "1"
        & $exakit stop *> $null
    } finally { $env:EXAKIT_STOP_ADDONS = $previousStop }
    # Write-Host, not Out-Host: with --json, Invoke-ExakitVsAside moves these lines to stderr.
    & $exakit start | ForEach-Object { Write-Host "$_" }
    try { [void](Repair-PersonalSlcDns) } catch { }
    Ok "Java language container installed"
    return $true
}

# Repair-ExakitVsForRetry - what the bridge does about exit 20 (DNS repaired),
# 21 (Java installed) or 23 (Rust installed) before its one retry; $false when
# it could not, or was not allowed to. Twin of _exakit_vs_repair.
function Repair-ExakitVsForRetry {
    param([int]$Code)
    if ($Code -eq 20) {
        Info "Giving the database's language containers the deployment's DNS, then trying again"
        if (-not (Repair-PersonalSlcDns)) { Write-Host "  DNS could not be repaired. Restart the database (exakit stop, exakit start) and try again." -ForegroundColor Red; return $false }
        return $true
    }
    if ($Code -eq 21) { return [bool](Install-ExakitVsJava) }
    if ($Code -eq 23) { return [bool](Install-ExakitVsRust) }
    return $false
}

# Invoke-ExakitVsRun - the engine once, repairing DNS (exit 20) or installing
# Java (exit 21) and retrying once. Twin of _exakit_vs_run. With --json
# ($script:ExakitVsJson) the engine answers in JSON, its events to the log; the
# last run's lines are kept in $script:ExakitVsLastLines for the caller to
# print, and what the bridge says while it repairs goes to stderr.
function Invoke-ExakitVsRun {
    param([string[]]$Arguments, [string]$Secret = "")
    $script:ExakitVsResult = $null
    $script:ExakitVsLastLines = @()
    # Once: a caller that built its arguments with --json already has it.
    if ($script:ExakitVsJson -and (@($Arguments) -notcontains "--json")) { $Arguments = @("--json") + @($Arguments) }
    for ($try = 1; $try -le 2; $try++) {
        $run = Invoke-ExakitVsEngine -Arguments $Arguments -Secret $Secret
        if ($script:ExakitVsJson) { $script:ExakitVsLastLines = @($run.Lines) }
        else { $script:ExakitVsResult = Show-ExakitVsLines -Lines $run.Lines }
        if ($try -eq 2) { break }
        if (@(20, 21, 23) -notcontains $run.Code) { break }
        $code = $run.Code
        if ($script:ExakitVsJson) {
            # A repair that throws (a download, an install) ends the repair,
            # not the command: the first run's object is still the answer.
            $fixed = $false
            try { $fixed = Invoke-ExakitVsAside { Repair-ExakitVsForRetry -Code $code } }
            catch {
                [Console]::Error.WriteLine("  " + $_.Exception.Message)
                if (Get-Command Write-ExakitLog -ErrorAction SilentlyContinue) { Write-ExakitLog "ERROR" $_.Exception.Message }
            }
            if (-not $fixed) { break }
        } elseif (-not (Invoke-ExakitVsAside { Repair-ExakitVsForRetry -Code $code })) { break }
    }
    return $run.Code
}

# Show-ExakitVsQueryHints - a first query on one of the source's real tables,
# quoted as it must be, then the connector's tips. Twin of _exakit_vs_query_hints.
function Show-ExakitVsQueryHints {
    param($Result, [string]$Name)
    if ($null -ne $Result -and $Result.PSObject.Properties["example"] -and $Result.example) {
        Ok ("Query it like any schema: " + $Result.example)
        foreach ($t in @($Result.tips)) { if ($t) { Info $t } }
    } else {
        Ok "Query it like any schema: SELECT * FROM VS_$($Name.ToUpperInvariant()).<table> LIMIT 10"
    }
}

# Show-ExakitVsDropPlan - what disconnect or remove drops, keeps and deletes.
# Twin of the "drop" branch of the renderer in cmd_source.
function Show-ExakitVsDropPlan {
    param($Plan)
    Write-Host ("  drops: " + (@($Plan.drop) -join ", "))
    if ($Plan.keep) { Write-Host ("  keeps: " + (@($Plan.keep) -join ", ")) }
    if ($Plan.PSObject.Properties["delete_files"]) {
        Write-Host ("  deletes {0} unused file(s); keeps {1} still shared" -f @($Plan.delete_files).Count, @($Plan.keep_files).Count)
    }
    Write-Host ("  note: " + $Plan.note)
}

function Show-ExakitVsPlan {
    param($Plan)
    if ($null -eq $Plan) { return }
    Write-Host ("  Plan for {0} ({1}, {2}, {3})" -f $Plan.name, $Plan.connector, $Plan.tier, $Plan.status)
    foreach ($d in @($Plan.downloads)) {
        $verb = "download"
        if ($d.cached) { $verb = "reuse" }
        Write-Host ("    {0} {1} {2} ({3:N1} MB, {4})" -f $verb, $d.role, $d.version, ($d.bytes / 1e6), $d.license)
    }
    foreach ($step in @($Plan.steps)) { Write-Host "    - $step" }
    Write-Host "    Exposure: $($Plan.exposure)"
    foreach ($w in @($Plan.warnings)) { if ($w) { Write-Host "    Warning: $w" } }
    if ($Plan.gate) { Write-Host "    Not available yet: $($Plan.gate)" }
}

# --- the terminal flow: pick, fill in, review, connect ----------------------------
#
# Twin of the block of the same name in virtual-schemas.sh: `exakit connect` on a
# console that can draw and answer, without --yes, --dry-run or --json, picks in
# the marketplace's own table (Invoke-ExakitTableMenu), asks for each source in a
# panel whose answers the engine checks one by one (cli.py field, the value
# base64 on its stdin), reviews the engine's plans above one table and one
# question, then runs the sources one at a time while that table animates. One
# difference by design: the engine runs synchronously here, so a row's bar creeps
# with time instead of stepping on the engine's OK lines - the animator runs in
# its own runspace and keeps it alive meanwhile.

# Test-ExakitVsTuiOk - can the terminal flow run here? Twin of _exakit_vs_tui_ok.
function Test-ExakitVsTuiOk {
    if (-not $script:UiFancy) { return $false }
    if ($script:ExakitVsAssumeYes) { return $false }
    if (-not (Test-ExakitInteractive)) { return $false }
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
    return $true
}

# Get-ExakitVsResultOf - the parsed RESULT line of an engine run, or $null.
function Get-ExakitVsResultOf {
    param([string[]]$Lines = @())
    foreach ($line in $Lines) {
        if ($line -like "RESULT *") { try { return ($line.Substring(7) | ConvertFrom-Json) } catch { return $null } }
    }
    return $null
}

# Format-ExakitVsTuiShort / Format-ExakitVsTuiTail - the text cut to a width, its
# start or its end kept. Twins of _exakit_vs_tui_short / _exakit_vs_tui_tail.
function Format-ExakitVsTuiShort {
    param([string]$Text = "", [int]$Width = 10)
    if ($Text.Length -le $Width) { return $Text }
    return $Text.Substring(0, $Width - 1) + $script:UiEllipsis
}
function Format-ExakitVsTuiTail {
    param([string]$Text = "", [int]$Width = 10)
    if ($Text.Length -le $Width) { return $Text }
    return $script:UiEllipsis + $Text.Substring($Text.Length - $Width + 1)
}

# Format-ExakitVsTuiFit - the text, its end kept when it is wider, or nothing
# when the width is too small to say anything. Twin of _exakit_vs_tui_fit.
function Format-ExakitVsTuiFit {
    param([string]$Text = "", [int]$Width = 10)
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -ge 4) { return (Format-ExakitVsTuiTail $Text $Width) }
    return ""
}

# Get-ExakitVsTuiRows - how many console lines a line of that many characters
# takes; one that fills the last column exactly counts as two (a console that
# wraps there has moved on before the newline). Twin of _exakit_vs_tui_rows.
function Get-ExakitVsTuiRows {
    param([int]$Chars)
    if ($Chars -le 0) { return 1 }
    return [int][Math]::Floor($Chars / $script:EvtCols) + 1
}

# Invoke-ExakitVsPick - the connector menu. Returns the chosen connector ids;
# none when nothing was chosen. Twin of _exakit_vs_pick.
function Invoke-ExakitVsPick {
    $catalog = Get-ExakitVsResultOf (Invoke-ExakitVsEngine -Arguments @("catalog")).Lines
    if ($null -eq $catalog) { Write-Host ("  {0} The connector catalog could not be read. Details: exakit logs" -f $script:UiCross) -ForegroundColor Red; return @() }
    # Source, the adapter version it pins, and GA or Beta: GA first, then Beta.
    # Twin of _exakit_vs_pick.
    $entries = @(@($catalog.connectors) | Where-Object { $_.tier -eq "GA" }) + @(@($catalog.connectors) | Where-Object { $_.tier -ne "GA" })
    $t = New-ExakitTable -Title "Connect external sources" -Col1 "Source" -Col2 "Version" -Col3 "Release"
    $ids = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $tree = "tee"
        if ($i -eq $entries.Count - 1) { $tree = "corner" }
        $kind = "" + $e.version
        $text = "" + $e.tier
        $label = "" + $e.name
        if ("" + $e.status -eq "gated") {
            $row = Add-ExakitTableRow -Kind $tree -Label $label -Col2 $kind -Col3 ($text + ", not available yet") -Table $t
            Disable-ExakitTableRow -Row $row -Note "not available yet" -Table $t
        } else {
            [void](Add-ExakitTableRow -Kind $tree -Label $label -Col2 $kind -Col3 $text -Table $t)
        }
        $ids += ("" + $e.id)
    }
    $skip = Add-ExakitTableRow -Kind "plain" -Label "Skip" -Table $t
    Info "Tick one or more sources; the details for each are asked next."
    $sel = @(Invoke-ExakitTableMenu -Table $t -ExclusiveIndex $skip -StartRow 1)
    if (-not $script:ExakitTableConfirmed) { return @() }
    if ($sel -contains $skip) { return @() }
    $picked = @()
    foreach ($r in $sel) { if ($r -ge 1 -and $r -le $ids.Count) { $picked += $ids[$r - 1] } }
    return $picked
}

# Show-ExakitVsTuiPanel - one source's panel over what the form drew last
# ($script:EvtOnScreen lines), in one write. A field still to answer is dim, with
# (required) or (optional) and its default; an answered one is ticked - or, with
# -Numbered (the summary), numbered - and says so when a pasted connection string
# gave it. The engine's notes on that string ($Form.Notes) stay under the panel.
# Twin of _exakit_vs_tui_draw and _exakit_vs_tui_frame.
function Show-ExakitVsTuiPanel {
    param([hashtable]$Form, [int]$Current, [switch]$Numbered)
    $e = $script:UiEsc
    $in = $script:EvtIn
    $title = " " + $Form.Title + " "
    $fill = [Math]::Max(0, $in - $title.Length - 1)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("  " + $script:UiAccent + $script:UiTL + $script:UiHr + $script:UiReset + $script:UiBold + $title + $script:UiReset + $script:UiAccent + ($script:UiHr * $fill) + $script:UiTR + $script:UiReset + "`r`n")
    $lines = 1
    # What a row's value may take: the panel's inside less the mark and label.
    $room = $in - 7 - $Form.LW
    for ($i = 0; $i -lt $Form.Fields.Count; $i++) {
        $f = $Form.Fields[$i]
        $lab = $f.Label.PadRight($Form.LW)
        $lead = ""
        if ($i -eq $Current) {
            $mark = $script:UiAccent + $script:UiArrow + $script:UiReset; $shown = $script:UiBold + $lab + $script:UiReset
            $plain = ""; $val = ""
        } elseif ($f.Done) {
            $mark = $script:UiOk + $script:UiTick + $script:UiReset; $shown = $lab
            # The summary's number takes the tick's place, in as many columns.
            if ($Numbered) { $lead = " " + $script:UiAccent + ("{0,2}" -f ($i + 1)) + $script:UiReset + "  " }
            $v = "" + $f.Val
            if ($f.Kind -eq "secret") { if ($v) { $v = "(given, hidden)" } else { $v = "(read from a file)" } }
            # Emptied with "-": the default is what the plan will use.
            if (-not $v) { $v = "" + $f.Def }
            if (-not $v) { $v = "(none)" }
            $from = ""
            if ($f.From) { $from = " (from the string)" }
            # Too narrow for both: the mark goes first, then the value is cut.
            if ($v.Length + $from.Length -gt $room) { $from = "" }
            $plain = Format-ExakitVsTuiFit $v $room
            $val = $plain
            if ($from) { $val = $val + $script:UiDim + $from + $script:UiReset; $plain = $plain + $from }
        } else {
            $mark = " "; $shown = $script:UiDim + $lab + $script:UiReset
            $req = "(optional)"
            if ($f.Req) { $req = "(required)" }
            $v = "" + $f.Val
            if (-not $v) { $v = "" + $f.Def }
            if ($f.Kind -in @("secret", "secret-file")) { $v = "" }
            $plain = $req
            if ($v) { $plain = $req + " [" + $v + "]" }
            if ($plain.Length -gt $room) {
                # Too narrow: the mark goes first, then the default is cut, then
                # it goes too (the question says both again).
                $plain = ""
                if ($v -and $room -ge 6) { $plain = "[" + (Format-ExakitVsTuiFit $v ($room - 2)) + "]" }
            }
            $val = $script:UiDim + $plain + $script:UiReset
        }
        if (-not $lead) { $lead = "  " + $mark + "  " }
        $pad = [Math]::Max(0, $in - 7 - $Form.LW - $plain.Length)
        [void]$sb.Append("  " + $script:UiAccent + $script:UiVB + $script:UiReset + $lead + $shown + "  " + $val + (" " * $pad) + $script:UiAccent + $script:UiVB + $script:UiReset + "`r`n")
        $lines++
    }
    [void]$sb.Append("  " + $script:UiAccent + $script:UiBL + ($script:UiHr * $in) + $script:UiBR + $script:UiReset + "`r`n")
    $lines++
    foreach ($note in @($Form.Notes)) {
        if (-not $note) { continue }
        $nm = $script:UiDim + $script:UiBullet + $script:UiReset
        if ($note -like "WARN *") { $nm = $script:UiWarn + "!" + $script:UiReset }
        $parts = @(Split-ExakitWrap -Text ($note.Substring($note.IndexOf(" ") + 1)) -Width ($script:EvtCols - 8))
        for ($k = 0; $k -lt $parts.Count; $k++) {
            if ($k -eq 0) { [void]$sb.Append("    " + $nm + " " + $parts[$k] + "`r`n") }
            else { [void]$sb.Append("      " + $parts[$k] + "`r`n") }
            $lines++
        }
    }
    if ($script:EvtOnScreen -gt 0) { [Console]::Write("`r$e[$($script:EvtOnScreen)A$e[0J" + $sb.ToString()) }
    else { [Console]::Write($sb.ToString()) }
    $script:EvtOnScreen = $lines
}

# Write-ExakitVsTuiSay - a line under the panel (a refused answer and why, or
# with -Mark a hint), wrapped and counted. Twin of _exakit_vs_tui_say.
function Write-ExakitVsTuiSay {
    param([string]$Text, [string]$Mark = "")
    if (-not $Mark) { $Mark = $script:UiErr + $script:UiCross + $script:UiReset }
    $parts = @(Split-ExakitWrap -Text $Text -Width ($script:EvtCols - 8))
    for ($k = 0; $k -lt $parts.Count; $k++) {
        if ($k -eq 0) { [Console]::Write("    " + $Mark + " " + $parts[$k] + "`r`n") }
        else { [Console]::Write("      " + $parts[$k] + "`r`n") }
    }
    $script:EvtOnScreen += $parts.Count
}

# Read-ExakitVsTuiAnswer - one answer, the prompt under the panel; $null at end
# of input. A hidden one never echoes. Twin of _exakit_vs_tui_ask.
function Read-ExakitVsTuiAnswer {
    param([string]$Plain, [string]$Colour, [switch]$Hidden)
    [Console]::Write("  " + $Colour + ": ")
    if ($Hidden) {
        # Key by key, nothing echoed - the console call the menu reads with.
        # Read-Host -AsSecureString here left the console's next ReadLine
        # reading garbage on pwsh for Unix after an empty answer (measured).
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) { break }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($sb.Length -gt 0) { [void]$sb.Remove($sb.Length - 1, 1) }
                continue
            }
            if ([int]$key.KeyChar -ge 32) { [void]$sb.Append($key.KeyChar) }
        }
        $answer = $sb.ToString()
        [void]$sb.Clear()
        [Console]::Write("`r`n")
        $script:EvtOnScreen += (Get-ExakitVsTuiRows ($Plain.Length + 4))
        return $answer
    }
    $answer = [Console]::ReadLine()
    if ($null -eq $answer) { return $null }
    $script:EvtOnScreen += (Get-ExakitVsTuiRows ($Plain.Length + 4 + $answer.Length))
    return $answer
}

# Confirm-ExakitVsTui - y/N, counted like any line under the panel.
function Confirm-ExakitVsTui {
    param([string]$Question)
    [Console]::Write("  " + $script:UiAsk + $Question + " [y/N]" + $script:UiReset + " ")
    $a = [Console]::ReadLine()
    $script:EvtOnScreen += 1
    return ("" + $a -match '^(y|yes)$')
}

# Get-ExakitVsPasteForms - the connection strings a connector's paste block reads
# ("a, b or c"), for the question that asks for one; empty when it reads none.
# Twin of _exakit_vs_paste_forms.
function Get-ExakitVsPasteForms {
    param([string]$Connector)
    $defs = Get-ExakitVsDefs
    if (-not $defs -or -not $Connector) { return "" }
    $file = Join-ExakitCorePath $defs "connectors" $Connector "connector.json"
    if (-not (Test-Path -LiteralPath $file)) { return "" }
    $doc = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
    if (-not $doc.PSObject.Properties["paste"] -or -not $doc.paste) { return "" }
    $forms = @(@($doc.paste.forms) | Where-Object { $_ } | ForEach-Object { "" + $_ })
    if ($forms.Count -eq 0) { return "" }
    if ($forms.Count -eq 1) { return $forms[0] }
    return ((@($forms | Select-Object -First ($forms.Count - 1))) -join ", ") + " or " + $forms[$forms.Count - 1]
}

# Format-ExakitVsPasteTyped - the engine's paste lines, for a string typed at a
# prompt: its credential note (a WARN line) ends by saying the string was on the
# command line, which a typed one was not, so that sentence is dropped. The
# RESULT line, which repeats the notes, is left whole. Twin of
# _exakit_vs_paste_typed.
function Format-ExakitVsPasteTyped {
    param([string[]]$Lines = @())
    foreach ($line in $Lines) {
        if ("" + $line -like "WARN *") { ("" + $line) -replace ' The string was on the command line.*$', '' } else { "" + $line }
    }
}

# Read-ExakitVsLineAnswer - one line-by-line answer. With -Marks (someone is
# answering: not --yes, --dry-run or --json) the question says (required) or
# (optional), dim, and an empty answer to a required one is refused ("<label> is
# required") and asked again; without, it is Read-ExakitPrompt as it always was.
# Twin of _exakit_vs_prompt.
function Read-ExakitVsLineAnswer {
    param([string]$Question, [string]$Default = "", [bool]$Required = $false, [bool]$Marks = $false, [string]$Label = "")
    if (-not $Marks) { return (Read-ExakitPrompt $Question $Default) }
    $mark = "(optional)"
    if ($Required) { $mark = "(required)" }
    if (-not $Label) { $Label = $Question }
    while ($true) {
        if (-not (Test-ExakitInteractive)) { return $Default }
        $v = "" + (Read-ExakitPrompt ("{0} {1}{2}{3}" -f $Question, $script:UiDim, $mark, $script:UiReset) $Default)
        if ($v -or -not $Required) { return $v }
        Write-Host ("  {0} {1} is required" -f $script:UiCross, $Label) -ForegroundColor Red
        Write-ExakitLog "ERROR" "$Label is required"
    }
}

# Read-ExakitVsLinePaste - the line-by-line twin of the form's first question: a
# connection string, read hidden as a password is (it often holds one), to the
# engine's paste, base64 on its stdin, never an argument; or Enter to type the
# fields. Returns @{ Sets; Names } for what the string named; only those fields
# are shown. A string the engine cannot read is said, in its words, and asked
# again. Twin of _exakit_vs_ask_paste.
function Read-ExakitVsLinePaste {
    param([string]$Connector)
    $answer = @{ Sets = @(); Names = @() }
    $forms = Get-ExakitVsPasteForms $Connector
    if (-not $forms) { return $answer }
    Info ("Paste the source's connection string as it shows it: " + $forms)
    while ($true) {
        $url = "" + (Read-ExakitVsHidden "Connection string (Enter to type the fields)")
        if (-not $url) { return $answer }
        $pasted = Invoke-ExakitVsEngine -Arguments @("paste", $Connector, "--base64") -Secret $url
        $url = $null
        $res = Show-ExakitVsLines -Lines @(Format-ExakitVsPasteTyped $pasted.Lines)
        if ($pasted.Code -ne 0) { continue }
        if ($null -ne $res -and $res.values) {
            foreach ($p in @($res.values.PSObject.Properties)) {
                $answer.Sets += @("--set", ("{0}={1}" -f $p.Name, $p.Value)); $answer.Names += $p.Name
            }
        }
        return $answer
    }
}

# Read-ExakitVsTuiField - field $Index asked under the panel (with why it is
# asked again, when there is a reason): its label, (required) or (optional), its
# notes and its default. Enter takes the default; an optional one with none is
# left empty, a required one is refused in one line and asked again. The engine
# checks a typed answer (cli.py field, base64 on its stdin); a credential is
# hidden, and asked again keeps the one given on Enter. $false at end of input.
# Twin of _exakit_vs_tui_field.
function Read-ExakitVsTuiField {
    param([hashtable]$Form, [int]$Index, [string]$Why = "")
    Show-ExakitVsTuiPanel -Form $Form -Current $Index
    if ($Why) { Write-ExakitVsTuiSay $Why }
    $f = $Form.Fields[$Index]
    $old = "" + $f.Val
    $def = $old
    if (-not $def) { $def = "" + $f.Def }
    $keep = $false
    $note = "(optional)"
    if ($f.Req) { $note = "(required)" }
    if ($f.Kind -eq "choice") { $note += " (" + ($f.Choices -join (" " + $script:UiMidDot + " ")) + ")" }
    elseif ($f.Kind -eq "secret") {
        $def = ""
        # Given already - typed, or read from --password-file: Enter keeps it.
        if ($old -or ($f.Done -and $Form.PwFile)) { $keep = $true; $note += " (hidden, Enter keeps the one given)" } else { $note += " (hidden)" }
    }
    elseif ($f.Kind -eq "secret-file") { $note += " (the path to the file)" }
    # An optional answer that differs from its default can be taken back.
    if (-not $f.Req -and $old -and $old -ne ("" + $f.Def) -and $f.Kind -notin @("secret", "secret-file")) { $note += " (- clears it)" }
    if ($def) { $note += " [" + (Format-ExakitVsTuiTail $def 32) + "]" }
    $plain = $f.Label + " " + $note
    $colour = $script:UiAsk + $f.Label + $script:UiReset + " " + $script:UiDim + $note + $script:UiReset
    while ($true) {
        if ($f.Kind -eq "secret") {
            $a = Read-ExakitVsTuiAnswer -Plain $plain -Colour $colour -Hidden
            if (-not $a) {
                if ($keep) { break }
                if ($f.Req) { Write-ExakitVsTuiSay ("{0} is required; it stays in memory and goes only to the database" -f $f.LabelFull); continue }
            }
            $f.Val = "" + $a; $a = $null
            break
        }
        $a = Read-ExakitVsTuiAnswer -Plain $plain -Colour $colour
        if ($null -eq $a) { return $false }
        if ($a -eq "-" -and -not $f.Req) { $f.Val = ""; break }
        $v = $a
        if (-not $v) { $v = $def }
        if ($v -like "~*") { $v = $HOME + $v.Substring(1) }
        if (-not $v) {
            if ($f.Req) { Write-ExakitVsTuiSay ("{0} is required" -f $f.LabelFull); continue }
            $f.Val = ""
            break
        }
        if ($f.Kind -eq "secret-file") {
            if (Test-Path -LiteralPath $v -PathType Leaf) { $f.Val = $v; break }
            Write-ExakitVsTuiSay "$v cannot be read here; give the path to the key file"
            continue
        }
        # The engine's own rule for this input, in the words a scripted connect
        # would get; the value travels base64 on its stdin, never in argv.
        $check = Invoke-ExakitVsEngine -Arguments @("field", $Form.Connector, $f.Name, "--base64") -Secret $v
        if ($check.Code -eq 0) {
            $res = Get-ExakitVsResultOf $check.Lines
            if ($null -ne $res) { $v = "" + $res.value }
            if ($f.Kind -eq "source-name" -and (@($Form.Taken) -contains $v)) {
                Write-ExakitVsTuiSay "$v is already the name of another source in this list"; continue
            }
            $f.Val = $v
            break
        }
        $why = (@($check.Lines) | Where-Object { $_ -like "FAIL *" } | Select-Object -First 1)
        if ($why) { $why = $why.Substring(5) } else { $why = "that value was refused" }
        Write-ExakitVsTuiSay $why
    }
    $f.Done = $true
    # Changed by hand, it is no longer what the connection string said.
    if (("" + $f.Val) -ne $old) { $f.From = $false }
    return $true
}

# Invoke-ExakitVsTuiWalk - every field not answered yet, in order; $false at end
# of input. Twin of _exakit_vs_tui_walk.
function Invoke-ExakitVsTuiWalk {
    param([hashtable]$Form, [string]$Why = "")
    for ($i = 0; $i -lt $Form.Fields.Count; $i++) {
        if ($Form.Fields[$i].Done) { continue }
        if (-not (Read-ExakitVsTuiField -Form $Form -Index $i -Why $Why)) { return $false }
    }
    return $true
}

# Invoke-ExakitVsTuiReview - the summary before the plan: the panel with every
# answer numbered (a credential as hidden, a key file by its path), with why it
# is shown again when a plan refused. A number asks that one field again, then
# the summary comes back; Enter goes on. Once a plan has refused this source
# ($Form.Refused), skip leaves it out. Returns "go", "eof" or "skip". Twin of
# _exakit_vs_tui_review.
function Invoke-ExakitVsTuiReview {
    param([hashtable]$Form, [string]$Why = "")
    $why = $Why
    $plain = "Number to change, Enter to continue"
    if ($Form.Refused) { $plain += ", skip to leave this source out" }
    $colour = $script:UiAsk + "Number to change" + $script:UiReset + $script:UiDim + $plain.Substring(16) + $script:UiReset
    while ($true) {
        Show-ExakitVsTuiPanel -Form $Form -Current -1 -Numbered
        if ($why) { Write-ExakitVsTuiSay $why }
        $a = Read-ExakitVsTuiAnswer -Plain $plain -Colour $colour
        if ($null -eq $a) { return "eof" }
        $n = $a -replace ' ', ''
        if ($n -eq "skip" -and $Form.Refused) { return "skip" }
        if (-not $n) {
            # The answers as they stand, ticked again, the question gone.
            Show-ExakitVsTuiPanel -Form $Form -Current -1
            return "go"
        }
        if ($n -match '^[0-9]{1,2}$') {
            $k = [int]$n
            if ($k -ge 1 -and $k -le $Form.Fields.Count) {
                if (-not (Read-ExakitVsTuiField -Form $Form -Index ($k - 1))) { return "eof" }
                $why = ""
                continue
            }
        }
        $why = "give a number from 1 to {0}, or press Enter to continue" -f $Form.Fields.Count
    }
}

# Invoke-ExakitVsTuiPaste - the form's first question, for a connector that reads
# a connection string (its paste block): read hidden, the string goes to the
# engine's paste, base64 on its stdin, never in argv, and is not kept. What it names is answered,
# marked "from the string" and not asked; the engine's notes stay under the
# panel. A string it cannot read is said, in the engine's words, and asked again;
# Enter types the fields instead. $false at end of input. Twin of
# _exakit_vs_tui_paste.
function Invoke-ExakitVsTuiPaste {
    param([hashtable]$Form)
    $forms = Get-ExakitVsPasteForms $Form.Connector
    if (-not $forms) { return $true }
    $why = ""
    # Read with echo off, as a password is: the string often holds one. Only the
    # fields it filled are shown afterwards.
    $plain = "Connection string (hidden; Enter to type the fields)"
    $colour = $script:UiAsk + "Connection string" + $script:UiReset + " " + $script:UiDim + "(hidden; Enter to type the fields)" + $script:UiReset
    while ($true) {
        Show-ExakitVsTuiPanel -Form $Form -Current -1
        Write-ExakitVsTuiSay -Text ("Paste the source's connection string as it shows it: " + $forms) -Mark ($script:UiDim + $script:UiBullet + $script:UiReset)
        if ($why) { Write-ExakitVsTuiSay $why }
        $a = Read-ExakitVsTuiAnswer -Plain $plain -Colour $colour -Hidden
        if ($null -eq $a) { return $false }
        if (-not $a) { return $true }
        $pasted = Invoke-ExakitVsEngine -Arguments @("paste", $Form.Connector, "--base64") -Secret $a
        $a = $null
        if ($pasted.Code -ne 0) {
            $why = (@($pasted.Lines) | Where-Object { $_ -like "FAIL *" } | Select-Object -First 1)
            if ($why) { $why = $why.Substring(5) } else { $why = "the connection string could not be read" }
            continue
        }
        $res = Get-ExakitVsResultOf $pasted.Lines
        if ($null -ne $res -and $res.values) {
            foreach ($p in @($res.values.PSObject.Properties)) {
                foreach ($f in $Form.Fields) {
                    if ($f.Name -eq $p.Name) { $f.Val = "" + $p.Value; $f.Done = $true; $f.From = $true }
                }
            }
        }
        $Form.Notes = @(Format-ExakitVsPasteTyped @(@($pasted.Lines) | Where-Object { $_ -like "WARN *" -or $_ -like "INFO *" }))
        return $true
    }
}

# Find-ExakitVsTuiNamed - the field a plan's refusal names: its index when it
# names one, -2 when it names several, -1 when none. Input names count first, as
# whole words in any case ("host", "tls=verify", "URI"; the source name as
# "source name", not the bare word); only when none is named, the labels, the
# same way ("Port" is not "report"). Twin of _exakit_vs_tui_named.
function Find-ExakitVsTuiNamed {
    param([hashtable]$Form, [string]$Text = "")
    $hits = @()
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    foreach ($pass in @("name", "label")) {
        for ($i = 0; $i -lt $Form.Fields.Count; $i++) {
            $f = $Form.Fields[$i]
            $word = "" + $f.Name
            if ($f.Kind -eq "source-name") { $word = "source name" }
            if ($pass -eq "label") { $word = "" + $f.LabelFull }
            if (-not $word) { continue }
            if ([regex]::IsMatch($Text, '(?<![A-Za-z0-9_])' + [regex]::Escape($word) + '(?![A-Za-z0-9_])', $options)) { $hits += $i }
        }
        if ($hits.Count -gt 0) { break }
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -gt 1) { return -2 }
    return -1
}

# Invoke-ExakitVsTuiForm - one source's panel. Returns its answers as a
# hashtable, "left-out" when the reader gave up on it, or "broken" when the
# connector's definition could not be read. Twin of _exakit_vs_tui_form.
function Invoke-ExakitVsTuiForm {
    param([string]$Connector, [int]$Pos, [int]$Total, [string]$GivenName = "", [string[]]$GivenSets = @(),
          [string]$PasswordFile = "", [string[]]$Taken = @())
    $run = Invoke-ExakitVsEngine -Arguments @("inputs", $Connector)
    $doc = Get-ExakitVsResultOf $run.Lines
    if ($run.Code -ne 0 -or $null -eq $doc) {
        [void](Show-ExakitVsLines -Lines $run.Lines)
        Write-Host ("  {0} The connect form could not read {1}'s inputs. Update the kit (exakit update), or connect without the form: exakit connect {1} --name <name> --set KEY=VALUE ... --yes" -f $script:UiCross, $Connector) -ForegroundColor Red
        return "broken"
    }
    $given = @{}
    for ($g = 0; $g -lt $GivenSets.Count; $g++) {
        if ($GivenSets[$g] -eq "--set" -and $g + 1 -lt $GivenSets.Count) {
            $pair = $GivenSets[$g + 1]; $at = $pair.IndexOf("=")
            if ($at -gt 0) { $given[$pair.Substring(0, $at)] = $pair.Substring($at + 1) }
        }
    }
    $fields = New-Object System.Collections.ArrayList
    $lw = 0
    foreach ($spec in @($doc.inputs)) {
        $label = "" + $spec.label
        foreach ($cut in @(" - ", " (", "; ")) { $label = $label.Split(@($cut), [StringSplitOptions]::None)[0] }
        $f = @{ Name = "" + $spec.name; Label = $label; LabelFull = $label; Kind = "" + $spec.kind; Req = [bool]$spec.required
                Def = "" + $spec.default; Choices = @($spec.choices); Val = ""; Done = $false; From = $false }
        if ($f.Kind -eq "source-name" -and $GivenName) { $f.Val = $GivenName; $f.Done = $true }
        if ($given.ContainsKey($f.Name)) { $f.Val = $given[$f.Name]; $f.Done = $true }
        if ($PasswordFile) {
            if ($f.Kind -eq "secret") { $f.Done = $true }
            if ($f.Kind -eq "secret-file") { $f.Val = $PasswordFile; $f.Done = $true }
        }
        if ($label.Length -gt $lw) { $lw = $label.Length }
        [void]$fields.Add($f)
    }
    if ($lw -gt 30) { $lw = 30 }
    foreach ($f in $fields) { $f.Label = Format-ExakitVsTuiShort $f.Label $lw }
    $form = @{ Title = ("{0} of {1} {2} {3}" -f $Pos, $Total, $script:UiMidDot, $doc.name); Fields = $fields; LW = $lw
               Connector = $Connector; Taken = @($Taken); Notes = @(); PwFile = $PasswordFile; Refused = $false }
    $pwFile = $PasswordFile
    $script:EvtOnScreen = 0
    # 1. A connection string first, when the command line answered nothing but
    # the name: what it names is answered (and marked so), the rest asked next.
    $asked = $false
    foreach ($f in $fields) { if ($f.Done -and $f.Kind -notin @("source-name", "secret", "secret-file")) { $asked = $true } }
    if (-not $asked) { if (-not (Invoke-ExakitVsTuiPaste -Form $form)) { return "left-out" } }
    # 2. every field not answered yet
    if (-not (Invoke-ExakitVsTuiWalk -Form $form)) { return "left-out" }
    $again = ""
    while ($true) {
        # 3. the numbered summary: one answer at a time asked again, then Enter
        if ((Invoke-ExakitVsTuiReview -Form $form -Why $again) -ne "go") { return "left-out" }
        $again = ""
        $base = @($Connector)
        foreach ($f in $fields) {
            if ($f.Kind -eq "source-name") { $base += @("--name", $f.Val) }
            elseif ($f.Kind -in @("secret", "secret-file")) { }
            elseif ($f.Val) { $base += @("--set", ("{0}={1}" -f $f.Name, $f.Val)) }
        }
        $planned = Invoke-ExakitVsEngine -Arguments (@("plan") + $base)
        if ($planned.Code -eq 0) { break }
        $why = (@($planned.Lines) | Where-Object { $_ -like "FAIL *" } | Select-Object -First 1)
        if ($why) { $why = $why.Substring(5) } else { $why = "" }
        $form.Refused = $true
        # A refusal that names one input goes straight back to that one, its
        # reason above the question; one that names several opens the summary
        # with the reason; any other is said, and every answer can be given
        # again. The summary then offers skip, so no refusal is a dead end.
        $at = Find-ExakitVsTuiNamed -Form $form -Text $why
        if ($at -ge 0) {
            if (-not (Read-ExakitVsTuiField -Form $form -Index $at -Why $why)) { return "left-out" }
            continue
        }
        if ($at -eq -2) { $again = $why; continue }
        if ($why) { Write-ExakitVsTuiSay $why }
        if (-not (Confirm-ExakitVsTui "Change the answers?")) { return "left-out" }
        foreach ($f in $fields) { $f.Done = $false }
        $pwFile = ""; $form.PwFile = ""
        if (-not (Invoke-ExakitVsTuiWalk -Form $form -Why $why)) { return "left-out" }
    }
    # The plan's own INFO lines (a source on the internet: the public IP it must
    # allow) are said in the review, as the line-by-line path says them.
    $planInfo = @(@($planned.Lines) | Where-Object { $_ -like "INFO *" } | ForEach-Object { $_.Substring(5) })
    $src = @{ Id = $Connector; Label = "" + $doc.name; Base = $base; Plan = (Get-ExakitVsResultOf $planned.Lines)
              PlanInfo = $planInfo; Name = ""; Secret = ""; SecretFile = ""; Where = "" }
    foreach ($f in $fields) {
        if ($f.Kind -eq "source-name") { $src.Name = $f.Val }
        elseif ($f.Kind -eq "secret") { $src.Secret = $f.Val }
        elseif ($f.Kind -eq "secret-file") { $src.SecretFile = $f.Val }
        elseif ($f.Name -in @("host", "bucket", "account", "project", "uri", "region") -and -not $src.Where) { $src.Where = "" + $f.Val }
    }
    if (-not $src.Secret -and -not $src.SecretFile -and $pwFile) { $src.SecretFile = $pwFile }
    $w = $src.Where
    $at = $w.IndexOf("://"); if ($at -ge 0) { $w = $w.Substring($at + 3) }
    $w = $w.Split("/")[0]
    if ($w -match '\.' -and $w -match '[A-Za-z]') { $w = $w.Split(".")[0] }
    $src.Where = Format-ExakitVsTuiShort $w 18
    [Console]::Write("`r`n")
    return $src
}

# New-ExakitVsTuiTable - a table of finished forms, every row waiting. Twin of
# _exakit_vs_tui_table.
function New-ExakitVsTuiTable {
    param([string]$Title, [object[]]$Sources)
    $t = New-ExakitTable -Title $Title -Col1 "Name" -Col2 "Source" -Col3 "Where"
    for ($i = 0; $i -lt $Sources.Count; $i++) {
        $tree = "tee"
        if ($i -eq $Sources.Count - 1) { $tree = "corner" }
        $row = Add-ExakitTableRow -Kind $tree -Label $Sources[$i].Name -Col2 $Sources[$i].Label -Col3 $Sources[$i].Where -Ticked -Table $t
        Set-ExakitTableRow -Row $row -State waiting -Table $t
    }
    return $t
}

# Invoke-ExakitVsTuiRun - connect those sources one after another while the
# table animates; each source's Outcome is set (ok, failed, java, rust). Twin of
# _exakit_vs_tui_run and _exakit_vs_tui_live together.
function Invoke-ExakitVsTuiRun {
    param([hashtable]$Table, [object[]]$Sources, [int]$OnScreen = 0)
    $Table.Lines = $OnScreen
    $live = Start-ExakitTable -Table $Table
    $short = @{ "auth" = "the credentials were refused"; "tls" = "the certificate did not verify"
                "unreachable" = "the source did not answer"; "nohost" = "the host name does not resolve"
                "dns" = "Java in the database has no DNS"; "denied" = "the account may not read this"
                "region" = "the region does not match"; "nobucket" = "no such bucket or container"
                "clock" = "the database clock is wrong"; "privilege" = "the account lacks a privilege"
                "missing_or_denied" = "no such object, or not granted" }
    for ($i = 0; $i -lt $Sources.Count; $i++) {
        $s = $Sources[$i]
        $row = $i + 1
        $t0 = Get-Date
        $secret = $s.Secret
        if (-not $secret -and $s.SecretFile) {
            $secret = ((Get-Content -Raw -LiteralPath $s.SecretFile) -replace "[\r\n]+$", "")
        }
        $engineArgs = @("--json", "connect") + $s.Base
        if ($secret) { $engineArgs += "--secret-stdin" }
        for ($try = 1; $try -le 2; $try++) {
            Set-ExakitTableRow -Row $row -State running -Pct 5 -Ceiling 90 -Secs 30 -Phase "connecting" -Table $Table
            $run = Invoke-ExakitVsEngine -Arguments $engineArgs -Secret $secret
            if ($run.Code -eq 20 -and $try -eq 1) {
                Set-ExakitTableRow -Row $row -State running -Pct 30 -Ceiling 60 -Secs 20 -Phase "repairing DNS" -Table $Table
                $repaired = $false
                try { $repaired = [bool](Repair-PersonalSlcDns 6> $null) } catch { }
                if ($repaired) { continue }
            }
            break
        }
        $secret = $null
        $doc = $null
        try { $doc = (@($run.Lines) -join "`n") | ConvertFrom-Json } catch { }
        $s.Lines = $run.Lines
        $secs = [int]((Get-Date) - $t0).TotalSeconds
        if ($run.Code -eq 0) {
            $n = "?"
            if ($null -ne $doc -and $null -ne $doc.tables) { $n = "" + $doc.tables }
            $plural = "s"; if ($n -eq "1") { $plural = "" }
            Set-ExakitTableRow -Row $row -State done -Final ("VS_{0} {4} {1} table{2} {4} {3} s" -f $s.Name.ToUpperInvariant(), $n, $plural, $secs, $script:UiMidDot) -Table $Table
            $s.Outcome = "ok"; $s.Result = $doc
        } else {
            $why = ""
            if ($run.Code -eq 21) { $why = "needs Java in the database"; $s.Outcome = "java" }
            elseif ($run.Code -eq 23) { $why = "needs Rust in the database"; $s.Outcome = "rust" }
            else {
                $s.Outcome = "failed"; $s.Code = $run.Code
                if ($null -ne $doc -and $short.ContainsKey("" + $doc.kind)) { $why = $short["" + $doc.kind] }
                elseif ($run.Code -eq 3) { $why = "the name is already taken" }
                elseif ($null -ne $doc -and $doc.error) { $why = Format-ExakitVsTuiShort ("" + $doc.error) 34 }
                else { $why = "did not connect" }
                $s.Error = ""
                if ($null -ne $doc) { $s.Error = "" + $doc.error }
            }
            Set-ExakitTableRow -Row $row -State failed -Final $why -Table $Table
        }
    }
    if ($live) { Stop-ExakitTable -Table $Table } else { Show-ExakitTable -Table $Table -Cursor 0 }
    # Keys pressed while it ran are not kept: an impatient Enter must not answer
    # the next question.
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}

# Invoke-ExakitVsTui - the whole terminal flow; returns the connect's exit code.
# Twin of _exakit_vs_tui.
function Invoke-ExakitVsTui {
    param([string]$Source = "", [string]$Name = "", [string]$PasswordFile = "", [string[]]$Sets = @())
    $script:EvtCols = 80
    try { $script:EvtCols = [Console]::WindowWidth } catch { }
    $w = [Math]::Min($script:EvtCols - 2, 96)
    $script:EvtIn = $w - 4
    $script:EvtOnScreen = 0
    # 1. which sources
    if ($Source) {
        $resolved = Invoke-ExakitVsEngine -Arguments @("resolve", $Source)
        if ($resolved.Code -ne 0) { [void](Show-ExakitVsLines -Lines $resolved.Lines); return $resolved.Code }
        $picked = @((Get-ExakitVsResultOf $resolved.Lines).connector)
    } else {
        $picked = @(Invoke-ExakitVsPick)
        if ($picked.Count -eq 0) { Info "Nothing was chosen; nothing was changed."; return 5 }
    }
    # 2. the details, one panel each; --name, --set and --password-file belong
    # to the one source the command named
    if ($picked.Count -ne 1) { $Name = ""; $PasswordFile = ""; $Sets = @() }
    [Console]::Write("`r`n")
    $sources = @()
    $taken = @()
    for ($p = 0; $p -lt $picked.Count; $p++) {
        $src = Invoke-ExakitVsTuiForm -Connector $picked[$p] -Pos ($p + 1) -Total $picked.Count -GivenName $Name `
            -GivenSets $Sets -PasswordFile $PasswordFile -Taken $taken
        if ($src -is [string]) {
            if ($src -eq "broken") { return 2 }
            [Console]::Write("`r`n"); Info "Left out: $($picked[$p])"
            continue
        }
        $src.Outcome = ""; $src.Lines = @(); $src.Code = 0; $src.Error = ""; $src.Result = $null
        $sources += $src
        $taken += $src.Name
    }
    if ($sources.Count -eq 0) { Info "Nothing was changed."; return 5 }
    # 3. review: what each plan downloads and who can read the result, then the
    # plan's own INFO lines, above one table and one question
    foreach ($s in $sources) {
        $plan = $s.Plan
        if ($null -eq $plan) { continue }
        $new = @(@($plan.downloads) | Where-Object { -not $_.cached })
        if ($new.Count -gt 0) {
            $mb = 0; foreach ($d in $new) { $mb += [double]$d.bytes }
            Info ("{0} downloads {1} ({2:N0} MB)" -f $plan.name, ((@($new) | ForEach-Object { "$($_.role) $($_.version)" }) -join ", "), ($mb / 1e6))
        }
        foreach ($warning in @($plan.warnings)) { if ($warning) { Warn2 ("{0}: {1}" -f $plan.name, $warning) } }
        if ($plan.exposure) { Info ("{0}: {1}" -f $plan.name, ($plan.exposure.Substring(0, 1).ToUpperInvariant() + $plan.exposure.Substring(1))) }
        foreach ($note in @($s.PlanInfo)) { if ($note) { Info ("{0}: {1}" -f $plan.name, $note) } }
    }
    $plural = "s"; if ($sources.Count -eq 1) { $plural = "" }
    $t = New-ExakitVsTuiTable -Title ("Connect {0} source{1}" -f $sources.Count, $plural) -Sources $sources
    Show-ExakitTable -Table $t -Cursor 0
    $lines = [int]$t.Lines
    $script:EvtOnScreen = 0
    $question = "Connect all $($sources.Count) now?"
    if ($sources.Count -eq 1) { $question = "Connect it now?" }
    if (-not (Confirm-ExakitVsTui $question)) { Info "Nothing was changed."; return 5 }
    # 4. connect: the review table comes alive in place, over itself and the question
    Invoke-ExakitVsTuiRun -Table $t -Sources $sources -OnScreen ($lines + $script:EvtOnScreen)
    # A language container is a download and a restart: asked once, below the
    # table, then those sources run again in a table of their own.
    foreach ($lang in @("java", "rust")) {
        $wait = @($sources | Where-Object { $_.Outcome -eq $lang })
        if ($wait.Count -eq 0) { continue }
        [Console]::Write("`r`n")
        $installed = $false
        if ($lang -eq "java") { $installed = Install-ExakitVsJava } else { $installed = Install-ExakitVsRust }
        if (-not $installed) { foreach ($s in $wait) { $s.Outcome = "failed"; $s.Code = 1 }; continue }
        [Console]::Write("`r`n")
        $again = New-ExakitVsTuiTable -Title "Connect again" -Sources $wait
        Invoke-ExakitVsTuiRun -Table $again -Sources $wait -OnScreen 0
    }
    # What went wrong in the engine's own words, below the finished table.
    [Console]::Write("`r`n")
    $code = 0
    foreach ($s in $sources) {
        if ($s.Outcome -eq "ok") { continue }
        Warn2 "$($s.Name) did not connect:"
        if ($s.Error) { Write-Host ("  {0} {1}" -f $script:UiCross, $s.Error) -ForegroundColor Red }
        if ($code -eq 0) { $code = [int]$s.Code; if ($code -eq 0) { $code = 1 } }
    }
    foreach ($s in $sources) {
        if ($s.Outcome -eq "ok") { Show-ExakitVsQueryHints -Result $s.Result -Name $s.Name }
    }
    if (@($sources | Where-Object { $_.Outcome -eq "ok" }).Count -gt 0) {
        Info "Manage with: exakit source show <name> (every action: exakit help source)"
    }
    # Nothing secret outlives the command in this session.
    foreach ($s in $sources) { $s.Secret = $null }
    return $code
}
