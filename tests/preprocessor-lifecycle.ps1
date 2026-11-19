#!/usr/bin/env pwsh
# preprocessor-lifecycle.ps1 - the Windows bridge to the SQL preprocessor
# framework coordinator, run against the same simulated database as
# tests/preprocessor-lifecycle.sh (tests/lib/fake-exapump.py). The coordinator
# itself is the real setup\preprocessor\manage.py; that suite covers its every
# branch, so this one covers what the PowerShell side owns:
#
#   - the pin: the advertised one, or this kit copy's when the advertised one
#     needs a newer kit
#   - the package is fetched only when a fresh install asks for it, verified,
#     and cached by digest
#   - the coordinator's lines are rendered, and a FAIL line becomes the reason
#     the closing summary prints
#   - a framework that arrives after an add-on (0.2.5 -> 0.3.0) registers that
#     add-on's module on this side too
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/preprocessor-lifecycle.ps1
#   pwsh -NoProfile -File tests/preprocessor-lifecycle.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Has($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$needle> in <$haystack>" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-preproc-ps-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$isWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $py3 = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py3) { Write-Host "python is required for this suite"; exit 1 }
    $shim = Join-Path $work "shim"
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $shim "python") -Target $py3.Source | Out-Null
    $env:PATH = $shim + [System.IO.Path]::PathSeparator + $env:PATH
}
$pythonExe = (Get-Command python).Source

# The stand-in exapump, runnable the way manage.py runs the real binary.
$fake = Join-Path $repo (Join-Path "tests" (Join-Path "lib" "fake-exapump.py"))
if ($isWin) {
    $exapump = Join-Path $work "exapump.cmd"
    Set-Content -LiteralPath $exapump -Value "@echo off`r`n`"$pythonExe`" `"$fake`" %*`r`n" -Encoding ASCII
} else {
    $exapump = Join-Path $work "exapump"
    Set-Content -LiteralPath $exapump -Value "#!/bin/sh`nexec `"$pythonExe`" `"$fake`" `"`$@`"`n" -Encoding ASCII
    & chmod +x $exapump
}

# A small package with the real release.sql's shape.
$pkg = Join-Path $work "release.sql"
$sql = "CREATE ROLE PREPROC_ADMIN;`nCREATE SCHEMA IF NOT EXISTS PREPROC;`nCREATE SCHEMA IF NOT EXISTS PREPROC_RT;`n"
foreach ($s in @("PREPROC_RT.MASTER", "PREPROC_RT.CONTROL_SUGAR_V1", "PREPROC.REFRESH_CORE", "PREPROC.REFRESH",
                 "PREPROC.STATUS", "PREPROC.RULE_ENSURE", "PREPROC.RULE_DROP", "PREPROC.RULE_LIST",
                 "PREPROC.MODULE_REGISTER", "PREPROC.MODULE_RETIRE", "PREPROC.MODULE_RECLAIM")) {
    $sql += "--/`nCREATE OR REPLACE LUA SCRIPT $s() AS`nlocal a = 1`n/`n"
}
$sql += "--/`nCREATE OR REPLACE PYTHON3 SET SCRIPT PREPROC.MODULE_RESOLVER_V1(s VARCHAR(10)) EMITS (r VARCHAR(10)) AS`ndef run(ctx):`n    ctx.emit('OK')`n/`n"
$sql += "INSERT INTO PREPROC.CONFIG (rule_id) SELECT 1;`n"
[System.IO.File]::WriteAllText($pkg, $sql)
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $pkg).Hash.ToLowerInvariant()
$derive = & $pythonExe (Join-Path $repo (Join-Path "setup" (Join-Path "preprocessor" "manage.py"))) derive --package $pkg
$core = ($derive | ConvertFrom-Json).sha256

