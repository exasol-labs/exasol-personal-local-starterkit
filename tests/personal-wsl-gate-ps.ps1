# personal-wsl-gate-ps.ps1 - the Windows WSL 2.7 check for Podman, run against
# a stub wsl.exe. Twin of tests/personal-wsl-gate.sh for
# setup/lib/runtime-personal.ps1.
#
#   pwsh -NoProfile -NonInteractive -File tests/personal-wsl-gate-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/personal-wsl-gate-ps.ps1
#
# What it pins, and why each one exists:
#   - wsl.exe is handed --version UNQUOTED. Invoke-ExakitBounded's -Arguments
#     quotes every element, wsl.exe matched the quoted token as no option and
#     ran it as a Linux command, and the release read failed on every machine.
#     On Windows the .cmd stub records the raw argument it received; on a Unix
#     pwsh .NET re-parses the command line (quotes vanish), so the parameters
#     handed to Invoke-ExakitBounded are checked as well, everywhere.
#   - The release is read out of UTF-16LE with a localized label, and only as
#     a dotted number: a Japanese label's high bytes once leaked a "0".
#   - Unknown is not old: missing, failing, timed-out, empty and usage-text
#     answers warn and let through; only a release read below 2.7 refuses.
#
# Stub wsl.exe only; never touches a real one. Writes only under a temp dir.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected [$expected], got [$actual]" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "present" "present" } else { Check $label "present" "MISSING ($haystack)" }
}
function Lacks($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "absent" "PRESENT ($haystack)" } else { Check $label "absent" "absent" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-wsl-gate-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:HOME = Join-Path $work "home"
$env:EXAKIT_HOME = Join-Path $work "exakit"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "no-deployment"
New-Item -ItemType Directory -Force -Path $env:HOME, $env:EXAKIT_HOME | Out-Null
Set-Content -Path (Join-Path $env:EXAKIT_HOME "manifest.json") -Encoding Ascii -Value '{"manifest_version": 1}'
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")

# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
$onWindows = ($env:OS -like "*Windows*")

# --- what the gate says -------------------------------------------------------
$script:Said = New-Object System.Collections.ArrayList
function Warn2 { param([string]$Message) [void]$script:Said.Add("WARN $Message") }
function Info { param([string]$Message) [void]$script:Said.Add("INFO $Message") }
function Get-ExakitInstallCommand { return "irm install | iex" }

# --- fixtures: UTF-16LE with its byte order mark and CRLF, as Windows writes --
# Escapes, not literals: Windows PowerShell 5.1 reads a BOM-less script in the
# ANSI code page, so a Katakana literal would arrive as something else.
$fixtures = Join-Path $work "fixtures"
New-Item -ItemType Directory -Force -Path $fixtures | Out-Null
function New-Utf16Fixture {
    param([string]$Name, [string]$Escaped)
    $text = [regex]::Unescape($Escaped)
    $bytes = [byte[]](@([byte]0xFF, [byte]0xFE) + [System.Text.Encoding]::Unicode.GetBytes($text))
    $path = Join-Path $fixtures $Name
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}
$fx = @{
    "en26"  = New-Utf16Fixture "en26"  'WSL version: 2.6.1.0\r\nKernel version: 6.6.87.2-1\r\n'
    "en27"  = New-Utf16Fixture "en27"  'WSL version: 2.7.0.0\r\nKernel version: 6.6.87.2-1\r\n'
    "en210" = New-Utf16Fixture "en210" 'WSL version: 2.10.1.0\r\nKernel version: 6.6.87.2-1\r\n'
    "de"    = New-Utf16Fixture "de"    'WSL-Version: 2.6.1.0\r\nKernelversion: 6.6.87.2-1\r\n'
    "fr"    = New-Utf16Fixture "fr"    'Version WSL : 2.6.1.0\r\nVersion du noyau : 6.6.87.2-1\r\n'
    "ja"    = New-Utf16Fixture "ja"    'WSL \u30d0\u30fc\u30b8\u30e7\u30f3: 2.7.0.0\r\n\u30ab\u30fc\u30cd\u30eb \u30d0\u30fc\u30b8\u30e7\u30f3: 6.6.87.2-1\r\n'
    "ru"    = New-Utf16Fixture "ru"    '\u0412\u0435\u0440\u0441\u0438\u044f WSL: 2.6.1.0\r\n\u0412\u0435\u0440\u0441\u0438\u044f \u044f\u0434\u0440\u0430: 6.6.87.2-1\r\n'
    "zh"    = New-Utf16Fixture "zh"    'WSL \u7248\u672c\uff1a 2.6.1.0\r\n\u5185\u6838\u7248\u672c\uff1a 6.6.87.2-1\r\n'
    "inbox" = New-Utf16Fixture "inbox" 'Usage: wsl.exe [Argument] [Options...] [CommandLine]\r\n'
    "empty" = New-Utf16Fixture "empty" ''
}

# --- the stub wsl.exe ---------------------------------------------------------
# Records the raw arguments it received in STUB_ARGS, writes the bytes of
# STUB_WSL_OUT to stdout, exits STUB_WSL_RC. A .cmd on Windows (cmd's own echo
# keeps the quotes a quoting caller added), a sh script elsewhere.
$stubDir = Join-Path $work "stubs"
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
if ($onWindows) {
    $stub = Join-Path $stubDir "wsl.cmd"
    Set-Content -Path $stub -Encoding Ascii -Value @(
        "@echo off",
        "echo %*> `"%STUB_ARGS%`"",
        "if not `"%STUB_WSL_OUT%`"==`"`" powershell -NoProfile -NonInteractive -Command `"`$b=[IO.File]::ReadAllBytes(`$env:STUB_WSL_OUT); `$o=[Console]::OpenStandardOutput(); `$o.Write(`$b,0,`$b.Length); `$o.Flush()`"",
        "exit /b %STUB_WSL_RC%"
    )
} else {
    $stub = Join-Path $stubDir "wsl.exe"
    Set-Content -Path $stub -Value @(
        "#!/bin/sh",
        "printf '%s\n' `"`$*`" > `"`$STUB_ARGS`"",
        "[ -n `"`${STUB_WSL_OUT:-}`" ] && cat `"`$STUB_WSL_OUT`"",
        "exit `"`${STUB_WSL_RC:-0}`""
    )
    chmod +x $stub
}
$env:STUB_ARGS = Join-Path $work "args"

