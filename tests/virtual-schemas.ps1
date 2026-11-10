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
$connectLines = @($r.Lines)
$result = Show-ExakitVsLines -Lines (Invoke-ExakitVsEngine -Arguments @("list")).Lines
Check "list comes back parsed" "sales" (@($result.sources)[0].name)
Check "...each row adds where it lives and its TLS level (host, tls)" "pg.example.com verify" ("" + @($result.sources)[0].host + " " + @($result.sources)[0].tls)
Check "...and keeps every key it had" "connector host last_check name needs_refresh schema status tls" ((@(@($result.sources)[0].PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join " ")
$r = Invoke-ExakitVsEngine -Arguments @("paste", "pg", "--base64") -Secret "jdbc:postgresql://h/db?user=r&password=Abc&Xyz9"
Check "paste through the bridge: a password's unencoded & leaks no name" $false (($r.Lines -join "`n").Contains("Xyz9"))
# Where this computer is follows the deployment's engine: the engine reads the
# kit's record (runtime.engine) under --kit-home, which this bridge passes.
$engineRecord = Join-Path $home2 "manifest.json"
$localhostPlan = @("plan", "postgresql", "--name", "lo", "--set", "host=localhost", "--set", "database=x", "--set", "user=u")
# Linux, WSL or Windows: on macOS the advice is the launcher VM's whatever the
# record says, so EXAKIT_VS_OS stands in for the platform.
$env:EXAKIT_VS_OS = "Windows"
Set-Content -LiteralPath $engineRecord -Value '{"runtime": {"type": "personal", "engine": "docker"}}' -Encoding ASCII
$r = Invoke-ExakitVsEngine -Arguments $localhostPlan
Check "a Docker deployment: localhost is refused, exit 2" 2 $r.Code
Check "...with Docker's address for this computer" $true (($r.Lines -join "`n").Contains("on Docker host.docker.internal where the deployment provides it, else the bridge gateway"))
Check "...not Podman's" $false (($r.Lines -join "`n").Contains("host.containers.internal"))
Set-Content -LiteralPath $engineRecord -Value '{"runtime": {"type": "personal", "engine": "podman"}}' -Encoding ASCII
$r = Invoke-ExakitVsEngine -Arguments $localhostPlan
Check "a Podman deployment: Podman's name" $true (($r.Lines -join "`n").Contains("on Linux and WSL host.containers.internal"))
Set-Content -LiteralPath $engineRecord -Value '{"runtime": {"type": "personal", "engine": "docker"}}' -Encoding ASCII
$env:EXAKIT_VS_OS = "Darwin"
$r = Invoke-ExakitVsEngine -Arguments $localhostPlan
Check "macOS: the launcher VM's address whatever the record says" $true (($r.Lines -join "`n").Contains("on macOS 192.168.64.1"))
# Nothing recorded yet (an install that has not written it): this run's
# choice, as Get-PersonalSlcDnsEngine falls back to it - $script:PersonalEngine,
# which the bridge hands the engine; a stray environment value is not it.
$env:EXAKIT_VS_OS = "Windows"
Set-Content -LiteralPath $engineRecord -Value '{"runtime": {"type": "personal"}}' -Encoding ASCII
$script:PersonalEngine = "docker"
$r = Invoke-ExakitVsEngine -Arguments $localhostPlan
Check "no engine recorded, this run chose Docker: Docker's address" $true (($r.Lines -join "`n").Contains("on Docker host.docker.internal"))
$script:PersonalEngine = ""
$env:EXAKIT_PERSONAL_ENGINE = "docker"
$r = Invoke-ExakitVsEngine -Arguments $localhostPlan
Check "...no choice made (a stray EXAKIT_PERSONAL_ENGINE ignored, as the bridge ignores it): Podman's" $true (($r.Lines -join "`n").Contains("on Linux and WSL host.containers.internal"))
Check "...and the caller's environment is put back" "docker" $env:EXAKIT_PERSONAL_ENGINE
Remove-Item Env:\EXAKIT_PERSONAL_ENGINE
Remove-Item Env:\EXAKIT_VS_OS
Remove-Item -LiteralPath $engineRecord -Force

Write-Host ""
Write-Host "== the query hint after connect: a quoted name, escaped for exakit.cmd =="
# On Windows `exakit` is exakit.cmd, and PowerShell strips the inner double
# quotes of an argument it hands to a batch file: a quoted name needs \".
$script:shown.Clear()
Show-ExakitVsQueryHints -Result ([pscustomobject]@{ example = 'SELECT * FROM VS_X."actor" LIMIT 10'; tips = @("a tip") }) -Name "x"
Check "an example that quotes a name is shown as it is" 'OK Query it like any schema: SELECT * FROM VS_X."actor" LIMIT 10' $script:shown[0]
Check "...then the form that works from PowerShell, each inner double quote escaped" 'INFO From PowerShell: exakit sql ''SELECT * FROM VS_X.\"actor\" LIMIT 10''' $script:shown[1]
Check "...with why, in one line" $true (("" + $script:shown[2]).StartsWith("INFO ") -and ("" + $script:shown[2]).Contains("drops unescaped ones when it hands the query to exakit.cmd"))
Check "...before the connector's tips" "INFO a tip" $script:shown[3]
$connectResult = Show-ExakitVsLines -Lines $connectLines
$script:shown.Clear()
Show-ExakitVsQueryHints -Result $connectResult -Name "sales"
Check "the real connect's example quotes no name: no PowerShell line, the tips follow it" $true ((@($script:shown) -join "|").StartsWith("OK Query it like any schema: SELECT * FROM VS_SALES.ORDERS LIMIT 10|INFO Names arrive in upper case"))
Check "...and nothing says From PowerShell" $false ((@($script:shown) -join "|").Contains("From PowerShell"))

Write-Host ""
Write-Host "== MongoDB: an authSource other than admin is refused =="
$mgString = "mongodb+srv://reader@cluster0.abc12.mongodb.net/movies"
$r = Invoke-ExakitVsEngine -Arguments @("paste", "mongodb", "--base64") -Secret ($mgString + "?authSource=sales")
Check "paste with authSource=sales: exit 2, the adapter signs in against admin" "2 True" ("" + $r.Code + " " + (($r.Lines -join "`n").Contains("the MongoDB adapter always signs in against the admin database")))
$r = Invoke-ExakitVsEngine -Arguments @("paste", "mongodb", "--base64") -Secret ($mgString + "?authSource=admin")
Check "...authSource=admin is read" 0 $r.Code
$r = Invoke-ExakitVsEngine -Arguments @("paste", "mongodb", "--base64") -Secret $mgString
Check "...and so is no authSource" 0 $r.Code
$mgPlan = @("plan", "mongodb", "--name", "mgps", "--set", "database=sample_mflix", "--set", "collection=movies", "--set", "user=reader", "--set")
$r = Invoke-ExakitVsEngine -Arguments ($mgPlan + @("uri=mongodb+srv://cluster0.example.net/?authSource=sales"))
Check "plan --set uri with authSource=sales: exit 2, the fix named" "2 True" ("" + $r.Code + " " + (($r.Lines -join "`n").Contains("make the reader a user of admin and drop authSource or set it to admin")))
$r = Invoke-ExakitVsEngine -Arguments ($mgPlan + @("uri=mongodb+srv://cluster0.example.net/?authSource=admin"))
Check "...authSource=admin is accepted" 0 $r.Code
$r = Invoke-ExakitVsEngine -Arguments ($mgPlan + @("uri=mongodb+srv://cluster0.example.net/"))
Check "...and so is no authSource" 0 $r.Code

Write-Host ""
Write-Host "== a --password-file read as bytes: UTF-8 with or without a BOM, UTF-16 by its BOM =="
# Get-Content without an encoding read a BOM-less UTF-8 file in the ANSI code
# page on 5.1: a non-ASCII password became another one. a-umlaut, o-umlaut and
# the euro sign, from code points.
$pwEnc = "p" + [char]0xE4 + "ssw" + [char]0xF6 + "rd" + [char]0x20AC
$utf8 = New-Object System.Text.UTF8Encoding($false)
$encFiles = [ordered]@{
    "utf8" = $utf8.GetBytes($pwEnc + "`n")
    "bom" = [byte[]](@(0xEF, 0xBB, 0xBF) + $utf8.GetBytes($pwEnc + "`r`n"))
    "utf16" = [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes($pwEnc + "`r`n")) }
foreach ($enc in $encFiles.Keys) {
    [System.IO.File]::WriteAllBytes((Join-Path $work "enc-$enc.pw"), $encFiles[$enc])
    Check "--password-file in $($enc): read as itself, one line ending dropped" $pwEnc (Read-ExakitVsSecret -Label "Password" -PasswordFile (Join-Path $work "enc-$enc.pw"))
}
[System.IO.File]::WriteAllBytes((Join-Path $work "enc-latin1.pw"), [byte[]](@(0x70, 0xE4, 0x73, 0x73)))
Check "a Latin-1 file is neither: no text, so it is refused, not guessed" $true ($null -eq (Get-ExakitVsSecretFileText -Path (Join-Path $work "enc-latin1.pw")))
Check "exactly one trailing line ending is dropped" ("pw" + "`n") (ConvertFrom-ExakitVsSecretBytes -Bytes $utf8.GetBytes("pw`n`n"))
Check "UTF-16 big endian by its BOM" $pwEnc (ConvertFrom-ExakitVsSecretBytes -Bytes ([byte[]](@(0xFE, 0xFF) + [System.Text.Encoding]::BigEndianUnicode.GetBytes($pwEnc))))
# Security review 1, 8 and 11: the decoder's edges.
Check "review 1: a NUL anywhere is refused (a shell variable would drop it)" $true ($null -eq (ConvertFrom-ExakitVsSecretBytes -Bytes $utf8.GetBytes("p" + [char]0 + "w")))
Check "review 1: UTF-16 without its BOM (NUL bytes) is refused" $true ($null -eq (ConvertFrom-ExakitVsSecretBytes -Bytes ([System.Text.Encoding]::Unicode.GetBytes("pass`n"))))
Check "review 1: UTF-16 with a stray byte (an odd count) is refused" $true ($null -eq (ConvertFrom-ExakitVsSecretBytes -Bytes ([byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes("pass") + @(0x0A)))))
Check "review 8: a newline then a soft hyphen: nothing is cut (an ordinal comparison, not a culture one)" ("pw`n" + [char]0xAD) (ConvertFrom-ExakitVsSecretBytes -Bytes $utf8.GetBytes("pw`n" + [char]0xAD))
$Error.Clear()
[void](ConvertFrom-ExakitVsSecretBytes -Bytes ([byte[]]@(0x70, 0xE4, 0x73, 0x73)))
Check "review 11: a refused decode leaves no record in `$Error (one would hold a byte of the credential)" 0 $Error.Count
# Review 6: Git Bash's mintty hands a Windows program its terminal as a pipe.
Check "review 6: an MSYS2 / Cygwin terminal pipe is recognised, another pipe is not" "True True False False" ("{0} {1} {2} {3}" -f (Test-ExakitVsMsysPtyName "\msys-1888ae32e00d56aa-pty0-from-master"), (Test-ExakitVsMsysPtyName "\cygwin-e022582115c10879-pty4-to-master"), (Test-ExakitVsMsysPtyName "\exakit-other-pipe"), (Test-ExakitVsMsysPtyName ""))
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { Check "review 6: ...off Windows there is no pipe name to ask for" "" (Get-ExakitVsStdinPipeName) }
else { Check "review 6: ...on Windows the handle's name is asked for (a string)" $true ((Get-ExakitVsStdinPipeName) -is [string]) }

Write-Host ""
Write-Host "== the engine runs isolated: python -I =="
# A module planted on PYTHONPATH named like one the engine imports (argparse,
# its first) runs inside the process that holds the credential - unless the
# interpreter is isolated. The control first: without -I it runs.
$plant = Join-Path $work "planted"; New-Item -ItemType Directory -Force -Path $plant | Out-Null
Set-Content -LiteralPath (Join-Path $plant "argparse.py") -Encoding ASCII -Value "import os`nopen(os.environ['EXAKIT_PLANT_MARK'], 'w').write('planted')`nraise SystemExit(97)"
$mark = Join-Path $work "plant.mark"
$previousPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = $plant; $env:EXAKIT_PLANT_MARK = $mark
try {
    $ErrorActionPreference = "Continue"
    & $python (Join-Path (Join-Path $defs "engine") "cli.py") --defs $defs --kit-home $home2 resolve pg 2>$null | Out-Null
    $controlCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    Check "control: without -I a planted argparse on PYTHONPATH runs in the engine" "97 True" ("$controlCode " + (Test-Path -LiteralPath $mark))
    Remove-Item -LiteralPath $mark -ErrorAction SilentlyContinue
    $r = Invoke-ExakitVsEngine -Arguments @("resolve", "pg")
    Check "Invoke-ExakitVsEngine: the planted module is ignored, the engine imports its own and answers" "0 RESULT {`"connector`": `"postgresql`"} False" ("{0} {1} {2}" -f $r.Code, ($r.Lines -join ""), (Test-Path -LiteralPath $mark))
} finally {
    $ErrorActionPreference = "Stop"
    if ($previousPythonPath) { $env:PYTHONPATH = $previousPythonPath } else { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue }
    Remove-Item Env:\EXAKIT_PLANT_MARK -ErrorAction SilentlyContinue
}
$bridgeText = Get-Content -Raw -LiteralPath (J @("setup", "lib", "virtual-schemas.ps1"))
Check "every engine run goes through Invoke-ExakitVsEngine: cli.py is named once, after -I" "1 1" ("{0} {1}" -f ([regex]::Matches($bridgeText, '"engine" "cli.py"')).Count, ([regex]::Matches($bridgeText, [regex]::Escape('@("-I", (Join-ExakitCorePath $defs "engine" "cli.py")'))).Count)
# Review 3: -I does not cover PYTHONEXECUTABLE. A macOS framework build takes
# its program path from it, so sys.prefix - and the site-packages whose .pth
# files run at startup - become a planted venv's. The control first; a Python
# that ignores the variable (Windows, Linux, a non-framework build) cannot show it.
$pyv = "" + @(& $python -c "import sys; print('python%d.%d' % sys.version_info[:2])")[0]
$pyHome = "" + @(& $python -c "import os, sys; print(os.path.dirname(os.path.realpath(sys.executable)))")[0]
$pex = Join-Path $work "pyexe"
$pexSite = Join-Path (Join-Path (Join-Path $pex "lib") $pyv) "site-packages"
New-Item -ItemType Directory -Force -Path (Join-Path $pex "bin"), $pexSite | Out-Null
Set-Content -LiteralPath (Join-Path $pex "pyvenv.cfg") -Value "home = $pyHome" -Encoding ASCII
Set-Content -LiteralPath (Join-Path $pexSite "plant.pth") -Value "import os; open(os.environ['EXAKIT_PLANT_MARK'], 'w').write('pth')" -Encoding ASCII
$pexBin = Join-Path (Join-Path $pex "bin") "python"
$env:PYTHONEXECUTABLE = $pexBin; $env:EXAKIT_PLANT_MARK = $mark
try {
    Remove-Item -LiteralPath $mark -ErrorAction SilentlyContinue
    $ErrorActionPreference = "Continue"
    & $python -I -c "pass" 2>$null
    $ErrorActionPreference = "Stop"
    if (Test-Path -LiteralPath $mark) {
        $script:PASS++; Write-Host "  ok   review 3 control: this python runs a planted .pth under -I through PYTHONEXECUTABLE"
        Remove-Item -LiteralPath $mark
        $r = Invoke-ExakitVsEngine -Arguments @("resolve", "pg")
        Check "review 3: Invoke-ExakitVsEngine runs without it: no .pth ran, it answered, the caller keeps the variable" ("0 False " + $pexBin) ("{0} {1} {2}" -f $r.Code, (Test-Path -LiteralPath $mark), $env:PYTHONEXECUTABLE)
    } else { $script:PASS++; Write-Host "  ok   review 3: this python ignores PYTHONEXECUTABLE under -I: nothing to show here" }
} finally {
    $ErrorActionPreference = "Stop"
    Remove-Item Env:\PYTHONEXECUTABLE, Env:\EXAKIT_PLANT_MARK -ErrorAction SilentlyContinue
}

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
# Docker: linked in the image, so the database needs a start to see it.
function Repair-PersonalSlcDns { [void]$script:calls.Add("REPAIR"); $script:PersonalSlcDnsNeedsStart = $true; return $false }
function Restart-ExakitVsDatabase { [void]$script:calls.Add("RESTART"); return $true }
$script:ExakitVsAssumeYes = $true
$script:codes.AddRange(@(20, 0)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "exit 20 on Docker, --yes: one restart, then the retry" "0 connect|REPAIR|RESTART|connect" ("$code " + ($script:calls -join "|"))
$script:ExakitVsAssumeYes = $false
$previousJson = $script:ExakitVsJson; $script:ExakitVsJson = $true
$script:codes.AddRange(@(20)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect") 6> $null
Check "...without --yes (--json never asks): no restart, no retry" "20 --json|REPAIR" ("$code " + ($script:calls -join "|"))
$script:ExakitVsJson = $previousJson
function Repair-PersonalSlcDns { [void]$script:calls.Add("REPAIR"); $script:PersonalSlcDnsNeedsStart = $false; return $true }
$script:codes.AddRange(@(21)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "exit 21: Java offered; declined, not retried" "21 connect|JAVA" ("$code " + ($script:calls -join "|"))
$script:codes.AddRange(@(1)); $script:calls.Clear()
$code = Invoke-ExakitVsRun -Arguments @("connect")
Check "any other failure: no retry" "1 connect" ("$code " + ($script:calls -join "|"))
# A repair that fails: the bridge names the stop and start, whose start links
# the image on Docker and repairs the container elsewhere.
function Repair-PersonalSlcDns { [void]$script:calls.Add("REPAIR"); $script:PersonalSlcDnsNeedsStart = $false; return $false }
function Get-PersonalSlcDnsEngine { return $script:stubEngine }
foreach ($stubEngine in @("docker", "podman")) {
    $script:stubEngine = $stubEngine
    $said = (@(Repair-ExakitVsForRetry -Code 20 6>&1) | ForEach-Object { "$_" }) -join "|"
    Check "a failed repair ($stubEngine): the stop and start that fix it" $true ($said.Contains("Restart the database (exakit stop, exakit start) and try again."))
}
function Repair-PersonalSlcDns { [void]$script:calls.Add("REPAIR"); return $true }

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
Write-Host "== exakit source list: one table, host and TLS, inside the console =="
# The same rows and widths as the bash suite: the two renderers are twins.
$longHost = "mydb.cluster-abc123def456.eu-west-1.rds.amazonaws.com"
$listRows = 'RESULT {"sources": [{"name": "sales", "connector": "postgresql", "schema": "VS_SALES", "status": "ready", "last_check": {"at": "2026-11-09T10:22:33Z"}, "needs_refresh": false, "host": "pg.example.com", "tls": "verify"}, {"name": "orders", "connector": "mysql", "schema": "VS_ORDERS", "status": "auth-failed", "last_check": null, "needs_refresh": false, "host": "' + $longHost + '", "tls": "require"}, {"name": "old", "connector": "gone", "schema": "VS_OLD", "status": "ready", "last_check": null, "needs_refresh": false, "host": "", "tls": null}]}'
function Invoke-ListChild([string]$Cols, [string]$Rows, [string]$Action = "list") {
    $env:COLUMNS = $Cols
    $ErrorActionPreference = "Continue"
    $o = & $pwsh -NoProfile -File $childFile (J @("setup", "exakit.ps1")) $record 0 (Canned $Rows) $Action 2>&1
    $ErrorActionPreference = "Stop"
    Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue
    return @($o | ForEach-Object { "$_" })
}
function Get-Row([string[]]$Lines, [string]$Start) { return (@($Lines | Where-Object { $_.StartsWith($Start) }) -join "") }
$out = Invoke-ListChild "200" $listRows
Check "list on a wide console: every column, under a heading" $true ((Get-Row $out "  NAME ").StartsWith("  NAME    SOURCE      SCHEMA     HOST"))
Check "...a row names its host" $true ((Get-Row $out "  sales ").StartsWith("  sales   postgresql  VS_SALES   pg.example.com"))
Check "...then TLS, status and when it was last checked" $true ((Get-Row $out "  sales ").EndsWith("verify   ready        2026-11-09 10:22"))
Check "...a host in full when there is room" $true ((Get-Row $out "  orders ").Contains($longHost + "  require  auth-failed  never"))
Check "...a source whose connector is gone: no host, TLS n/a" $true ((Get-Row $out "  old ").StartsWith("  old     gone        VS_OLD     -") -and (Get-Row $out "  old ").Contains(" n/a "))
$out = Invoke-ListChild "80" $listRows
Check "on 80 columns: every line fits (79, the last column unwritten)" 0 @($out | Where-Object { $_.Length -gt 79 }).Count
Check "...SCHEMA goes first, then LAST CHECK; HOST and TLS stay" "  NAME    SOURCE      HOST                                 TLS      STATUS" (Get-Row $out "  NAME ")
Check "...then a long host is cut, marked ..." $true ((Get-Row $out "  orders ").Contains("mydb.cluster-abc123def456.eu-wes...  require  auth-failed"))
Check "...a short one kept whole" $true ((Get-Row $out "  sales ").StartsWith("  sales   postgresql  pg.example.com"))
$out = Invoke-ListChild "60" $listRows
Check "on 60 columns: the host is cut further, every line still fits" "0 True" ("" + @($out | Where-Object { $_.Length -gt 59 }).Count + " " + (Get-Row $out "  orders ").Contains("mydb.cluster...  require"))
$out = Invoke-ListChild "80" 'RESULT {"issues": [{"name": "orders", "connector": "mysql", "schema": "VS_ORDERS", "status": "auth-failed", "last_check": {"at": "2026-11-09T10:22:33Z"}, "needs_refresh": false, "host": "my.example.com", "tls": "require", "remedy": "the source rejected the credentials: exakit source reauth orders", "command": "exakit source reauth orders"}]}' "issues"
Check "issues: the same table, the fix on its own line under the row" $true ($out -contains "    fix: the source rejected the credentials: exakit source reauth orders")
$out = Invoke-ListChild "80" 'RESULT {"sources": []}'
Check "no sources: (none), no heading" "  (none)|" ((@($out | Where-Object { $_.Trim() }) -join "|") + "|")

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
    @("a name another connector holds", 3, "conflict", (@("mysql", "--name", "jsonps") + $pgSet + @("--password-file", $jsonPw, "--json"))),
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
[void](Invoke-JsonConnect (@("mysql", "--name", "jsonps") + $pgSet + @("--password-file", $jsonPw, "--json")))
Check "the taken name's fix names the source" $true ("$($jsonDoc.remedy)".Contains("exakit source remove jsonps"))
Check "...and its error is what happened, without the fix" "a source named jsonps already exists (postgresql), so it cannot be connected as mysql" $jsonDoc.error
[void](Invoke-JsonConnect @("pg", "--name", "x", "--password=hunter2", "--json"))
Check "a credential given as an argument is not echoed" $false ($jsonText.Contains("hunter2"))

Write-Host ""
Write-Host "== exakit connect re-points a connected source in place (the twin of the bash cases) =="
# The source moved: the same connect with the new address and the credential
# again updates it. The credential is always given again (the database never
# returns a stored one, and moving a CONNECTION clears it); VS_<NAME> keeps its
# name; the new address and credential are tried before anything changes;
# --json without --yes changes nothing (exit 5, declined); the same inputs and
# no credential are 'unchanged', exit 0.
$db = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
$db.sources | Add-Member -NotePropertyName "pgnew.example.com" -NotePropertyValue ([pscustomobject]@{ tables = @("ORDERS", "ITEMS"); secret = "Json-Pw-2" }) -Force
$db.sources | Add-Member -NotePropertyName "pgauth.example.com" -NotePropertyValue ([pscustomobject]@{ tables = @("ORDERS"); secret = "Another-Pw" }) -Force
Set-Content -LiteralPath $state -Value ($db | ConvertTo-Json -Depth 8) -Encoding ASCII
function Get-RepointConn { param([string]$Key) $d = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json; return ("" + $d.connections.EXAKIT_SRC_JSONPS.$Key) }
function Get-RepointHost { return (Get-Content -Raw -LiteralPath (Join-Path $home2 "sources/jsonps/config.json") | ConvertFrom-Json).inputs.host }
$jsonPw2 = Join-Path $work "json2.pw"
Set-Content -LiteralPath $jsonPw2 -Value "Json-Pw-2" -Encoding ASCII -NoNewline
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=pgnew.example.com", "--json")
Check "a re-point without --yes or a credential: one object, exit 5, kind declined, no command to run as is, nothing changed" "True 5 declined True pg.example.com" `
    "$one $jsonCode $($jsonDoc.kind) $($null -eq $jsonDoc.command) $(Get-RepointHost)"
Check "...its fix names the credential" $true ("$($jsonDoc.remedy)".Contains("--password-file <file> or --password-stdin"))
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=pgnew.example.com", "--password-file", $jsonPw2, "--json")
Check "...with --password-file, no --yes: declined, the --yes form names the file" "True 5 exakit connect postgresql --name jsonps --set host=pgnew.example.com --password-file $jsonPw2 --yes --json" `
    "$one $jsonCode $($jsonDoc.command)"
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=pgnew.example.com", "--dry-run", "--json")
Check "...--dry-run --json: the plan, exit 0, the change and the credential required" "True 0 repoint host pg.example.com pgnew.example.com required" `
    ("$one $jsonCode $($jsonDoc.action) " + (@($jsonDoc.changes) | ForEach-Object { "$($_.input) $($_.from) $($_.to)" }) + " $($jsonDoc.credential)")
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "user=read,er", "--dry-run", "--json")
Check "...its command quoted for PowerShell (a comma would split the word there)" "exakit connect postgresql --name jsonps --set 'user=read,er'" $jsonDoc.command
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=pgnew.example.com", "--yes", "--json")
Check "...--yes without a credential: exit 2, kind input, nothing changed" "True 2 input pg.example.com" "$one $jsonCode $($jsonDoc.kind) $(Get-RepointHost)"
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=pgnew.example.com", "--password-file", $jsonPw2, "--yes", "--json")
Check "...--yes and the credential: exit 0, repointed, replaced" "True 0 repointed replaced" "$one $jsonCode $($jsonDoc.action) $($jsonDoc.credential)"
Check "...the CONNECTION holds the new host and the credential given; the record follows" "True Json-Pw-2 pgnew.example.com" `
    ("{0} {1} {2}" -f (Get-RepointConn "url").StartsWith("jdbc:postgresql://pgnew.example.com:5432/"), (Get-RepointConn "secret"), (Get-RepointHost))
Check "...VS_JSONPS kept its name and reads the new source" "ITEMS ORDERS" ((@((Get-Content -Raw -LiteralPath $state | ConvertFrom-Json).virtual.VS_JSONPS.tables) | Sort-Object) -join " ")
Check "...no credential in the answer" $false ($jsonText.Contains("Json-Pw-"))
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=pgnew.example.com", "--json")
Check "...the same again, no credential: exit 0, unchanged, ready" "True 0 unchanged ready" "$one $jsonCode $($jsonDoc.action) $($jsonDoc.status)"
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=pgauth.example.com", "--password-file", $jsonPw2, "--yes", "--json")
Check "a new host that refuses the credential given: exit 1, kind auth, nothing changed" "True 1 auth True pgnew.example.com" `
    ("$one $jsonCode $($jsonDoc.kind) " + "$($jsonDoc.remedy)".Contains("nothing was changed") + " $(Get-RepointHost)")
Check "...the CONNECTION as it was" "True Json-Pw-2" `
    ("{0} {1}" -f (Get-RepointConn "url").StartsWith("jdbc:postgresql://pgnew.example.com:5432/"), (Get-RepointConn "secret"))
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "host=localhost", "--password-file", $jsonPw2, "--yes", "--json")
Check "a re-point to localhost: exit 2, kind input, the loopback advice" "True 2 input True" `
    ("$one $jsonCode $($jsonDoc.kind) " + "$($jsonDoc.error)".Contains("would be the database itself"))
$one = Invoke-JsonConnect @("pg", "--name", "jsonps", "--set", "password=Hunter-2", "--json")
Check "a credential given with --set: refused before the engine runs, exit 2, its value never repeated" "True 2 input True False" `
    "$one $jsonCode $($jsonDoc.kind) $($jsonDoc.rejected) $($jsonText.Contains('Hunter-2'))"
# Without --json and without a console: the plan says what changes, and only --yes agrees.
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name jsonps --set port=5433 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "exakit connect (no --json, no console), a re-point without --yes: exit 5, nothing changed" "5 5432" `
    "$childCode $((Get-Content -Raw -LiteralPath (Join-Path $home2 "sources/jsonps/config.json") | ConvertFrom-Json).inputs.port)"
Check "...the plan says what changes and that the credential is required, never kept" "True True False" `
    ("{0} {1} {2}" -f $text.Contains("port: 5432 -> 5433"), $text.Contains("Credential: required"), $text.Contains("Credential: kept"))
Check "...and how to agree" $true $text.Contains("Nothing was changed. Confirm it with --yes.")
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name jsonps --set port=5433 --yes 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Check "...--yes without a credential: exit 2, nothing changed" "2 5432" `
    "$childCode $((Get-Content -Raw -LiteralPath (Join-Path $home2 "sources/jsonps/config.json") | ConvertFrom-Json).inputs.port)"
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name jsonps --set port=5433 --password-file $jsonPw2 --yes 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "...--yes and --password-file: exit 0, re-pointed, said" "0 True" ("$childCode " + $text.Contains("Re-pointed jsonps (port 5432 -> 5433) with the credential given; VS_JSONPS kept its name"))
$ErrorActionPreference = "Continue"
$out = & $pwsh -NoProfile -File $urlChildFile $repo $defs $home2 $deploy $python $urlRecord pg --name jsonps --set port=5433 2>&1
$childCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
$text = (@($out) | ForEach-Object { "$_" }) -join "`n"
Check "...and again: nothing to change, exit 0, said" "0 True" ("$childCode " + $text.Contains("Nothing to change: jsonps already reads from"))
# Java missing and no --yes: no question, the engine's nojava answer, exit 21.
$db = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
$db | Add-Member -NotePropertyName java -NotePropertyValue $false -Force
Set-Content -LiteralPath $state -Value ($db | ConvertTo-Json -Depth 8) -Encoding ASCII
$one = Invoke-JsonConnect (@("pg", "--name", "jsonjava") + $pgSet + @("--password-file", $jsonPw, "--json"))
Check "a Java container that is missing, without --yes: one object, exit 21" "True 21 nojava" "$one $jsonCode $($jsonDoc.kind)"
Check "...whose fix names --yes" $true ("$($jsonDoc.remedy)".Contains("--yes"))
# A fresh Exasol Personal 2.4: JAVA=builtin_java, no client in BucketFS - the
# same missing Java, where the engine used to answer exit 1.
$db = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
$db | Add-Member -NotePropertyName java -NotePropertyValue "builtin" -Force
Set-Content -LiteralPath $state -Value ($db | ConvertTo-Json -Depth 8) -Encoding ASCII
$one = Invoke-JsonConnect (@("pg", "--name", "jsonj24") + $pgSet + @("--password-file", $jsonPw, "--json"))
Check "Personal 2.4's builtin_java without its client, without --yes: one object, exit 21" "True 21 nojava" "$one $jsonCode $($jsonDoc.kind)"
$db = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
$db | Add-Member -NotePropertyName java -NotePropertyValue $false -Force
Set-Content -LiteralPath $state -Value ($db | ConvertTo-Json -Depth 8) -Encoding ASCII
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
Write-Host "== --password-stdin (PowerShell): all of stdin, read as bytes =="
# The child's stdin carries exact bytes: a Process, not a PowerShell pipe,
# which re-encodes what it sends (5.1: ASCII) and adds a line ending.
function Invoke-StdinChild {
    param([string]$ChildFile, [string]$Record, [string[]]$A, [byte[]]$Bytes = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    $all = @("-NoProfile", "-File", $ChildFile, $repo, $defs, $home2, $deploy, $python, $Record) + $A
    $psi.Arguments = (@($all | ForEach-Object { '"' + $_ + '"' }) -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $in = $p.StandardInput.BaseStream
    if ($Bytes.Length -gt 0) { $in.Write($Bytes, 0, $Bytes.Length) }
    $in.Close()
    $o = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $script:stdinErr = $errTask.Result
    $script:jsonCode = $p.ExitCode
    $script:jsonText = $o.Trim()
    $script:jsonDoc = $null
    try { $script:jsonDoc = $script:jsonText | ConvertFrom-Json } catch { }
    return ($null -ne $script:jsonDoc -and $script:jsonDoc -isnot [array])
}
function Get-StateSecret([string]$Connection) {
    $d = Get-Content -Raw -LiteralPath $state -Encoding UTF8 | ConvertFrom-Json
    if (-not $d.connections -or -not $d.connections.PSObject.Properties[$Connection]) { return "(none)" }
    return $d.connections.$Connection.secret
}
$one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "stdinps") + $pgSet + @("--password-stdin", "--json")) $utf8.GetBytes($pwEnc + "`n")
Check "connect --password-stdin --json: one object, exit 0" "True 0 True" "$one $jsonCode $($jsonDoc.ok)"
Check "...the non-ASCII credential, its newline dropped, is the CONNECTION's" $pwEnc (Get-StateSecret "EXAKIT_SRC_STDINPS")
Check "...and in neither stream" $false (($jsonText + $stdinErr).Contains($pwEnc))
$one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "stdinps16") + $pgSet + @("--password-stdin", "--json")) $encFiles["utf16"]
Check "--password-stdin in UTF-16 LE with its BOM: exit 0, the same credential" ("0 " + $pwEnc) ("$jsonCode " + (Get-StateSecret "EXAKIT_SRC_STDINPS16"))
$keyJson = "{`n  `"type`": `"service_account`",`n  `"private_key`": `"-----BEGIN PRIVATE KEY-----\nMIIx\n-----END PRIVATE KEY-----\n`"`n}"
$one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "stdinkey") + $pgSet + @("--password-stdin", "--json")) $utf8.GetBytes($keyJson + "`r`n")
Check "a JSON key on stdin: its line breaks kept, the trailing CRLF dropped" ("0 " + $keyJson) ("$jsonCode " + (Get-StateSecret "EXAKIT_SRC_STDINKEY"))
foreach ($enc in $encFiles.Keys) {
    $one = Invoke-JsonConnect (@("pg", "--name", "encps$enc") + $pgSet + @("--password-file", (Join-Path $work "enc-$enc.pw"), "--json"))
    Check "--password-file in $($enc), end to end: exit 0, the CONNECTION holds the credential" ("0 " + $pwEnc) ("$jsonCode " + (Get-StateSecret ("EXAKIT_SRC_ENCPS" + $enc.ToUpperInvariant())))
}
$one = Invoke-JsonConnect (@("pg", "--name", "encpslatin") + $pgSet + @("--password-file", (Join-Path $work "enc-latin1.pw"), "--json"))
Check "a Latin-1 --password-file: one object, exit 2, kind input, nothing connected" "True 2 input (none)" "$one $jsonCode $($jsonDoc.kind) $(Get-StateSecret 'EXAKIT_SRC_ENCPSLATIN')"
Check "...its error says why" $true ("$($jsonDoc.error)".Contains("is not UTF-8 or UTF-16 text"))
$one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "stdinnone") + $pgSet + @("--password-stdin", "--json"))
Check "--password-stdin, nothing on stdin: one object, exit 2, kind input" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
Check "...its error says what happened" "--password-stdin was given, but standard input was empty" $jsonDoc.error
Check "...command and public_ip present, rejected" "True True True" ("{0} {1} {2}" -f ($null -ne $jsonDoc.PSObject.Properties["command"]), ($null -ne $jsonDoc.PSObject.Properties["public_ip"]), $jsonDoc.rejected)
$one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "stdinnone") + $pgSet + @("--password-stdin"))
Check "...without --json: exit 2, one line" "2 True" ("$jsonCode " + $jsonText.Contains("DENY --password-stdin read nothing: standard input was empty."))
$one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "stdinboth") + $pgSet + @("--password-stdin", "--password-file", $jsonPw, "--json")) $utf8.GetBytes("x")
Check "--password-stdin with --password-file: one object, exit 2, nothing connected" "True 2 input (none)" "$one $jsonCode $($jsonDoc.kind) $(Get-StateSecret 'EXAKIT_SRC_STDINBOTH')"
$one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "stdinlatin") + $pgSet + @("--password-stdin", "--json")) ([byte[]](@(0x70, 0xE4, 0x73, 0x73)))
Check "Latin-1 bytes on stdin: one object, exit 2, nothing connected" "True 2 input (none)" "$one $jsonCode $($jsonDoc.kind) $(Get-StateSecret 'EXAKIT_SRC_STDINLATIN')"
# Standard input the console: the child is told it is (the one primitive,
# [Console]::IsInputRedirected, is what a piped run above answered false to).
$ttyChildFile = Join-Path $work "tty-child.ps1"
Set-Content -LiteralPath $ttyChildFile -Encoding ASCII -Value ($urlChild.Replace('Invoke-CmdConnect -Arguments $args', "function Test-ExakitVsStdinTerminal { return `$true }`nInvoke-CmdConnect -Arguments `$args"))
$one = Invoke-StdinChild $ttyChildFile $urlRecord (@("pg", "--name", "stdintty") + $pgSet + @("--password-stdin", "--json")) $utf8.GetBytes("x")
Check "--password-stdin with the console on stdin: one object, exit 2" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
Check "...its error says what happened" "--password-stdin was given, but standard input is a terminal" $jsonDoc.error
$one = Invoke-StdinChild $ttyChildFile $urlRecord (@("pg", "--name", "stdintty") + $pgSet + @("--password-stdin")) $utf8.GetBytes("x")
Check "...without --json: exit 2, one line, nothing connected" "2 True (none)" ("$jsonCode " + $jsonText.Contains("DENY --password-stdin reads the credential from standard input, which is a terminal here") + " " + (Get-StateSecret "EXAKIT_SRC_STDINTTY"))
Check "review 7: ...pointing at --password-file and cmd's redirection, never a PowerShell pipe (5.1 pipes only ASCII)" "True True False" ("{0} {1} {2}" -f $jsonText.Contains("--password-file <file>"), $jsonText.Contains('cmd /c "exakit ... --password-stdin < key.json"'), $jsonText.Contains("Get-Content"))
# Review 6: stdin redirected, but the pipe behind it is Git Bash's terminal.
$msysChildFile = Join-Path $work "msys-child.ps1"
Set-Content -LiteralPath $msysChildFile -Encoding ASCII -Value ($urlChild.Replace('Invoke-CmdConnect -Arguments $args', "function Get-ExakitVsStdinPipeName { return '\msys-1888ae32e00d56aa-pty0-from-master' }`nInvoke-CmdConnect -Arguments `$args"))
$one = Invoke-StdinChild $msysChildFile $urlRecord (@("pg", "--name", "stdinmsys") + $pgSet + @("--password-stdin", "--json")) $utf8.GetBytes("typed")
Check "review 6: a Git Bash terminal pipe on stdin: refused as a terminal, nothing connected" "True 2 --password-stdin was given, but standard input is a terminal (none)" "$one $jsonCode $($jsonDoc.error) $(Get-StateSecret 'EXAKIT_SRC_STDINMSYS')"
# Review 1: UTF-16 with a stray byte, or without its BOM, refused on both flags.
$bad16 = [ordered]@{ "odd" = [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes("pass") + @(0x0A)); "bomless" = [System.Text.Encoding]::Unicode.GetBytes("pass`n") }
foreach ($k in $bad16.Keys) {
    $f = Join-Path $work "bad16-$k.pw"; [System.IO.File]::WriteAllBytes($f, $bad16[$k])
    $one = Invoke-JsonConnect (@("pg", "--name", "bad16f$k") + $pgSet + @("--password-file", $f, "--json"))
    Check "review 1: a --password-file in UTF-16 $($k): one object, exit 2, not text, nothing connected" "True 2 True (none)" ("$one $jsonCode " + "$($jsonDoc.error)".Contains("is not UTF-8 or UTF-16 text") + " " + (Get-StateSecret ("EXAKIT_SRC_BAD16F" + $k.ToUpperInvariant())))
    $one = Invoke-StdinChild $urlChildFile $urlRecord (@("pg", "--name", "bad16s$k") + $pgSet + @("--password-stdin", "--json")) $bad16[$k]
    Check "review 1: --password-stdin in UTF-16 $($k): the same" "True 2 True (none)" ("$one $jsonCode " + "$($jsonDoc.error)".Contains("is not UTF-8 or UTF-16 text") + " " + (Get-StateSecret ("EXAKIT_SRC_BAD16S" + $k.ToUpperInvariant())))
}
# Review 2: a credential given as an option is refused by name; no =value is repeated.
foreach ($a in @("--password-stdin=hunter2", "--passwd=hunter2", "--password-file=hunter2", "--secret=hunter2", "--bogus=hunter2")) {
    $one = Invoke-JsonConnect (@("pg", "--name", "jsonarg") + $pgSet + @($a, "--json"))
    Check ("review 2: connect {0}: one object, exit 2, kind input" -f ($a -replace "hunter2", "<v>")) "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
    Check "...the value not repeated" $false ($jsonText.Contains("hunter2"))
}
Check "review 2: an unknown option: its name only" "unknown option '--bogus' for connect" $jsonDoc.error
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
Remove-Item -LiteralPath $srcRecord -ErrorAction SilentlyContinue
$one = Invoke-StdinChild $srcChildFile $srcRecord @("reauth", "jsonre", "--json", "--password-stdin") $utf8.GetBytes("Json-Pw-2`r`n")
Check "reauth --json --password-stdin: one object, exit 0, the source ready" "True 0 ready" "$one $jsonCode $($jsonDoc.status)"
Check "...the engine got --secret-stdin, never the credential" "--json show jsonre|--json reauth jsonre --secret-stdin" ((Get-Content -LiteralPath $srcRecord) -join "|")
$one = Invoke-StdinChild $srcChildFile $srcRecord @("reauth", "jsonre", "--json", "--password-stdin")
Check "reauth --json --password-stdin, nothing on stdin: one object, exit 2" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
$one = Invoke-StdinChild $srcChildFile $srcRecord @("check", "jsonre", "--json", "--password-stdin") $utf8.GetBytes("x")
Check "--password-stdin on an action that takes no credential: one object, exit 2" "True 2 input" "$one $jsonCode $($jsonDoc.kind)"
Remove-Item -LiteralPath $srcRecord -ErrorAction SilentlyContinue
$one = Invoke-JsonSource @("reauth", "jsonre", "--password=hunter2", "--json")
Check "review 2: source reauth --password=<v> --json: one object, exit 2, the engine never ran" "True 2 False" "$one $jsonCode $(Test-Path -LiteralPath $srcRecord)"
Check "...the error names the problem" "a credential was given as an argument, where other users can read it in the process list" $jsonDoc.error
Check "...not the value" $false ($jsonText.Contains("hunter2"))
$one = Invoke-JsonSource @("list", "--bogus=hunter2", "--json")
Check "review 2: source list --bogus=<v> --json: the option's name only" "True 2 unknown option '--bogus' for source list" "$one $jsonCode $($jsonDoc.error)"
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

