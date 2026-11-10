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
#            (Docker: the fix is in the image - one restart, then the retry)
#   exit 21  the Java language container is missing   -> `exasol slc install java`, retry once
#
# A person connecting at a console is not asked before either: picking the
# source was the permission, so the step is said and made
# (Test-ExakitVsInteractive). A script (--json, or no console) keeps its
# contract: --yes, else the exit code and its remedy.

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

# Get-ExakitVsUnavailableReason - why Test-ExakitVsAvailable said no, in the few
# words the data table's disabled row has room for (the whole label stays
# inside the name column of an 80-column table). Twin of
# exakit_vs_unavailable_reason.
function Get-ExakitVsUnavailableReason {
    if (-not (Get-ExakitVsDefs)) { return "unavailable" }
    return "no pyexasol"
}

# Get-ExakitVsCli - the kit's own command beside this library (setup\exakit.ps1).
# It loads THIS library (its lib\ comes first), so it is the same kit version as
# the installer that dot-sourced it, whatever the kit home holds yet. Twin of
# _exakit_vs_cli.
function Get-ExakitVsCli {
    $cli = Join-Path (Split-Path -Parent $PSScriptRoot) "exakit.ps1"
    if (Test-Path -LiteralPath $cli) { return $cli }
    return $null
}

# Ctrl+C while the wizard runs. The console sends it to every process attached
# to it: the wizard's child ends, and this PowerShell, on its own handler, would
# stop its pipeline as soon as the child returned - in the installer that is
# step 7, the closing panel and the summary of what did not finish, all lost,
# and Invoke-ExakitBestEffort cannot catch a stopped pipeline. While the child
# runs, a Console.CancelKeyPress handler (registered after PowerShell's own, so
# asked first) answers Cancel = true for this process only; the child still
# gets its Ctrl+C. C# 5 and ASCII, for Windows PowerShell 5.1's compiler.
$script:ExakitVsCtrlCSource = @"
using System;
public static class ExakitConnectCtrlC {
    private static ConsoleCancelEventHandler handler = null;
    public static bool Held { get { return handler != null; } }
    public static void Hold() {
        if (handler != null) { return; }
        handler = new ConsoleCancelEventHandler(OnCancel);
        Console.CancelKeyPress += handler;
    }
    public static void Release() {
        if (handler == null) { return; }
        Console.CancelKeyPress -= handler;
        handler = null;
    }
    private static void OnCancel(object sender, ConsoleCancelEventArgs e) {
        e.Cancel = true;
    }
}
"@

# Get-ExakitVsCtrlC - the helper type, compiled once per process; $null when it
# cannot be (the wizard then runs without it, as it did before).
function Get-ExakitVsCtrlC {
    $type = 'ExakitConnectCtrlC' -as [type]
    if ($type) { return $type }
    try {
        Add-Type -TypeDefinition $script:ExakitVsCtrlCSource -Language CSharp -ErrorAction Stop
    } catch {
        Write-ExakitLog "WARN" "Ctrl+C guard for exakit connect not available: $_"
        return $null
    }
    return ('ExakitConnectCtrlC' -as [type])
}

