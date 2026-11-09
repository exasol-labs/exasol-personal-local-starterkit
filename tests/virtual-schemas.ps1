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
# Offline: no public IP lookup, except where it is tested (a file:// URL).
$env:EXAKIT_NO_IP_LOOKUP = "1"
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
$r = Invoke-ExakitVsEngine -Arguments @("paste", "pg", "--base64") -Secret "jdbc:postgresql://h/db?user=r&password=Abc&Xyz9"
Check "paste through the bridge: a password's unencoded & leaks no name" $false (($r.Lines -join "`n").Contains("Xyz9"))

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
foreach ($def in @($lib.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -in @("Show-ExakitVsDropPlan", "Exit-ExakitVs", "Get-ExakitVsLogMark", "Get-ExakitVsLogPath", "Get-ExakitVsLogFolder") }, $true))) {
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

Write-Host ""
Write-Host "== the connect form: required or optional, a pasted string, one answer changed =="
# Invoke-ExakitVsTuiForm in a child PowerShell, with the real bridge and engine on
# the simulated database. The console's answers come from a file and every
# question is recorded: its text, and whether it was asked hidden.
$formChild = @'
param($repo, $defs, $kitHome, $deploy, $python, $answers, $record, $planFail)
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
. (Join-Path $repo "setup/lib/ui.ps1")
. (Join-Path $repo "setup/lib/core-setup.ps1")
. (Join-Path $repo "setup/lib/virtual-schemas.ps1")
function Get-ExakitVsDefs { return $defs }
$script:UiFancy = $false
Set-ExakitPalette
$script:EvtCols = 100
if ($env:FORM_COLS) { $script:EvtCols = [int]$env:FORM_COLS }
$script:EvtIn = [Math]::Min($script:EvtCols - 2, 96) - 4; $script:EvtOnScreen = 0
$script:queue = New-Object System.Collections.ArrayList
foreach ($line in @(Get-Content -LiteralPath $answers)) { [void]$script:queue.Add("" + $line) }
function Read-ExakitVsTuiAnswer { param([string]$Plain, [string]$Colour, [switch]$Hidden)
    $tag = "ASK"
    if ($Hidden) { $tag = "HIDDEN" }
    Add-Content -LiteralPath $record -Value "$tag $Plain"
    if ($script:queue.Count -eq 0) { return $null }
    $a = $script:queue[0]; $script:queue.RemoveAt(0)
    return $a }
function Confirm-ExakitVsTui { param([string]$Question) Add-Content -LiteralPath $record -Value "CONFIRM $Question"; return $false }
if ($planFail) {
    # The first plan refuses an input the form's own checks let through.
    $realEngine = ${function:Invoke-ExakitVsEngine}
    $script:refused = $false
    function Invoke-ExakitVsEngine { param([string[]]$Arguments = @(), [string]$Secret = "")
        if ($Arguments[0] -eq "plan" -and -not $script:refused) {
            $script:refused = $true
            return [pscustomobject]@{ Code = 2; Lines = @("FAIL " + $planFail) }
        }
        return (& $realEngine -Arguments $Arguments -Secret $Secret) }
}
$pw = ""
if ($env:FORM_PWFILE) { $pw = $env:FORM_PWFILE }
$src = Invoke-ExakitVsTuiForm -Connector "postgresql" -Pos 1 -Total 1 -PasswordFile $pw
if ($src -is [string]) { Write-Host "FORM $src" }
else {
    Write-Host ("FORM " + ($src.Base -join " ")); Write-Host ("SECRET " + ($src.Secret -eq $env:FORM_SECRET))
    Write-Host ("SECRETFILE " + ($src.SecretFile -eq $pw))
}
'@
$formChildFile = Join-Path $work "form-child.ps1"; Set-Content -LiteralPath $formChildFile -Value $formChild -Encoding ASCII
$formAnswers = Join-Path $work "form-answers.txt"
$formRecord = Join-Path $work "form-record.txt"
$env:FORM_SECRET = "Form-s3cret-" + [char]0x20AC
$pastePw = "Paste-pw-zz8"
function Invoke-FormChild([string[]]$Answers, [string]$PlanFail = "") {
    Set-Content -LiteralPath $formAnswers -Value $Answers -Encoding UTF8
    Remove-Item -LiteralPath $formRecord -ErrorAction SilentlyContinue
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $o = & $pwsh -NoProfile -File $formChildFile $repo $defs $home2 $deploy $python $formAnswers $formRecord $PlanFail 2>&1
    $ErrorActionPreference = $previous
    $script:formOut = (@($o) | ForEach-Object { "$_" }) -join "`n"
    $script:formAsked = @(Get-Content -LiteralPath $formRecord -ErrorAction SilentlyContinue)
}
function Row([string]$Label, [string]$Value) { return ($Label.PadRight(24) + "  " + $Value) }
# Enter on the required name is refused; on the optional schema it takes the
# default, on the optional CA it leaves it empty; 3 asks the port again.
Invoke-FormChild @(("postgres://reader:" + $pastePw + "@pg.example.com:5433/sales"), "", "psform", "", "", $env:FORM_SECRET, "", "", "3", "5432", "")
Check "the first question is the connection string, read hidden" "HIDDEN Connection string (hidden; Enter to type the fields)" $script:formAsked[0]
Check "...its help names the forms the connector reads" $true $script:formOut.Contains("jdbc:postgresql://host:5432/db,")
Check "the panel marks a required field" $true $script:formOut.Contains((Row "Host name or address" "(required)"))
Check "...and an optional one, with its default" $true $script:formOut.Contains((Row "Port" "(optional) [5432]"))
Check "the question says (required)" $true ($script:formAsked -contains "ASK Name for this connection (required)")
Check "...an empty required answer is refused, in one line" $true $script:formOut.Contains("Name for this connection is required")
Check "...an optional one says so, with the default Enter takes" $true ($script:formAsked -contains "ASK Schema (optional) [public]")
Check "the fields the string filled are marked" $true $script:formOut.Contains((Row "Host name or address" "pg.example.com (from the string)"))
Check "...and not asked" 0 @($script:formAsked | Where-Object { $_ -like "*Host name or address*" }).Count
Check "a password in the string: the note says it was not used" $true $script:formOut.Contains("it was not used.")
Check "...without the command-line sentence" $false $script:formOut.Contains("The string was on the command line")
Check "...the hidden prompt still asks for it" $true ($script:formAsked -contains "HIDDEN Password (required) (hidden)")
Check "...whose empty answer is refused too" $true $script:formOut.Contains("Password is required; it stays in memory")
Check "the summary numbers every answer" $true $script:formOut.Contains("  3  " + (Row "Port" "5433 (from the string)"))
Check "...a number asks that field again" $true ($script:formAsked -contains "ASK Port (optional) (- clears it) [5433]")
Check "...one change, the rest as given" "FORM postgresql --name psform --set host=pg.example.com --set port=5432 --set database=sales --set schema=public --set user=reader --set tls=verify" (@($script:formOut -split "`n" | Where-Object { $_ -like "FORM *" })[0])
Check "...the typed credential kept for the connect, not the string's" "SECRET True" (@($script:formOut -split "`n" | Where-Object { $_ -like "SECRET *" })[0])
Check "...and the string's password is in none of the output" $false $script:formOut.Contains($pastePw)

# A string that does not parse is said and asked again; Enter types the fields.
# A plan that refuses an input goes straight back to that field.
Invoke-FormChild @("not a url", "jdbc:mysql://my.example.com/shop", "", "psjump", "old.example.com", "", "sales", "", "reader", $env:FORM_SECRET, "", "", "", "pg.example.com", "") "host=old.example.com is not a host this test lets through"
Check "a string with a space is refused in the engine's words" $true $script:formOut.Contains("the connection string has a space, line break or control character in it")
Check "...so is another connector's" $true $script:formOut.Contains("the kit does not read this as a PostgreSQL connection string")
Check "the plan's refusal is said above the field it names" $true $script:formOut.Contains("host=old.example.com is not a host this test lets through")
Check "...which is asked again, its answer the default" $true ($script:formAsked -contains "ASK Host name or address (required) [old.example.com]")
Check "...instead of asking to change every answer" 0 @($script:formAsked | Where-Object { $_ -like "CONFIRM*" }).Count
Check "...and the corrected host is the one planned" $true $script:formOut.Contains("FORM postgresql --name psjump --set host=pg.example.com ")
Check "...the summary after it offers to leave the source out" $true ($script:formAsked -contains "ASK Number to change, Enter to continue, skip to leave this source out")

# A refusal naming two inputs opens the summary with its reason; "-" takes an
# optional answer back to its default; skip leaves the source out.
Invoke-FormChild @("", "psca", "pg.example.com", "", "sales", "ops", "reader", $env:FORM_SECRET, "", "", "", "5", "-", "skip") "ca is used to verify the server, so it needs tls=verify (not require)"
Check "a refusal naming two inputs: the summary, with the reason" $true $script:formOut.Contains("ca is used to verify the server, so it needs tls=verify (not require)")
Check "...no question to change every answer" 0 @($script:formAsked | Where-Object { $_ -like "CONFIRM*" }).Count
Check "...an optional answer says how to take it back" $true ($script:formAsked -contains "ASK Schema (optional) (- clears it) [ops]")
Check "...and - did: the default stands again" $true $script:formOut.Contains("  5  " + (Row "Schema" "public"))
Check "...skip left the source out" "FORM left-out" (@($script:formOut -split "`n" | Where-Object { $_ -like "FORM *" })[0])

# The credential from --password-file, picked in the summary, is kept on Enter.
$pwFileForm = Join-Path $work "form.pw"
Set-Content -LiteralPath $pwFileForm -Value $env:FORM_SECRET -Encoding UTF8 -NoNewline
$env:FORM_PWFILE = $pwFileForm
Invoke-FormChild @("", "pspw", "pg.example.com", "", "sales", "", "reader", "", "", "7", "", "")
Remove-Item Env:\FORM_PWFILE
Check "a password file, picked in the summary: Enter keeps it" $true ($script:formAsked -contains "HIDDEN Password (required) (hidden, Enter keeps the one given)")
Check "...the file still the credential" "SECRETFILE True" (@($script:formOut -split "`n" | Where-Object { $_ -like "SECRETFILE *" })[0])

# 56 columns: a row too narrow for its value and "(from the string)" drops the
# mark; no row is wider than the panel.
$env:FORM_COLS = "56"
Invoke-FormChild @(("postgres://reader:" + $pastePw + "@pg.example.com:5433/sales"), "psnarrow", "", $env:FORM_SECRET, "", "", "")
Remove-Item Env:\FORM_COLS
$wide = @($script:formOut -split "`n" | Where-Object { $_ -like "  |*" -and $_.TrimEnd("`r").Length -gt 54 })
Check "56 columns: no panel row wider than the panel" 0 $wide.Count
Check "...the value kept" $true $script:formOut.Contains((Row "Host name or address" "pg.example.com"))
Check "...its mark dropped" $false $script:formOut.Contains("(from the string)")

# A line exactly as wide as the console is one row: the console holds the wrap
# until the next character (PowerShell reads no line through readline).
$script:EvtCols = 56
Check "a line exactly as wide as the console is one row" 1 (Get-ExakitVsTuiRows 56)
Check "...one character wider is two" 2 (Get-ExakitVsTuiRows 57)

# Which field a plan's refusal names: input names first, as whole words in any
# case; labels only when no name is named; several named is -2, none -1.
$named = @{ Fields = @(
    @{ Name = "name"; LabelFull = "Name for this connection"; Kind = "source-name" },
    @{ Name = "host"; LabelFull = "Host name or address"; Kind = "host" },
    @{ Name = "port"; LabelFull = "Port"; Kind = "port" },
    @{ Name = "ca"; LabelFull = "CA certificate file"; Kind = "ca-file" },
    @{ Name = "tls"; LabelFull = "TLS"; Kind = "choice" },
    @{ Name = "uri"; LabelFull = "MongoDB URI"; Kind = "mongodb-uri" },
    @{ Name = "user"; LabelFull = "Reader account"; Kind = "text" }) }
Check "a refusal naming host goes to host" 1 (Find-ExakitVsTuiNamed -Form $named -Text "host is required (Host name or address)")
Check "...one naming ca and tls opens the summary" -2 (Find-ExakitVsTuiNamed -Form $named -Text "ca is used to verify the server, so it needs tls=verify (not require)")
Check "...Port is not in report or export" -1 (Find-ExakitVsTuiNamed -Form $named -Text "the report could not be exported")
Check "...a label counts when no name does, as a whole word in any case" 6 (Find-ExakitVsTuiNamed -Form $named -Text "the reader account may not read this")
Check "...the source name is named as such, not by the bare word name" 0 (Find-ExakitVsTuiNamed -Form $named -Text "the source name must be lower case")
Check "...so a value that is not a valid name names only its input" 2 (Find-ExakitVsTuiNamed -Form $named -Text "port='x y' is not a valid name")
Check "...the MongoDB URI with user: names uri and user, not user alone" -2 (Find-ExakitVsTuiNamed -Form $named -Text "the MongoDB URI carries credentials (user:password@): give the user with --set user=...")

Write-Host ""
Write-Host "== exakit connect line by line: marks, a pasted string, the credential still hidden =="
# Invoke-CmdConnect on a console without the drawn form: Read-ExakitPrompt's
# answers from a file, every question recorded; the hidden prompt recorded too.
$lineChild = @'
param($repo, $defs, $kitHome, $deploy, $python, $answers, $record)
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
function Test-ExakitInteractive { return $true }
function Test-ExakitVsTuiOk { return $false }
function Deny-ExakitInput { param([string]$Message, $Remedy = $null) Write-Output "DENY $Message"; exit 2 }
$script:queue = New-Object System.Collections.ArrayList
foreach ($line in @(Get-Content -LiteralPath $answers)) { [void]$script:queue.Add("" + $line) }
function Read-ExakitPrompt { param([string]$Question, [string]$Default = "")
    Add-Content -LiteralPath $record -Value ("ASK " + $Question + " [" + $Default + "]")
    if ($script:queue.Count -eq 0) { return $Default }
    $a = $script:queue[0]; $script:queue.RemoveAt(0)
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a }
function Read-ExakitVsSecret { param([string]$Label, [string]$PasswordFile = "", [string]$Kind = "secret")
    Add-Content -LiteralPath $record -Value "HIDDEN $Label"
    return $env:FORM_SECRET }
function Read-ExakitVsHidden { param([string]$Label)
    Add-Content -LiteralPath $record -Value "HIDDEN $Label"
    if ($script:queue.Count -eq 0) { return "" }
    $a = $script:queue[0]; $script:queue.RemoveAt(0)
    return $a }
Invoke-CmdConnect -Arguments $args
'@
$lineChildFile = Join-Path $work "line-child.ps1"; Set-Content -LiteralPath $lineChildFile -Value $lineChild -Encoding ASCII
function Invoke-LineChild([string[]]$Answers, [string[]]$CliArgs) {
    Set-Content -LiteralPath $formAnswers -Value $Answers -Encoding UTF8
    Remove-Item -LiteralPath $formRecord -ErrorAction SilentlyContinue
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $o = & $pwsh -NoProfile -File $lineChildFile $repo $defs $home2 $deploy $python $formAnswers $formRecord @CliArgs 2>&1
    $script:lineCode = $LASTEXITCODE
    $ErrorActionPreference = $previous
    $script:formOut = (@($o) | ForEach-Object { "$_" }) -join "`n"
    $script:formAsked = @(Get-Content -LiteralPath $formRecord -ErrorAction SilentlyContinue)
}
Invoke-LineChild @("garbage string", ("jdbc:postgresql://pg.example.com:5432/sales?user=reader&password=" + $pastePw), "", "psline", "", "", "", "y") @("pg")
Check "line by line: exit 0" 0 $script:lineCode
Check "...the connection string is asked first, hidden" "HIDDEN Connection string (Enter to type the fields)" $script:formAsked[0]
Check "...a garbage string is said and asked again" $true $script:formOut.Contains("the connection string has a space, line break or control character in it")
Check "...the password in it noted, not used" $true $script:formOut.Contains("it was not used.")
Check "...what it filled is said" $true $script:formOut.Contains("From the connection string: database, host, port, user")
Check "...without the command-line sentence" $false $script:formOut.Contains("The string was on the command line")
Check "...the fields it filled are not asked" 0 @($script:formAsked | Where-Object { $_ -like "*Host name or address*" }).Count
Check "...each question says (required)" $true ($script:formAsked -contains "ASK Name for this connection (lower case, e.g. sales) (required) []")
Check "...or (optional), with its default" $true ($script:formAsked -contains "ASK Schema (optional) [public]")
Check "...an empty required answer is refused" $true $script:formOut.Contains("Name for this connection is required")
Check "...the credential still asked hidden" $true ($script:formAsked -contains "HIDDEN Password")
$db = Get-Content -Raw -LiteralPath $state -Encoding UTF8 | ConvertFrom-Json
Check "...the typed one reaches the CONNECTION" $env:FORM_SECRET $db.connections.EXAKIT_SRC_PSLINE.secret
Check "...and the string's password is in none of the output" $false $script:formOut.Contains($pastePw)
# --dry-run at the same console asks as it always did.
Invoke-LineChild @("", "sales", "", "reader", "", "") @("pg", "--name", "psdry", "--set", "host=pg.example.com", "--dry-run")
Check "--dry-run on a console: exit 0" 0 $script:lineCode
Check "...the questions as before" $true ($script:formAsked -contains "ASK Database []")
Check "...no marks" 0 @($script:formAsked | Where-Object { $_ -like "*(required)*" -or $_ -like "*(optional)*" }).Count
Check "...no connection string" 0 @($script:formAsked | Where-Object { $_ -like "*Connection string*" }).Count
Remove-Item Env:\FORM_SECRET

Write-Host ""
Write-Host "== this computer's public IP: the plan's INFO line and --json, through Invoke-CmdConnect =="
$ipFile = Join-Path $work "public-ip.txt"
Set-Content -LiteralPath $ipFile -Value "203.0.113.7" -Encoding ASCII
Remove-Item Env:\EXAKIT_NO_IP_LOOKUP
# file:///C:/... on Windows, file:///var/... elsewhere ([System.Uri] reads a
# Unix path as relative and gives no AbsoluteUri).
$env:EXAKIT_PUBLIC_IP_URL = "file:///" + (($ipFile -replace '\\', '/') -replace ' ', '%20').TrimStart('/')
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name ipps --set host=pg.example.com --set database=sales --set user=reader --dry-run 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "connect --dry-run, a host on the internet: exit 0" 0 $childCode
Check "...the plan's INFO line names the address and the host" $true $text.Contains("INFO This computer's public IP is 203.0.113.7: pg.example.com must allow it if it filters by address")
Check "...said once" 1 ([regex]::Matches($text, "public IP is").Count)
# --json: stdout is the plan object alone (the INFO line goes to the log).
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name ipps --set host=pg.example.com --set database=sales --set user=reader --dry-run --json 2>$null
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "connect --dry-run --json, a host on the internet: exit 0" 0 $childCode
Check "...and the JSON carries public_ip" $true ($text -match '"public_ip":\s+"203\.0\.113\.7"')
Check "...and stdout is that object alone" "203.0.113.7" (($text | ConvertFrom-Json).public_ip)
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name ipps --set host=192.168.64.1 --set database=sales --set user=reader --dry-run --json 2>&1
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "a private host: no public IP line" $false $text.Contains("public IP is")
Check "...and public_ip is null" $true ($text -match '"public_ip":\s+null')
Remove-Item Env:\EXAKIT_PUBLIC_IP_URL

Write-Host ""
Write-Host "== exakit connect --json: one object on stdout, whatever happens =="
# Every path a script or an agent takes: a real connect, a dry run, and each
# refusal - by the bridge or by the engine - answers with one JSON object and
# nothing else on stdout (Ok/Info here write to the host, which is stdout too).
$env:EXAKIT_NO_IP_LOOKUP = "1"
Set-Content -LiteralPath $state -Value '{"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"]}}}' -Encoding ASCII
$jsonPw = Join-Path $work "json.pw"
Set-Content -LiteralPath $jsonPw -Value "Json-Pw-1" -Encoding ASCII -NoNewline
$pgSet = @("--set", "host=pg.example.com", "--set", "database=sales", "--set", "user=reader")
function Invoke-JsonConnect {
    param([string[]]$A)
    $ErrorActionPreference = "Continue"
    $o = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord @A 2>$null
    $script:jsonCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    $script:jsonText = (@($o) | ForEach-Object { "$_" }) -join "`n"
    $script:jsonDoc = $null
    try { $script:jsonDoc = $script:jsonText | ConvertFrom-Json } catch { }
    return ($null -ne $script:jsonDoc -and $script:jsonDoc -isnot [array])
}
$one = Invoke-JsonConnect (@("pg", "--name", "jsonps") + $pgSet + @("--password-file", $jsonPw, "--json"))
Check "a real connect: stdout is one JSON object, exit 0" "True 0" "$one $jsonCode"
Check "...the connect result: ok, the schema, public_ip present" "True VS_JSONPS True" ("{0} {1} {2}" -f $jsonDoc.ok, $jsonDoc.objects.schema, ($null -ne $jsonDoc.PSObject.Properties["public_ip"]))
Check "...no query hint or Manage line on stdout" $false ($jsonText.Contains("Manage it with") -or $jsonText.Contains("OK "))
$one = Invoke-JsonConnect (@("pg", "--name", "jsondry") + $pgSet + @("--dry-run", "--json"))
Check "a dry run: one object, the plan, exit 0" "True 0 jsondry" "$one $jsonCode $($jsonDoc.name)"
Check "...no rendered plan before it" $false ($jsonText.Contains("Plan for"))
$cases = @(
    @("an unknown connector", 2, "input", @("nosuchdb", "--name", "x", "--json")),
    @("no credential", 2, "input", (@("pg", "--name", "jsonnopw") + $pgSet + @("--json"))),
    @("a bad input", 2, "input", @("pg", "--name", "jsonbad", "--set", "host=pg.example.com", "--set", "database=sales", "--set", "user=reader", "--set", "port=70000", "--json")),
    @("a name already taken", 3, "conflict", (@("pg", "--name", "jsonps") + $pgSet + @("--password-file", $jsonPw, "--json"))),
    @("an unknown option", 2, "input", @("pg", "--name", "x", "--bogus", "--json")),
    @("no name", 2, "input", @("pg", "--json")),
    @("a credential as an argument", 2, "input", @("pg", "--name", "x", "--password=hunter2", "--json")))
foreach ($c in $cases) {
    $one = Invoke-JsonConnect $c[3]
    Check ("{0}: one object, exit {1}" -f $c[0], $c[1]) "True $($c[1])" "$one $jsonCode"
    Check "...ok false, kind $($c[2]), an error and a remedy, command and public_ip present" "False $($c[2]) True True True True" ("{0} {1} {2} {3} {4} {5}" -f $jsonDoc.ok, $jsonDoc.kind, [bool]$jsonDoc.error, [bool]$jsonDoc.remedy, ($null -ne $jsonDoc.PSObject.Properties["command"]), ($null -ne $jsonDoc.PSObject.Properties["public_ip"]))
}
[void](Invoke-JsonConnect @("nosuchdb", "--name", "x", "--json"))
Check "the unknown connector's command lists the connectors" "exakit source catalog" $jsonDoc.command
[void](Invoke-JsonConnect (@("pg", "--name", "jsonps") + $pgSet + @("--password-file", $jsonPw, "--json")))
Check "the taken name's fix names the source" $true ("$($jsonDoc.remedy)".Contains("exakit source remove jsonps"))
Check "...and its error is what happened, without the fix" "a source named jsonps already exists (postgresql)" $jsonDoc.error
[void](Invoke-JsonConnect @("pg", "--name", "x", "--password=hunter2", "--json"))
Check "a credential given as an argument is not echoed" $false ($jsonText.Contains("hunter2"))
# Java missing and no --yes: no question, the engine's nojava answer, exit 21.
$db = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
$db | Add-Member -NotePropertyName java -NotePropertyValue $false -Force
Set-Content -LiteralPath $state -Value ($db | ConvertTo-Json -Depth 8) -Encoding ASCII
$one = Invoke-JsonConnect (@("pg", "--name", "jsonjava") + $pgSet + @("--password-file", $jsonPw, "--json"))
Check "a Java container that is missing, without --yes: one object, exit 21" "True 21 nojava" "$one $jsonCode $($jsonDoc.kind)"
Check "...whose fix names --yes" $true ("$($jsonDoc.remedy)".Contains("--yes"))
# A --password-file that cannot be read: one object, never a PowerShell error.
$one = Invoke-JsonConnect (@("pg", "--name", "jsondir") + $pgSet + @("--password-file", $work, "--json"))
Check "a --password-file that is a folder: one object, exit 2, kind input" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    $locked = Join-Path $work "locked.pw"
    Set-Content -LiteralPath $locked -Value "x" -Encoding ASCII -NoNewline
    & chmod 000 $locked
    $one = Invoke-JsonConnect (@("pg", "--name", "jsonlocked") + $pgSet + @("--password-file", $locked, "--json"))
    Check "a --password-file that exists but cannot be read: one object, exit 2" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
    & chmod 600 $locked
} else { $script:PASS++; Write-Host "  ok   an unreadable --password-file: skipped (no chmod here)" }
# The gate before the name, with --json as without: exit 5 both ways.
$catalogFile = Join-Path $defs "catalog.json"
$cat = Get-Content -Raw -LiteralPath $catalogFile | ConvertFrom-Json
$cat.connectors += [pscustomobject]@{ id = "gatedtest"; name = "Gated Test"; aliases = @("gt"); profile = "java-jdbc"; tier = "GA"; status = "gated"; gate = "not qualified yet" }
Set-Content -LiteralPath $catalogFile -Value ($cat | ConvertTo-Json -Depth 8) -Encoding ASCII
New-Item -ItemType Directory -Force -Path (Join-Path $defs "connectors/gatedtest") | Out-Null
Copy-Item (Join-Path $defs "connectors/postgresql/connector.json") (Join-Path $defs "connectors/gatedtest/connector.json")
$one = Invoke-JsonConnect @("gatedtest", "--json")
Check "a gated connector and no name, --json: one object, exit 5" "True 5 gated" "$one $jsonCode $($jsonDoc.kind)"
[void](Invoke-JsonConnect @("gatedtest"))
Check "...and without --json: exit 5 too" 5 $jsonCode
$one = Invoke-JsonConnect (@("pg", "--name", "Bad-Name") + $pgSet + @("--json"))
Check "an invalid name, --json: one object, exit 2" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
Set-Content -LiteralPath $state -Value '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}' -Encoding ASCII