# A kit copy: the real coordinators, and a versions.json pinning the package.
$kit = Join-Path $work "kit"
$kitSetup = Join-Path $kit "setup"
New-Item -ItemType Directory -Force -Path $kitSetup | Out-Null
Copy-Item -Recurse -Force (Join-Path $repo (Join-Path "setup" "core")) $kitSetup
Copy-Item -Recurse -Force (Join-Path $repo (Join-Path "setup" "preprocessor")) $kitSetup
$versions = Get-Content -Raw -LiteralPath (Join-Path $repo "versions.json") | ConvertFrom-Json
$versions.components.preprocessor.sha256."release-sql" = $sha
$versions.components.preprocessor.sha256."core-only" = $core
$versions | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $kit "versions.json") -Encoding ASCII
# The "advertised" document: the same pin, unless a test says otherwise.
$advertised = Join-Path $work "advertised.json"
Copy-Item -Force (Join-Path $kit "versions.json") $advertised

# --- the kit around the module, replaced -------------------------------------
$script:ExakitHome = Join-Path $work "home"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:LogFile = Join-Path $work "setup.log"
$script:ExapumpProfile = "starter-kit"
$script:ManagedPythonVersion = "3.12"
New-Item -ItemType Directory -Force -Path $script:ExakitHome | Out-Null
$script:events = New-Object System.Collections.ArrayList
$script:fetches = New-Object System.Collections.ArrayList
function Note([string]$Text) { [void]$script:events.Add($Text) }
function Test-ExakitSystemPython { return $true }
function Install-ExakitUv { throw "uv must not be needed here" }
function Write-ExakitLog { param($Level, $Msg) Add-Content -LiteralPath $script:LogFile -Value "$Level $Msg" }
function Info([string]$Msg) { Note "INFO $Msg" }
function OkStep([string]$Msg) { Note "OKSTEP $Msg" }
function Warn2([string]$Msg) { Note "WARN $Msg" }
function Set-ExakitFailureReason { param([string]$Reason) $script:reason = $Reason }
function Get-ExakitManifestValue {
    param([string]$Path)
    if ($Path -eq "runtime.user") { return "sys" }
    $node = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $null }
        $node = $node.$part
    }
    return $node
}
function Get-ExapumpCli { return $exapump }
function Get-ExakitInstallCommand { return "irm https://example.invalid/install.ps1 | iex" }
function Get-ExakitComponentCurrent { param([string]$Component) return "0.3.0" }
function Test-ExakitVersionNewer {
    param([string]$Latest, [string]$Current)
    return ([version]($Latest -replace '[^0-9.]', '') -gt [version]($Current -replace '[^0-9.]', ''))
}
function Get-ExakitVersionsValue {
    param([string]$Path, [string]$DocPath = "")
    if (-not $DocPath) { $DocPath = $advertised }
    $node = Get-Content -Raw -LiteralPath $DocPath | ConvertFrom-Json
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $null }
        $node = $node.$part
    }
    return $node
}
function Invoke-ExakitWithSpinner { param($Label, $Body) return (& $Body) }
function Get-ExakitFile {
    param([string]$Url, [string]$Dest)
    [void]$script:fetches.Add($Url)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
    Copy-Item -Force -LiteralPath $pkg -Destination $Dest
}
function Test-ExakitSha256 {
    param([string]$Path, [string]$Expected)
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -ne $Expected) { throw "checksum mismatch" }
}

# Invoke-ExakitPythonFile lives in the shared layer; lifted out of it here so
# the rest of exakit-common.ps1 (logging, paths, the manifest) stays stubbed.
$commonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo (Join-Path "setup" (Join-Path "lib" "exakit-common.ps1"))), [ref]$null, [ref]$null)
foreach ($def in @($commonAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq "Invoke-ExakitPythonFile" }, $true))) {
    . ([scriptblock]::Create($def.Extent.Text))
}
. (Join-Path $repo (Join-Path "setup" (Join-Path "lib" "core-setup.ps1")))

$state = Join-Path $work "state.json"
$env:FAKE_EXAPUMP_STATE = $state
function Reset-Db([string]$Json = "{}") {
    Set-Content -LiteralPath $state -Value $Json -Encoding ASCII
    Set-Content -LiteralPath $script:ManifestPath -Value '{"components": {}}' -Encoding ASCII
    $script:events.Clear(); $script:fetches.Clear(); $script:reason = ""
}
function Get-Db([string]$Key) { return ((Get-Content -Raw -LiteralPath $state | ConvertFrom-Json).$Key) }

