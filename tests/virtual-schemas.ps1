#!/usr/bin/env pwsh
# virtual-schemas.ps1 - the Windows bridge to the virtual schema engine, run
# against the REAL engine and the simulated Exasol of tests/virtual-schemas.sh.
# What only this side can get wrong:
#   - a credential piped to Python survives byte for byte, non-ASCII included
#     (Windows PowerShell 5.1 pipes to native programs in ASCII by default)
#   - no empty argument reaches the engine
#   - exit 20 repairs DNS and retries once; exit 21 offers Java and stops when declined
#   - `exakit connect` refuses a credential given as an argument
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/virtual-schemas.ps1
#   pwsh -NoProfile -File tests/virtual-schemas.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function J { param([string[]]$Parts) $p = $repo; foreach ($x in $Parts) { $p = Join-Path $p $x }; return $p }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-vs-ps-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { $python = Get-Command python3 }
$python = $python.Source

# Definitions copied with stand-in artifacts pinned and cached, as in the bash suite.
# The same layout as a kit copy: setup/virtual-schemas beside setup/core,
# which the engine imports.
$setupCopy = Join-Path $work "setup"; New-Item -ItemType Directory -Force -Path $setupCopy | Out-Null
$defs = Join-Path $setupCopy "virtual-schemas"; $home2 = Join-Path $work "kit"; $deploy = Join-Path $work "deploy"
Copy-Item -Recurse (J @("setup", "virtual-schemas")) $defs
Copy-Item -Recurse (J @("setup", "core")) (Join-Path $setupCopy "core")
New-Item -ItemType Directory -Force -Path (Join-Path $deploy "local/runtime/exa/bucketfs/bfsdefault/default"), (Join-Path $deploy "local/runtime/exa/jdbc") | Out-Null
$seed = @'
import hashlib, json, os, sys
defs, home = sys.argv[1:3]
for cid in ("postgresql",):
    path = os.path.join(defs, "connectors", cid, "connector.json")
    doc = json.load(open(path))
    for role in ("adapter", "driver"):
        data = (role + "-" + cid).encode()
        doc[role]["size"], doc[role]["sha256"] = len(data), hashlib.sha256(data).hexdigest()
        folder = os.path.join(home, "cache", "virtual-schemas", doc[role]["sha256"])
        os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, doc[role]["asset"]), "wb").write(data)
    json.dump(doc, open(path, "w"), indent=2)
'@
$seedFile = Join-Path $work "seed.py"; Set-Content -LiteralPath $seedFile -Value $seed -Encoding ASCII
& $python $seedFile $defs $home2

# --- the kit around the module, replaced --------------------------------------
$script:ExakitHome = $home2
$script:LogFile = Join-Path $work "log.txt"
function Write-ExakitLog { param($L, $M) Add-Content -LiteralPath $script:LogFile -Value "$L $M" }
$script:shown = New-Object System.Collections.ArrayList
function Ok([string]$M) { [void]$script:shown.Add("OK $M") }
function Info([string]$M) { [void]$script:shown.Add("INFO $M") }
function Warn2([string]$M) { [void]$script:shown.Add("WARN $M") }
function Get-ExakitRepoRoot { return $null }
function Get-PyexasolVenvPython { return $python }
function Get-ExakitManifestValue { param([string]$Path)
    switch ($Path) { "runtime.deployment_dir" { return $deploy } "runtime.dsn" { return "127.0.0.1:8563" } "runtime.user" { return "sys" } default { return "" } } }
. (J @("setup", "lib", "core-setup.ps1"))
. (J @("setup", "lib", "virtual-schemas.ps1"))
function Get-ExakitVsDefs { return $defs }

$state = Join-Path $work "db.json"
$env:EXAKIT_VS_FAKE_DB = J @("tests", "lib", "fake-exasol-vs.py")
$env:FAKE_VS_STATE = $state
Set-Content -LiteralPath $state -Value '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}' -Encoding ASCII

Write-Host ""
Write-Host "== the engine through the PowerShell bridge =="
$r = Invoke-ExakitVsEngine -Arguments @("resolve", "mssql")
Check "resolve runs and answers" "RESULT {`"connector`": `"sqlserver`"}" ($r.Lines -join "")
# a-umlaut, o-umlaut, the euro sign and two CJK characters, built from code points: test files stay ASCII so 5.1
# reads them the same under every code page.
$secret = "p" + [char]0xE4 + "ssw" + [char]0xF6 + "rd-" + [char]0x20AC + "-" + [char]0x65E5 + [char]0x672C
$r = Invoke-ExakitVsEngine -Arguments @("connect", "postgresql", "--name", "sales", "--set", "host=pg.example.com", "--set", "database=sales", "--set", "user=reader", "--secret-stdin") -Secret $secret
Check "connect through the bridge: exit 0" 0 $r.Code
$db = Get-Content -Raw -LiteralPath $state -Encoding UTF8 | ConvertFrom-Json
Check "a non-ASCII credential reaches the CONNECTION byte for byte" $secret $db.connections.EXAKIT_SRC_SALES.secret
Check "...and is in none of the output" $false (($r.Lines -join "`n").Contains($secret.Substring(0, 5)))
$result = Show-ExakitVsLines -Lines (Invoke-ExakitVsEngine -Arguments @("list")).Lines
Check "list comes back parsed" "sales" (@($result.sources)[0].name)