Write-Host ""
Write-Host "== exakit source --json (PowerShell): one object of the same shape =="
$srcChildFile = Join-Path $work "src-child.ps1"
Set-Content -LiteralPath $srcChildFile -Value ($urlChild -replace "Invoke-CmdConnect", "Invoke-CmdSource") -Encoding ASCII
function Invoke-JsonSource {
    param([string[]]$A)
    $ErrorActionPreference = "Continue"
    $o = & $pwsh -NoProfile -File $srcChildFile $repo $defs $home2 $deploy $python $srcRecord @A 2>$null
    $script:jsonCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    $script:jsonText = (@($o) | ForEach-Object { "$_" }) -join "`n"
    $script:jsonDoc = $null
    try { $script:jsonDoc = $script:jsonText | ConvertFrom-Json } catch { }
    return ($null -ne $script:jsonDoc -and $script:jsonDoc -isnot [array])
}
$srcRecord = Join-Path $work "src-calls.txt"
[void](Invoke-JsonConnect (@("pg", "--name", "jsonre") + $pgSet + @("--password-file", $jsonPw, "--json")))
Check "a source to reauth: connected" "0 True" "$jsonCode $($jsonDoc.ok)"
$db = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
$db.sources.'pg.example.com' | Add-Member -NotePropertyName secret -NotePropertyValue "Json-Pw-2" -Force
Set-Content -LiteralPath $state -Value ($db | ConvertTo-Json -Depth 8) -Encoding ASCII
$jsonPw2 = Join-Path $work "json2.pw"
Set-Content -LiteralPath $jsonPw2 -Value "Json-Pw-2" -Encoding ASCII -NoNewline
Remove-Item -LiteralPath $srcRecord -ErrorAction SilentlyContinue
$one = Invoke-JsonSource @("reauth", "jsonre", "--json", "--password-file", $jsonPw2)
Check "reauth --json: one object, exit 0, the source ready" "True 0 True ready" "$one $jsonCode $($jsonDoc.ok) $($jsonDoc.status)"
Check "...no rendered line on stdout" $false ($jsonText.Contains("ready again"))
Check "...the engine asked with --json once" "--json show jsonre|--json reauth jsonre --secret-stdin" ((Get-Content -LiteralPath $srcRecord) -join "|")
$one = Invoke-JsonSource @("--json")
Check "source --json (no action): the listing's one object, exit 0" "True 0 True" "$one $jsonCode $($jsonDoc.ok)"
$one = Invoke-JsonSource @("remove", "jsonre", "--json")
Check "source remove --json without --yes: exit 5, kind declined, the --yes form named" "True 5 declined exakit source remove jsonre --yes --json" "$one $jsonCode $($jsonDoc.kind) $($jsonDoc.command)"
$one = Invoke-JsonSource @("show", "jsonre", "--json")
Check "...and the source is still there" "True 0 True" "$one $jsonCode $($jsonDoc.ok)"
$one = Invoke-JsonSource @("reauth", "jsonre", "--json", "--password-file", $jsonPw)
Check "reauth --json with a credential the source refuses: one failure object" "True False auth True" "$one $($jsonDoc.ok) $($jsonDoc.kind) $([bool]$jsonDoc.remedy)"
$one = Invoke-JsonSource @("reauth", "jsonre", "--json", "--password-file", $work)
Check "reauth --json, a --password-file that cannot be read: one object, exit 2" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
$one = Invoke-JsonSource @("reauth", "jsonre", "--json")
Check "reauth --json, no credential: one object, exit 2" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
foreach ($a in @(@("bogus", "--json"), @("show", "--json"), @("check", "--json"), @("list", "--bogus", "--json"), @("show", "a", "b", "--json"))) {
    $one = Invoke-JsonSource $a
    Check ("source {0}: one object, exit 2, kind input, remedy and command keys" -f ($a -join " ")) "True 2 input True True" "$one $jsonCode $($jsonDoc.kind) $([bool]$jsonDoc.remedy) $($null -ne $jsonDoc.PSObject.Properties['command'])"
}
[void](Invoke-JsonSource @("show", "--json"))
Check "...a missing name's command lists the sources" "exakit source list" $jsonDoc.command