Write-Host ""
Write-Host "== the pin =="
$pin = Get-ExakitCorePreprocessorPin -KitRoot $kit
Check "the advertised pin is used, both digests" "0.9.1 v0.9.1 release.sql exasol-labs/preprocessor-framework $sha $core" "$($pin.Version) $($pin.Ref) $($pin.Asset) $($pin.Repo) $($pin.Sha256) $($pin.CoreSha256)"
$ahead = Get-Content -Raw -LiteralPath $advertised | ConvertFrom-Json
$ahead.components.preprocessor.version = "0.10.0"
$ahead.components.preprocessor.min_kit_version = "0.9.0"
$ahead | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $advertised -Encoding ASCII
$pin = Get-ExakitCorePreprocessorPin -KitRoot $kit
Check "an advertised pin that needs a newer kit falls back to this kit copy's" "0.9.1" $pin.Version
Copy-Item -Force (Join-Path $kit "versions.json") $advertised

Write-Host ""
Write-Host "== a fresh database =="
Reset-Db
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "installed, tested and activated" $true $ok
Check "the package was fetched once, from the pinned release asset" "https://github.com/exasol-labs/preprocessor-framework/releases/download/v0.9.1/release.sql" ($script:fetches -join "|")
$cached = Join-ExakitCorePath $script:ExakitHome "cache" "preprocessor" $sha "release.sql"
Check "...into the digest-keyed cache" $true (Test-Path -LiteralPath $cached)
Has "the coordinator's lines are rendered" "OKSTEP SQL preprocessor framework 0.9.1 installed, tested and activated" ($script:events -join "|")
Check "the dispatcher holds the slot" "PREPROC_RT.MASTER" (Get-Db "system_slot")
Check "...on a database with no Python: the resolver was left out" $false ((Get-Db "scripts") -contains "PREPROC.MODULE_RESOLVER_V1")

Write-Host ""
Write-Host "== a second pass =="
$script:events.Clear(); $script:fetches.Clear()
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "verifies" $true $ok
Check "...without fetching anything" 0 $script:fetches.Count
Has "...and says so" "verified and active" ($script:events -join "|")

Write-Host ""
Write-Host "== a slot the user's own preprocessor holds =="
# PRE-02: declined, not failed. A failure here left the core task pending, so
# every `exakit update` reran the installer and exited 1 with a remedy that
# could never work while the user kept their script.
Reset-Db '{"system_slot": "OTHER.SCRIPT"}'
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "is the task done, as declined" $true $ok
Check "...with no failure reason for the summary" "" $script:reason
Check "...and the slot is untouched" "OTHER.SCRIPT" (Get-Db "system_slot")
$record = (Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json).components.preprocessor
Check "...recorded as declined, with the holder" "True OTHER.SCRIPT" "$($record.declined) $($record.slot_holder)"
Has "...said once, as information" "INFO The database's SQL preprocessor slot holds OTHER.SCRIPT" ($script:events -join "|")
Has "...with this platform's installer as the way to opt in" "then run irm https://example.invalid/install.ps1 | iex again" ($script:events -join "|")
Check "...and nothing was fetched" 0 $script:fetches.Count
$script:events.Clear()
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "the next pass is still done" $true $ok
Check "...without the whole story again" 0 @($script:events | Where-Object { "$_".StartsWith("INFO ") }).Count
Has "...only the step's line" "OKSTEP SQL preprocessor slot left to OTHER.SCRIPT" ($script:events -join "|")