# The stub podman, with a FAKE MACHINE behind it. `machine ssh <command>` RUNS
# the command it was handed - in a POSIX sh, with /etc/containers and
# /usr/share/containers pointed into $STUB_FAKE and $HOME at $STUB_FAKE/home -
# and exits with that command's own code, as `podman machine ssh` does. A
# stub that printed a fixture and exited 0 whatever it was asked passed a
# reader whose `cat` exited 1 on any missing file, which refused the real
# machine (WIN4-01). A stopped machine answers ssh with exit 125; `machine
# list` and `machine start` read and set its state file; every call is logged.
# Never a real podman. It runs through a POSIX sh: /bin/sh, or on Windows the
# one Git for Windows ships; without one the machine cases are skipped.
$posixSh = $null
if ($onWindows) {
    foreach ($candidate in @((Join-Path "$env:ProgramFiles" "Git\bin\sh.exe"), (Join-Path "$env:ProgramFiles" "Git\usr\bin\sh.exe"))) {
        if (Test-Path -LiteralPath $candidate) { $posixSh = $candidate; break }
    }
} elseif (Test-Path -LiteralPath "/bin/sh") {
    $posixSh = "/bin/sh"
}
$podmanStub = Join-Path $stubDir "podman-stub.sh"
$podmanStubText = @(
    '#!/bin/sh',
    'fake=$(cygpath -u "$STUB_FAKE" 2>/dev/null || printf %s "$STUB_FAKE")',
    'printf "%s\n" "$*" >> "$STUB_PODMAN_LOG"',
    'state=$(cat "$STUB_MACHINE_STATE" 2>/dev/null || echo running)',
    'case "$1 $2" in',
    '    "machine ssh")',
    '        if [ "$state" != running ]; then echo "Error: vm podman-machine-default is not running" >&2; exit 125; fi',
    '        cmd=$(printf "%s" "$3" | sed -e "s#/usr/share/containers/#$fake/usr/share/containers/#g" -e "s#/etc/containers/#$fake/etc/containers/#g")',
    '        HOME="$fake/home" XDG_CONFIG_HOME="" sh -c "$cmd"',
    '        exit $? ;;',
    '    "machine list")',
    '        if [ "$state" = running ]; then echo "podman-machine-default* true"; else echo "podman-machine-default* false"; fi',
    '        exit 0 ;;',
    '    "machine start")',
    '        if [ "${STUB_MACHINE_START_FAILS:-0}" = 1 ]; then exit 125; fi',
    '        echo running > "$STUB_MACHINE_STATE"',
    '        exit 0 ;;',
    '    "info --format")',
    '        if [ "$state" != running ]; then exit 125; fi',
    '        echo amd64',
    '        exit 0 ;;',
    'esac',
    'exit 125'
) -join "`n"
[System.IO.File]::WriteAllText($podmanStub, $podmanStubText + "`n")
$fakeMachine = Join-Path $work "machine"
$env:STUB_FAKE = ($fakeMachine -replace '\\', '/')
$env:STUB_MACHINE_STATE = ((Join-Path $work "machine-state") -replace '\\', '/')
$env:STUB_PODMAN_LOG = ((Join-Path $work "podman.log") -replace '\\', '/')

# Get-Command wsl.exe answers the stub, or nothing when $script:StubWsl is "".
# podman answers $script:StubPodman, nothing by default: a real podman on the
# machine running this test must never be asked.
$script:StubWsl = $stub
$script:StubPodman = ""
function Get-Command {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    if ($Name -eq "wsl.exe") {
        if (-not $script:StubWsl) { return $null }
        return [pscustomobject]@{ Source = $script:StubWsl }
    }
    if ($Name -eq "podman") {
        if (-not $script:StubPodman) { return $null }
        return [pscustomobject]@{ Source = $script:StubPodman }
    }
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
}

# What Invoke-ExakitBounded was handed; STUB_TIMEOUT=1 answers as a probe that
# was cut off does ($null), without waiting the 20 seconds for it. The stub
# podman is a sh script, so it is run through the POSIX sh, its arguments
# exactly as the kit passed them.
${function:Invoke-ExakitBoundedReal} = ${function:Invoke-ExakitBounded}
function Invoke-ExakitBounded {
    param([string]$FilePath, [string[]]$Arguments = @(), [string]$ArgumentString = "", [int]$TimeoutSeconds = 8)
    $script:SeenArguments = ($Arguments -join "|")
    $script:SeenArgumentString = $ArgumentString
    if ($env:STUB_TIMEOUT -eq "1") { return $null }
    if ($FilePath -eq $podmanStub) {
        $Arguments = @(($podmanStub -replace '\\', '/')) + $Arguments
        $FilePath = $posixSh
    }
    return (Invoke-ExakitBoundedReal -FilePath $FilePath -Arguments $Arguments -ArgumentString $ArgumentString -TimeoutSeconds $TimeoutSeconds)
}

# Use-Machine <files> [-State] [-StartFails] - a fresh fake machine: each key a
# path under its root (etc/..., usr/share/..., home/...), each value the file's
# text. Clears the reader's per-process cache and the call log.
function Use-Machine {
    param([hashtable]$Files = @{}, [string]$State = "running", [switch]$StartFails)
    Remove-Item -Recurse -Force $fakeMachine -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $fakeMachine | Out-Null
    foreach ($rel in $Files.Keys) {
        $path = Join-Path $fakeMachine $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllText($path, ($Files[$rel] -replace "`r", ""))
    }
    [System.IO.File]::WriteAllText((Join-Path $work "machine-state"), "$State`n")
    if ($StartFails) { $env:STUB_MACHINE_START_FAILS = "1" } else { $env:STUB_MACHINE_START_FAILS = "0" }
    Remove-Item -Force (Join-Path $work "podman.log") -ErrorAction SilentlyContinue
    $script:PersonalPodmanIptablesCache = $null
    $script:PersonalPodmanMachineStopped = $false
    $script:Said.Clear()
}
# Podman-Calls <verb> - how often the stub podman was asked "<verb>" (e.g.
# "machine ssh") since Use-Machine.
function Podman-Calls {
    param([string]$Verb)
    $log = Join-Path $work "podman.log"
    if (-not (Test-Path -LiteralPath $log)) { return 0 }
    return @(Get-Content -LiteralPath $log | Where-Object { "$_".StartsWith($Verb) }).Count
}

# The machine's firewall driver, as the gate sees it. The real reader is kept
# and tested on its own below; the gate is tested against this stub, which also
# counts how often the gate asked.
${function:Test-PersonalPodmanMachineIptablesReal} = ${function:Test-PersonalPodmanMachineIptables}
$script:StubIptables = $false
$script:IptablesAsked = 0
function Test-PersonalPodmanMachineIptables { $script:IptablesAsked++; return $script:StubIptables }

function Use-Wsl {
    param([string]$Out = "", [int]$Rc = 0, [string]$Timeout = "0")
    $env:STUB_WSL_OUT = $Out
    $env:STUB_WSL_RC = "$Rc"
    $env:STUB_TIMEOUT = $Timeout
    $script:Said.Clear()
    Remove-Item -Force $env:STUB_ARGS -ErrorAction SilentlyContinue
}
function Show-Release {
    $r = Get-PersonalWslRelease
    if ($null -eq $r) { return "<null>" }
    return $r
}

Write-Host "Get-PersonalWslRelease: wsl.exe is handed --version unquoted"
Use-Wsl -Out $fx["en26"]
Check "English label"                    "2.6.1.0" (Show-Release)
Check "  through -ArgumentString"        "--version" $script:SeenArgumentString
Check "  and not -Arguments"             "" $script:SeenArguments
$seen = ""
if (Test-Path $env:STUB_ARGS) { $seen = ("" + (Get-Content -Raw $env:STUB_ARGS)).Trim() }
Check "  the stub received it bare"      "--version" $seen

Write-Host ""
Write-Host "Get-PersonalWslRelease: the dotted release out of UTF-16LE, whatever the label"
foreach ($case in @(
        @("German label", "de", "2.6.1.0"),
        @("French label", "fr", "2.6.1.0"),
        @("Japanese label", "ja", "2.7.0.0"),
        @("Russian label", "ru", "2.6.1.0"),
        @("Chinese label", "zh", "2.6.1.0"),
        @("two-digit minor", "en210", "2.10.1.0"))) {
    Use-Wsl -Out $fx[$case[1]]
    Check $case[0] $case[2] (Show-Release)
}