Write-Host ""
Write-Host "== --json repairs say what they do on stderr, the answer is the retry's =="
$script:jcodes = New-Object System.Collections.ArrayList
$script:jcalls = New-Object System.Collections.ArrayList
function Invoke-ExakitVsEngine { param([string[]]$Arguments = @(), [string]$Secret = "")
    [void]$script:jcalls.Add($Arguments[0]); $c = $script:jcodes[0]; $script:jcodes.RemoveAt(0)
    return [pscustomobject]@{ Code = $c; Lines = @("{`"try`": $($script:jcalls.Count)}") } }
function Install-ExakitVsJava { [void]$script:jcalls.Add("JAVA"); Write-Host "installing Java"; return $true }
$script:ExakitVsJson = $true
$script:jcodes.AddRange(@(21, 0))
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "exit 21 with consent: Java installed, retried, the engine called with --json first" "0 --json|JAVA|--json" ("$code " + ($script:jcalls -join "|"))
Check "...only the retry's answer is kept for stdout" "{`"try`": 3}" ($script:ExakitVsLastLines -join "")
function Install-ExakitVsJava { [void]$script:jcalls.Add("JAVA"); throw "the download did not match its checksum (test)" }
$script:jcalls.Clear(); $script:jcodes.AddRange(@(21))
$code = Invoke-ExakitVsRun -Arguments @("--json", "connect")
Check "an install that throws: no retry, exit 21, the first run's object kept" "21 --json|JAVA {`"try`": 1}" ("$code " + ($script:jcalls -join "|") + " " + ($script:ExakitVsLastLines -join ""))
$script:ExakitVsJson = $false

Write-Host ""
Write-Host "== the day log: a failed connect or source command names it once, no secret in it =="
# engine/vslog.py writes <kit home>/logs/virtual-schemas-YYYYMMDD.log; the
# bridge names it at the end of a command that failed and wrote to it (twin
# of _exakit_vs_exit), on stderr under --json. Real engine, simulated database.
$today = (Get-Date).ToString("yyyyMMdd", [Globalization.CultureInfo]::InvariantCulture)
$vsLogPath = Join-Path (Join-Path $home2 "logs") ("virtual-schemas-" + $today + ".log")
$logLine = "Log (every SQL statement, secrets redacted): " + $vsLogPath
Set-Content -LiteralPath $state -Value '{"sources": {"pg.example.com": {"tables": ["ORDERS"], "secret": "Ps-Right-Pw-8"}}}' -Encoding ASCII
$wrongPw = Join-Path $work "wrong.pw"; Set-Content -LiteralPath $wrongPw -Value "Ps-Wrong-Pw-7" -Encoding ASCII -NoNewline
$rightPw = Join-Path $work "right.pw"; Set-Content -LiteralPath $rightPw -Value "Ps-Right-Pw-8" -Encoding ASCII -NoNewline
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name pslog @pgSet --password-file $wrongPw 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "connect, a --password-file the source refuses: exit 1" 1 $childCode
Check "...names the day log once" 1 ([regex]::Matches($text, [regex]::Escape($logLine)).Count)
$logText = ""
if (Test-Path -LiteralPath $vsLogPath) { $logText = Get-Content -Raw -LiteralPath $vsLogPath }
Check "...the run is in it, its credential as ***" $true ($logText -match "\] connect pslog SQL +CREATE CONNECTION .* IDENTIFIED BY '\*\*\*'")
Check "...the password from the file is not" $false ($logText.Contains("Ps-Wrong-Pw-7"))
if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    $mode = @(& $python -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])" $vsLogPath)[0]
    Check "...owner-only (mode 600)" "600" "$mode"
} else { $script:PASS++; Write-Host "  ok   mode 600: skipped (on Windows the bridge sets the file's ACL)" }
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name pslogok @pgSet --password-file $rightPw 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "a connect that succeeds: exit 0, no log line" "0 False" ("$childCode " + $text.Contains("Log (every SQL"))
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord nosuchdb --name x 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "a refusal the engine never logged (an unknown connector): no log line" "2 False" ("$childCode " + $text.Contains("Log (every SQL"))
# --json: stdout stays the one object; the path goes to stderr.
$jsonErr = Join-Path $work "json-err.txt"
$ErrorActionPreference = "Continue"
$o = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name psjson @pgSet --password-file $wrongPw --json 2>$jsonErr
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$jsonText = (@($o) | ForEach-Object { "$_" }) -join "`n"
$doc = $null; try { $doc = $jsonText | ConvertFrom-Json } catch { }
$errText = (@(Get-Content -LiteralPath $jsonErr -ErrorAction SilentlyContinue) | ForEach-Object { "$_" }) -join "`n"
Check "connect --json that fails: exit 1, one object, kind auth" "1 auth" ("$childCode " + $(if ($doc) { $doc.kind } else { "NOT-ONE-OBJECT" }))
Check "...the path once on stderr" 1 ([regex]::Matches($errText, [regex]::Escape($logLine)).Count)
Check "...and not on stdout" $false ($jsonText.Contains("Log (every SQL"))
# A source command that fails names it too.
$db = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
$db.sources.'pg.example.com' | Add-Member -NotePropertyName fail -NotePropertyValue "unreachable" -Force
Set-Content -LiteralPath $state -Value ($db | ConvertTo-Json -Depth 8) -Encoding ASCII
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $srcChildFile $repo $defs $home2 $deploy $python $srcRecord check pslogok 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "source check of a source that fails: exit 1, the log's path once" "1 1" ("$childCode " + [regex]::Matches($text, [regex]::Escape($logLine)).Count)
Check "no credential of these runs is in the log" $false ((Get-Content -Raw -LiteralPath $vsLogPath) -match "Ps-Wrong-Pw-7|Ps-Right-Pw-8")
# exakit logs: the day log is one of its targets (twin of exakit_log_targets).
foreach ($def in @($cliAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Get-ExakitLogTargets" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
function Get-ExakitMarketplaceInstalledAddons { return @() }
$script:LogDir = Join-Path $home2 "logs"
$target = @(Get-ExakitLogTargets) | Where-Object { $_.Id -eq "virtual-schemas" } | Select-Object -First 1
Check "exakit logs lists it: target virtual-schemas, the newest day file" $vsLogPath ("" + $target.Source)
$script:LogDir = $null

Write-Host ""
Write-Host "== the day log: the security review's Windows finding =="
# Review 7: the ACL was set only after the engine exited, so its lines were
# first written under the inherited one (and stayed so after a Ctrl+C). The
# bridge now makes today's file and protects it BEFORE Python starts. Here
# Protect-ExakitFile records what it saw: the file there, still empty.
. (J @("setup", "lib", "virtual-schemas.ps1"))
function Get-ExakitVsDefs { return $defs }
$script:protects = New-Object System.Collections.ArrayList
function Protect-ExakitFile { param([string]$Path)
    $len = -1
    if (Test-Path -LiteralPath $Path) { $len = (Get-Item -LiteralPath $Path).Length }
    [void]$script:protects.Add(("{0}|{1}" -f (Split-Path -Leaf $Path), $len)) }
Remove-Item -LiteralPath $vsLogPath -ErrorAction SilentlyContinue
$r = Invoke-ExakitVsEngine -Arguments @("list")
Check "review 7: today's file exists and is protected before the engine writes to it" ("virtual-schemas-" + $today + ".log|0") ("" + $script:protects[0])
$after = "" + $script:protects[$script:protects.Count - 1]
Check "review 7: ...and protected again after it wrote" $true (($script:protects.Count -ge 2) -and ($after -like ("virtual-schemas-" + $today + ".log|*")) -and -not ($after -like "*|0"))
Check "review 7: ...the run itself unchanged" "0" ("" + $r.Code)
# Second review 2: under th-TH or ar-SA, Get-Date -Format "yyyyMMdd" gives
# another calendar's year (25691109, 14480529): the file made ready and
# protected was not the one the engine writes. The name is the engine's own.
$logsDir = Join-Path $home2 "logs"
$previousCulture = [System.Globalization.CultureInfo]::CurrentCulture
foreach ($culture in @("th-TH", "ar-SA")) {
    Remove-Item -LiteralPath $vsLogPath -ErrorAction SilentlyContinue
    $before = @(Get-ChildItem -LiteralPath $logsDir -Filter "virtual-schemas-*.log" | ForEach-Object { $_.Name })
    [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
    try { Protect-ExakitVsLog -Today } finally { [System.Globalization.CultureInfo]::CurrentCulture = $previousCulture }
    $made = @(Get-ChildItem -LiteralPath $logsDir -Filter "virtual-schemas-*.log" | ForEach-Object { $_.Name } | Where-Object { $before -notcontains $_ })
    Check "second review 2: under $culture the file made ready is the engine's day file" ("virtual-schemas-" + $today + ".log") ($made -join " ")
}
# A file made ready but never written (a lookup the engine does not log)
# names nothing when the command fails.
$exitChild = Join-Path $work "exit-child.ps1"
Set-Content -LiteralPath $exitChild -Encoding ASCII -Value @'
param($lib, $kitHome)
$script:ExakitHome = $kitHome
function Info([string]$M) { Write-Host "INFO $M" }
. $lib
$script:ExakitVsLogMark = Get-ExakitVsLogMark
$day = Join-Path (Join-Path $kitHome "logs") ("virtual-schemas-" + (Get-Date).ToString("yyyyMMdd", [Globalization.CultureInfo]::InvariantCulture) + ".log")
New-Item -ItemType File -Force -Path $day | Out-Null
Exit-ExakitVs 1
'@
$home3 = Join-Path $work "kit3"
New-Item -ItemType Directory -Force -Path (Join-Path $home3 "logs") | Out-Null
$older = Join-Path (Join-Path $home3 "logs") "virtual-schemas-20200101.log"
Set-Content -LiteralPath $older -Value "an older day" -Encoding ASCII
(Get-Item -LiteralPath $older).LastWriteTime = [datetime]"2020-01-01"
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $exitChild (J @("setup", "lib", "virtual-schemas.ps1")) $home3 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Check "review 7: ...a day file made ready but never written: a failure names no log" "1 False" ("$childCode " + ((@($out) | ForEach-Object { "$_" }) -join "`n").Contains("Log ("))

Remove-Item Env:\EXAKIT_VS_FAKE_DB, Env:\FAKE_VS_STATE
if (-not $env:KEEP_WORK) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue } else { Write-Host "work: $work" }
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