Write-Host ""
Write-Host "== the framework arrives after an add-on (0.2.5 -> 0.3.0) =="
# The add-on was installed by a kit that had no framework; the installer the
# update reruns installs the framework, and its verify registers the add-on.
$modDir = Join-Path $kit (Join-Path "setup" (Join-Path "preprocessor" (Join-Path "modules" "demo-addon")))
New-Item -ItemType Directory -Force -Path $modDir | Out-Null
$artifact = Join-Path $modDir "demo_mod_v1.sql"
[System.IO.File]::WriteAllText($artifact, "--/`nCREATE OR REPLACE LUA SCRIPT PREPROC_RT.DEMO_MOD_V1() AS`nfunction demo_mod(sqltext)`n    return nil`nend`n/`n")
$artifactSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
$toml = "name = `"demo_mod`"`ndescription = `"a test module`"`nphase = `"EXPAND`"`nscript_name = `"PREPROC_RT.DEMO_MOD_V1`"`n" +
    "function = `"demo_mod`"`nversion = 1`nmin_framework = `"0.9.1`"`ndeploy_mode = `"library-deployed`"`nsha256 = `"$artifactSha`"`n" +
    "[suggested_scope]`ntype = `"ROLE`"`nvalue = `"PUBLIC`"`n" +
    "[kit]`naddon = `"demo-addon`"`nlabel = `"Demo`"`nreceipt = `"components.demo_addon`"`nartifact = `"demo_mod_v1.sql`"`n"
[System.IO.File]::WriteAllText((Join-Path $modDir "module.toml"), $toml)
Reset-Db
Set-Content -LiteralPath $script:ManifestPath -Value '{"components": {"demo_addon": {"ownership": "kit", "version": "1.0.0"}}}' -Encoding ASCII
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "the framework installs" $true $ok
Has "...and registers the add-on that was already there" "OKSTEP Demo registered with the SQL preprocessor framework: PREPROC_RT.DEMO_MOD_V1 for role PUBLIC" ($script:events -join "|")
$rule = @((Get-Db "rules") | Where-Object { $_.script -eq "PREPROC_RT.DEMO_MOD_V1" })
Check "...with one rule for every user" "1 ROLE PUBLIC" "$($rule.Count) $($rule[0].scope_type) $($rule[0].scope_value)"
$record = (Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json).components.preprocessor.modules."demo-addon"
Check "...recorded in the manifest" "1 PREPROC_RT.DEMO_MOD_V1" "$($record.version) $($record.script)"
$script:events.Clear()
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "the next pass verifies" $true $ok
Check "...and says nothing more about the add-on" 0 @($script:events | Where-Object { "$_".Contains("Demo") }).Count

Write-Host ""
Write-Host "== a module artifact with Windows line endings registers for real =="
# exapump ends a script body only at a "/" followed by a bare LF. A CRLF
# artifact (generate.py writes text mode on Windows) ran its first body on to
# the end of the batch: the RULE_ENSURE and MODULE_REGISTER after it were body
# text, exapump exited 0, and JSON Tables said "registered" with no module in
# the database (Windows 11 upgrade re-run). Twin of jt-crlf in
# tests/preprocessor-lifecycle.sh.
Remove-Item -Recurse -Force -LiteralPath $modDir
$crlfDir = Join-Path $kit (Join-Path "setup" (Join-Path "preprocessor" (Join-Path "modules" "crlf-addon")))
New-Item -ItemType Directory -Force -Path $crlfDir | Out-Null
$crlfArtifact = Join-Path $crlfDir "crlf_mod_v1.sql"
[System.IO.File]::WriteAllText($crlfArtifact, "--/`r`nCREATE OR REPLACE LUA SCRIPT PREPROC_RT.CRLF_MOD_V1() AS`r`nfunction crlf_mod(sqltext)`r`n    return nil`r`nend`r`n/`r`n")
$crlfSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $crlfArtifact).Hash.ToLowerInvariant()
$toml = "name = `"crlf_mod`"`ndescription = `"a test module`"`nphase = `"EXPAND`"`nscript_name = `"PREPROC_RT.CRLF_MOD_V1`"`n" +
    "function = `"crlf_mod`"`nversion = 1`nmin_framework = `"0.9.1`"`ndeploy_mode = `"library-deployed`"`nsha256 = `"$crlfSha`"`n" +
    "[suggested_scope]`ntype = `"ROLE`"`nvalue = `"PUBLIC`"`n" +
    "[kit]`naddon = `"crlf-addon`"`nlabel = `"Crlf`"`nreceipt = `"components.crlf_addon`"`nartifact = `"crlf_mod_v1.sql`"`n"