Write-Host ""
Write-Host "Get-PersonalWslRelease: no release read is `$null, never a version"
Use-Wsl -Out $fx["inbox"] -Rc 1
Check "inbox WSL, usage on exit 1"       "<null>" (Show-Release)
Use-Wsl -Out $fx["inbox"]
Check "inbox WSL, usage on exit 0"       "<null>" (Show-Release)
Use-Wsl -Rc 1
Check "interop failure (exit 1, no output)" "<null>" (Show-Release)
Use-Wsl -Out $fx["en26"] -Rc 1
Check "a version, but exit 1"            "<null>" (Show-Release)
Use-Wsl -Out $fx["empty"]
Check "empty output"                     "<null>" (Show-Release)
Use-Wsl -Out $fx["en26"] -Timeout "1"
Check "probe timed out"                  "<null>" (Show-Release)
$script:StubWsl = ""
Use-Wsl -Out $fx["en26"]
Check "no wsl.exe"                       "<null>" (Show-Release)
$script:StubWsl = $stub

Write-Host ""
Write-Host "Test-PersonalWslPodmanNetworkOk: only a release read below 2.7 refuses"
Use-Wsl -Out $fx["en26"]
$ok = Test-PersonalWslPodmanNetworkOk "exakit start"
# $lines, not $said: PowerShell names are case-insensitive, and $said at the
# script's top level IS $script:Said.
$lines = ($script:Said -join "`n")
Check "WSL 2.6 -> refused"               $false $ok
Has "  names the release"                "Podman on WSL 2.6.1.0 cannot" $lines
Has "  names the fix"                    "wsl --update" $lines
Has "  and the re-run"                   "re-run: exakit start" $lines
Has "  changed nothing"                  "Nothing was changed." $lines
Check "  the failure reason"             "WSL 2.6.1.0 is older than 2.7, so Podman cannot create the deployment network (run: wsl --update)" (Get-ExakitFailureReason)
Use-Wsl -Out $fx["ru"]
Check "Russian label on 2.6 -> refused"  $false (Test-PersonalWslPodmanNetworkOk)
Use-Wsl -Out $fx["ja"]
Check "Japanese label on 2.7 -> ok"      $true (Test-PersonalWslPodmanNetworkOk)
Use-Wsl -Out $fx["en27"]
Check "WSL 2.7 -> ok"                    $true (Test-PersonalWslPodmanNetworkOk)
Use-Wsl -Out $fx["en210"]
Check "WSL 2.10 -> ok"                   $true (Test-PersonalWslPodmanNetworkOk)
foreach ($case in @(
        @("inbox WSL (usage text)", $fx["inbox"], 1, "0"),
        @("interop failure (exit 1)", "", 1, "0"),
        @("probe timed out", $fx["en26"], 0, "1"),
        @("empty output", $fx["empty"], 0, "0"))) {
    Use-Wsl -Out $case[1] -Rc $case[2] -Timeout $case[3]
    $ok = Test-PersonalWslPodmanNetworkOk
    $lines = ($script:Said -join "`n")
    Check "$($case[0]) -> let through" $true $ok
    Has "  with a warning"               "so it is unknown" $lines
    Lacks "  never 'older than'"         "older than 2.0" $lines
}
$script:StubWsl = ""
Use-Wsl
Check "no wsl.exe -> let through"        $true (Test-PersonalWslPodmanNetworkOk)
Has "  with a warning"                   "check with 'wsl --version'" ($script:Said -join "`n")
$script:StubWsl = $stub

Write-Host ""
Write-Host "Test-PersonalWslPodmanNetworkOk -Replace: unknown refuses the destroy (WSLR-01, WSLR-07)"
foreach ($case in @(
        @("interop failure (exit 1)", "", 1, "0"),
        @("probe timed out", $fx["en26"], 0, "1"),
        @("usage text", $fx["inbox"], 0, "0"))) {
    Use-Wsl -Out $case[1] -Rc $case[2] -Timeout $case[3]
    $ok = Test-PersonalWslPodmanNetworkOk "exakit start" -Replace
    $lines = ($script:Said -join "`n")
    Check "$($case[0]) -> refused" $false $ok
    Has "  says the release was not read" "Could not read the WSL release" $lines
    Has "  names wsl --version"          "wsl --version" $lines
    Has "  and the 2.7 floor"            "2.7 or newer" $lines
    Check "  one 'Nothing was' line"     1 @($script:Said | Where-Object { "$_" -match 'Nothing was' }).Count
}
Has "  the failure reason"               "replacing the Podman deployment was refused" (Get-ExakitFailureReason)
$env:EXAKIT_WSL_CHECKED = "1"
Use-Wsl -Rc 1
Check "unknown, EXAKIT_WSL_CHECKED=1 -> let through" $true (Test-PersonalWslPodmanNetworkOk "exakit start" -Replace)
Use-Wsl -Out $fx["en26"]
Check "  but never over a release read as 2.6" $false (Test-PersonalWslPodmanNetworkOk "exakit start" -Replace)
Remove-Item Env:\EXAKIT_WSL_CHECKED
Use-Wsl -Out $fx["en26"]
$ok = Test-PersonalWslPodmanNetworkOk "exakit start" -Replace
$lines = ($script:Said -join "`n")
Check "replace on WSL 2.6 -> refused"    $false $ok
Has "  nothing deleted"                  "Nothing was deleted" $lines
Lacks "  never 'Nothing was changed'"    "Nothing was changed" $lines
Has "  one next step: exakit start"      "then: exakit start" $lines
Check "  said once"                      1 @($script:Said | Where-Object { "$_" -match 'Nothing was' }).Count
Use-Wsl -Out $fx["en27"]
Check "replace on WSL 2.7 -> ok"         $true (Test-PersonalWslPodmanNetworkOk "exakit start" -Replace)
Use-Wsl -Rc 1
Check "install path, unknown -> still let through" $true (Test-PersonalWslPodmanNetworkOk)