Write-Host ""
Write-Host "== a restart whose start fails is not a running database =="
# The real functions, over every stand-in above; a stand-in exakit.cmd whose
# start exits FAKE_START_RC. Twin of the bash bridge's "did not come back".
$vsAst = [System.Management.Automation.Language.Parser]::ParseFile((J @("setup", "lib", "virtual-schemas.ps1")), [ref]$null, [ref]$null)
foreach ($def in @($vsAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
        (@("Restart-ExakitVsDatabase", "Install-ExakitVsJava", "Repair-ExakitVsForRetry") -contains $n.Name) }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
$fakeBin = Join-Path $work "fakebin"; New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
$fakeExakit = Join-Path $fakeBin "exakit.cmd"
$fakeCalls = Join-Path $work "exakit-calls.txt"
if ($env:OS -like "*Windows*") {
    Set-Content -LiteralPath $fakeExakit -Encoding Ascii -Value @("@echo off", "echo %1>>""$fakeCalls""",
        "if ""%1""==""start"" exit /b %FAKE_START_RC%", "exit /b 0")
} else {
    Set-Content -LiteralPath $fakeExakit -Encoding Ascii -Value @("#!/bin/sh", "echo `"`$1`" >> '$fakeCalls'",
        "[ `"`$1`" = start ] && exit `${FAKE_START_RC:-0}", "exit 0")
    chmod +x $fakeExakit
}
$previousBin = $script:BinDir
$script:BinDir = $fakeBin
function Calls { if (Test-Path -LiteralPath $fakeCalls) { $c = (@(Get-Content -LiteralPath $fakeCalls) | ForEach-Object { "$_".Trim() }) -join "|"; Remove-Item -LiteralPath $fakeCalls; return $c }; return "" }
$env:FAKE_START_RC = "1"
$r = Restart-ExakitVsDatabase 6> $null
Check "Restart-ExakitVsDatabase: a start that fails is False" "False stop|start" ("$r " + (Calls))
$env:FAKE_START_RC = "0"
$r = Restart-ExakitVsDatabase 6> $null
Check "...a start that succeeds is True" "True stop|start" ("$r " + (Calls))
# The Java install around it, with the launcher and the DNS steps replaced.
function Ok([string]$M) { Write-Host "OK $M" }
function Get-PersonalCli { return "exasol" }
function Get-PersonalAutoApproveFlag { return "" }
function Invoke-ExakitLogged { return 0 }
function Initialize-PersonalSlcDns { param([switch]$Pull) }
function Repair-PersonalSlcDns { $script:PersonalSlcDnsNeedsStart = $script:stubNeedsStart; return (-not $script:stubNeedsStart) }
$script:stubNeedsStart = $false
$previousYes = $script:ExakitVsAssumeYes; $script:ExakitVsAssumeYes = $true
$env:FAKE_START_RC = "1"
$said = @(Install-ExakitVsJava 6>&1)
$r = $said[-1]; $text = (@($said) | ForEach-Object { "$_" }) -join "|"
Check "Install-ExakitVsJava, the start fails: False, and it says so" "False True False" `
    ("$r " + $text.Contains("The database did not come back after installing Java. Run: exakit start") + " " + $text.Contains("Java language container installed"))
[void](Calls)
$env:FAKE_START_RC = "0"
$said = @(Install-ExakitVsJava 6>&1)
Check "...the start succeeds: True, installed" "True True stop|start" ("$($said[-1]) " + ((@($said) | ForEach-Object { "$_" }) -join "|").Contains("Java language container installed") + " " + (Calls))
# Docker, an older installed kit: the second restart is checked too.
$script:stubNeedsStart = $true
$env:FAKE_START_RC = "1"
$said = @(Install-ExakitVsJava 6>&1)
Check "...the second restart (an older kit's start) fails: False" "False" "$($said[-1])"
[void](Calls)
# Exit 20 on Docker, --yes: the bridge must not retry a database that is down.
$env:FAKE_START_RC = "1"
$said = @(Repair-ExakitVsForRetry -Code 20 6>&1)
Check "Repair-ExakitVsForRetry 20 on Docker, the restart's start fails: False, said as bash says it" "False True" `
    ("$($said[-1]) " + ((@($said) | ForEach-Object { "$_" }) -join "|").Contains("The database did not come back. Run: exakit start"))
[void](Calls)
$env:FAKE_START_RC = "0"
$said = @(Repair-ExakitVsForRetry -Code 20 6>&1)
Check "...the start succeeds: True, retried" "True stop|start" ("$($said[-1]) " + (Calls))
$script:ExakitVsAssumeYes = $previousYes
$script:BinDir = $previousBin
Remove-Item Env:\FAKE_START_RC

Remove-Item Env:\EXAKIT_VS_FAKE_DB, Env:\FAKE_VS_STATE
if (-not $env:KEEP_WORK) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue } else { Write-Host "work: $work" }
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