[System.IO.File]::WriteAllText((Join-Path $crlfDir "module.toml"), $toml)
Reset-Db
Set-Content -LiteralPath $script:ManifestPath -Value '{"components": {"crlf_addon": {"ownership": "kit", "version": "1.0.0"}}}' -Encoding ASCII
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "the framework installs" $true $ok
Has "...and registers the CRLF module" "OKSTEP Crlf registered with the SQL preprocessor framework: PREPROC_RT.CRLF_MOD_V1 for role PUBLIC" ($script:events -join "|")
$rule = @((Get-Db "rules") | Where-Object { $_.script -eq "PREPROC_RT.CRLF_MOD_V1" })
Check "...its rule is in the database" 1 $rule.Count
$prov = @((Get-Db "modules") | Where-Object { $_.name -eq "crlf_mod" -and $_.status -eq "deployed" })
Check "...and so is its provenance row" 1 $prov.Count
Remove-Item -Recurse -Force -LiteralPath $crlfDir

Write-Host ""
Write-Host "== the slot changes while the MCP server runs: it is restarted after, once (U5) =="
# Twin of the same section in tests/preprocessor-lifecycle.sh. A system setting
# reaches only new sessions, so an MCP server already running (an `exakit
# update` from 0.2.x sets it up before the framework) is restarted once the
# framework holds the slot. The stand-in notes the slot at the moment it runs;
# Restart-McpSidecar itself is covered in tests/mcp-sidecar-ps.ps1.
$script:restartSays = $true
function Restart-McpSidecar { Note ("RESTART slot=" + (Get-Db "system_slot")); return $script:restartSays }
Reset-Db
Set-Content -LiteralPath $script:ManifestPath -Value '{"components": {}}' -Encoding ASCII
$script:events.Clear()
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "the framework is activated" $true $ok
$order = @($script:events | Where-Object { "$_" -like "*installed, tested and activated*" -or "$_" -like "RESTART*" })
Check "...then the MCP server is restarted, the framework already in the slot, once" `
    "OKSTEP SQL preprocessor framework 0.9.1 installed, tested and activated|RESTART slot=PREPROC_RT.MASTER" ($order -join "|")
$script:events.Clear()
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "a pass that only verifies" $true $ok
Check "...leaves the server alone" 0 @($script:events | Where-Object { "$_" -like "RESTART*" }).Count
& $pythonExe -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['system_slot']=''; json.dump(d,open(p,'w'))" $state
$script:events.Clear(); $script:restartSays = $false
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "a cleared slot activated again restarts it too" "RESTART slot=PREPROC_RT.MASTER" (@($script:events | Where-Object { "$_" -like "RESTART*" }) -join "|")
Check "...and a restart that fails does not fail the framework task" $true $ok
Remove-Item Function:\Restart-McpSidecar
# The install screen's "SQL Preprocessor" sub-line ends "MCP server restarted",
# found by matching the start of the line Restart-McpSidecar says.
$restartLine = ([regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $repo (Join-Path "setup" (Join-Path "lib" "mcp.ps1")))),
    'Info "(The MCP server was restarted[^"]*)"')).Groups[1].Value
# Test-ExakitItemHeld as exakit-common.ps1 has it, over that one held line.
function Test-ExakitItemHeld([string]$Pattern) { return ("INFO $restartLine" -match $Pattern) }
Has "...and the install sub-line still says MCP server restarted" "MCP server restarted" (Get-ExakitCoreTaskItemDetail -Name "preprocessor")
Remove-Item Function:\Test-ExakitItemHeld

Write-Host ""
Write-Host "== exakit update runs the framework verify pass every time (PPX-04) =="
# Twin of the same section in tests/preprocessor-lifecycle.sh. Once the core
# task was done, exakit update reran nothing, so an add-on whose module the
# database lacks stayed without it while every remedy said "exakit update".
function Get-ExakitRepoRoot { return $kit }
function Test-PersonalDeploymentRunning { return $script:dbRunning }
function Add-ExakitUpdateNote { param([string]$Component, [string]$Outcome, [string]$From = "", [string]$To = "", [string]$Remedy = "", [string]$ErrorText = "", [string]$Hint = "") Note "NOTE $Component $Outcome" }
function Get-ExakitFailureReason { $r = $script:reason; $script:reason = ""; return $r }
New-Item -ItemType Directory -Force -Path $modDir | Out-Null
[System.IO.File]::WriteAllText($artifact, "--/`nCREATE OR REPLACE LUA SCRIPT PREPROC_RT.DEMO_MOD_V1() AS`nfunction demo_mod(sqltext)`n    return nil`nend`n/`n")
$toml = "name = `"demo_mod`"`ndescription = `"a test module`"`nphase = `"EXPAND`"`nscript_name = `"PREPROC_RT.DEMO_MOD_V1`"`n" +
    "function = `"demo_mod`"`nversion = 1`nmin_framework = `"0.9.1`"`ndeploy_mode = `"library-deployed`"`nsha256 = `"$artifactSha`"`n" +
    "[suggested_scope]`ntype = `"ROLE`"`nvalue = `"PUBLIC`"`n" +
    "[kit]`naddon = `"demo-addon`"`nlabel = `"Demo`"`nreceipt = `"components.demo_addon`"`nartifact = `"demo_mod_v1.sql`"`n"