Write-Host ""
Write-Host "Test-PersonalFirewallDriverIptables: the last firewall_driver under [network] decides"
Check "under [network]"                   $true  (Test-PersonalFirewallDriverIptables "[network]`nfirewall_driver=`"iptables`"")
Check "  spaced, indented"                $true  (Test-PersonalFirewallDriverIptables "[network]`n  firewall_driver = `"iptables`"")
Check "  single quotes"                   $true  (Test-PersonalFirewallDriverIptables "[network]`nfirewall_driver = 'iptables'")
Check "  a trailing comment"              $true  (Test-PersonalFirewallDriverIptables "[ network ]`nfirewall_driver = `"iptables`" # set by hand")
Check "  CRLF"                            $true  (Test-PersonalFirewallDriverIptables "[network]`r`nfirewall_driver = `"iptables`"`r`n")
Check "a commented line -> no"            $false (Test-PersonalFirewallDriverIptables "[network]`n#firewall_driver = `"iptables`"")
Check "nftables -> no"                    $false (Test-PersonalFirewallDriverIptables "[network]`nfirewall_driver = `"nftables`"")
Check "outside any table -> no"           $false (Test-PersonalFirewallDriverIptables 'firewall_driver="iptables"')
Check "under [engine] -> no"              $false (Test-PersonalFirewallDriverIptables "[engine]`nfirewall_driver = `"iptables`"")
Check "  [network] then [engine] -> no"   $false (Test-PersonalFirewallDriverIptables "[network]`ndns_bind_port = 53`n[engine]`nfirewall_driver = `"iptables`"")
Check "user's nftables overrides system"  $false (Test-PersonalFirewallDriverIptables "#@file`n[network]`nfirewall_driver=`"iptables`"`n#@file`n[network]`nfirewall_driver = `"nftables`"")
Check "user's iptables over an empty one" $true  (Test-PersonalFirewallDriverIptables "#@file`n[network]`n#firewall_driver = `"`"`n#@file`n[network]`nfirewall_driver = `"iptables`"")
Check "a table does not carry into the next file" $false (Test-PersonalFirewallDriverIptables "#@file`n[network]`n#@file`nfirewall_driver = `"iptables`"")
Check "nothing -> no"                     $false (Test-PersonalFirewallDriverIptables "")
Check "an unquoted value -> no"           $false (Test-PersonalFirewallDriverIptables "[network]`nfirewall_driver = iptables")
Check "  and it overrides an earlier iptables" $false (Test-PersonalFirewallDriverIptables "#@file`n[network]`nfirewall_driver = `"iptables`"`n#@file`n[network]`nfirewall_driver = iptables")
Check "[NETWORK] is not [network] -> no"  $false (Test-PersonalFirewallDriverIptables "[NETWORK]`nfirewall_driver = `"iptables`"")
Check "Firewall_Driver is not the key -> no" $false (Test-PersonalFirewallDriverIptables "[network]`nFirewall_Driver = `"iptables`"")
Check "[[network]] is not the table -> no" $false (Test-PersonalFirewallDriverIptables "[[network]]`nfirewall_driver = `"iptables`"")

Write-Host ""
Write-Host "Test-PersonalPodmanMachineIptables: the machine's own files, through podman machine ssh"
$netIpt = "[network]`nfirewall_driver = `"iptables`"`n"
$netNft = "[network]`nfirewall_driver = `"nftables`"`n"
$etcConf = "etc/containers/containers.conf"
$userConf = "home/.config/containers/containers.conf"
$script:StubPodman = $podmanStub
$env:STUB_TIMEOUT = "0"
if (-not $posixSh) {
    Write-Host "  skip: no POSIX sh to run the fake machine (install Git for Windows)"
} else {
    Use-Machine @{ $etcConf = $netIpt }
    Check "/etc only, on iptables (the reported machine) -> yes" $true (Test-PersonalPodmanMachineIptablesReal)
    Has   "  asked through machine ssh, one remote command" "machine|ssh|for f in /usr/share/containers/containers.conf /etc/containers/containers.conf " $script:SeenArguments
    Lacks "  never a double quote in it"      '"' $script:SeenArguments
    Has   "  the drop-in directory too"       "/etc/containers/containers.conf.d/*.conf" $script:SeenArguments
    Has   "  and the user's files"            '${XDG_CONFIG_HOME:-$HOME/.config}/containers/containers.conf' $script:SeenArguments
    Use-Machine @{ $userConf = $netIpt }
    Check "user file only, on iptables -> yes" $true (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ "usr/share/containers/containers.conf" = $netIpt }
    Check "/usr/share only, on iptables -> yes" $true (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $etcConf = $netIpt; $userConf = $netNft }
    Check "user file overrides to nftables -> no" $false (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $etcConf = "[engine]`nfirewall_driver = `"iptables`"`n" }
    Check "the key under [engine] -> no"      $false (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $etcConf = $netNft; "etc/containers/containers.conf.d/50-iptables.conf" = $netIpt }
    Check "a drop-in in containers.conf.d -> honoured" $true (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $etcConf = $netIpt; "home/.config/containers/containers.conf.d/90-nft.conf" = $netNft }
    Check "  the user's drop-in last of all" $false (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $userConf = "[network]`nfirewall_driver = 'iptables'`n" }
    Check "single quotes -> yes"              $true (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $etcConf = $netIpt; $userConf = "[network]`nfirewall_driver = iptables`n" }
    Check "a user file with an unquoted value -> no" $false (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $etcConf = "[network]`n"; $userConf = "firewall_driver = `"iptables`"`n" }
    Check "a top-level key in the next file -> no" $false (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{ $etcConf = "[network]`n#firewall_driver = `"`"`n" }
    Check "no driver set -> no"               $false (Test-PersonalPodmanMachineIptablesReal)
    Use-Machine @{}
    Check "no file at all -> no"              $false (Test-PersonalPodmanMachineIptablesReal)
    Check "  a definite answer, kept"         $false $script:PersonalPodmanIptablesCache

    Write-Host ""
    Write-Host "Test-PersonalPodmanMachineIptables: one ssh per process, a stopped machine is not an answer"
    Use-Machine @{ $etcConf = $netIpt }
    [void](Test-PersonalPodmanMachineIptablesReal)
    Check "running, iptables -> yes, again"   $true (Test-PersonalPodmanMachineIptablesReal)
    Check "  the machine asked once"          1 (Podman-Calls "machine ssh")
    Use-Machine @{ $etcConf = $netIpt } -State "stopped"
    Check "stopped -> no"                     $false (Test-PersonalPodmanMachineIptablesReal)
    Check "  not kept"                        "" ("" + $script:PersonalPodmanIptablesCache)
    Check "  the machine is named stopped"    $true $script:PersonalPodmanMachineStopped
    Check "  and never started without -StartMachine" 0 (Podman-Calls "machine start")
    [void](Test-PersonalPodmanMachineIptablesReal)
    Check "  asked again on the next call"    2 (Podman-Calls "machine ssh")
    Use-Machine @{ $etcConf = $netIpt } -State "stopped"
    Check "stopped, -StartMachine -> started, then yes" $true (Test-PersonalPodmanMachineIptablesReal -StartMachine)
    Check "  started once"                    1 (Podman-Calls "machine start")
    Has   "  and says so"                     "starting it to read its firewall driver" ($script:Said -join "`n")
    Check "  not named stopped"               $false $script:PersonalPodmanMachineStopped
    Use-Machine @{ $etcConf = $netIpt } -State "stopped" -StartFails
    Check "stopped, start fails -> no"        $false (Test-PersonalPodmanMachineIptablesReal -StartMachine)
    Check "  named stopped"                   $true $script:PersonalPodmanMachineStopped
    Use-Machine @{ $etcConf = $netIpt }
    $env:STUB_TIMEOUT = "1"
    Check "ssh timed out -> no"               $false (Test-PersonalPodmanMachineIptablesReal)
    Check "  not kept"                        "" ("" + $script:PersonalPodmanIptablesCache)
    $env:STUB_TIMEOUT = "0"

    Write-Host ""
    Write-Host "Test-PersonalWslPodmanNetworkOk with the real reader: a stopped machine on WSL 2.6"
    ${function:Test-PersonalPodmanMachineIptables} = ${function:Test-PersonalPodmanMachineIptablesReal}
    Use-Machine @{ $etcConf = $netIpt } -State "stopped"
    Use-Wsl -Out $fx["en26"]
    $ok = Test-PersonalWslPodmanNetworkOk
    $lines = ($script:Said -join "`n")
    Check "refused"                           $false $ok
    Has   "  names podman machine start"      "podman machine start" $lines
    Has   "  still names the WSL fix"         "wsl --update" $lines
    Check "  not kept"                        "" ("" + $script:PersonalPodmanIptablesCache)
    Use-Machine @{ $etcConf = $netIpt } -State "stopped"
    Use-Wsl -Out $fx["en26"]
    Check "the deploy step (-StartMachine) starts it and passes" $true (Test-PersonalWslPodmanNetworkOk -StartMachine)
    Check "  nothing refused"                 0 @($script:Said | Where-Object { "$_" -match 'cannot create the network' }).Count
    Use-Machine @{ $etcConf = $netIpt } -State "stopped"
    Use-Wsl -Out $fx["en26"]
    $ok = Test-PersonalWslPodmanNetworkOk "exakit start" -Replace
    Check "replace, stopped, not started -> refused" $false $ok
    Has   "  names podman machine start"      "podman machine start" ($script:Said -join "`n")
    Use-Machine @{ $etcConf = $netNft }
    Use-Wsl -Out $fx["en26"]
    $ok = Test-PersonalWslPodmanNetworkOk
    Check "running, on nftables -> refused"   $false $ok
    Lacks "  no machine-start line"           "podman machine start" ($script:Said -join "`n")
    Check "  the gate's answer is kept"       $false $script:PersonalPodmanIptablesCache
    Use-Wsl -Out $fx["en26"]
    [void](Test-PersonalWslPodmanNetworkOk -StartMachine)
    Check "  so the deploy step asks no second ssh" 1 (Podman-Calls "machine ssh")
    function Test-PersonalPodmanMachineIptables { $script:IptablesAsked++; return $script:StubIptables }
}
$script:StubPodman = ""
Use-Machine @{}
Check "no podman -> no"                   $false (Test-PersonalPodmanMachineIptablesReal)

Write-Host ""
Write-Host "Test-PersonalWslPodmanNetworkOk: a machine on iptables passes below 2.7"
$script:StubIptables = $true
Use-Wsl -Out $fx["en26"]
$script:IptablesAsked = 0
Check "WSL 2.6, iptables -> ok"           $true (Test-PersonalWslPodmanNetworkOk "exakit start")
Check "  nothing said"                    0 $script:Said.Count
Check "  asked the machine once"          1 $script:IptablesAsked
Use-Wsl -Out $fx["en26"]
Check "replace on WSL 2.6, iptables -> ok" $true (Test-PersonalWslPodmanNetworkOk "exakit start" -Replace)
Use-Wsl -Rc 1
Check "replace, release unknown, iptables -> ok" $true (Test-PersonalWslPodmanNetworkOk "exakit start" -Replace)
Use-Wsl -Out $fx["en26"]
Check "quiet on WSL 2.6, iptables -> ok"  $true (Test-PersonalWslPodmanNetworkOk -Quiet)
Use-Wsl -Out $fx["en27"]
$script:IptablesAsked = 0
Check "WSL 2.7 -> ok"                     $true (Test-PersonalWslPodmanNetworkOk)
Check "  never pays for the ssh"          0 $script:IptablesAsked
$script:StubIptables = $false

Write-Host ""
Write-Host "Test-PersonalWslPodmanNetworkOk -Quiet: the verdict, nothing said"
Use-Wsl -Out $fx["en26"]
[void](Get-ExakitFailureReason)
Check "WSL 2.6 -> refused"               $false (Test-PersonalWslPodmanNetworkOk -Quiet)
Check "  nothing said"                   0 $script:Said.Count
Check "  no failure reason"              "" (Get-ExakitFailureReason)
Check "  the release kept"               "2.6.1.0" $script:PersonalWslReleaseSeen

Write-Host ""
Write-Host "Test-PersonalStartNetworkBlocked: Podman AND netavark's error in this start (WINR-03)"
$script:LogFile = Join-Path $work "start.log"
$script:StubEngine = "podman"
function Get-PersonalEngineRecorded { return $script:StubEngine }
$nft = 'Error: netavark: nftables error: "nft" did not return successfully while applying ruleset'
function Test-Start([string]$Line) {
    Set-Content -Path $script:LogFile -Value "an earlier line"
    $at = Get-PersonalLogOffset
    Add-Content -Path $script:LogFile -Value $Line
    return (Test-PersonalStartNetworkBlocked -LogOffset $at)
}
Use-Wsl -Out $fx["en26"]
Check "WSL 2.6, nft error -> blocked"            $true (Test-Start $nft)
Check "WSL 2.6, machine not running -> not"      $false (Test-Start "Error: podman machine not running")
Check "WSL 2.6, port held -> not"                $false (Test-Start "bind: address already in use")
Check "benign 'nftables not available' -> not"   $false (Test-Start 'level=warn msg="nftables not available, falling back"')
Set-Content -Path $script:LogFile -Value $nft
Check "an older run's nft line -> not"           $false (Test-PersonalStartNetworkBlocked -LogOffset (Get-PersonalLogOffset))
$script:StubEngine = "docker"
Check "a Docker deployment, nft error -> not"    $false (Test-Start $nft)
$script:StubEngine = "podman"
$env:CONTAINERS_MACHINE_PROVIDER = "hyperv"
Check "a Hyper-V Podman machine -> not"          $false (Test-Start $nft)
Remove-Item Env:\CONTAINERS_MACHINE_PROVIDER

Write-Host ""
Write-Host "Wait-PersonalReadyOrDeploy: a deploy that met the WSL kernel never names repair-runtime (WSL4-01)"
# The launcher's start exited 0 doing nothing; its deploy then hits netavark's
# nftables error. The caller that ends the run must name the WSL fix.
# Every function replaced here is put back after the section.
$saved = @{}
foreach ($name in @("Invoke-ExakitLogged", "Test-PersonalReadyProbe", "Get-PersonalAutoApproveFlag", "Show-PersonalPodmanRootfulHint",
                    "Start-Personal", "Test-PersonalDeploymentExists", "Test-PersonalDeploymentRunning", "Fail")) {
    $saved[$name] = (Get-Item "Function:\$name").ScriptBlock
}
Set-ExakitManifestValue "runtime.type" "personal"
$script:DeployLine = $nft
function Invoke-ExakitLogged { Add-Content -Path $script:LogFile -Value $script:DeployLine; return 1 }
function Test-PersonalReadyProbe { return $false }
function Get-PersonalAutoApproveFlag { return "" }
function Show-PersonalPodmanRootfulHint { }
function Start-Personal { }
function Test-PersonalDeploymentExists { return $true }
function Test-PersonalDeploymentRunning { return $false }
function Fail([string]$Msg) { Set-ExakitFailureReason $Msg; throw $Msg }
Set-Content -Path $script:LogFile -Value "an earlier line"
Check "the deploy fails on the nft error -> false" $false (Wait-PersonalReadyOrDeploy)
Check "  flagged as the WSL kernel"              $true $script:PersonalStartNetworkBlocked
Has   "  the reason is the network sentence"     "cannot create the deployment network: run wsl --update" (Get-ExakitFailureReason)
Has   "  said in one short line"                 "The launcher's deploy failed: this WSL kernel cannot create the deployment network" ($script:Said -join "`n")
$threw = ""
try { Confirm-ExakitRuntimeRunning } catch { $threw = "" + $_.Exception.Message }
Has   "exakit start's self-heal ends with the WSL fix" "This WSL kernel cannot create the deployment network: run wsl --update" $threw
Lacks "  never 'repair with: exakit repair-runtime'" "repair with: exakit repair-runtime" $threw
$script:DeployLine = "Error: something else went wrong"
Set-Content -Path $script:LogFile -Value "an earlier line"
$threw = ""
try { Confirm-ExakitRuntimeRunning } catch { $threw = "" + $_.Exception.Message }
Check "any other deploy failure -> not flagged" $false $script:PersonalStartNetworkBlocked
Has   "  and still names repair-runtime"         "repair with: exakit repair-runtime" $threw
$script:StubEngine = "docker"
$script:DeployLine = $nft
Set-Content -Path $script:LogFile -Value "an earlier line"
[void](Wait-PersonalReadyOrDeploy)
Check "a Docker deployment, nft line -> not flagged" $false $script:PersonalStartNetworkBlocked
$script:StubEngine = "podman"
foreach ($name in @($saved.Keys)) { Set-Item -Path "Function:\$name" -Value $saved[$name] }
Remove-ExakitManifestValue "runtime"

Write-Host ""
Write-Host "Get-PersonalStartNetworkText: the fix, and the iptables alternative inside Podman's machine"
$netText = Get-PersonalStartNetworkText
Has   "names wsl --update (status keys on it)"   "wsl --update" $netText
Has   "  and the network sentence"               "cannot create the deployment network" $netText
Has   "  then wsl --shutdown, then exakit start" "then wsl --shutdown, then exakit start" $netText
Has   "  the iptables setting"                   'firewall_driver = "iptables" under [network]' $netText
Has   "  where it lives on Windows"              "inside Podman's machine (podman machine ssh)" $netText
Has   "  never repair-runtime"                   "do not repair-runtime" $netText
Lacks "  no 'reopen this distro' on Windows"     "reopen" $netText

Write-Host ""
Write-Host "Install-PersonalDeployment, an existing stopped deployment: the start's evidence and the consent"
$saved2 = @{}
foreach ($name in @("Test-PersonalDeploymentExists", "Get-PersonalEngineExisting", "Test-PersonalDeploymentRunning", "Get-PersonalLauncherState",
                    "Test-PersonalLauncherSupports", "Show-PersonalGuestRebuildNote", "Get-PersonalAutoApproveFlag", "Invoke-ExakitLogged",
                    "Test-PersonalWslPodmanNetworkOk", "Test-ExakitInteractive")) {
    $saved2[$name] = (Get-Item "Function:\$name").ScriptBlock
}
$script:DepCalls = New-Object System.Collections.ArrayList
$script:StartLine = ""
$script:StubInteractive = $false
function Test-PersonalDeploymentExists { return $true }
function Get-PersonalEngineExisting { return "podman" }
function Test-PersonalDeploymentRunning { return $false }
function Get-PersonalLauncherState { return "stopped" }
function Test-PersonalLauncherSupports { return $true }
function Show-PersonalGuestRebuildNote { }
function Get-PersonalAutoApproveFlag { return "" }
function Invoke-ExakitLogged {
    [void]$script:DepCalls.Add("LAUNCHER " + (@($args | Select-Object -Skip 1) -join " "))
    if ($script:StartLine) { Add-Content -Path $script:LogFile -Value $script:StartLine }
    return 1
}
function Test-PersonalWslPodmanNetworkOk { [void]$script:DepCalls.Add("WSL"); return $false }
function Test-ExakitInteractive { return $script:StubInteractive }
function Invoke-Dep {
    param([string]$Reuse = "1", [string]$Replace = "")
    $script:DepCalls.Clear(); $script:Said.Clear()
    Set-Content -Path $script:LogFile -Value "an earlier line"
    $env:EXAKIT_REUSE_DB = $Reuse
    if ($Replace) { $env:EXAKIT_REPLACE_DB = $Replace } else { Remove-Item Env:\EXAKIT_REPLACE_DB -ErrorAction SilentlyContinue }
    $script:PersonalNoDatabase = $false
    [void](Get-ExakitFailureReason)
    Install-PersonalDeployment
}
$script:StartLine = $nft
Invoke-Dep -Replace "1"
$lines = ($script:Said -join "`n")
Check "the start failed on the nft error -> no database" $true $script:PersonalNoDatabase
Has   "  says the network sentence"              "This WSL kernel cannot create the deployment network" $lines
Has   "  nothing deleted"                        "Nothing was deleted: the deployment and its data stay." $lines
Lacks "  never destroyed, even with EXAKIT_REPLACE_DB=1" "LAUNCHER destroy" ($script:DepCalls -join "|")
Lacks "  the release check is not needed"        "WSL" ($script:DepCalls -join "|")
Has   "  the reason is the network sentence"     "cannot create the deployment network: run wsl --update" (Get-ExakitFailureReason)
$script:StartLine = "Error: something else"
Invoke-Dep
$lines = ($script:Said -join "`n")
Lacks "no consent possible (unset, no console) -> no release check" "WSL" ($script:DepCalls -join "|")
Has   "  the normal advice"                      "Start it yourself with 'exakit start'" $lines
Lacks "  and no destroy"                         "LAUNCHER destroy" ($script:DepCalls -join "|")
Invoke-Dep -Replace "0"
Lacks "EXAKIT_REPLACE_DB=0 -> no release check" "WSL" ($script:DepCalls -join "|")
Invoke-Dep -Replace "1"
Has   "EXAKIT_REPLACE_DB=1 -> the release check runs" "WSL" ($script:DepCalls -join "|")
Lacks "  and refuses before the destroy"        "LAUNCHER destroy" ($script:DepCalls -join "|")
$script:StubInteractive = $true
Invoke-Dep
Has   "unset, on a console -> the check runs before the question" "WSL" ($script:DepCalls -join "|")
$script:StubInteractive = $false
$script:StartLine = ""
foreach ($name in @($saved2.Keys)) { Set-Item -Path "Function:\$name" -Value $saved2[$name] }
Remove-Item Env:\EXAKIT_REUSE_DB, Env:\EXAKIT_REPLACE_DB -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Test-PersonalRequirements: the WSL refusal is said only once the run is on Podman (WINR-01)"
$env:EXAKIT_FORCE = "1"
function Get-ExakitHostArch { return "amd64" }
function Test-PersonalDeploymentExists { return $false }
function Resolve-PersonalEngine { param([switch]$Probe) return "podman" }
function Get-CimInstance { throw "no CIM here" }
function Ok { param([string]$Message) [void]$script:Said.Add("OK $Message") }
$script:StubWsl = $stub
$realGetCommand = ${function:Get-Command}
function Get-Command {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    if ($Name -eq "podman") { return $null }
    & $realGetCommand @PSBoundParameters
}
Use-Wsl -Out $fx["en26"]
Test-PersonalRequirements
$lines = ($script:Said -join "`n")
Lacks "install gate on WSL 2.6: no refusal yet"  "cannot create the network" $lines
Lacks "  no 'Nothing was changed'"               "Nothing was changed" $lines
Check "  the verdict is kept for the deploy step" $false $script:PersonalWslVerdict
Use-Wsl -Out $fx["en26"]
$threw = ""
try { Test-PersonalRequirements -Preflight } catch { $threw = "" + $_.Exception.Message }
Has "preflight on WSL 2.6 -> a failure"          "Podman on this WSL kernel cannot create the network" $threw
Lacks "  never 'Compatibility check passed'"     "Compatibility check passed" ($script:Said -join "`n")
Use-Wsl -Out $fx["en27"]
$threw = ""
try { Test-PersonalRequirements -Preflight } catch { $threw = "" + $_.Exception.Message }
Check "preflight on WSL 2.7 -> passes"           "" $threw
Has "  and says so"                              "Compatibility check passed" ($script:Said -join "`n")
Use-Wsl -Rc 1
$threw = ""
try { Test-PersonalRequirements -Preflight } catch { $threw = "" + $_.Exception.Message }
Check "preflight, release unknown -> passes"     "" $threw
Has "  with a note"                              "The WSL release could not be read" ($script:Said -join "`n")
function Resolve-PersonalEngine { param([switch]$Probe) return "docker" }
Use-Wsl -Out $fx["en26"]
$threw = ""
try { Test-PersonalRequirements -Preflight } catch { $threw = "" + $_.Exception.Message }
Check "preflight, Docker planned, WSL 2.6 -> passes" "" $threw
Lacks "  never mentions the WSL kernel"          "WSL" ($script:Said -join "`n")

Write-Host ""
Write-Host "an unreadable release is still warned about once, at the deploy (WIN3-04)"
function Resolve-PersonalEngine { param([switch]$Probe) if (-not $Probe) { $script:PersonalEngine = "podman" }; return "podman" }
function Test-ExakitPortInUse { return $true }
function Test-PersonalDeploymentRunning { return $false }
function Set-ExakitFailureReason { param([string]$Reason) }
Use-Wsl -Rc 1
Test-PersonalRequirements
Lacks "the quiet gate says nothing"              "Could not read the WSL release" ($script:Said -join "`n")
Check "  but remembers the release was not read" $true $script:PersonalWslUnread
Install-PersonalDeployment
$unread = @($script:Said | Where-Object { "$_" -match 'Could not read the WSL release' }).Count
Check "the deploy step warns once"               1 $unread
Has   "  naming wsl --version"                   "wsl --version" ($script:Said -join "`n")
Check "  and the flag is spent"                  $false $script:PersonalWslUnread
Use-Wsl -Out $fx["en27"]
Test-PersonalRequirements
Install-PersonalDeployment
Lacks "a release read as 2.7 -> no warning"      "Could not read the WSL release" ($script:Said -join "`n")
$dep = (Get-Command Install-PersonalDeployment).Definition
Has   "a replace runs the WSL check unless the engine is docker" '$script:PersonalEngine -ne "docker" -and -not (Test-PersonalWslPodmanNetworkOk "exakit start" -Replace -StartMachine)' $dep
Has   "  the fresh path starts a stopped machine to read it" '$wslOk = Test-PersonalWslPodmanNetworkOk -StartMachine' $dep
$req = (Get-Command Test-PersonalRequirements).Definition
Lacks "the compatibility gate never starts the machine" '-StartMachine' $req
Has   "an unknown engine stops before the replace" 'Stop-PersonalEngineUnknown' $dep
Remove-Item Env:\EXAKIT_FORCE

Write-Host ""
Write-Host "exakit.ps1: the update hint after a post-swap start met the WSL kernel (AGK4-02)"
# The real function, out of the CLI's AST: exakit.ps1 runs its dispatcher when
# dot-sourced, so only its function definitions are loaded.
$cliPath = Join-Path $repo "setup/exakit.ps1"
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile($cliPath, [ref]$null, [ref]$null)
$remedyFn = $cliAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-ExakitUpdateFailureRemedy" }, $true)
. ([scriptblock]::Create($remedyFn.Extent.Text))
$startDie = Get-PersonalStartNetworkText
$fix = Get-ExakitUpdateFailureRemedy -Component "personal" -Reason $startDie
Check "the start's network Fail -> remedy wsl --update" "wsl --update" $fix.Remedy
Check "  the hint says the launcher WAS updated" "The launcher was updated, but the database could not start: this WSL kernel cannot create the deployment network. Run wsl --update, then wsl --shutdown, then exakit start." $fix.Hint
Lacks "  never 'nothing was updated'"         "nothing was updated" $fix.Hint
Lacks "  never 'reopen this distro' on Windows" "reopen" $fix.Hint
$fix = Get-ExakitUpdateFailureRemedy -Component "personal" -Reason "download failed"
Check "any other failure -> exakit update personal" "exakit update personal" $fix.Remedy
Check "  and no hint"                        "" $fix.Hint
$cliText = Get-Content -Raw $cliPath
$restartFn = $cliAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Start-ExakitRuntime" }, $true).Extent.Text
Has   "the post-swap restart ends a WSL-blocked deploy with the WSL fix" 'Stop-PersonalStartNetworkBlocked' $restartFn
Lacks "no comment still describes a WSL gate refusing the swap" "the WSL gate refusing the" $cliText

Write-Host ""
Write-Host "exakit.ps1: repair-runtime --json refused, remedy by cause under remedy_hint (AGK4-04)"
$repairFn = $cliAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-CmdRepairRuntime" }, $true).Extent.Text
Has   "the refused object carries remedy_hint" 'remedy_hint = $repairHint' $repairFn
Lacks "  and no bare hint key"                '                hint = $repairHint' $repairFn
Has   "  a release read below 2.7 -> wsl --update" '$repairRemedy = "wsl --update"' $repairFn
Has   "  an unreadable release -> wsl --version" '$repairRemedy = "wsl --version"' $repairFn
Has   "  with the EXAKIT_WSL_CHECKED path"     "If it shows 2.7 or newer, re-run with EXAKIT_WSL_CHECKED=1; otherwise run wsl --update first." $repairFn
$statusFn = $cliAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-CmdStatus" }, $true).Extent.Text
Has   "status --json answers wsl --version for the same state" '$remedies["database"] = "wsl --version"' $statusFn
Has   "  the soft record too"                  '$remedies[$property.Name] = "wsl --version"' $statusFn

Write-Host ""
Write-Host "status --json and the soft records, in a fresh process (WSL4-05, AGK3-02, the unread hint)"
# A child engine - the same one running this file (5.1 or 7) - so the stubs
# above cannot leak into the CLI's own functions.
#
# ONE STATUS READ PER CHILD. Invoke-CmdStatus -Json ends in `exit 3` (not
# running) or `exit 0` (running) - the documented exit-code contract - and an
# exit inside a function ends the whole script. A child that ran setup, then
# status, then more steps died at its first status read, so its JSON never
# arrived and every step after it never ran. The state lives on disk (the
# manifest and the failure note under one work dir per scenario), so each step
# is its own child and the status read is always the last thing a child does.
$statusScript = Join-Path $work "status-child.ps1"
Set-Content -Path $statusScript -Encoding Ascii -Value @'
param([string]$Repo, [string]$Work, [string]$Step, [string]$Db = "stopped")
$ErrorActionPreference = "Continue"
$env:HOME = "$Work/home"; $env:USERPROFILE = "$Work/home"; $env:EXAKIT_HOME = "$Work/kit"; $env:EXAKIT_BIN_DIR = "$Work/bin"; $env:EXAKIT_PERSONAL_DEPLOY_DIR = "$Work/deploy"
$env:EXAKIT_FAILURE_NOTE = "$Work/kit/.last-failure"
New-Item -ItemType Directory -Force -Path $env:HOME, $env:EXAKIT_HOME | Out-Null
# Only the first step of a scenario writes the manifest: a later step reads
# the soft records an earlier one booked there.
if (-not (Test-Path "$env:EXAKIT_HOME/manifest.json")) {
    $m = '{"kit_level":1,"steps_completed":["launcher","runtime","exapump","mcp","pyexasol","exakit_helper"],"runtime":{"type":"personal","engine":"podman"}}'
    Set-Content -Path "$env:EXAKIT_HOME/manifest.json" -Value $m -Encoding Ascii
}
. "$Repo/setup/lib/exakit-common.ps1"
. "$Repo/setup/lib/runtime-personal.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$Repo/setup/exakit.ps1", [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent.Parent -eq $ast }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:ManifestPath = "$env:EXAKIT_HOME/manifest.json"
function Get-ExakitInstallCommand { "irm https://x/install.ps1 | iex" }
function Test-PersonalDockerUsable { return $true }
$script:Db = $Db
function Get-PersonalStatus { $script:Db }
$netText = Get-PersonalStartNetworkText
switch ($Step) {
    "resumed" {
        # The installer's resume arm: the start refused for the WSL kernel,
        # booked against the completed runtime step; a later step's note
        # replaced the start's; the end of the install pruned the records.
        Register-ExakitSoftFailure -Component "runtime" -Repair "exakit start" -Reason $netText -Label "the local database"
        Set-ExakitManifestValue "install.soft_failures.exapump.reason" "an old record"
        Clear-ExakitFinishedSoftFailures
        Write-ExakitFailureNote "something later did not finish"
        Remove-Item -Force $env:EXAKIT_FAILURE_NOTE
        $kept = @((Get-ExakitManifestValue "install.soft_failures").PSObject.Properties | ForEach-Object { $_.Name }) -join ","
        Write-Output "KEPT=[$kept] LABEL=[$(Get-ExakitManifestValue 'install.soft_failures.runtime.label')]"
    }
    "retire" {
        Clear-ExakitStartSoftFailure
        Write-Output "AFTER=[$(@((Get-ExakitManifestValue 'install.soft_failures').PSObject.Properties | ForEach-Object { $_.Name }) -join ',')]"
    }
    "unread" {
        Write-ExakitFailureNote "the local database did not finish - The WSL release could not be read, so replacing the Podman deployment was refused ('wsl --version' must show 2.7 or newer). Retry with: x"
    }
    "unreadstopped" {
        Write-ExakitFailureNote "The WSL release could not be read, so replacing the Podman deployment was refused ('wsl --version' must show 2.7 or newer)"
    }
}
# Last, because it exits: the CLI prints the status object over many lines.
if ($Step -ne "retire") { Write-Output "JSON-BEGIN"; Invoke-CmdStatus -Json }
'@
$engine = (Get-Process -Id $PID).Path
if (-not $engine) { $engine = Join-Path $PSHOME "powershell.exe" }
# System.Diagnostics.Process, not `& $engine ... 2>&1`: stdout and stderr come
# back as two plain strings, the exit code with them, and 5.1 never turns the
# child's stderr into ErrorRecords (terminating ones under "Stop").
function Invoke-StatusChild([string]$Scenario, [string]$Step, [string]$Db = "stopped") {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $engine
    $childArgs = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $statusScript,
        "-Repo", $repo, "-Work", (Join-Path $work "st-$Scenario"), "-Step", $Step, "-Db", $Db)
    $psi.Arguments = (@($childArgs | ForEach-Object { '"' + $_ + '"' }) -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $stdout = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $stderr = $errTask.Result
    $lines = @(("" + $stdout) -split "`r?`n" | ForEach-Object { "" + $_ })
    return New-Object PSObject -Property @{ Lines = $lines; Out = "" + $stdout; Err = "" + $stderr; Code = $p.ExitCode }
}
# The status object: everything after the child's JSON-BEGIN marker. $null
# when there is none or it does not parse - the caller FAILs with what the
# child said, so a CI log shows the cause rather than a count of 0.
function Get-StatusDoc($Child) {
    $at = -1
    for ($i = 0; $i -lt $Child.Lines.Count; $i++) { if ("$($Child.Lines[$i])".Trim() -eq "JSON-BEGIN") { $at = $i; break } }
    if ($at -lt 0) { return $null }
    # From its opening brace to its closing one, so a stray host line around
    # the object cannot break the parse.
    $first = -1; $last = -1
    for ($i = $at + 1; $i -lt $Child.Lines.Count; $i++) {
        $t = "$($Child.Lines[$i])".TrimEnd()
        if ($first -lt 0 -and $t.TrimStart().StartsWith("{")) { $first = $i }
        if ($first -ge 0 -and $t -eq "}") { $last = $i }
    }
    if ($first -lt 0 -or $last -lt $first) { return $null }
    $body = ($Child.Lines[$first..$last] -join "`n")
    try { return ($body | ConvertFrom-Json) } catch { return $null }
}
function Show-ChildOutput([string]$What, $Child) {
    Write-Host "       ${What}: exit $($Child.Code)"
    foreach ($l in @(($Child.Out + "`n" + $Child.Err) -split "`r?`n")) { if ("$l".Trim()) { Write-Host "       | $l" } }
}
function Check-StatusDoc([string]$What, $Child) {
    $doc = Get-StatusDoc $Child
    if ($null -eq $doc) {
        Check "$What -> a status object" "a status object" "none"
        Show-ChildOutput $What $Child
    }
    return $doc
}

$child = Invoke-StatusChild "resumed" "resumed" "stopped"
Has   "the prune keeps a start the WSL kernel refused" "KEPT=[runtime]" $child.Out
Has   "  the record keeps the installer's label"   "LABEL=[the local database]" $child.Out
$doc = Check-StatusDoc "stopped, the start's note gone" $child
if ($doc) {
    Check "stopped, the start's note gone -> still wsl --update" "wsl --update" $doc.remedy
    Check "  remedies.database too"                "wsl --update" $doc.remedies.database
    Has   "  last_failure says the label, not the step id" "the local database did not finish" $doc.last_failure
    Lacks "  never 'runtime did not finish'"       "runtime did not finish" $doc.last_failure
}
$doc = Check-StatusDoc "running" (Invoke-StatusChild "resumed" "status" "running")
if ($doc) {
    Check "running -> no remedy"                   "" ("" + $doc.remedy)
    Check "  and no runtime remedy"                "" ("" + $doc.remedies.runtime)
}
$child = Invoke-StatusChild "resumed" "retire" "running"
Has   "a successful start retires the record"      "AFTER=[]" $child.Out
if (-not $child.Out.Contains("AFTER=[]")) { Show-ChildOutput "retire" $child }
$doc = Check-StatusDoc "interrupted, release unread" (Invoke-StatusChild "unread" "unread" "interrupted")
if ($doc) {
    Check "interrupted, release unread -> wsl --version" "wsl --version" $doc.remedy
    Has   "  the hint names EXAKIT_WSL_CHECKED=1"  "re-run with EXAKIT_WSL_CHECKED=1" $doc.remedy_hint
    Has   "  and that the re-run destroys the data" "The re-run is exakit repair-runtime, which DESTROYS the database and its data - ask the user, then pass --yes" $doc.remedy_hint
}
$doc = Check-StatusDoc "stopped, release unread" (Invoke-StatusChild "unreadstopped" "unreadstopped" "stopped")
if ($doc) {
    Check "stopped, release unread -> wsl --version" "wsl --version" $doc.remedy
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "personal-wsl-gate-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