Write-Host ""
Write-Host "== repair and retry =="
$script:codes = New-Object System.Collections.ArrayList
$script:calls = New-Object System.Collections.ArrayList
function Invoke-ExakitVsEngine { param([string[]]$Arguments = @(), [string]$Secret = "")
    [void]$script:calls.Add($Arguments[0]); $c = $script:codes[0]; $script:codes.RemoveAt(0)
    return [pscustomobject]@{ Code = $c; Lines = @() } }
function Repair-PersonalSlcDns { [void]$script:calls.Add("REPAIR"); return $true }
function Install-ExakitVsJava { [void]$script:calls.Add("JAVA"); return $false }
$script:codes.AddRange(@(20, 0)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "exit 20: DNS repaired, retried once, exit 0" "0 connect|REPAIR|connect" ("$code " + ($script:calls -join "|"))
$script:codes.AddRange(@(21)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "exit 21: Java offered; declined, not retried" "21 connect|JAVA" ("$code " + ($script:calls -join "|"))
$script:codes.AddRange(@(1)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "any other failure: no retry" "1 connect" ("$code " + ($script:calls -join "|"))

Write-Host ""
Write-Host "== exakit connect refuses a credential argument =="
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile((J @("setup", "exakit.ps1")), [ref]$null, [ref]$null)
foreach ($def in @($cliAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Invoke-CmdConnect" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
function Deny-ExakitInput { param([string]$Message, $Remedy = $null) throw "DENY $Message" }
function Assert-ExakitInstalled { param([switch]$Json) [void]$script:calls.Add("ASSERT") }
$script:calls.Clear()
$denied = ""
try { Invoke-CmdConnect -Arguments @("pg", "--name", "sales", "--password=hunter2") } catch { $denied = "$_" }
Check "a password argument is refused" $true ($denied -like "DENY A credential is never taken as an argument*")
Check "...before anything ran" "" ($script:calls -join "|")

Write-Host ""
Write-Host "== exakit source: the name before the credential, (none) for no checks =="
# Invoke-CmdSource ends with `exit`, so it runs in a child PowerShell with
# the engine and the secret prompt replaced by recorders.
# The engine's canned answer travels in a file: Windows PowerShell 5.1 does not
# escape the double quotes of a JSON argument to a native program, so the
# child would get it split into several (measured on CI: exit 2, "takes one name").
$child = @'
param($cli, $record, $code, $resultFile)
$result = Get-Content -Raw -LiteralPath $resultFile
$ast = [System.Management.Automation.Language.Parser]::ParseFile($cli, [ref]$null, [ref]$null)
foreach ($def in @($ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Invoke-CmdSource" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
function Assert-ExakitInstalled { param([switch]$Json) }
function Initialize-ExakitLogging { }
function Deny-ExakitInput { param([string]$Message, $Remedy = $null) Write-Output "DENY $Message"; exit 2 }
function Read-ExakitVsSecret { param($Label, $PasswordFile) Add-Content -LiteralPath $record -Value "SECRET-READ"; return "pw" }
function Invoke-ExakitVsEngine { param([string[]]$Arguments = @(), [string]$Secret = "")
    Add-Content -LiteralPath $record -Value ($Arguments -join " ")
    return [pscustomobject]@{ Code = [int]$code; Lines = @($result) } }
function Invoke-ExakitVsRun { param([string[]]$Arguments, [string]$Secret = "")
    $r = Invoke-ExakitVsEngine -Arguments $Arguments; $script:ExakitVsResult = ($r.Lines[0].Substring(7) | ConvertFrom-Json); return $r.Code }
function Show-ExakitVsLines { param([string[]]$Lines = @()) $r = $null; foreach ($l in $Lines) { if ($l -like "RESULT *") { $r = $l.Substring(7) | ConvertFrom-Json } else { Write-Output $l } }; return $r }
function Confirm-ExakitVs { param([string]$Question) return [bool]$script:ExakitVsAssumeYes }
function Ok([string]$M) { Write-Host "OK $M" }
function Info([string]$M) { Write-Host "INFO $M" }
$lib = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $cli) "lib/virtual-schemas.ps1"), [ref]$null, [ref]$null)
foreach ($def in @($lib.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Show-ExakitVsDropPlan" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
Invoke-CmdSource -Arguments $args
'@
$childFile = Join-Path $work "source-child.ps1"; Set-Content -LiteralPath $childFile -Value $child -Encoding ASCII
function Canned([string]$Text) {
    $f = Join-Path $work ("canned-" + [guid]::NewGuid().ToString("N") + ".txt")
    Set-Content -LiteralPath $f -Value $Text -Encoding ASCII -NoNewline
    return $f
}
$pwsh = (Get-Process -Id $PID).Path
$record = Join-Path $work "source-calls.txt"
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $childFile (J @("setup", "exakit.ps1")) $record 4 (Canned "FAIL no source named nosuch (see: exakit source list)") reauth nosuch 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Check "reauth of a missing source: exit 4" 4 $childCode
Check "...asked the engine for the name and never for the credential" "show nosuch" ((Get-Content -LiteralPath $record) -join "|")
Remove-Item -LiteralPath $record
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $childFile (J @("setup", "exakit.ps1")) $record 0 (Canned 'RESULT {"checks": []}') check --all 2>&1
$ErrorActionPreference = "Stop"
Check "check --all with no sources says (none)" $true ((@($out) -join "`n").Contains("(none)"))
$drop = 'RESULT {"name": "sales", "drop": ["CONNECTION EXAKIT_SRC_SALES"], "keep": [], "delete_files": ["a.jar"], "keep_files": ["b.jar"], "note": "n"}'
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $childFile (J @("setup", "exakit.ps1")) $record 0 (Canned $drop) disconnect sales 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Check "disconnect without --yes and no console: exit 5, not 0" 5 $childCode
Check "...after showing what it would drop" $true ((@($out) -join "`n").Contains("drops: CONNECTION EXAKIT_SRC_SALES"))
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $childFile (J @("setup", "exakit.ps1")) $record 0 (Canned $drop) remove sales --yes 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Check "remove --yes: exit 0, and says it is done" "0 True" ("$childCode " + (@($out) -join "`n").Contains("sales removed"))

Write-Host ""
Write-Host "== exakit connect --url: the string on the engine's stdin, --set still wins =="
# Invoke-CmdConnect ends with `exit`: a child PowerShell runs it with the real
# bridge and engine on the simulated database, every engine call recorded.
$urlChild = @'
param($repo, $defs, $kitHome, $deploy, $python, $record)
$ErrorActionPreference = "Stop"
$script:ExakitHome = $kitHome
function Write-ExakitLog { param($L, $M) }
function Ok([string]$M) { Write-Host "OK $M" }
function Info([string]$M) { Write-Host "INFO $M" }
function Warn2([string]$M) { Write-Host "WARN $M" }
function Get-ExakitRepoRoot { return $null }
function Get-PyexasolVenvPython { return $python }
function Get-ExakitManifestValue { param([string]$Path)
    switch ($Path) { "runtime.deployment_dir" { return $deploy } "runtime.dsn" { return "127.0.0.1:8563" } "runtime.user" { return "sys" } default { return "" } } }
. (Join-Path $repo "setup/lib/core-setup.ps1")
. (Join-Path $repo "setup/lib/virtual-schemas.ps1")
function Get-ExakitVsDefs { return $defs }
$cli = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
foreach ($def in @($cli.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Invoke-CmdConnect" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
function Assert-ExakitInstalled { param([switch]$Json) }
function Initialize-ExakitLogging { }
function Test-ExakitInteractive { return $false }
function Deny-ExakitInput { param([string]$Message, $Remedy = $null) Write-Output "DENY $Message"; exit 2 }
$realEngine = ${function:Invoke-ExakitVsEngine}
function Invoke-ExakitVsEngine { param([string[]]$Arguments = @(), [string]$Secret = "")
    Add-Content -LiteralPath $record -Value ($Arguments -join " ")
    return (& $realEngine -Arguments $Arguments -Secret $Secret) }
Invoke-CmdConnect -Arguments $args
'@
$urlChildFile = Join-Path $work "url-child.ps1"; Set-Content -LiteralPath $urlChildFile -Value $urlChild -Encoding ASCII
$urlRecord = Join-Path $work "url-calls.txt"
$urlPw = "Pw-" + [char]0x20AC + "-url9"
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name urlps --url ("postgres://reader:" + $urlPw + "@pg.example.com:5433/sales?sslmode=require") --set port=5432 --dry-run 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$calls = @(Get-Content -LiteralPath $urlRecord -ErrorAction SilentlyContinue)
Check "connect --url --dry-run: exit 0" 0 $childCode
Check "...paste ran first, the string not among its arguments" "paste pg --base64" $calls[0]
Check "...the string's inputs come before the command line's --set, which wins" "plan postgresql --name urlps --set host=pg.example.com --set port=5433 --set database=sales --set user=reader --set tls=require --set port=5432" $calls[2]
Check "...the password is in no argument" $false ((($calls -join "`n")).Contains("url9"))
Check "...nor in the output" $false (((@($out) -join "`n")).Contains("url9"))
Check "...whose note says it was not used" $true (((@($out) -join "`n")).Contains("The string was on the command line"))

Remove-Item Env:\EXAKIT_VS_FAKE_DB, Env:\FAKE_VS_STATE
if (-not $env:KEEP_WORK) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue } else { Write-Host "work: $work" }
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