[System.IO.File]::WriteAllText((Join-Path $modDir "module.toml"), $toml)
Reset-Db
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
& $pythonExe -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['components']['demo_addon']={'ownership':'kit','version':'1.0.0'}; json.dump(d,open(p,'w'))" $script:ManifestPath
Check "an installed add-on whose module the database lacks" 0 @((Get-Db "rules") | Where-Object { $_.script -eq "PREPROC_RT.DEMO_MOD_V1" }).Count
$script:dbRunning = $true
$script:events.Clear()
$ok = @(Invoke-ExakitCorePreprocessorVerify -Target "all")[-1]
Check "exakit update's verify pass succeeds" $true $ok
Check "...it leaves no line for the framework it only verified" 0 @($script:events | Where-Object { "$_" -like "*verified and active*" }).Count
Has "...and says the module it registered" "OKSTEP Demo registered with the SQL preprocessor framework: PREPROC_RT.DEMO_MOD_V1 for role PUBLIC" ($script:events -join "|")
Check "...its rule is in the database" 1 @((Get-Db "rules") | Where-Object { $_.script -eq "PREPROC_RT.DEMO_MOD_V1" }).Count
$script:events.Clear()
$ok = @(Invoke-ExakitCorePreprocessorVerify -Target "all")[-1]
Check "a clean verify (nothing to repair) prints nothing: a normal update looks as before" "True 0" "$ok $($script:events.Count)"
$script:events.Clear()
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Has "...while the installer's pass still says it" "OKSTEP SQL preprocessor framework 0.9.1 verified and active" ($script:events -join "|")
& $pythonExe -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['calls']=[]; json.dump(d,open(p,'w'))" $state
$script:dbRunning = $false
$script:events.Clear()
$ok = @(Invoke-ExakitCorePreprocessorVerify -Target "all")[-1]
Check "with the database stopped" $true $ok
Has "...it is said, not started" "INFO The database is not running, so the SQL preprocessor modules were not checked" ($script:events -join "|")
Check "...and nothing reached the database" 0 @(Get-Db "calls").Count
$script:dbRunning = $true
$script:events.Clear()
$ok = @(Invoke-ExakitCorePreprocessorVerify -Target "exapump")[-1]
Check "exakit update <one component> keeps its scope" "True 0 0" "$ok $($script:events.Count) $(@(Get-Db 'calls').Count)"
Remove-Item -Recurse -Force -LiteralPath $modDir

Remove-Item Env:\FAKE_EXAPUMP_STATE
Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