# Start-ExakitVsChild <cli> - the command beside this library, `connect`, on the
# PowerShell running this one, started straight on this console (nothing
# redirected) rather than through the pipeline: a caller that captures output -
# the installer's data step runs inside [void](...) - would redirect the
# child's output, and ui.ps1 then turns its menus off (IsOutputRedirected).
# Returns its exit code; throws when it cannot be started.
function Start-ExakitVsChild {
    param([Parameter(Mandatory)][string]$Cli)
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { throw "the path of this PowerShell is not known" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Cli`" connect"
    $psi.UseShellExecute = $false
    $child = [System.Diagnostics.Process]::Start($psi)
    $child.WaitForExit()
    return $child.ExitCode
}

# Invoke-ExakitVsConnectWizard - the data-load row: `exakit connect` asking for
# everything, the same as typed with no arguments. Always a child: the command
# exits when it is done, and the installer does not have Invoke-CmdConnect at
# all. Ctrl+C ends the child only (see above). Never throws: a child that
# cannot be started is a connect that did not finish (exit 1). Returns the
# child's exit code - -1073741510 (0xC000013A) when Ctrl+C ended it, which
# Test-ExakitConnectCancelled reads as a cancel. Twin of
# exakit_vs_connect_wizard.
function Invoke-ExakitVsConnectWizard {
    $cli = Get-ExakitVsCli
    if (-not $cli) {
        Warn2 "This kit copy has no exakit command beside its library."
        return 2
    }
    $guard = Get-ExakitVsCtrlC
    try {
        if ($guard) { $guard::Hold() }
        return [int](Start-ExakitVsChild -Cli $cli)
    } catch {
        Write-ExakitLog "WARN" "exakit connect could not be started: $_"
        return 1
    } finally {
        if ($guard) { $guard::Release() }
    }
}

# Invoke-ExakitVsEngine - the engine with this installation's context. The
# secret, when there is one, goes to its stdin base64-encoded (and
# --secret-stdin becomes --secret-stdin-base64): Windows PowerShell 5.1
# re-encodes what it pipes to a native program - measured on CI, a
# byte-order mark added and every non-ASCII character turned into '?' even
# with $OutputEncoding set to UTF-8 - and plain ASCII survives every code
# page. Returns @{ Code; Lines }. Every engine run (catalog, resolve, inputs,
# field, paste, plan, connect, the source commands, the terminal form) comes
# through here. Python runs isolated (-I), which ignores every PYTHON*
# variable (PYTHONPATH, PYTHONHOME, PYTHONSTARTUP, ...), the user's
# site-packages and the script's own folder. It does NOT stop a macOS
# framework build taking its program path from PYTHONEXECUTABLE (or
# __PYVENV_LAUNCHER__), which decides sys.prefix - another venv's
# site-packages and its .pth files - so both are taken out of the child's
# environment for the run. cli.py puts its own folder on sys.path. Twin of
# exakit_vs_engine and _exakit_vs_python.
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
    $argv = @("-I", (Join-ExakitCorePath $defs "engine" "cli.py"), "--defs", $defs, "--kit-home", $script:ExakitHome)
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
    # Today's log exists and is owner-only BEFORE the engine writes a line to
    # it: content written under the inherited ACL would stay readable to
    # others if the run were stopped (Ctrl+C) before the step after it.
    Protect-ExakitVsLog -Today
    try { $errFile = [System.IO.Path]::GetTempFileName() }
    catch {
        if (-not $asJson) { throw }
        return [pscustomobject]@{ Code = 1; Lines = @(New-ExakitVsFailureJson -Kind "setup" -Problem "could not create a temporary file" -Remedy "check that the temporary folder exists, is writable and has space, then run the same command again") }
    }
    $previous = $ErrorActionPreference
    $previousEncoding = $OutputEncoding
    $previousExecutable = $env:PYTHONEXECUTABLE
    $previousLauncher = $env:__PYVENV_LAUNCHER__
    $previousEngine = $env:EXAKIT_PERSONAL_ENGINE
    $previousQuote = $env:EXAKIT_VS_QUOTE
    # This run's engine choice, where Get-PersonalSlcDnsEngine falls back to
    # it, so the engine (plan.py recorded_engine) falls back the same way.
    $runEngine = "" + (Get-Variable -Name PersonalEngine -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    try {
        $ErrorActionPreference = "Continue"
        Remove-Item Env:\PYTHONEXECUTABLE, Env:\__PYVENV_LAUNCHER__, Env:\EXAKIT_PERSONAL_ENGINE -ErrorAction SilentlyContinue
        if ($runEngine) { $env:EXAKIT_PERSONAL_ENGINE = $runEngine }
        # A command the engine names is run from this shell: quoted for it.
        $env:EXAKIT_VS_QUOTE = "powershell"
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
        if ($null -ne $previousExecutable) { $env:PYTHONEXECUTABLE = $previousExecutable }
        if ($null -ne $previousLauncher) { $env:__PYVENV_LAUNCHER__ = $previousLauncher }
        Remove-Item Env:\EXAKIT_PERSONAL_ENGINE, Env:\EXAKIT_VS_QUOTE -ErrorAction SilentlyContinue
        if ($null -ne $previousEngine) { $env:EXAKIT_PERSONAL_ENGINE = $previousEngine }
        if ($null -ne $previousQuote) { $env:EXAKIT_VS_QUOTE = $previousQuote }
    }
    foreach ($line in @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)) {
        if ("$line".Trim()) { Write-ExakitLog "VS" "$line" }
    }
    Remove-Item -Force -LiteralPath $errFile -ErrorAction SilentlyContinue
    # Again after it: a run that crossed midnight wrote a new day's file.
    Protect-ExakitVsLog
    return [pscustomobject]@{ Code = $code; Lines = @($lines | ForEach-Object { "$_" }) }
}

# Get-ExakitVsLogFolder - the kit's log folder, where the engine writes its
# day log (--kit-home + logs, as engine/cli.py names it); "" when unknown.
function Get-ExakitVsLogFolder {
    $folder = $script:LogDir
    if (-not $folder -and $script:ExakitHome) { $folder = Join-Path $script:ExakitHome "logs" }
    if (-not $folder) { return "" }
    return $folder
}

# Protect-ExakitVsLog [-Today] - the engine's day log owner-only. The engine
# creates it mode 600 on macOS and Linux; on Windows that is the file's ACL,
# which this side sets, as it does for the install log (Initialize-ExakitLogging).
# -Today creates today's file first, so the ACL is on it before the engine
# writes; without it, the newest file is protected.
function Protect-ExakitVsLog {
    param([switch]$Today)
    if (-not (Get-Command Protect-ExakitFile -ErrorAction SilentlyContinue)) { return }
    $path = ""
    if ($Today) {
        $folder = Get-ExakitVsLogFolder
        if (-not $folder) { return }
        # The local Gregorian date in digits, as the engine names the file
        # (vslog.day_name): the invariant culture, since th-TH or ar-SA would
        # format another calendar's year and make ready a file nobody writes.
        $path = Join-Path $folder ("virtual-schemas-{0}.log" -f (Get-Date).ToString("yyyyMMdd", [Globalization.CultureInfo]::InvariantCulture))
        try {
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path | Out-Null }
        } catch { return }
    } else {
        $path = Get-ExakitVsLogPath
    }
    if ($path) { try { Protect-ExakitFile $path } catch { } }
}

# Get-ExakitVsLogPath - the engine's day log (virtual-schemas-YYYYMMDD.log in
# the kit's log folder, written by engine/vslog.py: every statement it sent
# and every event, secrets redacted), the newest one; "" when there is none.
# Twin of exakit_vs_log_path.
function Get-ExakitVsLogPath {
    $folder = Get-ExakitVsLogFolder
    if (-not $folder) { return "" }
    $newest = Get-ChildItem -LiteralPath $folder -Filter "virtual-schemas-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { return $newest.FullName }
    return ""
}

# Get-ExakitVsLogMark - what that log is now (path:size), so the end of the
# command can tell whether this run wrote to it: a lookup or a refusal the
# engine never logged points at no log. Twin of _exakit_vs_log_mark.
function Get-ExakitVsLogMark {
    $path = Get-ExakitVsLogPath
    if (-not $path) { return "" }
    $size = 0
    try { $size = (Get-Item -LiteralPath $path -ErrorAction Stop).Length } catch { }
    return ("{0}:{1}" -f $path, $size)
}

# Exit-ExakitVs - end a connect or source command. A failure (not 5, a
# question not confirmed or a gated source) that the engine logged names the
# log once, so the statements it sent are one command away; with --json on
# stderr, which no parser reads. An empty file (made ready by
# Protect-ExakitVsLog for a command the engine does not log) names nothing.
# Twin of _exakit_vs_exit.
function Exit-ExakitVs {
    param([int]$Code)
    if ($Code -ne 0 -and $Code -ne 5) {
        $mark = Get-ExakitVsLogMark
        if ($mark -and $mark -ne $script:ExakitVsLogMark -and -not $mark.EndsWith(":0")) {
            $line = "Log (every SQL statement, secrets redacted): " + (Get-ExakitVsLogPath)
            if ($script:ExakitVsJson) { [Console]::Error.WriteLine($line) } else { Info $line }
        }
    }
    exit $Code
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

# Deny-ExakitVsCredentialArgument - a credential given as an option on the
# command line (--password=..., --passwd ..., --secret..., --token...):
# refused without repeating any of it, since every local user can read a
# process's arguments. Twin of _exakit_vs_credential_argument.
function Deny-ExakitVsCredentialArgument {
    Deny-ExakitVsInput "A credential is never taken as an argument (other users can read the process list). Use the hidden prompt, --password-file, or --password-stdin." "a credential was given as an argument, where other users can read it in the process list" "pipe it in with --password-stdin or give it with --password-file <file>"
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

# ConvertFrom-ExakitVsSecretBytes - a credential's bytes as text: UTF-16
# little or big endian by its byte-order mark, else UTF-8 with or without
# one, and no NUL anywhere; one trailing line ending (CRLF or LF) dropped, as
# the shell's reader does (the engine drops any others). $null when the bytes
# are not such text: a credential read in the wrong code page is another
# credential, so it is refused, never guessed. The engine and the shell read
# by the same rules (engine/cli.py decode_secret, _exakit_vs_secret_text);
# NUL is refused on all three because a shell variable drops it without a
# word. Get-Content without an encoding read a BOM-less UTF-8 file in the
# ANSI code page on Windows PowerShell 5.1, and a non-ASCII password became
# another one.
function ConvertFrom-ExakitVsSecretBytes {
    param([byte[]]$Bytes = @())
    $n = $Bytes.Length
    $skip = 0
    # Decoded without throwing (a caught decode error keeps a byte of the
    # credential in $Error: "Unable to translate bytes [E4]"), then encoded
    # back: an invalid byte became U+FFFD, which does not encode to what was read.
    $encoding = New-Object System.Text.UTF8Encoding($false, $false)
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $false, $false); $skip = 2
    } elseif ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $false, $false); $skip = 2
    } elseif ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $skip = 3
    }
    $text = $encoding.GetString($Bytes, $skip, $n - $skip)
    $back = $encoding.GetBytes($text)
    $same = ($back.Length -eq ($n - $skip))
    for ($i = 0; $same -and $i -lt $back.Length; $i++) { if ($back[$i] -ne $Bytes[$skip + $i]) { $same = $false } }
    [Array]::Clear($back, 0, $back.Length)
    if (-not $same -or $text.IndexOf([char]0) -ge 0) { return $null }
    # Ordinal: a culture comparison ignores a soft hyphen after the newline
    # and would cut that instead.
    if ($text.EndsWith("`r`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 2) }
    elseif ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
    return $text
}

# Get-ExakitVsSecretFileBytes - a credential file's bytes, read whole: a
# stream, not a length, so a pipe given as the file is read too (once - it
# cannot be opened again). $null when it is not there or cannot be read.
function Get-ExakitVsSecretFileBytes {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        # The full path: .NET resolves a relative one against the process's
        # folder, not PowerShell's current location.
        $stream = [System.IO.File]::OpenRead((Get-Item -LiteralPath $Path -ErrorAction Stop).FullName)
        $buffer = New-Object System.IO.MemoryStream
        try { $stream.CopyTo($buffer) } finally { $stream.Dispose() }
        # The comma keeps an empty file's empty array from unrolling to $null.
        return ,$buffer.ToArray()
    } catch { return $null }
}

# Get-ExakitVsSecretFileText - a credential file's text
# (ConvertFrom-ExakitVsSecretBytes); $null when it cannot be read, or is
# neither UTF-8 nor UTF-16 text.
function Get-ExakitVsSecretFileText {
    param([string]$Path)
    $bytes = Get-ExakitVsSecretFileBytes -Path $Path
    if ($null -eq $bytes) { return $null }
    return (ConvertFrom-ExakitVsSecretBytes -Bytes $bytes)
}

# Read-ExakitVsSecretFile - the file's text, or the refusal (exit 2; with
# --json the one object) saying which: it cannot be read (a missing file is
# the same refusal), or it is not text this side reads.
function Read-ExakitVsSecretFile {
    param([string]$Path)
    $bytes = Get-ExakitVsSecretFileBytes -Path $Path
    if ($null -eq $bytes) { Deny-ExakitVsInput "Cannot read $Path" "cannot read $Path" "give a file this user can read with --password-file" }
    $text = ConvertFrom-ExakitVsSecretBytes -Bytes $bytes
    if ($null -eq $text) { Deny-ExakitVsInput "The credential in $Path is not UTF-8 or UTF-16 text (another encoding, or a NUL byte): save it as UTF-8 (UTF-16 needs its byte-order mark)." "the credential is not UTF-8 or UTF-16 text" "save the file as UTF-8 (UTF-16 needs its byte-order mark), then run the same command again" }
    return $text
}

# Test-ExakitVsMsysPtyName <name> - is this pipe a Git Bash / MSYS2 / Cygwin
# terminal (\msys-<hex>-pty<n>-from-master, or cygwin-)?
function Test-ExakitVsMsysPtyName {
    param([string]$Name)
    return ($Name -match '^\\(msys|cygwin)-[0-9a-fA-F]+-pty[0-9]+-(from|to)-master')
}

# Get-ExakitVsStdinPipeName - the name of the pipe behind standard input on
# Windows, "" elsewhere or when there is none: GetFileInformationByHandleEx
# (FileNameInfo), as Git for Windows and go-isatty tell a mintty terminal
# from a pipe.
function Get-ExakitVsStdinPipeName {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { return "" }
    try {
        if (-not ("ExakitVsStdinName" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ExakitVsStdinName {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool GetFileInformationByHandleEx(IntPtr handle, int infoClass, IntPtr info, int size);
    public static string Get() {
        int size = 4 + 2 * 1024;
        IntPtr info = Marshal.AllocHGlobal(size);
        try {
            if (!GetFileInformationByHandleEx(GetStdHandle(-10), 2, info, size)) { return ""; }
            int length = Marshal.ReadInt32(info);
            if (length <= 0 || length > size - 4) { return ""; }
            return Marshal.PtrToStringUni(new IntPtr(info.ToInt64() + 4), length / 2);
        } finally { Marshal.FreeHGlobal(info); }
    }
}
'@
        }
        return [ExakitVsStdinName]::Get()
    } catch { return "" }
}

# Test-ExakitVsStdinTerminal - is a person's terminal on standard input? The
# console (nothing piped or redirected into it), or Git Bash's mintty, which
# hands a Windows program its terminal as a named pipe: "redirected", yet
# what is typed there echoes and nothing ever ends it.
function Test-ExakitVsStdinTerminal {
    if (-not [Console]::IsInputRedirected) { return $true }
    return (Test-ExakitVsMsysPtyName (Get-ExakitVsStdinPipeName))
}

# Read-ExakitVsStdinSecret - --password-stdin: ALL of standard input (a JSON
# key file has line breaks), decoded and trimmed as a --password-file is
# (ConvertFrom-ExakitVsSecretBytes). Its bytes, not [Console]::In, which
# decodes in the console's input code page and turns a UTF-8 credential's
# non-ASCII characters into others. Refuses (exit 2; with --json the one
# object) a console on stdin - the flag means a pipe or a file - and nothing
# read. It reaches the engine as every secret does: base64 on its stdin.
# Never echoed, logged or passed as an argument. Twin of _exakit_vs_stdin_secret.
function Read-ExakitVsStdinSecret {
    if (Test-ExakitVsStdinTerminal) {
        # Not a PowerShell pipe as the way out: Windows PowerShell 5.1 pipes only ASCII to a command.
        Deny-ExakitVsInput '--password-stdin reads the credential from standard input, which is a terminal here: give it with --password-file <file>, or redirect the file in cmd.exe (cmd /c "exakit ... --password-stdin < key.json"), or leave --password-stdin out to be asked.' "--password-stdin was given, but standard input is a terminal" "give it with --password-file <file>, or redirect a file into the command from cmd.exe (exakit ... --password-stdin < key.json)"
    }
    $buffer = New-Object System.IO.MemoryStream
    $stdin = [Console]::OpenStandardInput()
    try { $stdin.CopyTo($buffer) } finally { $stdin.Dispose() }
    $text = ConvertFrom-ExakitVsSecretBytes -Bytes $buffer.ToArray()
    $buffer.Dispose()
    if ($null -eq $text) { Deny-ExakitVsInput "--password-stdin: the credential on standard input is not UTF-8 or UTF-16 text (another encoding, or a NUL byte)." "the credential is not UTF-8 or UTF-16 text" "send it as UTF-8 (UTF-16 needs its byte-order mark), or give it with --password-file <file>" }
    if (-not $text) { Deny-ExakitVsInput "--password-stdin read nothing: standard input was empty." "--password-stdin was given, but standard input was empty" "pipe the credential into the command and close the pipe once it is written, or give it with --password-file <file>" }
    return $text
}

function Read-ExakitVsSecret {
    param([string]$Label, [string]$PasswordFile = "", [string]$Kind = "secret")
    if ($PasswordFile) { return (Read-ExakitVsSecretFile -Path $PasswordFile) }
    # --json never prompts: without --password-file there is no credential.
    if ($script:ExakitVsJson) { return "" }
    if (-not (Test-ExakitInteractive)) { Deny-ExakitInput "No $Label was given: use --password-file (a credential is never taken as an argument)." }
    if ($Kind -eq "secret-file") {
        # A key file is asked for by its path - nobody pastes a JSON key into a hidden prompt.
        $path = Read-ExakitPrompt "$Label - path to the file" ""
        if ($path -like "~*") { $path = $HOME + $path.Substring(1) }
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { Deny-ExakitInput "Cannot read $path" }
        return (Read-ExakitVsSecretFile -Path $path)
    }
    return (Read-ExakitVsHidden $Label)
}

# Read-ExakitVsHidden - one line from the console, never echoed: the
# credential, and the connection string (it often holds one). The prompt ends
# in its note, "(input hidden)" unless the caller says another. A key that
# sends an escape sequence (an arrow, Delete) is no character here: the host's
# secure read takes none. Twin of exakit_read_hidden.
function Read-ExakitVsHidden {
    param([string]$Label, [string]$Note = "input hidden")
    Write-Host ("    {0}?{1} {2} ({3}): " -f $script:UiAsk, $script:UiReset, $Label, $Note) -NoNewline
    $secure = Read-Host -AsSecureString
    # The rest of a multi-line paste answers no later question.
    Clear-ExakitVsPendingKeys
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# Clear-ExakitVsPendingKeys - after a hidden answer, the keys still pending (the
# rest of a multi-line paste) are read and dropped, until a tenth of a second
# passes with none: they would otherwise answer the next question, and a
# visible one would echo them. Twin of the drain in _exakit_vs_hidden_line.
function Clear-ExakitVsPendingKeys {
    try {
        do {
            Start-Sleep -Milliseconds 100
            $any = $false
            while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $any = $true }
        } while ($any)
    } catch { }
}

# Read-ExakitVsKey - one key from the console, nothing echoed: "enter", "esc",
# "eof" (Ctrl-D, or Ctrl-Z, the Windows console's) or the character typed. An
# arrow or another key with no character (KeyChar 0) is not a key here: the
# next one is read. What is still pending after it - the rest of a paste typed
# at the question - is discarded. A console that cannot read single keys
# answers "enter". Twin of _exakit_vs_key.
function Read-ExakitVsKey {
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            $code = [int]$key.KeyChar
            $answer = ""
            if ($key.Key -eq [ConsoleKey]::Enter -or $code -eq 13 -or $code -eq 10) { $answer = "enter" }
            elseif ($key.Key -eq [ConsoleKey]::Escape -or $code -eq 27) { $answer = "esc" }
            elseif ($code -eq 4 -or $code -eq 26) { $answer = "eof" }
            elseif ($code -ge 32) { $answer = "" + $key.KeyChar }
            if ($answer) {
                Clear-ExakitVsPendingKeys
                return $answer
            }
        }
    } catch { return "enter" }
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

# Test-ExakitVsInteractive - is a person connecting at a console? Set by
# Invoke-CmdConnect (a console, no --json) and the terminal flow
# ($script:ExakitVsInteractive). Picking the source was their permission to
# prepare the database for it, so a language container or a restart is said
# and made, never asked. Anything else keeps Confirm-ExakitVs: --yes, a y at a
# console (exakit source), and no for --json or no console - the exit code and
# remedy. Twin of _exakit_vs_interactive.
function Test-ExakitVsInteractive {
    return ([bool]$script:ExakitVsInteractive -and -not $script:ExakitVsJson)
}

# Join-ExakitVsAnd - "a", "a and b", "a, b and c": the sources a step is for, in
# the line that says it. Twin of _exakit_vs_and.
function Join-ExakitVsAnd {
    param([string[]]$Words = @())
    $w = @($Words | Where-Object { $_ })
    if ($w.Count -le 1) { return ($w -join "") }
    return ((@($w[0..($w.Count - 2)]) -join ", ") + " and " + $w[$w.Count - 1])
}

# Get-ExakitVsLabel - a connector's name in the catalog ("PostgreSQL"), for the
# line that says what a step is for; the id when the catalog cannot be read.
# Twin of _exakit_vs_label.
function Get-ExakitVsLabel {
    param([string]$Connector)
    try {
        $file = Join-ExakitCorePath (Get-ExakitVsDefs) "catalog.json"
        $entry = @((Get-Content -Raw -LiteralPath $file | ConvertFrom-Json).connectors) | Where-Object { $_.id -eq $Connector } | Select-Object -First 1
        if ($entry -and $entry.name) { return "" + $entry.name }
    } catch { }
    return $Connector
}

# Get-ExakitVsFor - what $script:ExakitVsFor names, or "this source".
function Get-ExakitVsFor {
    if ($script:ExakitVsFor) { return "" + $script:ExakitVsFor }
    return "this source"
}

# Install-ExakitVsJava - the Java language container, with consent: about 250
# MiB and one restart, through the exakit command's own stop/start so add-on
# services come back. A person connecting at a console gave it by picking the
# source: one line says what happens and why, and nothing is asked. Twin of
# _exakit_vs_install_java.
# Install-ExakitVsRust - the Rust language container a native adapter
# (Profile D) runs in, with consent (said, not asked, at a console, as Java's
# is): the exasol-labs build pinned for this CPU in profiles\rust-native, size-
# and SHA-256-checked, registered as the RUST alias, then one restart. Twin of
# _exakit_vs_install_rust.
function Install-ExakitVsRust {
    $defs = Get-ExakitVsDefs
    $custom = (Get-Content -Raw -LiteralPath (Join-ExakitCorePath $defs "profiles" "rust-native" "profile.json") | ConvertFrom-Json).slc.custom
    $arch = "x86_64"
    if ("$env:PROCESSOR_ARCHITECTURE" -eq "ARM64") { $arch = "aarch64" }
    $pin = $custom.arch.$arch
    if (-not $pin) { Write-Host "  There is no Rust language container build for this CPU ($arch)." -ForegroundColor Red; return $false }
    if (Test-ExakitVsInteractive) {
        Info ("Installing the Rust language container for {0}: {1} {2}, about {3} MiB, checksum-pinned, and the database restarts once (add-on services restart with it)." -f (Get-ExakitVsFor), $custom.upstream, $custom.version, [int]([double]$pin.size / 1048576))
    } else {
        Info "This source runs a native adapter inside the database, and its Rust language container is not installed."
        Info ("Installing it downloads {0} {1} (about {2} MiB, checksum-pinned) and restarts the database once (add-on services restart with it)." -f $custom.upstream, $custom.version, [int]([double]$pin.size / 1048576))
        if (-not (Confirm-ExakitVs "Install the Rust language container now?")) {
            Info "Nothing was installed. Run the same exakit connect again when you are ready."
            return $false
        }
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
    if (Test-ExakitVsInteractive) {
        Info ("Installing the Java language container for {0}: about 250 MiB, and the database restarts once (add-on services restart with it)." -f (Get-ExakitVsFor))
    } else {
        Info "Virtual schemas run Java inside the database, and its Java language container is not installed."
        Info "Installing it downloads about 250 MiB and restarts the database once (add-on services restart with it)."
        if (-not (Confirm-ExakitVs "Install the Java language container now?")) {
            Info "Install it later with: exasol slc install java --no-restart, then exakit stop and exakit start"
            return $false
        }
    }
    $slcArgs = @("slc", "install", "java", "--no-restart")
    $flag = Get-PersonalAutoApproveFlag "slc"
    if ($flag) { $slcArgs += $flag }
    if ((Invoke-ExakitLogged (Get-PersonalCli) @slcArgs) -ne 0) {
        Write-Host ("  {0} The Java language container did not install. Details: exakit logs" -f $script:UiCross) -ForegroundColor Red
        return $false
    }
    # Docker: the download the start would make, made now, and the image
    # linked to the deployment's DNS before the start mounts it read-only - so
    # this start is the only one (Initialize-PersonalSlcDns).
    try { Initialize-PersonalSlcDns -Pull } catch { }
    if (-not (Restart-ExakitVsDatabase)) {
        Write-Host ("  {0} The database did not come back after installing Java. Run: exakit start" -f $script:UiCross) -ForegroundColor Red
        return $false
    }
    # An installed kit's start repairs DNS; this kit copy may be newer than it.
    # Docker: linked in the image after an older kit's start mounted it - one
    # more start mounts it.
    try { [void](Repair-PersonalSlcDns) } catch { }
    if ($script:PersonalSlcDnsNeedsStart -and -not (Restart-ExakitVsDatabase)) {
        Write-Host ("  {0} The database did not come back after installing Java. Run: exakit start" -f $script:UiCross) -ForegroundColor Red
        return $false
    }
    Ok "Java language container installed"
    return $true
}

# Restart-ExakitVsDatabase - exakit stop (add-on services with it), then
# exakit start, through the installed kit: its start brings add-on services
# back and gives the language containers the deployment's DNS. $true when
# that start succeeded: a caller must not go on with a database that is down.
function Restart-ExakitVsDatabase {
    $exakit = Join-Path $script:BinDir "exakit.cmd"
    $previousStop = $env:EXAKIT_STOP_ADDONS
    try {
        $env:EXAKIT_STOP_ADDONS = "1"
        & $exakit stop *> $null
    } finally { $env:EXAKIT_STOP_ADDONS = $previousStop }
    # Write-Host, not Out-Host: with --json, Invoke-ExakitVsAside moves these lines to stderr.
    & $exakit start | ForEach-Object { Write-Host "$_" }
    return ($LASTEXITCODE -eq 0)
}

# Restart-ExakitVsForDns - Docker: the DNS fix is in the language container
# image, and the database mounts an image only when it starts - one restart.
# Said and made for a person connecting at a console; otherwise asked
# (Confirm-ExakitVs: --yes makes it, --json and no console do not). $true when
# the database came back. Twin of _exakit_vs_dns_restart.
function Restart-ExakitVsForDns {
    if (Test-ExakitVsInteractive) {
        Info ("Restarting the database once, so Java in it can resolve host names for {0} (add-on services restart with it)." -f (Get-ExakitVsFor))
    } else {
        Info "The database sees it from its next start: one restart (add-on services restart with it)."
        if (-not (Confirm-ExakitVs "Restart the database now?")) {
            Write-Host "  Java in the database resolves host names from its next start. Run: exakit stop, then exakit start - and try again." -ForegroundColor Red
            return $false
        }
    }
    if (-not (Restart-ExakitVsDatabase)) {
        Write-Host "  The database did not come back. Run: exakit start" -ForegroundColor Red
        return $false
    }
    return $true
}

# Repair-ExakitVsForRetry - what the bridge does about exit 20 (DNS repaired),
# 21 (Java installed) or 23 (Rust installed) before its one retry; $false when
# it could not, or was not allowed to. Twin of _exakit_vs_repair.
function Repair-ExakitVsForRetry {
    param([int]$Code)
    if ($Code -eq 20) {
        Info "Giving the database's language containers the deployment's DNS, then trying again"
        if (Repair-PersonalSlcDns) { return $true }
        if ($script:PersonalSlcDnsNeedsStart) { return [bool](Restart-ExakitVsForDns) }
        Write-Host "  DNS could not be repaired. Restart the database (exakit stop, exakit start) and try again." -ForegroundColor Red
        return $false
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
# quoted as it must be, then the connector's tips. Twin of _exakit_vs_query_hints,
# plus a line bash has no need for: here `exakit` is exakit.cmd, and PowerShell
# (5.1, and 7 too for a batch file) strips the inner double quotes of an argument
# it hands to one, so an example that quotes a name (MySQL, SQL Server, MongoDB
# keep their names' case) is shown again with each one written \".
function Show-ExakitVsQueryHints {
    param($Result, [string]$Name)
    if ($null -ne $Result -and $Result.PSObject.Properties["example"] -and $Result.example) {
        $example = "" + $Result.example
        Ok ("Query it like any schema: " + $example)
        if ($example.Contains('"')) {
            Info ("From PowerShell: exakit sql '" + $example.Replace('"', '\"').Replace("'", "''") + "'")
            Info 'Each inner double quote needs its \ there: PowerShell drops unescaped ones when it hands the query to exakit.cmd.'
        }
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
    $repoint = ($Plan.PSObject.Properties["action"] -and $Plan.action -eq "repoint")
    $title = "Plan for"
    if ($repoint) { $title = "Re-point" }
    Write-Host ("  {0} {1} ({2}, {3}, {4})" -f $title, $Plan.name, $Plan.connector, $Plan.tier, $Plan.status)
    if ($Plan.PSObject.Properties["changes"]) {
        foreach ($c in @($Plan.changes)) {
            if ($null -eq $c) { continue }
            $from = "(none)"; $to = "(none)"
            if ($null -ne $c.from) { $from = "" + $c.from }
            if ($null -ne $c.to) { $to = "" + $c.to }
            Write-Host ("    {0}: {1} -> {2}" -f $c.input, $from, $to)
        }
    }
    if ($Plan.PSObject.Properties["action"] -and $Plan.action -eq "unchanged") { Write-Host ("  " + $Plan.note) }
    if ($repoint) {
        if (@($Plan.changes | Where-Object { $null -ne $_ }).Count -eq 0) { Write-Host "    Address: as it is - only the credential is replaced" }
        Write-Host "    Credential: required - give it again (the database never returns a stored one); it is tried with the new address before anything changes"
    }
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

# Test-ExakitVsSourceLive - the name is a source the kit connected and has not
# disconnected: `exakit connect` re-points it in place (or says there is
# nothing to change), on the line-by-line path. Twin of _exakit_vs_source_live.
function Test-ExakitVsSourceLive {
    param([string]$Name)
    if (-not $Name -or $Name -cnotmatch '^[a-z][a-z0-9_]{0,39}$') { return $false }
    $folder = Join-Path (Join-Path $script:ExakitHome "sources") $Name
    if (-not (Test-Path -LiteralPath (Join-Path $folder "config.json") -PathType Leaf)) { return $false }
    $stateFile = Join-Path $folder "state.json"
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { return $true }
    $disconnected = @(Get-Content -LiteralPath $stateFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^  "status": "disconnected"' })
    return ($disconnected.Count -eq 0)
}

# Format-ExakitVsWord - the text as one PowerShell word: as it is when it needs
# no quoting, else in single quotes with each ' doubled. For a command the
# --json answer names. Twin of _exakit_vs_word, which quotes for a POSIX shell.
function Format-ExakitVsWord {
    param([string]$Text)
    if ($Text -and $Text -cmatch '^[A-Za-z0-9_+=:./\\-]+$') { return $Text }
    return ("'" + $Text.Replace("'", "''") + "'")
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
# takes; one that fills the last column exactly is one row, as the console
# holds the wrap until the next character. Twin of _exakit_vs_tui_rows (which
# counts a readline line one more; PowerShell reads no line through readline).
function Get-ExakitVsTuiRows {
    param([int]$Chars)
    if ($Chars -le 0) { return 1 }
    return [int][Math]::Floor(($Chars - 1) / $script:EvtCols) + 1
}

# Get-ExakitVsCatalog - the connector catalog (engine catalog), and with it this
# computer's public IP: its tip is said first when it is known (cloud sources
# see this address; the address in green), and nothing when the lookup is off
# (EXAKIT_NO_IP_LOOKUP=1) or failed - publicip.py's own rules and timeout. The
# answer is kept for the rest of this command ($env:_EXAKIT_VS_PUBLIC_IP), so
# each source's plan says it again without asking again. Returns the catalog,
# or $null. Twin of _exakit_vs_catalog.
function Get-ExakitVsCatalog {
    $run = Invoke-ExakitVsEngine -Arguments @("catalog", "--public-ip")
    # The engine's tip names the IP; on screen the address is green (the log
    # keeps the plain words). Every other line renders as it always has.
    $known = ""
    foreach ($line in @($run.Lines)) {
        if ("$line" -like "RESULT *") {
            try { $r = ("$line").Substring(7) | ConvertFrom-Json; if ($r.PSObject.Properties["public_ip"] -and $r.public_ip) { $known = "" + $r.public_ip } } catch { }
        }
    }
    $rest = @()
    foreach ($line in @($run.Lines)) {
        if ($known -and ("$line" -like "INFO *") -and ("$line".Contains($known))) {
            $text = ("$line").Substring(5)
            $at = $text.IndexOf($known)
            if (-not $script:UiAccent) { Info $text }
            else {
                if (-not $script:ExakitQuietDetail) {
                    $shown = $text.Substring(0, $at) + $script:UiAccent + $known + $script:UiReset + $text.Substring($at + $known.Length)
                    Write-Host ("    {0}{1}{2} {3}" -f $script:UiDim, $script:UiBullet, $script:UiReset, $shown)
                }
                Write-ExakitLog "INFO" $text
            }
        } else { $rest += $line }
    }
    $catalog = Show-ExakitVsLines -Lines $rest
    if ($null -ne $catalog) {
        $ip = "none"
        if ($catalog.PSObject.Properties["public_ip"] -and $catalog.public_ip) { $ip = "" + $catalog.public_ip }
        $env:_EXAKIT_VS_PUBLIC_IP = $ip
    }
    return $catalog
}

# Invoke-ExakitVsPick - the connector menu, under the line that names this
# computer's public IP (Get-ExakitVsCatalog). Returns the chosen connector ids;
# none when nothing was chosen. Twin of _exakit_vs_pick.
function Invoke-ExakitVsPick {
    $catalog = Get-ExakitVsCatalog
    if ($null -eq $catalog) { Write-Host ("  {0} The connector catalog could not be read. Details: exakit logs" -f $script:UiCross) -ForegroundColor Red; return @() }
    # Each source by its name and nothing more, in the catalog's order: the
    # adapter version and tier are `exakit source catalog`'s. Twin of _exakit_vs_pick.
    $entries = @($catalog.connectors)
    $t = New-ExakitTable -Title "Connect external sources" -Col1 "Source"
    # The Source column alone: nothing runs in this menu's rows, so it has no
    # Status column either.
    $t.StatMin = 0
    $ids = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $tree = "tee"
        if ($i -eq $entries.Count - 1) { $tree = "corner" }
        $label = "" + $e.name
        if ("" + $e.status -eq "gated") {
            # Its reason read on from its name: there is no Status column to say it in.
            $row = Add-ExakitTableRow -Kind $tree -Label ($label + " - not available yet") -Table $t
            Disable-ExakitTableRow -Row $row -Table $t
        } else {
            [void](Add-ExakitTableRow -Kind $tree -Label $label -Table $t)
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
# ($script:EvtOnScreen lines), in one write. A required field's label ends in a
# red * (a plain * without colour), which the legend under the fields explains;
# a field still to answer is dim, with its default; an answered one is ticked -
# or, with -Numbered (the summary), numbered - and says so when a pasted
# connection string gave it. The engine's notes on that string ($Form.Notes) stay under the panel.
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
    $anyReq = $false
    for ($i = 0; $i -lt $Form.Fields.Count; $i++) {
        $f = $Form.Fields[$i]
        $lab = $f.Label
        # The label column holds " *" after a required one ($Form.LW counts it).
        $star = ""; $starW = 0
        if ($f.Req) { $star = " " + $script:UiErr + "*" + $script:UiReset; $starW = 2; $anyReq = $true }
        $star += (" " * [Math]::Max(0, $Form.LW - $lab.Length - $starW))
        $lead = ""
        if ($i -eq $Current) {
            $mark = $script:UiAccent + $script:UiArrow + $script:UiReset; $shown = $script:UiBold + $lab + $script:UiReset + $star
            $plain = ""; $val = ""
        } elseif ($f.Done) {
            $mark = $script:UiOk + $script:UiTick + $script:UiReset; $shown = $lab + $star
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
            $mark = " "; $shown = $script:UiDim + $lab + $script:UiReset + $star
            $v = "" + $f.Val
            if (-not $v) { $v = "" + $f.Def }
            if ($f.Kind -in @("secret", "secret-file")) { $v = "" }
            $plain = ""
            if ($v) { $plain = "[" + $v + "]" }
            if ($plain.Length -gt $room) {
                # Too narrow: the default is cut, then it goes too (the question
                # says it again).
                $plain = ""
                if ($room -ge 6) { $plain = "[" + (Format-ExakitVsTuiFit $v ($room - 2)) + "]" }
            }
            $val = $script:UiDim + $plain + $script:UiReset
        }
        if (-not $lead) { $lead = "  " + $mark + "  " }
        $pad = [Math]::Max(0, $in - 7 - $Form.LW - $plain.Length)
        [void]$sb.Append("  " + $script:UiAccent + $script:UiVB + $script:UiReset + $lead + $shown + "  " + $val + (" " * $pad) + $script:UiAccent + $script:UiVB + $script:UiReset + "`r`n")
        $lines++
    }
    # The legend, one dim line under the fields: what the star means.
    if ($anyReq) {
        $pad = [Math]::Max(0, $in - 15)
        [void]$sb.Append("  " + $script:UiAccent + $script:UiVB + $script:UiReset + "     " + $script:UiErr + "*" + $script:UiReset + $script:UiDim + " required" + $script:UiReset + (" " * $pad) + $script:UiAccent + $script:UiVB + $script:UiReset + "`r`n")
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
        # Twin of _exakit_vs_hidden_line: Backspace and Ctrl-U edit, Ctrl-D (or
        # Ctrl-Z, the Windows console's) on an empty line is the end of input,
        # and what is still pending after Enter is discarded. An arrow, Home,
        # End or Delete arrives as one key with no character (KeyChar 0) and a
        # lone Esc as 27: below 32, neither joins the line.
        $sb = New-Object System.Text.StringBuilder
        $ended = $false
        while ($true) {
            $key = [Console]::ReadKey($true)
            $code = [int]$key.KeyChar
            if ($key.Key -eq [ConsoleKey]::Enter -or $code -eq 13 -or $code -eq 10) { break }
            if ($code -eq 4 -or $code -eq 26) {
                if ($sb.Length -eq 0) { $ended = $true; break }
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Backspace -or $code -eq 8 -or $code -eq 127) {
                if ($sb.Length -gt 0) { [void]$sb.Remove($sb.Length - 1, 1) }
                continue
            }
            if ($code -eq 21) { [void]$sb.Clear(); continue }
            if ($code -ge 32) { [void]$sb.Append($key.KeyChar) }
        }
        $answer = $sb.ToString()
        [void]$sb.Clear()
        Clear-ExakitVsPendingKeys
        [Console]::Write("`r`n")
        $script:EvtOnScreen += (Get-ExakitVsTuiRows ($Plain.Length + 4))
        if ($ended) { return $null }
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

# Get-ExakitVsPasteForms - the connection strings a connector's paste block
# reads, one per item, for the examples above the question that asks for one;
# none when it reads none. Twin of _exakit_vs_paste_forms.
function Get-ExakitVsPasteForms {
    param([string]$Connector)
    $defs = Get-ExakitVsDefs
    if (-not $defs -or -not $Connector) { return @() }
    $file = Join-ExakitCorePath $defs "connectors" $Connector "connector.json"
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $doc = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
    if (-not $doc.PSObject.Properties["paste"] -or -not $doc.paste) { return @() }
    return @(@($doc.paste.forms) | Where-Object { $_ } | ForEach-Object { "" + $_ })
}

# Write-ExakitVsPasteHint - the line-by-line hint above the question: what to
# paste, then each form on its own line, indented under the hint's text and dim;
# one wider than the console (or -Cols) is wrapped at the same indent. Twin of
# _exakit_vs_paste_hint.
function Write-ExakitVsPasteHint {
    param([string[]]$Forms = @(), [int]$Cols = 0)
    Info "Paste the source's connection string, for example:"
    $width = 70
    if ($Cols -gt 0) { $width = $Cols - 10 }
    else { try { $width = [Console]::WindowWidth - 10 } catch { } }
    if ($width -lt 10) { $width = 10 }
    # Split-ExakitWrap is ui.ps1's; without it (ui.ps1 failed to load) a form is
    # printed whole and the console wraps it.
    $canWrap = [bool](Get-Command Split-ExakitWrap -ErrorAction SilentlyContinue)
    foreach ($form in $Forms) {
        $parts = @($form)
        if ($canWrap) { $parts = @(Split-ExakitWrap -Text $form -Width $width) }
        foreach ($part in $parts) {
            Write-Host ("        " + $script:UiDim + $part + $script:UiReset)
        }
    }
}

# Get-ExakitVsPasteChoiceText - the question after a pasted string was read: its
# three answers, with the palette's separator. Twin of
# _exakit_vs_paste_choice_text.
function Get-ExakitVsPasteChoiceText {
    $dot = $script:UiMidDot
    if (-not $dot) { $dot = "-" }
    return ("Enter to use it {0} e to paste it again {0} Esc/n to type the fields instead" -f $dot)
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
# answering: not --yes, --dry-run or --json) a required question ends in a red *
# (a plain * without colour; Write-ExakitVsLegend says what it means), and an
# empty answer to it is refused ("<label> is required") and asked again; an
# optional one shows only its default. Without marks, it is Read-ExakitPrompt as
# it always was. Twin of _exakit_vs_prompt.
function Read-ExakitVsLineAnswer {
    param([string]$Question, [string]$Default = "", [bool]$Required = $false, [bool]$Marks = $false, [string]$Label = "")
    if (-not $Marks) { return (Read-ExakitPrompt $Question $Default) }
    $mark = ""
    if ($Required) { $mark = " " + $script:UiErr + "*" + $script:UiReset }
    if (-not $Label) { $Label = $Question }
    while ($true) {
        if (-not (Test-ExakitInteractive)) { return $Default }
        $v = "" + (Read-ExakitPrompt ($Question + $mark) $Default)
        if ($v -or -not $Required) { return $v }
        Write-Host ("  {0} {1} is required" -f $script:UiCross, $Label) -ForegroundColor Red
        Write-ExakitLog "ERROR" "$Label is required"
    }
}

# Write-ExakitVsLegend - the line above the marked questions that says what their
# star means, as the panel's legend does. Twin of _exakit_vs_legend.
function Write-ExakitVsLegend {
    Write-Host ("    {0}*{1} {2}required{1}" -f $script:UiErr, $script:UiReset, $script:UiDim)
}

# Read-ExakitVsLinePaste - the line-by-line twin of the form's first question: a
# connection string, read hidden as a password is (it often holds one), to the
# engine's paste, base64 on its stdin, never an argument; or Enter to type the
# fields. It is shown back, its credentials masked by the engine ("Read: ..."),
# and one key decides: Enter uses it, e asks for it again, Esc or n types the
# fields instead. Returns @{ Sets; Names } for what the string named; only
# those fields are shown. A string the engine cannot read is said, in its
# words, and asked again. Twin of _exakit_vs_ask_paste.
function Read-ExakitVsLinePaste {
    param([string]$Connector)
    $answer = @{ Sets = @(); Names = @() }
    $forms = @(Get-ExakitVsPasteForms $Connector)
    if ($forms.Count -eq 0) { return $answer }
    Write-ExakitVsPasteHint -Forms $forms
    while ($true) {
        $url = "" + (Read-ExakitVsHidden "Connection string" "not shown while you paste, Enter to type the fields")
        if (-not $url) { return $answer }
        $pasted = Invoke-ExakitVsEngine -Arguments @("paste", $Connector, "--base64") -Secret $url
        $url = $null
        if ($pasted.Code -eq 0) {
            $read = Get-ExakitVsResultOf $pasted.Lines
            $masked = ""
            if ($null -ne $read -and $read.PSObject.Properties["masked"]) { $masked = "" + $read.masked }
            Info ("Read: " + $masked)
            Write-Host ("    {0}?{1} {2} " -f $script:UiAsk, $script:UiReset, (Get-ExakitVsPasteChoiceText)) -NoNewline
            $key = ""
            while ($key -notin @("enter", "esc", "eof", "e", "n")) { $key = ("" + (Read-ExakitVsKey)).ToLowerInvariant() }
            Write-Host ""
            if ($key -eq "e") { continue }
            if ($key -ne "enter") { return $answer }
        }
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
# asked again, when there is a reason): its label, a red * when it is required,
# its notes and its default. Enter takes the default; an optional one with none is
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
    $notes = @()
    if ($f.Kind -eq "choice") { $notes += "(" + ($f.Choices -join (" " + $script:UiMidDot + " ")) + ")" }
    elseif ($f.Kind -eq "secret") {
        $def = ""
        # Given already - typed, or read from --password-file: Enter keeps it.
        if ($old -or ($f.Done -and $Form.PwFile)) { $keep = $true; $notes += "(hidden, Enter keeps the one given)" } else { $notes += "(hidden)" }
    }
    elseif ($f.Kind -eq "secret-file") { $notes += "(the path to the file)" }
    # An optional answer that differs from its default can be taken back.
    if (-not $f.Req -and $old -and $old -ne ("" + $f.Def) -and $f.Kind -notin @("secret", "secret-file")) { $notes += "(- clears it)" }
    if ($def) { $notes += "[" + (Format-ExakitVsTuiTail $def 32) + "]" }
    $note = $notes -join " "
    # A required one: the label's red * (a plain * without colour), as in the panel.
    $plain = $f.Label
    $colour = $script:UiAsk + $f.Label + $script:UiReset
    if ($f.Req) { $plain += " *"; $colour += " " + $script:UiErr + "*" + $script:UiReset }
    if ($note) { $plain += " " + $note; $colour += " " + $script:UiDim + $note + $script:UiReset }
    while ($true) {
        if ($f.Kind -eq "secret") {
            $a = Read-ExakitVsTuiAnswer -Plain $plain -Colour $colour -Hidden
            if ($null -eq $a) { return $false }
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

# Write-ExakitVsTuiExample - one example under the hint, indented under its text
# and dim; one wider than the terminal is wrapped at the same indent, and every
# line is counted for the next redraw. Twin of _exakit_vs_tui_example.
function Write-ExakitVsTuiExample {
    param([string]$Text)
    $parts = @(Split-ExakitWrap -Text $Text -Width ($script:EvtCols - 10))
    foreach ($part in $parts) { [Console]::Write("        " + $script:UiDim + $part + $script:UiReset + "`r`n") }
    $script:EvtOnScreen += $parts.Count
}

# Read-ExakitVsTuiChoice - the question after a pasted string, answered by one
# key (Read-ExakitVsKey): "enter", "e", "n", "esc" or "eof"; any other key is no
# answer. Twin of _exakit_vs_tui_choose.
function Read-ExakitVsTuiChoice {
    param([string]$Plain, [string]$Colour)
    [Console]::Write("  " + $Colour + " ")
    $key = ""
    while ($key -notin @("enter", "esc", "eof", "e", "n")) { $key = ("" + (Read-ExakitVsKey)).ToLowerInvariant() }
    [Console]::Write("`r`n")
    $script:EvtOnScreen += (Get-ExakitVsTuiRows ($Plain.Length + 3))
    return $key
}

# Invoke-ExakitVsTuiPaste - the form's first question, for a connector that reads
# a connection string (its paste block), under a hint and one example per line:
# read hidden, the string goes to the engine's paste, base64 on its stdin, never
# in argv, and is not kept. It is shown back with its credentials masked by the
# engine ("Read: ..."), and one key decides: Enter uses it, e asks for it again,
# Esc or n types the fields instead. What it names is answered, marked "from the
# string" and not asked; the engine's notes and the masked string stay under the
# panel. A string it cannot read is said, in the engine's words, and asked
# again; Enter types the fields instead. $false at end of input. Twin of
# _exakit_vs_tui_paste.
function Invoke-ExakitVsTuiPaste {
    param([hashtable]$Form)
    $forms = @(Get-ExakitVsPasteForms $Form.Connector)
    if ($forms.Count -eq 0) { return $true }
    $why = ""
    # Read with echo off, as a password is: the string often holds one. What was
    # read is shown back masked, and the fields it filled.
    $plain = "Connection string (not shown while you paste, Enter to type the fields)"
    $colour = $script:UiAsk + "Connection string" + $script:UiReset + " " + $script:UiDim + "(not shown while you paste, Enter to type the fields)" + $script:UiReset
    $choice = Get-ExakitVsPasteChoiceText
    # Where there is room, the question says a field can still be changed.
    $more = " " + $script:UiMidDot + " every field can be changed in the summary"
    if (($choice.Length + $more.Length + 3) -lt $script:EvtCols) { $choice = $choice + $more }
    while ($true) {
        Show-ExakitVsTuiPanel -Form $Form -Current -1
        Write-ExakitVsTuiSay -Text "Paste the source's connection string, for example:" -Mark ($script:UiDim + $script:UiBullet + $script:UiReset)
        foreach ($f in $forms) { Write-ExakitVsTuiExample $f }
        if ($why) { Write-ExakitVsTuiSay $why }
        $why = ""
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
        $masked = ""
        if ($null -ne $res -and $res.PSObject.Properties["masked"]) { $masked = "" + $res.masked }
        Write-ExakitVsTuiSay -Text ("Read: " + $masked) -Mark ($script:UiDim + $script:UiBullet + $script:UiReset)
        $key = Read-ExakitVsTuiChoice -Plain $choice -Colour ($script:UiAsk + $choice + $script:UiReset)
        if ($key -eq "e") { continue }
        if ($key -eq "eof") { return $false }
        if ($key -ne "enter") { return $true }
        if ($null -ne $res -and $res.values) {
            foreach ($p in @($res.values.PSObject.Properties)) {
                foreach ($f in $Form.Fields) {
                    if ($f.Name -eq $p.Name) { $f.Val = "" + $p.Value; $f.Done = $true; $f.From = $true }
                }
            }
        }
        $Form.Notes = @(@("INFO Read: " + $masked) + @(Format-ExakitVsPasteTyped @(@($pasted.Lines) | Where-Object { $_ -like "WARN *" -or $_ -like "INFO *" })))
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
        # The label column holds a required one's " *" too (Show-ExakitVsTuiPanel).
        $w = $label.Length
        if ($f.Req) { $w += 2 }
        if ($w -gt $lw) { $lw = $w }
        [void]$fields.Add($f)
    }
    if ($lw -gt 32) { $lw = 32 }
    foreach ($f in $fields) {
        $w = $lw
        if ($f.Req) { $w = $lw - 2 }
        $f.Label = Format-ExakitVsTuiShort $f.Label $w
    }
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
# table animates; each source's Outcome is set (ok, failed, java, rust, or dns:
# the restart Docker's DNS repair needs). Twin of _exakit_vs_tui_run and
# _exakit_vs_tui_live together.
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
        $unread = ""
        if (-not $secret -and $s.SecretFile) {
            $secret = Get-ExakitVsSecretFileText -Path $s.SecretFile
            if ($null -eq $secret) { $secret = ""; $unread = "" + $s.SecretFile }
        }
        $engineArgs = @("--json", "connect") + $s.Base
        if ($secret) { $engineArgs += "--secret-stdin" }
        $restart = $false
        for ($try = 1; $try -le 2; $try++) {
            if ($unread) {
                # Its row says so, as the engine says a file the shell hands it raw.
                $run = [pscustomobject]@{ Code = 2; Lines = @(New-ExakitVsFailureJson -Kind "input" -Problem "cannot read $unread as UTF-8 or UTF-16 text" -Remedy "save the file as UTF-8 (UTF-16 needs its byte-order mark), then run the same command again") }
                break
            }
            Set-ExakitTableRow -Row $row -State running -Pct 5 -Ceiling 90 -Secs 30 -Phase "connecting" -Table $Table
            $run = Invoke-ExakitVsEngine -Arguments $engineArgs -Secret $secret
            if ($run.Code -eq 20 -and $try -eq 1) {
                Set-ExakitTableRow -Row $row -State running -Pct 30 -Ceiling 60 -Secs 20 -Phase "repairing DNS" -Table $Table
                $repaired = $false
                try { $repaired = [bool](Repair-PersonalSlcDns 6> $null) } catch { }
                if ($repaired) { continue }
                # Docker: seen from the database's next start - that restart is
                # made below the table, as a language container is.
                if ($script:PersonalSlcDnsNeedsStart) { $restart = $true }
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
            elseif ($run.Code -eq 20 -and $restart) { $why = "needs a database restart"; $s.Outcome = "dns" }
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
    # A person at a console: what the picked sources need is said, not asked.
    $script:ExakitVsInteractive = $true
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
    # A language container (a download and a restart), or the restart Docker's
    # DNS repair needs: said once, below the table - picking the sources was the
    # permission, so nothing is asked - then those sources run again in a table
    # of their own. A restart made for a language container is the one the DNS
    # repair needed too.
    $restarted = $false
    foreach ($lang in @("java", "rust", "dns")) {
        $wait = @($sources | Where-Object { $_.Outcome -eq $lang })
        if ($wait.Count -eq 0) { continue }
        # The sources it is for, by the connector's name, each once.
        $script:ExakitVsFor = Join-ExakitVsAnd @($wait | ForEach-Object { "" + $_.Label } | Select-Object -Unique)
        [Console]::Write("`r`n")
        $installed = $false
        if ($lang -eq "java") { $installed = Install-ExakitVsJava }
        elseif ($lang -eq "rust") { $installed = Install-ExakitVsRust }
        elseif ($restarted) { $installed = $true }
        else { $installed = Restart-ExakitVsForDns }
        if (-not $installed) { foreach ($s in $wait) { $s.Outcome = "failed"; $s.Code = 1 }; continue }
        if ($lang -ne "dns") { $restarted = $true }
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
