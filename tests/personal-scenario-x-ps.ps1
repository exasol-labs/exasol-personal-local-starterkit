#!/usr/bin/env pwsh
# personal-scenario-x-ps.ps1 - the Windows twin of personal-scenario-x.sh: the
# kit next to an Exasol Personal the user installed by themselves.
#
# What it pins:
#   - every launcher call that acts on a deployment names the kit's own folder
#     (--deployment-dir), so the launcher's own choice - the folder it is run
#     from, or its default, which is the user's deployment - never applies
#   - which launcher a new install drives (CONTRACT section 2, Windows): the
#     kit's own 2.5 where the user has none (K), the user's 2.5 as it is (U),
#     and a stop at Step 1/4 next to their 2.4, a newer line, or deployments
#     of theirs in the older root with no launcher (A6). An install the kit
#     already records keeps its launcher, with the one warning line
#   - which database a new install uses (CONTRACT section 4): a new
#     starter-kit-local by default (Enter, no terminal), one of theirs renamed
#     to starter-kit-local when they pick it (the terminal, or EXAKIT_REUSE_DB
#     with its own parser), put back as it was when the rename cannot happen,
#     a starter-kit-local the kit has no record of used as theirs with no
#     question, and a database of theirs never offered for a replace
#
# Runs under Windows PowerShell 5.1 and pwsh; a stub launcher that records its
# arguments, never a real one, and never a real deployment.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-scenario-x-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "kit deployment"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
$script:LogFile = $null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Contains($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
$onWindows = $env:OS -eq "Windows_NT"

# The stub launcher: every call is recorded, one argument per line, so a folder
# with a space in its name stays one argument. A .cmd on Windows, sh elsewhere.
$calls = Join-Path $work "calls"
if ($onWindows) {
    $stub = Join-Path $work "exasol.cmd"
    Set-Content -Path $stub -Encoding Ascii -Value @(
        '@echo off',
        ':loop',
        'if "%~1"=="" goto done',
        ('>>"' + $calls + '" echo %~1'),
        'shift',
        'goto loop',
        ':done',
        ('>>"' + $calls + '" echo ---'),
        'exit /b 0')
} else {
    $stub = Join-Path $work "exasol"
    Set-Content -Path $stub -Encoding Ascii -Value @(
        '#!/bin/sh',
        ('for a in "$@"; do printf ''%s\n'' "$a" >> "' + $calls + '"; done'),
        ('echo --- >> "' + $calls + '"'),
        'exit 0')
    & chmod +x $stub
}
function Get-PersonalCli { return $script:stub }
$script:stub = $stub
function Get-LastCall {
    if (-not (Test-Path $calls)) { return "" }
    $all = @(Get-Content $calls | ForEach-Object { "$_".Trim() })
    Remove-Item $calls -Force
    $one = @()
    foreach ($a in $all) { if ($a -eq "---") { break }; $one += $a }
    return ($one -join "|")
}
$dd = "--deployment-dir|$($env:EXAKIT_PERSONAL_DEPLOY_DIR)"

try {
    Write-Host "== every launcher call that acts on a deployment names the kit's folder"
    New-Item -ItemType Directory -Force -Path $env:EXAKIT_PERSONAL_DEPLOY_DIR | Out-Null
    [void](Test-PersonalDeploymentExists)
    Check "info" "info|$dd" (Get-LastCall)
    [void](Get-PersonalLauncherState)
    Check "status --json" "status|--json|$dd" (Get-LastCall)
    function Test-PersonalLauncherSupports { return $true }
    function Set-ExakitManifestValue { }
    Stop-Personal 6>$null
    Check "stop" "stop|$dd" (Get-LastCall)
    [void](Invoke-PersonalDestroyOnce)
    Check "destroy" "destroy|--remove|--auto-approve|$dd" (Get-LastCall)
    # The unlock declines while a program of the launcher's name runs
    # (Unlock-PersonalStale asks the process list): none runs here, whatever
    # runs on the machine this suite runs on.
    & {
        function Get-Process { }
        [void](Unlock-PersonalStale)
    }
    Check "diag unlock" "diag|unlock|--auto-approve|$dd" (Get-LastCall)

    Write-Host "== every launcher call that acts on a deployment names the kit's folder (sweep of every file)"
    # Launcher 2.4.0 acts on the deployment in the CURRENT folder when no
    # --deployment-dir is given (review 0.3.1, item 1). Every (Get-PersonalCli)
    # call whose subcommand acts on a deployment carries the flag, and a
    # splatted list is built with Get-PersonalDeployDirArgs. Twin of the sweep
    # in personal-scenario-x.sh.
    $acts = '^\s*(?:-Arguments\s*@\()?\s*"?(install|deploy|start|stop|destroy|diag|info|status|slc|shell|sidecar|mcp)"?\b'
    $sweepFiles = @(Get-ChildItem -Path (Join-Path $repo "setup/lib") -Filter "*.ps1") + @(Get-Item (Join-Path $repo "setup/exakit.ps1"), (Join-Path $repo "setup/setup-windows.ps1"))
    $missing = @()
    foreach ($sf in $sweepFiles) {
        $all = [System.IO.File]::ReadAllText($sf.FullName)
        $n = 0
        foreach ($line in ($all -split "`r?`n")) {
            $n++
            if ($line.TrimStart().StartsWith("#")) { continue }
            foreach ($m in [regex]::Matches($line, '(?:Invoke-ExakitLogged|Invoke-ExakitBounded\s+-FilePath|&)\s*\(Get-PersonalCli\)')) {
                $rest = $line.Substring($m.Index + $m.Length)
                $splat = [regex]::Match($rest, '^\s+@(\w+)')
                if ($splat.Success) {
                    $v = [regex]::Escape($splat.Groups[1].Value)
                    if ($all -match ('(?i)\$' + $v + '\s*\+=\s*(?:@\()?\s*Get-PersonalDeployDirArgs') -or $all -match ('(?i)\$' + $v + '\s*=.*(--deployment-dir|Get-PersonalDeployDirArgs)')) { continue }
                    $missing += "$($sf.Name):$($n): splat @$($splat.Groups[1].Value)"
                    continue
                }
                if ($rest -match $acts -and -not $rest.Contains("--deployment-dir") -and -not $rest.Contains("Get-PersonalDeployDirArgs") -and -not $rest.Contains("--help")) {
                    $missing += "$($sf.Name):$($n): $($line.Trim())"
                }
            }
        }
    }
    # The marketplace's Python, shared by every platform: a launcher argv is
    # built in one place per module, which names the folder. Twin of the same
    # sweep in personal-scenario-x.sh.
    foreach ($pf in @(Get-ChildItem -Path (Join-Path $repo "marketplace") -Filter "*.py" -Recurse)) {
        $text = [System.IO.File]::ReadAllText($pf.FullName)
        foreach ($m in [regex]::Matches($text, '\[\s*(?:str\()?launcher\)?\s*,')) {
            $start = $text.LastIndexOf("`ndef ", $m.Index)
            $end = $text.IndexOf("`ndef ", $m.Index + $m.Length)
            if ($start -lt 0) { $start = 0 }
            if ($end -lt 0) { $end = $text.Length }
            $body = $text.Substring($start, $end - $start)
            if ($body.Contains('"deployments", "list"')) { continue }
            if (-not $body.Contains("--deployment-dir")) { $missing += "$($pf.Name): a launcher call without --deployment-dir" }
        }
    }
    Check "no launcher call that acts on a deployment goes without --deployment-dir (PowerShell, marketplace Python)" "" ($missing -join " | ")

    Write-Host "== ...and the argument lists the deploy builds carry it too"
    $src = Get-Content -Raw (Join-Path $repo "setup/lib/runtime-personal.ps1")
    $lists = [regex]::Matches($src, '\$(deployArgs|startArgs|installArgs) = @\(')
    $carried = [regex]::Matches($src, '\$(deployArgs|startArgs|installArgs) \+= Get-PersonalDeployDirArgs')
    Check "every deploy, start and install list adds the folder" $lists.Count $carried.Count
    Check "...and there are lists to check" $true ($lists.Count -ge 7)
    # The launcher verbs that act on a deployment, called with literal arguments.
    $bare = @([regex]::Matches($src, '\(Get-PersonalCli\)\)? (stop|destroy|deploy|start|diag unlock|slc list)\b[^\r\n]*') |
        Where-Object { $_.Value -notmatch '--deployment-dir' } | ForEach-Object { $_.Value })
    Check "no literal launcher call without the folder" "" ($bare -join " / ")

    # Every stub below lives in this block only (the sections after it use the
    # real functions).
    & {
    # One definition per name: a second one wins at load, and an edit to the
    # first does nothing.
    foreach ($one in @("runtime-personal.ps1", "exakit-common.ps1", "mcp.ps1")) {
        $oneAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/$one"), [ref]$null, [ref]$null)
        $twice = @($oneAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } | Group-Object Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        Check "no function defined twice in $one" "" ($twice -join " ")
    }

    Write-Host "== which launcher a new install drives: K, U, or a stop (A6)"
    # A launcher that answers `version` like the given release, and anything
    # else with a line of output, recording every call.
    $vcalls = Join-Path $work "vcalls"
    function New-VersionStub([string]$Version) {
        if ($onWindows) {
            $path = Join-Path $work "exasol-$Version.cmd"
            Set-Content -Path $path -Encoding Ascii -Value @(
                '@echo off',
                ('>>"' + $vcalls + '" echo %*'),
                ('if "%~1"=="version" echo ' + $Version),
                ('if not "%~1"=="version" echo {}'),
                'exit /b 0')
        } else {
            $path = Join-Path $work "exasol-$Version"
            Set-Content -Path $path -Encoding Ascii -Value @(
                '#!/bin/sh',
                ('echo "$*" >> "' + $vcalls + '"'),
                ('if [ "$1" = version ]; then echo ' + $Version + '; else echo "{}"; fi'),
                'exit 0')
            & chmod +x $path
        }
        return $path
    }
    # Invoke-ExakitBounded quotes every argument it hands the launcher, and the
    # Windows stub's `echo %*` keeps those quotes, so they are dropped here:
    # each call reads the same on every platform ("version" is version).
    function Get-VersionCalls { $t = ""; if (Test-Path $vcalls) { $t = (@(Get-Content $vcalls) | ForEach-Object { "$_".Replace('"', '') }) -join "|"; Remove-Item $vcalls -Force }; return $t }
    # The launcher's folders under this run's scratch folder, never the real profile.
    $env:LOCALAPPDATA = Join-Path $work "localappdata"
    $env:USERPROFILE = Join-Path $work "profile"
    $env:EXAKIT_PERSONAL_VERSION = "2.5.0"
    $spelled = Resolve-PersonalDeployDir -Path ""
    $newRoot = Split-Path -Parent $spelled.New
    $legacyRoot = Split-Path -Parent $spelled.Legacy
    $stub24 = New-VersionStub "2.4.0"
    $stub23 = New-VersionStub "2.3.1"
    $stub25 = New-VersionStub "2.5.0"
    $stub253 = New-VersionStub "2.5.3"
    $stub26 = New-VersionStub "2.6.0"
    $stubNone = New-VersionStub "no-version-here"
    Remove-Item -Recurse -Force $env:EXAKIT_PERSONAL_DEPLOY_DIR -ErrorAction SilentlyContinue
    $script:owner = "unknown"
    # An in-memory manifest: a new install records nothing yet.
    $script:mf = @{}
    function Get-ExakitManifestValue { param([string]$Path) return $script:mf[$Path] }
    function Set-ExakitManifestValue { param([string]$Path, $Value) $script:mf[$Path] = $Value }
    function Remove-ExakitManifestValue { param([string]$Path) $script:mf.Remove($Path) }
    $script:said = @()
    function Warn2([string]$Msg) { $script:said += "WARN $Msg" }
    function Info([string]$Msg) { $script:said += "INFO $Msg" }
    function Ok([string]$Msg) { $script:said += "OK $Msg" }
    $downloadMarker = Join-Path $work "downloaded"
    function Get-ExakitFile { Set-Content $downloadMarker 'reached'; throw 'download (fixture)' }
    function Get-PersonalS3Source { return $null }
    # Plan: a fresh process's launcher plan with <cli> as the user's launcher.
    function Plan([string]$Cli) {
        $script:stub = $Cli
        $script:PersonalLauncherPlan = $null
        # A fresh process: the kit's separate program not chosen yet.
        $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false
        $script:PersonalBinPath = Join-Path $script:BinDir "exasol.exe"
        [void](Get-VersionCalls)
        return (Get-PersonalLauncherPlan)
    }
    # Step1: Step 1/4 of a new install, its stop (Fail's sentence) kept.
    function Step1([string]$Cli) {
        $null = Plan $Cli
        $script:said = @()
        Remove-Item -Force $downloadMarker -ErrorAction SilentlyContinue
        $script:stepThrew = ""
        try { Install-PersonalLauncher 6>$null } catch { $script:stepThrew = "$($_.Exception.Message)" }
    }
    $noLauncher = Join-Path $work "no-launcher-here"

    $p = Plan $noLauncher
    Check "K: no launcher of the user's, nothing in the older root" "K|" "$($p.Mode)|$($p.Why)"
    Step1 $noLauncher
    Check "...the kit's own 2.5 goes to its folder, never on PATH (Krishna, 24 Nov)" "download (fixture)|$(Get-PersonalSeparateBinPath)" "$($script:stepThrew)|$($script:PersonalBinPath)"
    New-Item -ItemType Directory -Force -Path (Join-Path $legacyRoot "empty-folder") | Out-Null
    Check "K: a folder in the older root that holds no deployment does not count" "K" (Plan $noLauncher).Mode
    $theirOld = Join-Path $legacyRoot "default"
    New-Item -ItemType Directory -Force -Path $theirOld | Out-Null
    Set-Content -Path (Join-Path $theirOld "deployment.json") -Value '{"deploymentId": "exa-old"}' -Encoding Ascii
    Set-Content -Path (Join-Path $theirOld ".exasolLauncher.version") -Value '2.4.0' -Encoding Ascii
    $p = Plan $noLauncher
    Check "S: no launcher, but a deployment of theirs in the older root (Krishna, 24 Nov)" "S|legacy|$theirOld" "$($p.Mode)|$($p.Why)|$(@($p.Legacy) -join ',')"
    Step1 $noLauncher
    Check "...Step 1/4 says theirs is not changed" "INFO An Exasol Personal deployment is on this computer. The starter kit uses its own Exasol Personal 2.5.0, so yours is not changed." (@($script:said)[0])
    Check "...and installs the kit's own 2.5 in its folder (the download is reached)" "download (fixture)|True|$(Get-PersonalSeparateBinPath)" "$($script:stepThrew)|$(Test-Path $downloadMarker)|$($script:PersonalBinPath)"
    Check "...no launcher of theirs recorded" "" ("" + $script:mf["components.personal.user_launcher"])
    Remove-Item -Recurse -Force $legacyRoot -ErrorAction SilentlyContinue

    $p = Plan $stub24
    Check "S: the user's 2.4 (Krishna Q2)" "S|older|2.4.0" "$($p.Mode)|$($p.Why)|$($p.Version)"
    Check "...asked nothing but 'version'" "version" (Get-VersionCalls)
    $hash24 = (Get-FileHash $stub24).Hash
    Step1 $stub24
    Check "...Step 1/4 says theirs is not changed, the macOS line" $true ($script:said -contains "INFO Exasol Personal 2.4.0 is on this computer. The starter kit uses its own Exasol Personal 2.5.0, so yours is not changed.")
    Check "...and installs the kit's own 2.5 (the download is reached), never the A6 stop" "download (fixture)|True" "$($script:stepThrew)|$(Test-Path $downloadMarker)"
    Check "...as a separate program in the kit's home, never on PATH" $script:PersonalSeparateBinPath $script:PersonalBinPath
    Check "...which every kit command runs from now on" $script:PersonalSeparateBinPath (& { $rpAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/runtime-personal.ps1"), [ref]$null, [ref]$null); Invoke-Expression ($rpAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-PersonalCli" }, $true).Extent.Text); Get-PersonalCli })
    Check "...their launcher is untouched" $hash24 ((Get-FileHash $stub24).Hash)
    Check "...and never recorded as the kit's or as reused" "" ("" + $script:mf["components.personal.ownership"])
    # THEIR exasol.exe AT THE KIT'S DEFAULT PATH (%USERPROFILE%\.local\bin,
    # no receipt of the kit's): the kit never writes there. Its own program
    # goes only to its home, and the receipt names that one.
    $theirsAtKitPath = Join-Path $script:BinDir "exasol.exe"
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Copy-Item -LiteralPath $stub24 -Destination $theirsAtKitPath -Force
    $hashAtKitPath = (Get-FileHash $theirsAtKitPath).Hash
    $saved = @{}
    foreach ($fn in @("Get-PersonalLauncherDownload", "Set-ExakitComponentOwnership", "Reset-PersonalDeployFollow", "OkStep")) {
        $saved[$fn] = (Get-Item -LiteralPath "function:$fn" -ErrorAction SilentlyContinue)
    }
    function Get-PersonalLauncherDownload { param($Version, $TmpDir) $f = Join-Path $TmpDir "exasol.exe"; Set-Content -Path $f -Value "kit 2.5.0" -Encoding Ascii; return $f }
    function Set-ExakitComponentOwnership { param($Id, $Owner, $Path) $script:mf["components.$Id.ownership"] = $Owner; $script:mf["components.$Id.ownership_path"] = $Path }
    function Reset-PersonalDeployFollow { }
    function OkStep([string]$Msg) { $script:said += "OK $Msg" }
    $pAtKit = Plan $theirsAtKitPath
    Step1 $theirsAtKitPath
    Check "their 2.4 at the kit's own default path: S, the kit's program installed" "S|" "$($pAtKit.Mode)|$($script:stepThrew)"
    Check "...never written there: their file is as it was" $hashAtKitPath ((Get-FileHash $theirsAtKitPath).Hash)
    Check "...the kit's own program only in its home" "True|kit 2.5.0" ("{0}|{1}" -f (Test-Path -LiteralPath $script:PersonalSeparateBinPath), ((Get-Content -Raw -LiteralPath $script:PersonalSeparateBinPath).Trim()))
    Check "...its receipt: the kit's, at that path" "kit|$($script:PersonalSeparateBinPath)" ("{0}|{1}" -f $script:mf["components.personal.ownership"], $script:mf["components.personal.ownership_path"])
    foreach ($fn in $saved.Keys) {
        if ($saved[$fn]) { Set-Item -LiteralPath "function:$fn" -Value $saved[$fn].ScriptBlock }
        else { Remove-Item -LiteralPath "function:$fn" -ErrorAction SilentlyContinue }
    }
    Remove-Item -Force -LiteralPath $theirsAtKitPath, $script:PersonalSeparateBinPath -ErrorAction SilentlyContinue
    $script:mf = @{}
    Step1 $stub23
    Check "S: the user's 2.3 too" "S|INFO Exasol Personal 2.3.1 is on this computer. The starter kit uses its own Exasol Personal 2.5.0, so yours is not changed." "$((Get-PersonalLauncherPlan).Mode)|$(@($script:said)[0])"
    $p = Plan $stub26
    Check "A6: the user's 2.6, newer than the pinned line" "A6|newer" "$($p.Mode)|$($p.Why)"
    Step1 $stub26
    Check "...Step 1/4 stops with the sentence" "This Exasol Personal is newer than the starter kit supports. The starter kit needs Exasol Personal 2.5." $script:stepThrew
    Check "...nothing is downloaded" $false (Test-Path $downloadMarker)
    $script:mf["kit.version"] = "0.3.1"
    Step1 $stub26
    Check "...naming the kit's version when it is recorded" "This Exasol Personal is newer than the starter kit supports. The starter kit 0.3.1 needs Exasol Personal 2.5." $script:stepThrew
    $script:mf.Remove("kit.version")
    Step1 $stubNone
    Check "S: a launcher whose version cannot be read" "S|INFO An Exasol Personal launcher is on this computer. The starter kit uses its own Exasol Personal 2.5.0, so yours is not changed.|download (fixture)" "$((Get-PersonalLauncherPlan).Mode)|$(@($script:said)[0])|$($script:stepThrew)"
    # Not when the newer launcher is the one the install would warn about: the
    # warning line is for an install the kit already records.
    $null = Plan $stub26
    $script:said = @()
    Write-PersonalLauncherNewerWarning
    Check "A6: no 'uses the launcher it found' line for a new install" "" ($script:said -join "|")

    $p = Plan $stub25
    Check "U: the user's 2.5.0" "U" $p.Mode
    $hash25 = (Get-FileHash $stub25).Hash
    $script:reused = @()
    & {
        function Set-ExakitReusedOwnership { param($Id, $Path) $script:reused += "$Id|$Path" }
        function Invoke-ExakitBounded { param($FilePath, $Arguments, $TimeoutSeconds)
            if ($Arguments[0] -eq 'version') { return "2.5.0" }
            if (($Arguments -join ' ') -eq 'install --help') { return "Available presets:`n  local   Deploy locally" }
            return $null
        }
        Step1 $stub25
    }
    # The kit never runs the user's launcher (Krishna, 24 Nov): next to
    # their 2.5 it installs its own pinned 2.5 in its folder too.
    Check "...Step 1/4 installs the kit's own 2.5 in its folder (the download is reached)" "download (fixture)|True|$(Get-PersonalSeparateBinPath)" "$($script:stepThrew)|$(Test-Path $downloadMarker)|$($script:PersonalBinPath)"
    Check "...theirs is never recorded as reused or as the kit's, only as theirs" "False|$stub25" ("{0}|{1}" -f ($script:reused -contains "personal|$stub25"), $script:mf["components.personal.user_launcher"])
    Check "...the binary is not touched" $hash25 ((Get-FileHash $stub25).Hash)
    $script:mf.Remove("components.personal.user_launcher")
    Check "U: a patch ahead on the pinned line (2.5.3)" "U" (Plan $stub253).Mode
    $null = Plan $stub253
    $null = Get-PersonalLauncherPlan; $null = Get-PersonalLauncherPlan
    Check "the plan is decided once per process: one 'version' for three asks" "version" (Get-VersionCalls)

    # An install the kit records keeps its launcher: no mode, and the one
    # warning line for a newer launcher, as before. Recorded: a database of
    # the kit's, run by the user's launcher (a 0.3.0 kit that used it).
    $script:mf["components.personal.ownership"] = "user"
    $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = (Join-Path $newRoot "default")
    New-Item -ItemType Directory -Force -Path (Join-Path $newRoot "default") | Out-Null
    Check "recorded: no mode" "" (Plan $stub26).Mode
    $script:said = @()
    Write-PersonalLauncherNewerWarning
    Check "recorded, a 2.6.0 launcher: one warning" "WARN Exasol Personal 2.6.0 is on this computer. This kit is tested with Exasol Personal 2.5.0 and uses the launcher it found." ($script:said -join "|")
    Check "...a sentence without a semicolon" $false (($script:said -join "|").Contains(";"))
    $script:said = @()
    $null = Plan $stub253
    Write-PersonalLauncherNewerWarning
    Check "recorded, a 2.5.3 launcher (the pinned line): nothing said" "" ($script:said -join "|")
    # That database deleted by hand, run by a launcher of theirs (WP2-02): the
    # new one is a new install's, and the kit never makes it with their
    # launcher, whoever owned it.
    Remove-Item -Recurse -Force (Join-Path $newRoot "default")
    foreach ($goneOwner in @("user", "kit")) {
        $script:mf = @{}
        $script:mf["components.personal.ownership"] = "user"; $script:mf["components.personal.ownership_path"] = $stub24
        $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = (Join-Path $newRoot "default")
        $script:mf["runtime.ownership"] = $goneOwner; $script:mf["runtime.ownership_path"] = (Join-Path $newRoot "default"); $script:mf["runtime.deployment_id"] = "exa-gone"
        Check "gone (owner $goneOwner), their 2.4, 2.5, 2.6, unread: S, U, A6, S" "S U A6 S" (@(@($stub24, $stub25, $stub26, $stubNone) | ForEach-Object { (Plan $_).Mode }) -join " ")
        Step1 $stub24
        Check "...Step 1/4 installs the kit's own 2.5 in its folder, theirs is not touched" "download (fixture)|$(Get-PersonalSeparateBinPath)|$hash24" "$($script:stepThrew)|$($script:PersonalBinPath)|$((Get-FileHash $stub24).Hash)"
        $script:mf["components.personal.ownership"] = "kit"
        Check "...the kit's own launcher keeps it: no mode" "" (& { function Test-ExakitComponentManaged { param([string]$Id) return $true }; (Plan $stub24).Mode })
    }
    $script:mf = @{}
    $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = (Join-Path $newRoot "default")
    Check "a database the kit records: no mode either" "" (Plan $stub24).Mode
    $script:mf = @{}
    $script:mf["components.personal.ownership"] = "kit"
    Check "the kit's own launcher recorded, no database: no mode (it keeps its launcher)" "" (Plan $stub24).Mode
    $script:mf = @{}

    Write-Host "== a 0.3.0 kit that was answered No: the user's launcher recorded, no database"
    # The 0.3.0 installer recorded the launcher it found (theirs) and, on
    # Windows, the database receipt it wrote before asking, but no database:
    # the installer run again follows the new-user rules (SPEC, the existing
    # users' table), never "an existing install keeps its launcher". Next to
    # their 2.4 or a newer line that is the A6 stop, with their 2.5 the
    # launcher as it is and then the one question. Twin of the M1 cases in
    # personal-named-deploy.sh.
    function Set-Answered030No([string]$Cli) {
        $script:mf = @{}
        $script:mf["components.personal.ownership"] = "user"; $script:mf["components.personal.ownership_path"] = $Cli
        $script:mf["runtime.ownership"] = "user"; $script:mf["runtime.ownership_path"] = (Join-Path $legacyRoot "default")
    }
    Set-Answered030No $stub24
    $p = Plan $stub24
    Check "their 2.4: S, as for a new user (Krishna Q2)" "S|older" "$($p.Mode)|$($p.Why)"
    Step1 $stub24
    Check "...Step 1/4 installs the kit's own 2.5 (the download is reached)" "download (fixture)" $script:stepThrew
    Check "...as the separate program, their launcher untouched" "$($script:PersonalSeparateBinPath)|$hash24" "$($script:PersonalBinPath)|$((Get-FileHash $stub24).Hash)"
    Set-Answered030No $stub26
    Check "their 2.6: A6, newer" "A6|newer" "$((Plan $stub26).Mode)|$((Plan $stub26).Why)"
    $script:said = @()
    Write-PersonalLauncherNewerWarning
    Check "...no 'uses the launcher it found' line" "" ($script:said -join "|")
    Set-Answered030No $stub25
    Check "their 2.5: U, used as it is" "U" (Plan $stub25).Mode
    # THE 0.3.0 RUN ALSO TICKED STEP 1, with their launcher (found on macOS,
    # round 4: there the tick made Step 1 "already done" and nothing installed
    # the kit's launcher). Through the real Begin-ExakitStep: the tick never
    # skips the A6 stop, and with their 2.5 (U) Step 1 runs too: the kit
    # has no launcher of its own yet, and never runs theirs (WP2-03).
    $realStepDone = ${function:Test-ExakitStepDone}
    function Test-ExakitStepDone { param([string]$Step) return ($Step -eq "launcher") }
    function Step1Ticked([string]$Cli) {
        $null = Plan $Cli
        $script:said = @()
        Remove-Item -Force $downloadMarker -ErrorAction SilentlyContinue
        $script:stepThrew = ""; $script:step1Ran = $false
        try {
            if (Begin-ExakitStep "launcher" "Step 1/4  Exasol launcher" 6>$null) { $script:step1Ran = $true; Install-PersonalLauncher 6>$null }
        } catch { $script:stepThrew = "$($_.Exception.Message)" }
    }
    Set-Answered030No $stub24
    Step1Ticked $stub24
    Check "Step 1 ticked by the 0.3.0 run, their 2.4: Step 1 runs, and installs the kit's own 2.5" "True|download (fixture)" "$($script:step1Ran)|$($script:stepThrew)"
    Check "...their launcher untouched" $hash24 ((Get-FileHash $stub24).Hash)
    Check "...no 'Recorded as done' line for a tick that was never the kit's (Krishna Q27)" "" (($script:said | Where-Object { "$_" -like "*Recorded as done*" }) -join "|")
    Set-Answered030No $stub26
    Step1Ticked $stub26
    Check "...ticked, their 2.6: Step 1 runs, and A6 (newer) stops it" "True|This Exasol Personal is newer than the starter kit supports. The starter kit needs Exasol Personal 2.5." "$($script:step1Ran)|$($script:stepThrew)"
    Set-Answered030No $stub25
    Step1Ticked $stub25
    Check "...ticked, their 2.5 (U): Step 1 runs, and installs the kit's own 2.5" "True|download (fixture)" "$($script:step1Ran)|$($script:stepThrew)"
    Check "...quietly too" "" (($script:said | Where-Object { "$_" -like "*Recorded as done*" }) -join "|")
    Set-Answered030No $noLauncher
    Step1Ticked $noLauncher
    Check "...ticked, their launcher gone since (K): Step 1 runs" "K|True|download (fixture)" "$((Plan $noLauncher).Mode)|$($script:step1Ran)|$($script:stepThrew)"
    Set-Answered030No $stub25
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Get-PersonalSeparateBinPath)) | Out-Null
    Set-Content -Path (Get-PersonalSeparateBinPath) -Value "the kit's 2.5" -Encoding Ascii
    Step1Ticked $stub25
    Remove-Item -Force (Get-PersonalSeparateBinPath)
    Check "...ticked, the kit's own in its folder already: kept" "False|" "$($script:step1Ran)|$($script:stepThrew)"
    $script:mf = @{}
    $script:mf["components.personal.ownership"] = "kit"
    Step1Ticked $stub24
    Check "...the kit's own launcher recorded (no mode): its tick kept as before" "False|" "$($script:step1Ran)|$($script:stepThrew)"
    $script:mf = @{}
    Step1Ticked $noLauncher
    Check "...K (no launcher of theirs) with a tick: kept as before" "K|False|" "$((Plan $noLauncher).Mode)|$($script:step1Ran)|$($script:stepThrew)"
    Set-Item -Path function:Test-ExakitStepDone -Value $realStepDone
    $script:mf = @{}

    Write-Host "== a user's 2.6.0 at the kit's own path, that folder not on PATH (OWN-03)"
    # The plan and the install read the same launcher (Get-PersonalCli): the
    # user's own at the kit's path is never replaced. A new install next to it
    # stops at Step 1/4; nothing is downloaded and the binary is not touched.
    $own03 = Join-Path $work "own03"
    New-Item -ItemType Directory -Force -Path $own03 | Out-Null
    if ($onWindows) {
        $own03Bin = Join-Path $own03 "exasol.cmd"
        Set-Content -Path $own03Bin -Encoding Ascii -Value @('@echo off', 'if "%~1"=="version" echo 2.6.0',
            'if "%~1"=="install" echo Available presets:', 'if "%~1"=="install" echo   local   Deploy locally', 'exit /b 0')
    } else {
        $own03Bin = Join-Path $own03 "exasol"
        Set-Content -Path $own03Bin -Encoding Ascii -Value @('#!/bin/sh',
            'case "$1" in version) echo 2.6.0 ;; install) printf "Available presets:\n  local   Deploy locally\n" ;; esac', 'exit 0')
        & chmod +x $own03Bin
    }
    $own03Hash = (Get-FileHash $own03Bin).Hash
    $savedBinPath = $script:PersonalBinPath
    $script:PersonalBinPath = $own03Bin
    $rpAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/runtime-personal.ps1"), [ref]$null, [ref]$null)
    $realCli = $rpAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-PersonalCli" }, $true).Extent.Text
    & {
        # The real resolution: the suite stubs Get-PersonalCli for its other cases.
        Invoke-Expression $realCli
        $script:PersonalLauncherPlan = $null
        $script:said = @()
        Remove-Item -Force $downloadMarker -ErrorAction SilentlyContinue
        Write-PersonalLauncherNewerWarning
        $script:stepThrew = ""
        try { Install-PersonalLauncher 6>$null } catch { $script:stepThrew = "$($_.Exception.Message)" }
    }
    $script:PersonalBinPath = $savedBinPath
    Check "own path, off PATH: no warning line" "" (@($script:said | Where-Object { $_ -like "WARN *" }) -join "|")
    Check "...Step 1/4 stops" "This Exasol Personal is newer than the starter kit supports. The starter kit needs Exasol Personal 2.5." $script:stepThrew
    Check "...downloads nothing" $false (Test-Path $downloadMarker)
    Check "...the binary is not touched" $own03Hash ((Get-FileHash $own03Bin).Hash)

    Write-Host "== which database a new install uses: the one question (CONTRACT section 4)"
    & {
    # The user's 2.5 as a stand-in at the PowerShell level: every launcher call
    # recorded in $script:lcalls, its answers from the fixture below.
    $script:fakeCli = Join-Path $work "exasol-fake"
    Set-Content -Path $script:fakeCli -Value "fake" -Encoding Ascii
    $script:lcalls = @()
    $script:stopRc = 0; $script:startRc = 0; $script:stopLies = $false
    $script:recheck = @{}
    function Get-PersonalCli { return $script:fakeCli }
    function Invoke-ExakitBounded {
        param([string]$FilePath, [string[]]$Arguments = @(), [string]$ArgumentString = "", [int]$TimeoutSeconds = 8)
        $line = ($Arguments -join " ")
        $script:lcalls += "bounded: $line"
        if ($line -eq "version") { return "2.5.0" }
        if ($line -eq "deployments list --json") { return $script:listJson }
        if ($line -eq "install local --help") { return "Flags:`n      --container-engine string`n      --ports string`n" }
        if ($Arguments.Count -ge 2 -and $Arguments[0] -eq "status" -and $Arguments[1] -eq "--json") {
            $dir = $Arguments[$Arguments.Count - 1]
            if ($script:recheck.ContainsKey($dir)) { return ('{"deploymentDir": "x", "status": "' + $script:recheck[$dir] + '"}') }
            return '{"status": "stopped"}'
        }
        if ($Arguments.Count -ge 1 -and $Arguments[0] -eq "info") { if (Test-Path -LiteralPath $Arguments[$Arguments.Count - 1]) { return "info" }; return $null }
        return $null
    }
    function Invoke-ExakitLogged {
        $line = (@($args | Select-Object -Skip 1) -join " ")
        $script:lcalls += "logged: $line"
        # What the launcher says of a deployment follows its stop and start,
        # unless the case has a launcher whose stop answers 0 over nothing
        # ($script:stopLies).
        $of = "" + $args[$args.Count - 1]
        if ($args[1] -eq "stop") {
            if ($script:stopRc -eq 0 -and -not $script:stopLies) { $script:recheck[$of] = "stopped" }
            return $script:stopRc
        }
        if ($args[1] -eq "start") { if ($script:startRc -eq 0) { $script:recheck[$of] = "database_ready" }; return $script:startRc }
        if ($args[1] -eq "install") {
            # The launcher makes the deployment where it is told, on the port it is given.
            $at = [array]::IndexOf([string[]]@($args), "--deployment-dir")
            $dir = $args[$at + 1]
            $port = 8563
            $pa = [array]::IndexOf([string[]]@($args), "--ports")
            if ($pa -ge 0 -and "$($args[$pa + 1])" -match '^db:(\d+)$') { $port = [int]$Matches[1] }
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -Path (Join-Path $dir "deployment.json") -Encoding Ascii -Value ('{"deploymentId": "exa-kit-new", "connection": {"host": "127.0.0.1", "dbPort": ' + $port + ', "username": "sys"}}')
            return 0
        }
        return 0
    }
    function Deny-ExakitInput { param([string]$Message, $Remedy = $null) throw "DENIED: $Message" }
    function Write-ExakitLog { }
    # A deployment of the user's: its folder, its launcher id and port.
    function New-UserDeployment([string]$Root, [string]$Name, [int]$Port) {
        $dir = Join-Path $Root $Name
        New-Item -ItemType Directory -Force -Path (Join-Path $dir "local\runtime") | Out-Null
        Set-Content -Path (Join-Path $dir ".exasolLauncherState.json") -Encoding Ascii -Value ('{"deploymentId": "exa-' + $Name + '"}')
        Set-Content -Path (Join-Path $dir "deployment.json") -Encoding Ascii -Value ('{"deploymentId": "exa-' + $Name + '", "connection": {"host": "127.0.0.1", "dbPort": ' + $Port + ', "username": "sys"}}')
        return $dir
    }
    function Set-List([object[]]$Rows) {
        $items = @()
        foreach ($r in $Rows) { $items += [ordered]@{ name = $r[0]; path = $r[1]; status = $r[2]; infrastructure = $r[3]; installation = 'local' } }
        if ($items.Count -eq 0) { $script:listJson = '[]' } else { $script:listJson = (ConvertTo-Json -InputObject @($items) -Depth 4) }
    }
    # Fresh: a new installer process on this machine (nothing recorded, nothing asked yet).
    function Fresh {
        $script:mf = @{}
        $script:lcalls = @(); $script:said = @()
        $script:stopRc = 0; $script:startRc = 0
        $script:PersonalLauncherAsked = $false; $script:PersonalLauncherListed = $false; $script:PersonalLauncherDeployments = @()
        $script:PersonalLauncherDecided = $false; $script:PersonalDeployRec = ""; $script:PersonalDeployFollowed = ""; $script:PersonalDeployIdSeen = $false
        $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
        $script:PersonalNoDatabase = $false
        $script:PersonalPortPicked = 0
        $script:PersonalLauncherCache = $null
        Remove-Item Env:EXAKIT_REUSE_DB, Env:EXAKIT_PERSONAL_DEPLOY_DIR -ErrorAction SilentlyContinue
        # The state Step 1/4 leaves in every real new install (K and U): the
        # kit's own launcher from its folder, and not mode S. Without it the
        # question ran here in a state no install has.
        $script:PersonalSeparate = $true; $script:PersonalBinSynced = $true
        $script:PersonalBinPath = Get-PersonalSeparateBinPath
        $script:PersonalModeS = $false
    }
    # No port of this machine decides a check: a case that needs one in use
    # says so itself.
    function Test-ExakitPortInUse { return $false }
    function Test-PersonalPortFree { param([int]$Port) return -not (Test-ExakitPortInUse -Port $Port) }
    function Reset-Roots { foreach ($r in @($newRoot, $legacyRoot)) { Remove-Item -Recurse -Force $r -ErrorAction SilentlyContinue } }
    function Calls([string]$Kind) { return ((@($script:lcalls | Where-Object { $_ -like "$($Kind):*" }) | ForEach-Object { $_.Substring($Kind.Length + 2) }) -join " / ") }
    # Verb <kind> <verb>: a call of that launcher verb was made. By the verb,
    # never a word anywhere in the call: the folders it names hold this
    # machine's temp path, which can spell "start".
    function Verb([string]$Kind, [string]$Name) { return (@(@((Calls $Kind) -split ' / ') | Where-Object { $_ -match ('^' + [regex]::Escape($Name) + '( |$)') }).Count -gt 0) }
    $SKL = Join-Path $newRoot "starter-kit-local"
    # The machine: their default (running), dev (stopped), slow (listed as
    # not_initialized: a re-check says stopped), ghost (not_initialized for
    # good), broken (deployment_failed), cloud (aws). Only the first three are
    # offered.
    function Set-Machine {
        Reset-Roots
        $script:def = New-UserDeployment $newRoot "default" 8563
        $script:dev = New-UserDeployment $newRoot "dev" 8564
        $script:slow = New-UserDeployment $newRoot "slow" 8565
        $script:ghost = New-UserDeployment $newRoot "ghost" 8566
        $script:broken = New-UserDeployment $newRoot "broken" 8567
        $script:cloud = Join-Path $newRoot "cloud"
        New-Item -ItemType Directory -Force -Path $script:cloud | Out-Null
        Set-Content -Path (Join-Path $script:cloud ".exasolLauncherState.json") -Encoding Ascii -Value '{"deploymentId": "exa-cloud"}'
        Set-List @(
            @("broken", $script:broken, "deployment_failed", "local"),
            @("cloud", $script:cloud, "stopped", "aws"),
            @("default", $script:def, "database_ready", "local"),
            @("dev", $script:dev, "stopped", "local"),
            @("ghost", $script:ghost, "not_initialized", ""),
            @("slow", $script:slow, "not_initialized", ""))
        $script:recheck = @{}
        $script:recheck[$script:slow] = "stopped"
        $script:recheck[$script:ghost] = "not_initialized"
        $script:recheck[$script:def] = "database_ready"
        $script:stopLies = $false
    }

    Set-Machine; Fresh
    $offered = @(Get-PersonalEligibleDeployments)
    Check "offered: local, running or stopped, sorted, never starter-kit-local" "default:running dev:stopped slow:stopped" (($offered | ForEach-Object { "$($_.Name):$($_.State)" }) -join " ")
    Check "...a not_initialized one is asked again on its own, with 30 s" $true ((Calls "bounded") -like "*status --json --timeout 30 --deployment-dir $($script:slow)*")
    # BYTE ORDER, as the sh twin's `LC_ALL=C sort`: capitals before small
    # letters, '-' before a digit before '_'. The same answer picks the same
    # database on every platform (a culture sort put alpha first and Zeta last).
    Reset-Roots
    $byName = @()
    foreach ($n in @("Zeta", "alpha", "Beta", "dev_2", "dev-2", "dev1")) { $byName += ,@($n, (New-UserDeployment $newRoot $n 8700), "stopped", "local") }
    Set-List $byName
    Fresh
    $sorted = @(Get-PersonalEligibleDeployments)
    Check "the list in byte order, as the sh twin's" "Beta Zeta alpha dev-2 dev1 dev_2" (($sorted | ForEach-Object { $_.Name }) -join " ")
    Check "...and the names an answer may give, in that order" "reject:EXAKIT_REUSE_DB=x is not a database the kit can use. Set it to one of these names: Beta, Zeta, alpha, dev-2, dev1, dev_2. Or set it to 0 for a new database." ("reject:" + (Resolve-PersonalReuseDbAnswer -Deployments $sorted -Value "x").Message)

    Write-Host "== Step 1/4 and the one question in one installer run: K and U ask, S never does"
    # The real Install-PersonalLauncher decides the mode, then the real
    # Select-PersonalDatabase runs in the same process, as in the installer.
    function Step1Then([string]$Mode, [scriptblock]$Then) {
        function Get-PersonalLauncherPlan { return [pscustomobject]@{ Mode = $Mode; Launcher = "theirs.exe"; Version = "2.4.0"; Why = "older"; Legacy = @() } }
        function Get-PersonalLauncherDownload { param($Version, $TmpDir) $f = Join-Path $TmpDir "exasol.exe"; Set-Content -Path $f -Value "kit 2.5.0" -Encoding Ascii; return $f }
        function Set-ExakitComponentOwnership { param($Id, $Owner, $Path) $script:mf["components.$Id.ownership"] = $Owner; $script:mf["components.$Id.ownership_path"] = $Path }
        function OkStep { }
        # The launcher the kit runs, as Step 1/4 leaves it.
        function Get-PersonalCli { return $script:PersonalBinPath }
        $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false
        $script:PersonalBinPath = Join-Path $script:BinDir "exasol.exe"
        $script:PersonalLauncherPlan = $null
        Remove-Item -Force -LiteralPath (Get-PersonalSeparateBinPath) -ErrorAction SilentlyContinue
        Install-PersonalLauncher 6>$null
        $script:said = @()
        try { & $Then } catch { "$($_.Exception.Message)" } finally { Remove-Item -Force -LiteralPath (Get-PersonalSeparateBinPath) -ErrorAction SilentlyContinue }
    }
    function Test-PersonalPromptable { return $false }
    foreach ($mode in @("U", "K")) {
        Set-Machine; Fresh
        $env:EXAKIT_REUSE_DB = "dev"
        Check "mode ${mode}: EXAKIT_REUSE_DB=dev picks their dev" "renamed" (Step1Then $mode { Select-PersonalDatabase 6>$null })
        Set-Machine; Fresh
        $env:EXAKIT_REUSE_DB = "1"
        Check "mode ${mode}: EXAKIT_REUSE_DB=1 picks their default" "renamed" (Step1Then $mode { Select-PersonalDatabase 6>$null })
        Set-Machine; Fresh
        Check "mode ${mode}: no answer and no terminal: a new one, with line 1" "new|INFO Exasol Personal 2.5 is on this computer, with 3 databases of yours." ("{0}|{1}" -f (Step1Then $mode { Select-PersonalDatabase 6>$null }), ($script:said -join "|"))
    }
    Set-Machine; Fresh
    Check "mode S: a new one, nothing asked or listed" "new|" ("{0}|{1}" -f (Step1Then "S" { Select-PersonalDatabase 6>$null }), ($script:said -join "|"))
    Check "...recorded, so a resumed install knows it" "S" ("" + $script:mf["components.personal.mode"])
    # The install resumed in a new process: only the record says it is mode S.
    $script:PersonalModeS = $false; $script:said = @()
    Check "mode S resumed: a new one, nothing asked or listed" "new|" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), ($script:said -join "|"))
    Set-Machine; Fresh
    $script:mf["components.personal.mode"] = "S"
    $null = Step1Then "U" { "" }
    Check "a later install in mode U drops the record of mode S" "" ("" + $script:mf["components.personal.mode"])

    # Their launcher with nothing listed: the deploy still says theirs is not
    # changed (approved line 4), as on macOS and Linux.
    foreach ($mode in @("U", "S")) {
        Reset-Roots; Set-List @(); Fresh
        $next = Step1Then $mode { $null = Select-PersonalDatabase 6>$null; "$($script:PersonalNewNextToTheirs)" }
        Check "mode ${mode}, a launcher of theirs and no database listed: the new one is next to theirs" "True" $next
    }
    Reset-Roots; Set-List @(); Fresh
    Check "mode K, nothing of theirs: it is not" "False" (Step1Then "K" { $null = Select-PersonalDatabase 6>$null; "$($script:PersonalNewNextToTheirs)" })

    Write-Host "== EXAKIT_REUSE_DB has its own parser (not the yes/no one)"
    function Answer([string]$Value, [object[]]$Offer) {
        $a = Resolve-PersonalReuseDbAnswer -Deployments $Offer -Value $Value
        if ($a.Kind -eq "pick") { return "pick:$($a.Pick.Name)" }
        if ($a.Kind -eq "reject") { return "reject:$($a.Message)" }
        return $a.Kind
    }
    Check "unset: ask" "ask" (Answer "" $offered)
    foreach ($v in @("0", "n", "N", "no", "NO", "No", "new")) { Check "'$v': a new database" "new" (Answer $v $offered) }
    Check "'NEW' is not the word new (the sh side's list): a name, and none of theirs" $true ((Answer "NEW" $offered) -like "reject:*")
    Check "a name: that one" "pick:dev" (Answer "dev" $offered)
    Check "a name with a space after it: refused, as on macOS and Linux" $true ((Answer "dev " $offered) -like "reject:*")
    Check "a name in the wrong case: not one of theirs" $true ((Answer "Dev" $offered) -like "reject:*")
    Check "a name not offered (a cloud one): refused, naming what can be given" "reject:EXAKIT_REUSE_DB=cloud is not a database the kit can use. Set it to one of these names: default, dev, slow. Or set it to 0 for a new database." (Answer "cloud" $offered)
    foreach ($v in @("1", "y", "yes", "YES")) { Check "'$v' (0.3.0 scripts): their default" "pick:default" (Answer $v $offered) }
    $noDefault = @($offered | Where-Object { $_.Name -ne "default" })
    Check "'1' with several and none named default: refused" "reject:EXAKIT_REUSE_DB=1 does not say which of your databases the kit should use. Set it to one of these names: dev, slow. Or set it to 0 for a new database." (Answer "1" $noDefault)
    Check "'1' with exactly one: that one" "pick:slow" (Answer "1" @($offered | Where-Object { $_.Name -eq "slow" }))
    Check "'1' with none offered: a new database (0.3.0 deployed one too)" "new" (Answer "1" @())
    Check "a name with none offered: refused" "reject:EXAKIT_REUSE_DB=dev is not a database the kit can use on this computer. Unset it, or set it to 0, for a new database." (Answer "dev" @())
    Check "no answer has a semicolon" $false ((Answer "cloud" $offered).Contains(";") -or (Answer "1" $noDefault).Contains(";"))

    Write-Host "== no terminal and no answer: a new database (D1)"
    Set-Machine; Fresh
    function Test-PersonalPromptable { return $false }
    $choice = Select-PersonalDatabase 6>$null
    Check "the choice" "new" $choice
    Check "...the kit's folder is starter-kit-local" $SKL $script:PersonalDeployDir
    Check "...line 1 (line 4 comes with the deploy)" "INFO Exasol Personal 2.5 is on this computer, with 3 databases of yours." ($script:said -join "|")
    Check "...which is told it is next to theirs" $true $script:PersonalNewNextToTheirs
    Check "...none of theirs stopped, started or renamed" "" (Calls "logged")
    Check "...their default is where it was" $true (Test-Path (Join-Path $script:def "deployment.json"))
    Check "...nothing recorded yet" "" ("" + $script:mf["runtime.ownership"])

    Write-Host "== the terminal answer"
    Set-Machine; Fresh
    function Test-PersonalPromptable { return $true }
    $script:answers = New-Object System.Collections.Queue
    function Read-Host { if ($script:answers.Count -gt 0) { return $script:answers.Dequeue() }; return "" }
    $script:answers.Enqueue("")
    $shown = (& { [void](Select-PersonalDatabase) } 6>&1 | Out-String)
    Check "Enter: a new database" "$SKL|" ("{0}|{1}" -f $script:PersonalDeployDir, ("" + $script:mf["runtime.ownership"]))
    Check "...the question" $true ($shown.Contains("Which database should the starter kit use?"))
    Check "...1, a new one, recommended" $true ($shown.Contains("1) A new database 'starter-kit-local' (recommended)"))
    Check "...then theirs, with their state" $true ($shown.Contains("2) default (running)") -and $shown.Contains("3) dev (stopped)") -and $shown.Contains("4) slow (stopped)"))
    Check "...and the prompt" $true ($shown.Contains("Choose 1-4 [1]: "))
    Check "...no semicolon on the screen" $false ($shown.Contains(";"))
    Set-Machine; Fresh
    $script:answers.Clear(); foreach ($a in @("9", "x", "dev", "0", "-2")) { $script:answers.Enqueue($a) }
    $shown = (& { $script:choiceShown = Select-PersonalDatabase } 6>&1 | Out-String)
    Check "five answers that are no number of the list: a new database" "new" $script:choiceShown
    Check "...each but the last told what to answer" 4 ([regex]::Matches($shown, "Answer with a number from 1 to 4\.").Count)
    Check "...a name is not an answer either" "" (Calls "logged")
    # A leading zero is the same number, as the sh twin reads it: 01 is 1, 03
    # is 3. All zeros, or a number too long to be a choice, is asked again,
    # never an error.
    Set-Machine; Fresh
    $script:answers.Clear(); $script:answers.Enqueue("01")
    $choice = ""
    try { $shown = (& { $script:choiceShown = Select-PersonalDatabase } 6>&1 | Out-String); $choice = $script:choiceShown } catch { $choice = "threw: $($_.Exception.Message)" }
    Check "01: a new database, as 1, not asked again" "new|0" ("{0}|{1}" -f $choice, [regex]::Matches($shown, "Answer with a number from 1 to 4\.").Count)
    Set-Machine; Fresh
    $script:answers.Clear(); foreach ($a in @("99999999999999999999", "00", "03")) { $script:answers.Enqueue($a) }
    $choice = ""
    try { $shown = (& { $script:choiceShown = Select-PersonalDatabase } 6>&1 | Out-String); $choice = $script:choiceShown } catch { $choice = "threw: $($_.Exception.Message)" }
    Check "a number too long, then 00, both asked again, then 03: dev, as 3" "renamed|exa-dev|2" ("{0}|{1}|{2}" -f $choice, (Read-PersonalDeploymentId -Dir $SKL), [regex]::Matches($shown, "Answer with a number from 1 to 4\.").Count)

    Write-Host "== one of theirs picked: renamed to starter-kit-local (REN)"
    Set-Machine; Fresh
    $script:answers.Clear(); $script:answers.Enqueue("3")
    $choice = Select-PersonalDatabase 6>$null
    Check "3 (dev, stopped): renamed" "renamed" $choice
    Check "...no stop: it was stopped" "" (Calls "logged")
    Check "...its folder is starter-kit-local now, in the same root" $true ((Test-Path (Join-Path $SKL "deployment.json")) -and -not (Test-Path $script:dev))
    Check "...with its data" "exa-dev" (Read-PersonalDeploymentId -Dir $SKL)
    Check "...the kit's folder is it" $SKL $script:PersonalDeployDir
    Check "...recorded: folder, name, id, the user's" "$SKL|starter-kit-local|exa-dev|user|$SKL" ("{0}|{1}|{2}|{3}|{4}" -f $script:mf["runtime.deployment_dir"], $script:mf["runtime.deployment_name"], $script:mf["runtime.deployment_id"], $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"])
    Check "...line 1, then line 3" ("INFO Exasol Personal 2.5 is on this computer, with 3 databases of yours.|OK Your database 'dev' is now 'starter-kit-local'. The kit uses it and never deletes it.") (@($script:said | Where-Object { $_ -like "INFO *" -or $_ -like "OK *" }) -join "|")
    Check "...their others are not touched" $true ((Test-Path (Join-Path $script:def "deployment.json")) -and (Test-Path (Join-Path $script:slow "deployment.json")))
    Check "...the database is the user's: never destroyed" "user" (Get-ExakitComponentOwnership "database")
    Check "...its port is free: no port change (Q12)" $false (Verb "logged" "config")
    # Q12 (Krishna, 24 Nov): its saved port (8564) is held now by another
    # database: while it is stopped it gets the next free port, past the
    # ports the others have saved (8563, 8565, 8566, 8567).
    $realInUse = ${function:Test-ExakitPortInUse}
    function Test-ExakitPortInUse { param([int]$Port, [string]$ComputerName = "127.0.0.1", [int]$TimeoutMs = 700) return ($Port -eq 8564) }
    Set-Machine; Fresh
    $script:answers.Clear(); $script:answers.Enqueue("3")
    $choice = Select-PersonalDatabase 6>$null
    Check "its saved port held by another database (Q12): renamed, moved to the next free port" "renamed|config set --ports db:8568 --deployment-dir $SKL" ("{0}|{1}" -f $choice, (Calls "logged"))
    Check "...one line says so" $true ($script:said -contains "INFO Port 8564 is in use by another database, so your database 'starter-kit-local' now uses port 8568.")
    Set-Item -Path function:Test-ExakitPortInUse -Value $realInUse
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "default"
    $script:answers.Clear()
    $choice = Select-PersonalDatabase 6>$null
    Check "EXAKIT_REUSE_DB=default (running), on a terminal too: renamed, nothing asked" "renamed" $choice
    Check "...stopped first, by its own folder" "stop --deployment-dir $($script:def)" (Calls "logged")
    Check "...renamed" $true (Test-Path (Join-Path $SKL "deployment.json"))
    Check "...not started here (the deploy step starts it, once)" $false (Verb "logged" "start")
    function Test-PersonalPromptable { return $false }
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "1"
    $choice = Select-PersonalDatabase 6>$null
    Check "EXAKIT_REUSE_DB=1, no terminal: their default" "renamed|exa-default" "$choice|$(Read-PersonalDeploymentId -Dir $SKL)"
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "0"
    Check "EXAKIT_REUSE_DB=0: a new database" "new" (Select-PersonalDatabase 6>$null)
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "ghost"
    $denied = ""
    try { $null = Select-PersonalDatabase 6>$null } catch { $denied = "$($_.Exception.Message)" }
    Check "EXAKIT_REUSE_DB names one that is not offered: refused before anything changes" $true ($denied -eq "DENIED: EXAKIT_REUSE_DB=ghost is not a database the kit can use. Set it to one of these names: default, dev, slow. Or set it to 0 for a new database.")
    Check "...nothing stopped or renamed" "" (Calls "logged")
    Check "...their ghost stays" $true (Test-Path $script:ghost)

    Write-Host "== the launcher's own word after the question, never the state listed before it (RGR-01)"
    # Listed stopped, started by the user while the question waited: stopped
    # first. A stop that answers 0 is not "stopped".
    Set-Machine; Fresh
    $script:recheck[$script:dev] = "database_ready"
    $env:EXAKIT_REUSE_DB = "dev"
    $choice = Select-PersonalDatabase 6>$null
    Check "listed stopped, running now: stopped, then renamed" "renamed|stop --deployment-dir $($script:dev)|exa-dev" ("{0}|{1}|{2}" -f $choice, (Calls "logged"), (Read-PersonalDeploymentId -Dir $SKL))
    foreach ($lie in @("database_ready", "")) {
        foreach ($pick in @("dev", "default")) {
            Set-Machine; Fresh
            $dirOf = $(if ($pick -eq "dev") { $script:dev } else { $script:def })
            $script:recheck[$dirOf] = $lie
            $script:stopLies = $true
            $env:EXAKIT_REUSE_DB = $pick
            $choice = Select-PersonalDatabase 6>$null
            Check "$pick, the stop answers 0 and the launcher still says '$lie': not renamed" "|True|False" ("{0}|{1}|{2}" -f $choice, (Test-Path (Join-Path $dirOf "deployment.json")), (Test-Path $SKL))
            Check "...says why" "WARN Your database '$pick' did not stop, so it was not renamed. Nothing was changed." (@($script:said | Where-Object { $_ -like "WARN *" }) -join "|")
            Check "...nothing recorded, no port changed" "|False" ("{0}|{1}" -f $script:mf["runtime.ownership"], (Verb "logged" "config"))
            # One that ran and does not say that it runs is started again.
            Check "...started again only when it ran and went down" $(if ($pick -eq "default" -and -not $lie) { "True" } else { "False" }) ("{0}" -f (Verb "logged" "start"))
        }
    }
    # A stopped one in the older root: the 2.5 that is asked moves it to its own.
    Reset-Roots; Fresh; $script:recheck = @{}
    $old = New-UserDeployment $legacyRoot "old" 8571
    & {
        function Get-PersonalStateOf { param([string]$Dir)
            if (Test-Path -LiteralPath $old) { New-Item -ItemType Directory -Force -Path $newRoot | Out-Null; [System.IO.Directory]::Move($old, (Join-Path $newRoot "old")) }
            return "stopped" }
        Set-Variable -Name moved -Scope 1 -Value (Rename-PersonalUserDatabase -Pick ([pscustomobject]@{ Name = "old"; Path = $old; Status = "stopped"; State = "stopped" }) 6>$null)
    }
    Check "moved out of the older root by the answer: renamed where it is now" "True|exa-old" ("{0}|{1}" -f $moved, (Read-PersonalDeploymentId -Dir $SKL))

    Write-Host "== the engine on record is the picked database's own (E1)"
    foreach ($own in @("docker", "podman")) {
        Set-Machine; Fresh
        $rtDir = [IO.Path]::Combine($script:dev, "local", "runtime")
        New-Item -ItemType Directory -Force -Path $rtDir | Out-Null
        Set-Content -Path (Join-Path $rtDir "container-engine.json") -Encoding Ascii -Value ('{"engine":"' + $own + '"}')
        # The database before it ran on the other one.
        $script:mf["runtime.engine"] = $(if ($own -eq "docker") { "podman" } else { "docker" })
        $env:EXAKIT_REUSE_DB = "dev"
        $choice = Select-PersonalDatabase 6>$null
        Check "dev on ${own}: recorded with it" "renamed|$own|$own" ("{0}|{1}|{2}" -f $choice, $script:mf["runtime.engine"], (Get-PersonalEngineRecorded))
    }
    Set-Machine; Fresh

    Write-Host "== a record that is cleared is never left reading as the kit's (WP2-06)"
    # The kit's own destroyed, a starter-kit-local of the user's in its place
    # with another id: killed at every write of the clear, and of the record of
    # the user's that follows it.
    $killed = @(); $n = 0
    do {
        $n++
        Reset-Roots; Fresh; $script:recheck = @{}
        New-UserDeployment $newRoot "starter-kit-local" 8600 | Out-Null
        $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = $SKL; $script:mf["runtime.deployment_id"] = "exa-kit-old"
        $script:mf["runtime.deployment_name"] = "starter-kit-local"; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $SKL
        $script:mf["runtime.launcher"] = Join-Path $script:BinDir "exasol.exe"
        $script:writes = 0; $script:done = $false
        & {
            function Set-ExakitManifestValue { param([string]$Path, $Value) if ((++$script:writes) -gt ($n - 1)) { throw "KILLED" }; $script:mf[$Path] = $Value }
            function Remove-ExakitManifestValue { param([string]$Path) if ((++$script:writes) -gt ($n - 1)) { throw "KILLED" }; [void]$script:mf.Remove($Path) }
            try { Clear-PersonalDatabaseRecord; Set-PersonalUserDatabaseRecord -Dir $SKL } catch { }
            if ($script:writes -le ($n - 1)) { $script:done = $true }
        }
        $script:PersonalDeployDir = $SKL; $script:PersonalDeployFollowed = ""; $script:PersonalDeployRec = ""; $script:PersonalLauncherDecided = $false; $script:PersonalDeployIdSeen = $false
        & {
            function Test-ExakitLegacyKitOwned { param([string]$Id) return (("" + $script:mf["runtime.deployment_dir"]) -eq $SKL) }
            if ((Get-ExakitComponentOwnership "database") -eq "kit" -and -not (Get-ExakitPersonalDbState)) { Set-Variable -Name killed -Scope 1 -Value ($killed + "write $n") }
        }
    } while (-not $script:done -and $n -lt 40)
    Check "killed at any write: never the kit's, so no uninstall removes it" "" ($killed -join ", ")
    Check "...every write was tried, and the whole record is the user's" "True|user|exa-starter-kit-local" ("{0}|{1}|{2}" -f ($n -gt 8 -and $n -lt 40), $script:mf["runtime.ownership"], $script:mf["runtime.deployment_id"])
    Reset-Roots; Set-Machine; Fresh

    Write-Host "== what the kit made in one database is not made in another (OWN-07)"
    # The kit's own database missing, and one of theirs picked: the records of
    # the logins and roles the kit made get the old database's id.
    $blocks = @("mcp_server.connection", "exasol_scheduler", "semantic_views", "preprocessor")
    function MadeIn { return ((@($blocks | ForEach-Object { "" + $script:mf["components.$_.made_in"] })) -join ",") }
    function Made([string]$OldId) {
        Set-Machine; Fresh
        foreach ($b in $blocks) { $script:mf["components.$b"] = "recorded" }
        $script:mf["runtime.type"] = "personal"; $script:mf["runtime.ownership"] = "kit"
        $script:mf["runtime.deployment_dir"] = Join-Path $legacyRoot "gone"
        if ($OldId) { $script:mf["runtime.deployment_id"] = $OldId }
        $env:EXAKIT_REUSE_DB = "dev"
        $c = & { function Get-ExakitPersonalDbState { return "kit_database_missing|x|y" }; Select-PersonalDatabase 6>$null }
        Remove-Item Env:EXAKIT_REUSE_DB
        return "$c|$(MadeIn)|$($script:mf["runtime.deployment_id"])"
    }
    Check "dev picked over a missing database: each record says the old one's id" "renamed|exa-old,exa-old,exa-old,exa-old|exa-dev" (Made "exa-old")
    Check "...'unknown' when the old one had none" "renamed|unknown,unknown,unknown,unknown|exa-dev" (Made "")
    Check "...and nothing when it is the same database" "renamed|,,,|exa-dev" (Made "exa-dev")
    Set-Machine; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8600 | Out-Null
    $script:mf["components.semantic_views"] = "recorded"; $script:mf["runtime.deployment_id"] = "exa-old"
    $script:mf["runtime.type"] = "personal"; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.deployment_dir"] = Join-Path $legacyRoot "gone"
    $c = & { function Get-ExakitPersonalDbState { return "kit_database_missing|x|y" }; Select-PersonalDatabase 6>$null }
    Check "one of theirs under the kit's name: the same, only for what is on record" "leftover|,,exa-old," "$c|$(MadeIn)"
    # A database newer than the kit's launcher is refused before anything.
    Set-Machine; Fresh
    Set-Content -Path (Join-Path $script:dev ".exasolLauncher.version") -Value "2.6.1" -Encoding Ascii
    $env:EXAKIT_REUSE_DB = "dev"
    $choice = Select-PersonalDatabase 6>$null
    Remove-Item Env:EXAKIT_REUSE_DB
    Check "a picked database newer than the kit's launcher: not stopped, not renamed, said" "|True|False|The Exasol Personal deployment on this machine is version 2.6.1, which is newer than the launcher version this kit advertises (2.5.0)." ("{0}|{1}|{2}|{3}" -f $choice, (Test-Path $script:dev), (Verb "logged" "stop"), (Get-ExakitFailureReason))

    Write-Host "== a rename that cannot happen puts everything back"
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "default"
    $script:stopRc = 1
    $choice = Select-PersonalDatabase 6>$null
    Check "the stop fails: no database step" "" $choice
    Check "...nothing renamed" $true ((Test-Path $script:def) -and -not (Test-Path $SKL))
    Check "...not started again (it never stopped)" $false (Verb "logged" "start")
    Check "...nothing recorded" "" ("" + $script:mf["runtime.ownership"])
    Check "...says why" "WARN Your database 'default' did not stop, so it was not renamed. Nothing was changed." (@($script:said | Where-Object { $_ -like "WARN *" }) -join "|")
    Check "...the reason for the summary" "Your database 'default' did not stop, so it was not renamed" (Get-ExakitFailureReason)
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "default"
    # A launcher command at work on it: the rename refuses, the database that
    # was running is started again.
    Set-Content -Path (Join-Path $script:def ".dirmutex.exclusive") -Value "" -Encoding Ascii
    $choice = Select-PersonalDatabase 6>$null
    Check "the folder is held: no database step" "" $choice
    Check "...nothing renamed" $true ((Test-Path $script:def) -and -not (Test-Path $SKL))
    Check "...stopped, then started again, by its own folder" "stop --deployment-dir $($script:def) / start --deployment-dir $($script:def)" (Calls "logged")
    Check "...says why" "WARN Your database 'default' was not renamed to 'starter-kit-local', because another Exasol Personal command is using it. Nothing was changed." (@($script:said | Where-Object { $_ -like "WARN *" }) -join "|")
    Remove-Item -Force (Join-Path $script:def ".dirmutex.exclusive")
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "default"
    $script:startRc = 1
    Set-Content -Path (Join-Path $script:def ".dirmutex.exclusive") -Value "" -Encoding Ascii
    $null = Select-PersonalDatabase 6>$null
    Check "...and when it does not start again, that is said with its own command" $true ($script:said -contains "WARN Your database 'default' did not start again. Start it with: exasol start -d default")
    Remove-Item -Force (Join-Path $script:def ".dirmutex.exclusive")
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "dev"
    & {
        function Set-PersonalUserDatabaseRecord { param([string]$Dir) $script:mf["runtime.deployment_dir"] = $Dir; throw "manifest locked (fixture)" }
        $script:choiceInside = Select-PersonalDatabase 6>$null
    }
    Check "the record cannot be written: no database step" "" $script:choiceInside
    Check "...renamed back" $true ((Test-Path (Join-Path $script:dev "deployment.json")) -and -not (Test-Path $SKL))
    Check "...the record cleared" "" ("" + $script:mf["runtime.deployment_dir"])
    Check "...says why" $true ($script:said -contains "WARN Your database 'dev' was not renamed to 'starter-kit-local', because the kit could not write its record. Nothing was changed.")
    Set-Machine; Fresh
    New-UserDeployment $legacyRoot "starter-kit-local" 8570 | Out-Null
    $odd = [pscustomobject]@{ Name = "old"; Path = (New-UserDeployment $legacyRoot "old" 8571); Status = "stopped"; State = "stopped" }
    Check "the name is taken in its root: refused" $false (Rename-PersonalUserDatabase -Pick $odd 6>$null)
    Check "...nothing renamed" $true (Test-Path $odd.Path)
    Check "...says why" $true ($script:said -contains "WARN Your database 'old' was not renamed, because $(Get-ExakitTilde (Join-Path $legacyRoot 'starter-kit-local')) already exists. Nothing was changed.")
    Reset-Roots

    Write-Host "== the helpers phase B reuses: the rename and its undo"
    Fresh
    $from = New-UserDeployment $legacyRoot "default" 8580
    $to = Join-Path $legacyRoot "starter-kit-local"
    $script:mf["runtime.deployment_dir"] = $from; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $from
    $script:mf["components.mcp_server.sidecar_dir"] = $from
    Check "rename: done" $true (Rename-PersonalDeploymentFolder -From $from -To $to)
    Update-PersonalDeploymentRecord -From $from -To $to
    Check "...the record in one step" "$to|$to|$to|starter-kit-local|kit" ("{0}|{1}|{2}|{3}|{4}" -f $script:mf["runtime.deployment_dir"], $script:mf["runtime.ownership_path"], $script:mf["components.mcp_server.sidecar_dir"], $script:mf["runtime.deployment_name"], $script:mf["runtime.ownership"])
    Check "...the kit's folder" $to $script:PersonalDeployDir
    Check "undo: done" $true (Undo-PersonalDeploymentRename -From $from -To $to)
    Check "...the folder and the record back" "$from|$from|$from|default" ("{0}|{1}|{2}|{3}" -f (Get-ChildItem -LiteralPath $legacyRoot -Directory | Select-Object -First 1).FullName, $script:mf["runtime.deployment_dir"], $script:mf["runtime.ownership_path"], $script:mf["runtime.deployment_name"])
    Check "rename onto an existing folder: refused" $false (Rename-PersonalDeploymentFolder -From $from -To $from)
    Check "rename of a folder that is not there: refused" $false (Rename-PersonalDeploymentFolder -From (Join-Path $legacyRoot "nothing") -To $to)
    Reset-Roots

    Write-Host "== a starter-kit-local the kit has no record of: used as the user's, no question (D5)"
    Set-Machine; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8590 | Out-Null
    function Test-PersonalPromptable { return $true }
    $env:EXAKIT_REUSE_DB = "dev"
    $script:answers.Clear()
    $choice = Select-PersonalDatabase 6>$null
    Check "the choice" "leftover" $choice
    Check "...nothing asked, nothing listed" "" ((Calls "bounded") + (Calls "logged"))
    Check "...the line" "INFO Found the database 'starter-kit-local' from an earlier install. The kit uses it and never deletes it." ($script:said -join "|")
    Check "...recorded as the user's" "user|$SKL|exa-starter-kit-local" ("{0}|{1}|{2}" -f $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], $script:mf["runtime.deployment_id"])
    Check "...their dev is not touched" $true (Test-Path (Join-Path $script:dev "deployment.json"))
    function Test-PersonalPromptable { return $false }

    Write-Host "== what the kit records decides with no question"
    Set-Machine; Fresh
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $script:dev; $script:mf["runtime.ownership"] = "user"; $script:mf["runtime.ownership_path"] = $script:dev
    Check "a database the kit records (a 0.3.0 kit's answer): recorded, nothing asked" "recorded|" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), (Calls "bounded"))
    Set-Machine; Fresh
    $env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "chosen"
    Check "a folder the user named (EXAKIT_PERSONAL_DEPLOY_DIR): chosen, nothing asked" "chosen|" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), (Calls "bounded"))
    Remove-Item Env:EXAKIT_PERSONAL_DEPLOY_DIR
    # A 0.3.0 kit that was answered No recorded the user's launcher and, on
    # Windows, the database receipt it wrote before asking, but no database:
    # the installer run again asks the one question, as for a new user.
    Set-Machine; Fresh
    $script:mf["components.personal.ownership"] = "user"
    $script:mf["runtime.ownership"] = "user"; $script:mf["runtime.ownership_path"] = $script:def
    $env:EXAKIT_REUSE_DB = "dev"
    $choice = Select-PersonalDatabase 6>$null
    Remove-Item Env:EXAKIT_REUSE_DB
    Check "a 0.3.0 kit answered No: the one question (EXAKIT_REUSE_DB answers it), dev renamed" "renamed|user|$SKL|exa-dev" ("{0}|{1}|{2}|{3}" -f $choice, $script:mf["runtime.ownership"], $script:mf["runtime.deployment_dir"], $script:mf["runtime.deployment_id"])
    Check "...line 1 said" $true ($script:said -contains "INFO Exasol Personal 2.5 is on this computer, with 3 databases of yours.")

    Write-Host "== the kit's own missing (a 0.3.0 default a hand-installed 2.5 moved): the one question lists it"
    Set-Machine; Fresh
    $gone030 = Join-Path $legacyRoot "default"
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $gone030; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $gone030
    $script:mf["runtime.session_limit"] = "lifted"
    $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
    Check "the state names both folders" "kit_database_missing|$gone030|$($script:def)" (Get-ExakitPersonalDbState)
    $env:EXAKIT_REUSE_DB = "default"
    $choice = Select-PersonalDatabase 6>$null
    Check "picking it: renamed, keeping its data" "renamed|exa-default" "$choice|$(Read-PersonalDeploymentId -Dir $SKL)"
    Check "...recorded anew as the user's" "user|$SKL|$SKL" ("{0}|{1}|{2}" -f $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], $script:mf["runtime.deployment_dir"])
    Check "...what was done to the old one is forgotten" "" ("" + $script:mf["runtime.session_limit"])
    Check "...and nothing is missing any more" "" (Get-ExakitPersonalDbState)
    # THE RENAME OF THE ONE PICKED DOES NOT HAPPEN (a launcher command holds
    # it): the record of the kit's own missing database stays as it was, so
    # `exakit status` still says it is missing and the next run asks again.
    # Twin of personal_reuse_rename, which points the record at the renamed
    # folder only once it is renamed.
    function Set-Missing030 {
        Set-Machine; Fresh
        $script:mf["runtime.type"] = "personal"
        $script:mf["runtime.deployment_dir"] = $gone030; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $gone030
        $script:mf["runtime.session_limit"] = "lifted"
        $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
        $env:EXAKIT_REUSE_DB = "default"
    }
    Set-Missing030
    Set-Content -Path (Join-Path $script:def ".dirmutex.exclusive") -Value "" -Encoding Ascii
    $choice = Select-PersonalDatabase 6>$null
    Remove-Item -Force (Join-Path $script:def ".dirmutex.exclusive")
    Check "the rename of the one picked does not happen: no database step, nothing renamed" "|True|False" ("{0}|{1}|{2}" -f $choice, (Test-Path $script:def), (Test-Path $SKL))
    Check "...the record of the kit's own as it was" "$gone030|kit|$gone030|lifted" ("{0}|{1}|{2}|{3}" -f $script:mf["runtime.deployment_dir"], $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], $script:mf["runtime.session_limit"])
    Check "...so the kit's own is still missing, and the next run asks again" "kit_database_missing|$gone030|$($script:def)" (Get-ExakitPersonalDbState)
    Set-Missing030
    $script:stopRc = 1
    $choice = Select-PersonalDatabase 6>$null
    Check "...the same when it does not stop" "|$gone030|kit" ("{0}|{1}|{2}" -f $choice, $script:mf["runtime.deployment_dir"], $script:mf["runtime.ownership"])
    Set-Missing030
    & {
        function Set-PersonalUserDatabaseRecord { param([string]$Dir) $script:mf["runtime.deployment_dir"] = $Dir; $script:mf["runtime.ownership"] = "user"; throw "manifest locked (fixture)" }
        $script:choiceInside = Select-PersonalDatabase 6>$null
    }
    Check "...and when its record cannot be written: renamed back, the kit's record as it was" "|True|$gone030|kit|$gone030|lifted" ("{0}|{1}|{2}|{3}|{4}|{5}" -f $script:choiceInside, (Test-Path (Join-Path $script:def "deployment.json")), $script:mf["runtime.deployment_dir"], $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], $script:mf["runtime.session_limit"])
    Set-Machine; Fresh
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $gone030; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $gone030
    $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
    $env:EXAKIT_REUSE_DB = "new"
    Check "a new database instead: new, the old record forgotten" "new|$SKL|" ("{0}|{1}|{2}" -f (Select-PersonalDatabase 6>$null), $script:PersonalDeployDir, ("" + $script:mf["runtime.deployment_dir"]))
    Check "...their default untouched" $true (Test-Path (Join-Path $script:def "deployment.json"))
    # A STARTER-KIT-LOCAL OF THE USER'S WHERE A NEW ONE WOULD GO, with the
    # kit's own missing (the kit's own destroyed, theirs made under the same
    # name): neither a new database nor a rename could take the name, so
    # theirs is used as the user's, with its own id, no question, and the
    # screen says so. Twin of the L2 checks in personal-named-deploy.sh.
    $L2 = "INFO A database of yours is named 'starter-kit-local', the name of the kit's own database. The kit uses it and never deletes it."
    # (a) the same folder, another id: the kit's own starter-kit-local
    # recorded with exa-kit, the folder now holds theirs.
    Set-Machine; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8592 | Out-Null
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $SKL; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $SKL
    $script:mf["runtime.deployment_id"] = "exa-kit"
    $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
    Check "the kit's name taken in its own folder (another id): kit_database_missing" "kit_database_missing|$SKL|$SKL" (Get-ExakitPersonalDbState)
    function Test-PersonalPromptable { return $true }
    $script:answers.Clear()
    $choice = Select-PersonalDatabase 6>$null
    function Test-PersonalPromptable { return $false }
    Check "...theirs used, no question (even with a terminal), nothing listed" "leftover|" ("{0}|{1}" -f $choice, (Calls "bounded"))
    Check "...the line says why" $L2 ($script:said -join "|")
    Check "...recorded as the user's, with its own id" "user|$SKL|exa-starter-kit-local" ("{0}|{1}|{2}" -f $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], $script:mf["runtime.deployment_id"])
    Check "...and nothing is missing any more" "" (Get-ExakitPersonalDbState)
    Set-Machine; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8592 | Out-Null
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $SKL; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $SKL
    $script:mf["runtime.deployment_id"] = "exa-kit"
    $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
    $env:EXAKIT_REUSE_DB = "0"
    Check "...EXAKIT_REUSE_DB=0 is not read there (as D5): theirs, the line" "leftover|$L2" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), ($script:said -join "|"))
    # (b) the kit's own gone, and the kit's name in the launcher's other root.
    Set-Machine; Fresh
    $theirsOld = New-UserDeployment $legacyRoot "starter-kit-local" 8593
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $SKL; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $SKL
    $script:mf["runtime.deployment_id"] = "exa-kit"
    $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
    Check "the kit's own gone, its name in the other root: kit_database_missing" "kit_database_missing|$SKL|$theirsOld" (Get-ExakitPersonalDbState)
    Check "...theirs used, the line" "leftover|$L2" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), ($script:said -join "|"))
    Check "...recorded as the user's, where it is" "user|$theirsOld|exa-starter-kit-local" ("{0}|{1}|{2}" -f $script:mf["runtime.ownership"], $script:mf["runtime.deployment_dir"], $script:mf["runtime.deployment_id"])

    Write-Host "== the kit's own starter-kit-local whose first deploy was interrupted: resumed as the kit's"
    # Its receipt is written after `install local`, its first_boot_pending
    # before it: a Ctrl-C between the two left a starter-kit-local the next run
    # took for one an earlier uninstall kept, recorded as the user's, which the
    # deploy step never repairs or replaces. Twin of the M2 checks in
    # personal-named-deploy.sh.
    Set-Machine; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8594 | Out-Null
    $script:mf["runtime.first_boot_pending"] = "true"
    $choice = Select-PersonalDatabase 6>$null
    Check "first_boot_pending: the kit's own, no question, no line" "recorded||" ("{0}|{1}|{2}" -f $choice, ($script:said -join "|"), (Calls "bounded"))
    Check "...recorded as the kit's, with its id" "kit|$SKL|exa-starter-kit-local|$SKL" ("{0}|{1}|{2}|{3}" -f $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], $script:mf["runtime.deployment_id"], $script:mf["runtime.deployment_dir"])
    Check "...and the kit's to repair or replace" "True" (Test-ExakitComponentManaged "database")
    Set-Machine; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8594 | Out-Null
    $script:mf["runtime.deployment_id"] = "exa-starter-kit-local"
    Check "the id the kit recorded names it: recorded (no leftover line)" "recorded|" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), ($script:said -join "|"))
    Set-Machine; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8594 | Out-Null
    Check "with neither, it stays one an earlier install kept: the user's" "leftover|user" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), $script:mf["runtime.ownership"])

    Write-Host "== a 0.3.0 record of a default that is gone, nothing in its place: the new one is recorded before the deploy"
    # The 0.3.0 kit's `default` destroyed by hand: the installer run again
    # deploys starter-kit-local where a first install puts it. The record says
    # so before the deploy (the kit's own, no id of the gone one), so a deploy
    # cut short is resumed as the kit's, never taken for one of the user's.
    # Twin of the item 6 checks in personal-named-deploy.sh.
    Reset-Roots; Fresh
    $goneDef = Join-Path $legacyRoot "default"
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $goneDef; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $goneDef
    $script:mf["runtime.deployment_id"] = "exa-gone"
    $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
    $choice = Select-PersonalDatabase 6>$null
    Check "recorded, nothing asked, the kit's folder is starter-kit-local" "recorded|$SKL" ("{0}|{1}" -f $choice, $script:PersonalDeployDir)
    Check "...the record names it before the deploy, the kit's, without the gone id" "$SKL|starter-kit-local|kit|$SKL|" ("{0}|{1}|{2}|{3}|{4}" -f $script:mf["runtime.deployment_dir"], $script:mf["runtime.deployment_name"], $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], ("" + $script:mf["runtime.deployment_id"]))
    # The deploy cut short: the launcher made the folder, the kit wrote nothing more.
    New-UserDeployment $newRoot "starter-kit-local" 8563 | Out-Null
    $script:mf["runtime.first_boot_pending"] = "true"
    $keep = $script:mf.Clone()
    Fresh
    $script:mf = $keep
    $choice = Select-PersonalDatabase 6>$null
    Check "...the next run resumes it as the kit's: recorded, no line, still the kit's" "recorded||kit" ("{0}|{1}|{2}" -f $choice, ($script:said -join "|"), $script:mf["runtime.ownership"])
    # The user's, gone because its rebuild was cut short (RGR-02): the new one
    # is theirs, where a first install puts it.
    Reset-Roots; Fresh
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $goneDef; $script:mf["runtime.ownership"] = "user"; $script:mf["runtime.ownership_path"] = $goneDef
    $script:mf["runtime.rebuild_path"] = $goneDef
    $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
    $choice = Select-PersonalDatabase 6>$null
    Check "...gone in a rebuild cut short: recorded, the user's, and the note follows" "recorded|$SKL|user|$SKL|user" ("{0}|{1}|{2}|{3}|{4}" -f $choice, $script:mf["runtime.deployment_dir"], $script:mf["runtime.ownership"], $script:mf["runtime.rebuild_path"], (Get-PersonalNewDatabaseOwner))
    Reset-Roots; Fresh
    $chosenGone = Join-Path (Join-Path $work "chosen-gone") "default"
    $script:mf["runtime.type"] = "personal"
    $script:mf["runtime.deployment_dir"] = $chosenGone; $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $chosenGone
    Check "a folder the user chose, outside the launcher's roots, gone: its record is kept" "recorded|$chosenGone" ("{0}|{1}" -f (Select-PersonalDatabase 6>$null), $script:mf["runtime.deployment_dir"])

    Write-Host "== the deploy step around it (Install-PersonalDeployment)"
    # The engine, the WSL gate and the waits are stubbed; the launcher is the
    # stand-in above.
    function Get-PersonalEngineExisting { param([switch]$Quiet) return "podman" }
    function Resolve-PersonalEngine { param([switch]$Probe) $script:PersonalEngine = "podman"; return "podman" }
    function Test-PersonalEngineRunning { param($Engine) return $true }
    function Test-PersonalWslPodmanNetworkOk { param([string]$Rerun = "", [switch]$Replace, [switch]$Quiet, [switch]$StartMachine) return $true }
    function Test-PersonalPodmanRunning { return $true }
    function podman { }
    function Wait-PersonalReadyOrDeploy { return $true }
    function Set-PersonalManifest { param([string]$Status = "", [switch]$Fresh) $script:mf["runtime.status"] = $Status }
    function Show-PersonalGuestRebuildNote { }
    function Get-PersonalLauncherState { return "stopped" }
    function Get-PersonalLogOffset { return 0 }
    function Test-PersonalStartNetworkBlocked { param($LogOffset) return $false }
    function Test-PersonalLauncherSupports { param($Token) return $true }
    function Get-PersonalAutoApproveFlag { param($Subcommand) return $null }
    function Test-ExakitStdoutIsTerminal { return $false }
    function Wait-PersonalSlowFirstBoot { return $false }
    # Their default answers on 8563 (it runs): nothing the kit's is there.
    function Test-PersonalPortFree { param([int]$Port) return ($Port -ne 8563) }
    function Test-ExakitPortInUse { param([int]$Port) return ($Port -eq 8563) }
    function Test-PersonalDeploymentRunning { return $false }
    Set-Machine; Fresh
    Install-PersonalDeployment 6>$null
    Check "new next to theirs: a database" $false $script:PersonalNoDatabase
    Check "...on a port of its own, in starter-kit-local" $true ((Calls "logged") -like "*install local --container-engine podman --ports db:8568 --deployment-dir $SKL*")
    Check "...8563 to 8567 are theirs (running, or saved by a stopped one): 8568" "8568" ("" + (Get-PersonalDbPort))
    Check "...recorded as the kit's" "kit|$SKL" ("{0}|{1}" -f $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"])
    Check "...none of theirs stopped or started" $false ((Calls "logged") -match '(^| )(stop|start) ')
    Check "...says theirs is not changed (line 4), with the deploy" $true ($script:said -contains "INFO Deploying the starter kit's own database 'starter-kit-local'. Your Exasol Personal is not changed.")
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "dev"
    Install-PersonalDeployment 6>$null
    Check "dev picked: renamed, then started once by its new folder" "start --deployment-dir $SKL" (Calls "logged")
    Check "...used" $true (($script:said -join "|").Contains("OK Reusing the existing Exasol deployment (started)"))
    Check "...the user's" "user" ("" + $script:mf["runtime.ownership"])
    Check "...on its own port, kept" "8564" ("" + (Get-PersonalDbPort))
    Check "...said found and not running after the rename too, as the sh twin says it" $true ($script:said -contains "INFO An Exasol deployment was found, not running.")
    Set-Machine; Fresh
    $env:EXAKIT_REUSE_DB = "dev"
    $script:startRc = 1
    $env:EXAKIT_REPLACE_DB = "1"
    Install-PersonalDeployment 6>$null
    Check "the user's database does not start: no database step" $true $script:PersonalNoDatabase
    Check "...never offered for a replace, even with EXAKIT_REPLACE_DB=1" $false ((Calls "logged") -match 'destroy')
    Check "...says so, as the sh twin says it" $true (($script:said -join "|").Contains("INFO Nothing was deleted. This database is yours, so the kit never deletes it. Start it with 'exakit start', or diagnose it with 'exakit status'."))
    Check "...the reason, as the sh twin's" "A stopped deployment of yours could not be started. The kit never deletes it" (Get-ExakitFailureReason)
    Check "...its data stays" $true (Test-Path (Join-Path $SKL "deployment.json"))
    Remove-Item Env:EXAKIT_REPLACE_DB -ErrorAction SilentlyContinue
    # `exakit repair-runtime` over a database of the user's, which they
    # confirmed: replaced, and recorded as the user's at every step.
    function Rebuild([string]$Flag, [string]$OtherId = "") {
        Reset-Roots; Fresh
        New-UserDeployment $newRoot "starter-kit-local" 8600 | Out-Null
        $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = $SKL; $script:mf["runtime.deployment_name"] = "starter-kit-local"
        $script:mf["runtime.ownership"] = "user"; $script:mf["runtime.ownership_path"] = $SKL; $script:mf["runtime.deployment_id"] = "exa-starter-kit-local"
        if ($OtherId) { $script:mf["runtime.deployment_id"] = $OtherId }
        $env:EXAKIT_REUSE_DB = "0"; $env:EXAKIT_REPLACE_DB = "1"
        $global:ExakitRebuildOwner = $Flag
        $script:owners = @()
        & {
            function Set-ExakitManifestValue { param([string]$Path, $Value) if ($Path -eq "runtime.ownership") { $script:owners += "$Value" }; $script:mf[$Path] = $Value }
            function Invoke-PersonalDestroy { $script:lcalls += "logged: destroy"; Remove-Item -Recurse -Force $SKL; return $true }
            Install-PersonalDeployment 6>$null
        }
        $global:ExakitRebuildOwner = ""
        Remove-Item Env:EXAKIT_REUSE_DB, Env:EXAKIT_REPLACE_DB -ErrorAction SilentlyContinue
    }
    Rebuild "user"
    Check "repair-runtime, the user's database: replaced" $true (((Calls "logged") -like "destroy / install local*") -and -not $script:PersonalNoDatabase)
    Check "...recorded as the user's, with the new id" "user|$SKL|exa-kit-new" ("{0}|{1}|{2}" -f $script:mf["runtime.ownership"], $script:mf["runtime.ownership_path"], $script:mf["runtime.deployment_id"])
    Check "...never recorded as the kit's on the way" $false ($script:owners -contains "kit")
    # Cut short after `install local` made the new one, before its id was on
    # record (WP2-05): the next repair-runtime finishes it, and it is theirs.
    function RebuildMore([string]$Flag) {
        $script:lcalls = @(); $script:said = @(); $script:PersonalNoDatabase = $false; $script:PersonalPortPicked = 0
        $script:PersonalLauncherAsked = $false; $script:PersonalLauncherDecided = $false; $script:PersonalDeployRec = ""; $script:PersonalDeployFollowed = ""; $script:PersonalDeployIdSeen = $false
        $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path "").Dir
        if ($Flag) { $env:EXAKIT_REUSE_DB = "0"; $env:EXAKIT_REPLACE_DB = "1" }
        $global:ExakitRebuildOwner = $Flag
        & {
            function Invoke-PersonalDestroy { $script:lcalls += "logged: destroy"; Remove-Item -Recurse -Force $SKL; return $true }
            try { Install-PersonalDeployment 6>$null } catch { $script:said += "THREW $($_.Exception.Message)" }
        }
        $global:ExakitRebuildOwner = ""
        Remove-Item Env:EXAKIT_REUSE_DB, Env:EXAKIT_REPLACE_DB -ErrorAction SilentlyContinue
    }
    $realInstallLocal = ${function:Invoke-PersonalInstallLocal}
    function Invoke-PersonalInstallLocal { $null = New-UserDeployment $newRoot "starter-kit-local" 8600; Set-Content -Path (Join-Path $SKL "deployment.json") -Encoding Ascii -Value '{"deploymentId": "exa-half", "connection": {"host": "127.0.0.1", "dbPort": 8600, "username": "sys"}}'; Set-Content -Path (Join-Path $SKL ".exasolLauncherState.json") -Encoding Ascii -Value '{"deploymentId": "exa-half"}'; throw "window closed" }
    $cut = ""
    try { Rebuild "user" } catch { $cut = "$($_.Exception.Message)" }
    $global:ExakitRebuildOwner = ""; Remove-Item Env:EXAKIT_REUSE_DB, Env:EXAKIT_REPLACE_DB -ErrorAction SilentlyContinue
    Set-Item -Path function:Invoke-PersonalInstallLocal -Value $realInstallLocal
    Check "cut short after the new one was made: theirs on record" "window closed|user|exa-half" ("{0}|{1}|{2}" -f $cut, $script:mf["runtime.ownership"], (Read-PersonalDeploymentId -Dir $SKL))
    RebuildMore "user"
    Check "...the next repair-runtime replaces it, theirs" "True|False|user|exa-kit-new" ("{0}|{1}|{2}|{3}" -f ((Calls "logged") -like "destroy / install local*"), $script:PersonalNoDatabase, $script:mf["runtime.ownership"], $script:mf["runtime.deployment_id"])
    # The deploy of the rebuild fails, and the remedy the kit prints (the
    # installer again) makes it (RGR-02): still theirs.
    function Invoke-PersonalInstallLocal { return 1 }
    Rebuild "user"
    Set-Item -Path function:Invoke-PersonalInstallLocal -Value $realInstallLocal
    Check "the rebuild's deploy fails: no database, theirs on record" "True|user|False" ("{0}|{1}|{2}" -f $script:PersonalNoDatabase, $script:mf["runtime.ownership"], (Test-Path $SKL))
    RebuildMore ""
    Check "...the installer again makes it: theirs, so no uninstall removes it" "False|user|exa-kit-new" ("{0}|{1}|{2}" -f $script:PersonalNoDatabase, $script:mf["runtime.ownership"], $script:mf["runtime.deployment_id"])
    # On the engine it had, written down before the destroy, when nothing but
    # that record names it (RGR-02).
    & {
        function Get-PersonalEngineExisting { param([switch]$Quiet) return "docker" }
        function Invoke-PersonalInstallLocal { return 1 }
        Rebuild "user"
    }
    Check "the engine is on record before the destroy" "docker|False" ("{0}|{1}" -f $script:mf["runtime.engine"], (Test-Path $SKL))
    RebuildMore ""
    Check "...and the installer again makes it on that engine, theirs" "docker|user|True" ("{0}|{1}|{2}" -f $script:PersonalEngine, $script:mf["runtime.ownership"], ((Calls "logged") -like "*install local --container-engine docker*"))
    # The launcher says of what the cut left that its deploy failed: it is
    # deployed again, as the user's, by the installer and by exakit start.
    $script:mf["runtime.rebuild_path"] = $SKL
    & { function Get-PersonalLauncherState { return "deployment_failed" }; RebuildMore "" }
    Check "deployment_failed in a rebuild cut short: deployed again" "True|False|user" ("{0}|{1}|{2}" -f (Verb "logged" "deploy"), $script:PersonalNoDatabase, $script:mf["runtime.ownership"])
    [void]$script:mf.Remove("runtime.rebuild_path")
    & { function Get-PersonalLauncherState { return "deployment_failed" }; RebuildMore "" }
    Check "...and with no rebuild noted: named and left, as before" "False|True" ("{0}|{1}" -f (Verb "logged" "deploy"), $script:PersonalNoDatabase)
    [void]$script:mf.Remove("runtime.engine")
    # A database of theirs deleted by hand is not that rebuild: the new one is
    # the kit's, as for a new install.
    Reset-Roots; Fresh
    $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = $SKL; $script:mf["runtime.ownership"] = "user"; $script:mf["runtime.ownership_path"] = $SKL; $script:mf["runtime.deployment_id"] = "exa-gone"
    RebuildMore ""
    Check "deleted by hand: the new one is the kit's" "False|kit" ("{0}|{1}" -f $script:PersonalNoDatabase, $script:mf["runtime.ownership"])
    Rebuild ""
    Check "the same answers without that command: the user's database is never replaced" $false ((Calls "logged") -match 'destroy')
    Rebuild "user" "exa-another"
    Check "...nor in that command, when the folder holds another database than the record names" $false ((Calls "logged") -match 'destroy')

    # The kit's own stopped starter-kit-local, the installer run again: resumed
    # with no question.
    Reset-Roots; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8600 | Out-Null
    $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = $SKL
    $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $SKL; $script:mf["runtime.deployment_id"] = "exa-starter-kit-local"
    & {
        function Test-ExakitComponentManaged { param([string]$Id) return $true }
        Install-PersonalDeployment 6>$null
    }
    Check "the kit's own, stopped: started with no question" "start --deployment-dir $SKL" (Calls "logged")
    Check "...used" $true (($script:said -join "|").Contains("OK Reusing the existing Exasol deployment (started)"))
    Check "...nothing asked about it" $false (($script:said -join "|").Contains("DELETE"))
    # The kit's own, RUNNING: used, the running line said first, as the sh
    # twin says it on every reuse.
    Reset-Roots; Fresh
    New-UserDeployment $newRoot "starter-kit-local" 8600 | Out-Null
    $script:mf["runtime.type"] = "personal"; $script:mf["runtime.deployment_dir"] = $SKL
    $script:mf["runtime.ownership"] = "kit"; $script:mf["runtime.ownership_path"] = $SKL; $script:mf["runtime.deployment_id"] = "exa-starter-kit-local"
    & {
        function Test-ExakitComponentManaged { param([string]$Id) return $true }
        function Test-PersonalDeploymentRunning { return $true }
        Install-PersonalDeployment 6>$null
    }
    Check "the kit's own, running: the running line, then used, as the sh twin says it" "INFO An Exasol database is already running on port 8600.|OK Reusing the existing Exasol deployment" (@($script:said | Where-Object { $_ -like "*already running on port*" -or $_ -like "OK Reusing*" }) -join "|")
    # No port from 8563 to 8663 free for a new one: the sh twin's sentences.
    Set-Machine; Fresh
    & {
        function Select-PersonalDbPort { return 0 }
        Install-PersonalDeployment 6>$null
    }
    Check "no port free for a new one: no database step" $true $script:PersonalNoDatabase
    Check "...said as the sh twin says it" $true ($script:said -contains "WARN No port from 8563 to 8663 is free for the starter kit's database: each is in use, or saved by another Exasol Personal database.")
    Check "...with what to do" $true (@($script:said | Where-Object { $_.StartsWith("INFO Free one of them (stop a database you do not need), then re-run the installer: ") }).Count -eq 1)
    Check "...the reason, as the sh twin's" "No port from 8563 to 8663 is free for the starter kit's database" (Get-ExakitFailureReason)
    Reset-Roots
    Remove-Item Env:EXAKIT_REUSE_DB -ErrorAction SilentlyContinue
    }

    Write-Host "== a user deployment the launcher records as failed (OWN-06)"
    $script:mf = @{}
    # Only the kit's own deployment is ever deployed again or offered for
    # removal: one the user adopted (recorded as theirs), failed, is named and
    # left - no deploy.
    $script:stub = $stub25
    $script:owner = "user"
    $startSaid = ""
    & {
        function Get-ExakitComponentOwnership { param($Id) return $script:owner }
        function Get-PersonalLauncherState { return "deployment_failed" }
        function Get-PersonalEngineRecorded { return "podman" }
        function Get-PersonalPodman { return $null }
        function Get-PersonalCli { return $script:stub }
        try { Start-Personal 6>$null } catch { $startSaid = "$_" }
        Set-Variable -Name startSaid -Value $startSaid -Scope 1
    }
    Check "exakit start on an adopted failed deployment: named, not deployed" $true ($startSaid.Contains("is not the kit's, so the kit does not deploy it again"))
    Check "...no deploy of it" $false ((Get-VersionCalls) -match '(^|\|)deploy ')
    $script:owner = "unknown"

    Write-Host "== what is not newer than the pin, and what is"
    function Get-PersonalCli { return $script:stub }
    function Get-ExakitComponentOwnership { param($Id) return $script:owner }
    $script:stub = New-VersionStub "2.5.3"
    Check "the user's own launcher a patch ahead, on the pinned line" $false (Test-PersonalLauncherNewer)
    $script:stub = New-VersionStub "2.4.0"
    Check "an older launcher" $false (Test-PersonalLauncherNewer)
    # Probed whoever owns it (review 0.3.1, item 5): Exasol Personal puts itself
    # where the kit's launcher is and keeps the kit's ownership record.
    $script:owner = "kit"
    $script:stub = New-VersionStub "2.5.1"
    Check "the kit's own launcher a patch ahead (its own update path)" $false (Test-PersonalLauncherNewer)
    $script:stub = $stub26
    Check "a 2.6 put over the kit's own launcher is newer, the record notwithstanding" $true (Test-PersonalLauncherNewer)
    $script:owner = "unknown"
    # The kit follows a move the launcher makes, so `version` is asked even
    # with a deployment in the older folder.
    New-Item -ItemType Directory -Force -Path (Join-Path $legacyRoot "other") | Out-Null
    [void](Get-VersionCalls)
    Check "a deployment in the older folder: a 2.6 is found by its version" $true (Test-PersonalLauncherNewer)
    Check "...and asked nothing but 'version'" "version" (Get-VersionCalls)
    Remove-Item -Recurse -Force (Join-Path $legacyRoot "other") -ErrorAction SilentlyContinue
    }
    # The scratch folder the suite began with, for the sections below.
    $env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "kit deployment"
    $script:PersonalDeployDir = $env:EXAKIT_PERSONAL_DEPLOY_DIR
    Remove-Item Env:EXAKIT_REUSE_DB -ErrorAction SilentlyContinue

    Write-Host "== no runtime recorded: every remedy names the installer re-run, and status --json carries no refusal"
    $hostExe = (Get-Process -Id $PID).Path
    $rk = Join-Path $work "noruntime-kit"
    New-Item -ItemType Directory -Force -Path $rk | Out-Null
    Set-Content -Path (Join-Path $rk "manifest.json") -Encoding Ascii -Value '{"kit_level": 1, "steps_completed": [], "install": {}}'
    function Invoke-NoRuntime([string[]]$CliArgs) {
        $prev = $env:EXAKIT_HOME
        $env:EXAKIT_HOME = $rk
        try { return ((& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "setup/exakit.ps1") @CliArgs 2>&1 6>&1) | Out-String) }
        finally { $env:EXAKIT_HOME = $prev }
    }
    Contains "start names the installer re-run" "resumes at the unfinished step" (Invoke-NoRuntime @("start"))
    Contains "mcp-doctor says finish the install" "Finish the install first" (Invoke-NoRuntime @("mcp-doctor"))
    $t = Invoke-NoRuntime @("status", "--json")
    $doc = $null
    try { $doc = $t.Substring($t.IndexOf("{")) | ConvertFrom-Json } catch { }
    Check "status --json answers" $true ($null -ne $doc)
    Check "...with no refusal key" $false (@($doc.PSObject.Properties.Name) -contains "refusal")
    $t = Invoke-NoRuntime @("uninstall", "--dry-run")
    Contains "uninstall --dry-run lists the MCP entries" "managed MCP configuration" $t
    Check "...with no refusal line" $false ($t.Contains("Your own Exasol Personal is not touched."))

    Write-Host "== exakit repair-runtime rebuilds a database of the user's like the kit's own (Krishna Q19)"
    # The real Invoke-CmdRepairRuntime, in a child process of the same engine
    # (it ends with exit). The kit copy it re-runs the setup from is a
    # stand-in whose setup script only notes that it ran: no installer ever
    # runs here. Twin of the same checks in personal-named-deploy.sh.
    $rrKit = Join-Path $work "rrkit"
    New-Item -ItemType Directory -Force -Path (Join-Path $rrKit "setup") | Out-Null
    $rrMark = Join-Path $work "rr-rebuilt"
    Set-Content -Path (Join-Path $rrKit "setup/setup-windows.ps1") -Encoding Ascii -Value @(('Add-Content -Path "' + $rrMark + '" -Value ("REBUILT reuse=" + $env:EXAKIT_REUSE_DB + " owner=" + (Get-ExakitManifestValue "runtime.ownership") + " rebuild=" + $global:ExakitRebuildOwner)'), 'exit 0')
    $rrSets = Join-Path $work "rr-sets"
    $rrChild = Join-Path $work "rr-child.ps1"
    Set-Content -Path $rrChild -Encoding Ascii -Value @'
param([string]$Repo, [string]$Kit, [string]$Owner, [string]$Flags = "", [string]$Sets = "")
$ErrorActionPreference = "Stop"
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
foreach ($fn in @("Invoke-CmdRepairRuntime")) {
    Invoke-Expression ($ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true).Extent.Text)
}
# Global: the stand-in setup script reads it too, from its own script scope.
$global:rrmf = @{ "runtime.type" = "personal"; "runtime.ownership" = $Owner; "runtime.deployment_dir" = "C:\dbs\starter-kit-local" }
$global:rrSets = $Sets
function Get-ExakitManifestValue([string]$Path) { return $global:rrmf[$Path] }
function Set-ExakitManifestValue([string]$Path, $Value) { $global:rrmf[$Path] = "$Value"; Add-Content -Path $global:rrSets -Value "$Path=$Value" }
function Write-ExakitLog { }
function Assert-ExakitInstalled { param([switch]$Json) }
function Get-ExakitRepoRoot { return $Kit }
function Warn2([string]$Msg) { Write-Host "WARN $Msg" }
function Info([string]$Msg) { Write-Host "INFO $Msg" }
function Confirm-ExakitPrompt { return $false }
function Initialize-ExakitLogging { }
function Remove-ExakitStepDone { param([string]$Name) }
function Reset-ExakitDatasetFlags { }
function Test-ExakitStepDone { param([string]$Name) return $true }
function Get-ExakitInstallCommand { return "irm https://x/install.ps1 | iex" }
function Fail([string]$Message) { [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
$script:ExapumpProfile = "exasol"
if ($Flags -match "running") {
    function Test-PersonalDeploymentRunning { return $true }
    function Get-PersonalDbPort { return 8563 }
}
function Set-ExakitFailureReason { param([string]$Reason) Add-Content -Path $global:rrSets -Value "failure=$Reason" }
function Remove-ExakitStepDone { param([string]$Name) Add-Content -Path $global:rrSets -Value "unticked $Name" }
function Reset-ExakitDatasetFlags { Add-Content -Path $global:rrSets -Value "datasets reset" }
Invoke-CmdRepairRuntime -Yes:($Flags -match "yes") -Json:($Flags -match "json")
exit 0
'@
    $rrEngine = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    # Invoke-Repair <owner> <flags>: the child's lines (stdout and stderr, each
    # as its text: Windows PowerShell 5.1 decorates a native stderr line it
    # formats), its exit code, the JSON object it printed, and what it rebuilt.
    function Invoke-Repair([string]$Owner, [string]$Flags) {
        Remove-Item -Force $rrMark, $rrSets -ErrorAction SilentlyContinue
        New-Item -ItemType File -Force -Path $rrSets | Out-Null
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            # Never an empty -Flags: Windows PowerShell 5.1 drops an empty
            # argument to a native command, and the child then stops on a
            # -Flags with no value (exit 1) before the code under test runs.
            $flagArg = $Flags
            if (-not $flagArg) { $flagArg = "none" }
            $lines = @(& $rrEngine -NoProfile -ExecutionPolicy Bypass -File $rrChild -Repo $repo -Kit $rrKit -Owner $Owner -Flags $flagArg -Sets $rrSets 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        $rebuilt = ""
        if (Test-Path $rrMark) { $rebuilt = (Get-Content -Raw $rrMark).Trim() }
        $doc = $null
        foreach ($l in $lines) { if ($l.StartsWith("{")) { try { $doc = $l | ConvertFrom-Json } catch { } } }
        $sets = @(Get-Content -LiteralPath $rrSets -ErrorAction SilentlyContinue) -join "|"
        return [pscustomobject]@{ Lines = $lines; Text = ($lines -join "`n"); Code = $code; Doc = $doc; Rebuilt = $rebuilt; Sets = $sets }
    }
    $rr = Invoke-Repair "user" "yes"
    Check "a database of the user's, --yes: rebuilt like the kit's own (EXAKIT_REUSE_DB=0), exit 0" "0|REBUILT reuse=0 owner=user rebuild=user" "$($rr.Code)|$($rr.Rebuilt)"
    Check "...after the same warning" $true ($rr.Lines -contains "WARN This rebuilds your database from empty. Every table in it is deleted and cannot be recovered.")
    # A window closed in the middle of the rebuild leaves what is recorded:
    # the user's, never the kit's (an uninstall removes only the kit's).
    Check "...the record says the user's throughout, nothing written for the rebuild" "unticked runtime|datasets reset" $rr.Sets
    Check "...never refused" $false ($rr.Text.Contains("never deletes or replaces it"))
    # A RUNNING DATABASE (W10b): told to stop it before the warning and the
    # question, nothing re-run, nothing recorded, the user's as the kit's own.
    foreach ($rrOwner in @("user", "kit")) {
        foreach ($rrFlags in @("yes running", "running")) {
            $rr = Invoke-Repair $rrOwner $rrFlags
            Check "running, owner $rrOwner, '$rrFlags': told to stop it first, and nothing else" "INFO An Exasol database is already running on port 8563.|INFO Stop it first ('exakit stop'), then re-run the installer to deploy a fresh one - port 8563 stays in use while it is running: irm https://x/install.ps1 | iex" ($rr.Lines -join "|")
            Check "...exit 7, nothing re-run, no record and no failure note" "7||" "$($rr.Code)|$($rr.Rebuilt)|$($rr.Sets)"
        }
        $rr = Invoke-Repair $rrOwner "yes json running"
        Check "running, owner $rrOwner, --json: refused, nothing changed, exit 3" "3|False|refused|False|exakit stop||" ("{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f $rr.Code, $rr.Doc.ok, $rr.Doc.status, $rr.Doc.changed, $rr.Doc.remedy, $rr.Rebuilt, $rr.Sets)
        Check "...one object and nothing else" 1 (@($rr.Lines).Count)
    }
    $rr = Invoke-Repair "user" ""
    Check "...without --yes and no terminal: the answer is no, exit 5, nothing rebuilt or recorded" "5||" "$($rr.Code)|$($rr.Rebuilt)|$($rr.Sets)"
    $rr = Invoke-Repair "user" "yes json"
    $rrDoc = $rr.Doc
    Check "...--json: repaired, exit 0, the record untouched" "0|True|repaired|unticked runtime|datasets reset" `
        ("{0}|{1}|{2}" -f $rr.Code, $(if ($rrDoc) { "$($rrDoc.ok)|$($rrDoc.status)" } else { $rr.Text }), $rr.Sets)
    $rr = Invoke-Repair "kit" "yes"
    Check "the kit's own database: rebuilt as before (EXAKIT_REUSE_DB=0), and its record untouched" "REBUILT reuse=0 owner=kit rebuild=|unticked runtime|datasets reset" "$($rr.Rebuilt)|$($rr.Sets)"
    Check "...after its warning" $true ($rr.Lines -contains "WARN This rebuilds your database from empty. Every table in it is deleted and cannot be recovered.")

    Write-Host "== exakit exasol <args>: the kit's own launcher, the arguments as given"
    # The real Invoke-CmdExasol in a child process (it ends with exit). The
    # launcher is a stand-in that prints each argument on its own line, in
    # brackets, and exits with the code its first argument names.
    $exStubIsExe = $onWindows -and $PSVersionTable.PSVersion.Major -lt 6
    if ($exStubIsExe) {
        # A real program, as the launcher is: it reads its arguments from the
        # Windows command line, which a .cmd re-reads through cmd.exe (it splits
        # at = and drops what it cannot keep).
        $exStub = Join-Path $work "kit-exasol.exe"
        Add-Type -OutputType ConsoleApplication -OutputAssembly $exStub -TypeDefinition @'
using System;
class KitExasol {
    static int Main(string[] args) {
        foreach (string a in args) { Console.WriteLine("[" + a + "]"); }
        Console.Error.WriteLine("to stderr");
        return 3;
    }
}
'@
    } elseif ($onWindows) {
        $exStub = Join-Path $work "kit-exasol.cmd"
        Set-Content -Path $exStub -Encoding Ascii -Value @('@echo off', ':loop', 'if [%1]==[] goto done', 'echo [%~1]', 'shift', 'goto loop', ':done', 'echo to stderr 1>&2', 'exit /b 3')
    } else {
        $exStub = Join-Path $work "kit-exasol"
        Set-Content -Path $exStub -Encoding Ascii -Value @('#!/bin/sh', 'for a in "$@"; do printf "[%s]\n" "$a"; done', 'echo "to stderr" >&2', 'exit 3')
        & chmod +x $exStub
    }
    $exChild = Join-Path $work "ex-child.ps1"
    Set-Content -Path $exChild -Encoding Ascii -Value @'
param([string]$Repo, [string]$Cli, [string]$Owner, [string]$ArgFile)
$ErrorActionPreference = "Stop"
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
Invoke-Expression ($ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-CmdExasol" }, $true).Extent.Text)
$global:exmf = @{ "components.personal.ownership" = $Owner; "components.personal.ownership_path" = $Cli }
function Get-ExakitManifestValue([string]$Path) { if ($Owner -eq "none") { return $null }; return $global:exmf[$Path] }
$a = @(Get-Content -LiteralPath $ArgFile | ForEach-Object { if ($_ -eq "<empty>") { "" } else { $_ } })
Invoke-CmdExasol -Arguments $a
'@
    function Invoke-Exasol([string]$Owner, [string[]]$ArgList) {
        $argFile = Join-Path $work "ex-args.txt"
        Set-Content -LiteralPath $argFile -Value @($ArgList | ForEach-Object { if ($_ -eq "") { "<empty>" } else { $_ } })
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $lines = @(& $rrEngine -NoProfile -ExecutionPolicy Bypass -File $exChild -Repo $repo -Cli $exStub -Owner $Owner -ArgFile $argFile 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        return [pscustomobject]@{ Lines = $lines; Code = $code }
    }
    $ex = Invoke-Exasol "kit" @("status", "--json", "a b", "")
    Check "the kit's launcher runs with the arguments exactly as given (a space, an empty one)" "[status]|[--json]|[a b]|[]" (@($ex.Lines | Where-Object { $_.StartsWith("[") }) -join "|")
    Check "...its stderr passes through, and its exit code is the command's" "True|3" ("{0}|{1}" -f ($ex.Lines -contains "to stderr"), $ex.Code)
    $ex = Invoke-Exasol "user" @("version")
    Check "a launcher receipt of the user's (an install from before the kit's own folder): that launcher" "[version]|3" ("{0}|{1}" -f (@($ex.Lines | Where-Object { $_.StartsWith("[") }) -join "|"), $ex.Code)
    $ex = Invoke-Exasol "none" @("status")
    Check "no launcher of the kit's recorded: one line, exit 1, nothing run" "1|The starter kit has no Exasol launcher of its own yet. Run the installer first." ("{0}|{1}" -f $ex.Code, ($ex.Lines -join "|"))

    Write-Host "== exakit exasol <args>, through the real exakit.ps1: as typed, and nothing redirects it"
    # The whole CLI in a child process, with a kit home of its own whose
    # launcher receipt names the stand-in above (it prints each argument in
    # brackets and exits 3). -File: what an older exakit.cmd and an agent run.
    # Line: what exakit.cmd hands over.
    $xHome = Join-Path $work "xhome"
    New-Item -ItemType Directory -Force -Path $xHome | Out-Null
    Set-Content -Path (Join-Path $xHome "manifest.json") -Encoding Ascii -Value (@{ components = @{ personal = @{ ownership = "kit"; ownership_path = $exStub } } } | ConvertTo-Json -Depth 5)
    $exakitPs1 = Join-Path $repo "setup/exakit.ps1"
    function Invoke-Kit([string[]]$ArgList, [string]$Line = "") {
        $keep = $env:EXAKIT_HOME
        $env:EXAKIT_HOME = $xHome
        $env:EXAKIT_EXASOL_LINE = $Line
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $lines = @(& $rrEngine -NoProfile -ExecutionPolicy Bypass -File $exakitPs1 @ArgList 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous; $env:EXAKIT_HOME = $keep; Remove-Item Env:EXAKIT_EXASOL_LINE -ErrorAction SilentlyContinue }
        return ("{0} {1}" -f ((@($lines | Where-Object { $_.StartsWith("[") }) -join ""), $code))
    }
    foreach ($case in @(
        @("status -d starter-kit-local", "[status][-d][starter-kit-local] 3"),
        @("connect -c uninstall", "[connect][-c][uninstall] 3"),
        @("-v version", "[-v][version] 3"),
        @("status -o json -i -e x -w 5", "[status][-o][json][-i][-e][x][-w][5] 3"),
        @('info --deployment-dir=C:\Users\a\x', '[info][--deployment-dir=C:\Users\a\x] 3'),
        @('sql "a b" "" end', "[sql][a b][][end] 3"),
        @('sql "say \"hi\"" "C:\my dir\\" x', '[sql][say "hi"][C:\my dir\][x] 3'),
        @("install local --help", "[install][local][--help] 3"),
        @("-h", "[-h] 3"),
        @("--help --json", "[--help][--json] 3"),
        @("status --json", "[status][--json] 3"),
        @("status a&b|c", "[status][a&b|c] 3"))) {
        # The .cmd stand-in re-reads its arguments through cmd.exe, which
        # keeps neither embedded quotes nor an empty argument in the middle.
        if ($onWindows -and -not $exStubIsExe -and $case[0] -match '""|\\"|&') { continue }
        Check "exakit.cmd's line: exasol $($case[0])" $case[1] (Invoke-Kit @("exasol") "exasol $($case[0])")
    }
    Check "exakit.cmd's line, no arguments: the launcher alone" " 3" (Invoke-Kit @("exasol") "exasol")
    Check "-File: -d reaches the launcher" "[status][-d][starter-kit-local] 3" (Invoke-Kit @("exasol", "status", "-d", "starter-kit-local"))
    Check "-File: -c never dispatches another kit command" "[connect][-c][uninstall] 3" (Invoke-Kit @("exasol", "connect", "-c", "uninstall"))
    Check "-File: -v is not dropped" "[-v][version] 3" (Invoke-Kit @("exasol", "-v", "version"))
    Check "-File: --help is the launcher's" "[install][--help] 3" (Invoke-Kit @("exasol", "install", "--help"))
    # EVERY PREFIX OF EVERY PARAMETER exakit.ps1 DECLARES, bare, with a value,
    # and with a value that names a kit command: all the launcher's, whichever
    # way it is started. The declared names come from the script itself, so a
    # new parameter is in the sweep by itself. The names -Command and -RestArgs
    # it had are in it too.
    $xAst = [System.Management.Automation.Language.Parser]::ParseFile($exakitPs1, [ref]$null, [ref]$null)
    $xNames = @(@($xAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Where-Object { $_ -match '^[A-Za-z0-9_?]' }) + @("Command", "RestArgs")
    $xOptions = @()
    foreach ($xName in $xNames) { for ($len = 1; $len -le $xName.Length; $len++) { $xOptions += "-" + $xName.Substring(0, $len) } }
    $xOptions = @($xOptions | Select-Object -Unique)
    Check "the sweep has every prefix (-c to -Command, -R to -RestArgs)" $true ((@("-C", "-Co", "-Com", "-Command", "-R", "-Re", "-RestArgs") | Where-Object { $xOptions -notcontains $_ }).Count -eq 0)
    Check "no declared name starts with a letter, so no option spells one" "" ((@($xAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Where-Object { $_ -match '^[A-Za-z0-9_?]' }) -join " ")
    # In a PowerShell session: the same line, run as a command there.
    $inAny = Join-Path $work "in-any.ps1"
    Set-Content -Path $inAny -Encoding Ascii -Value @('param([string]$Exakit, [string]$ArgFile)', '$a = @(Get-Content -LiteralPath $ArgFile)', 'Invoke-Expression ("& ''$Exakit'' " + ($a -join " "))', 'exit $LASTEXITCODE')
    function Invoke-Session([string[]]$ArgList) {
        $argFile = Join-Path $work "in-any-args.txt"
        Set-Content -LiteralPath $argFile -Value $ArgList
        $keep = $env:EXAKIT_HOME; $env:EXAKIT_HOME = $xHome
        $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $l = @(& $rrEngine -NoProfile -ExecutionPolicy Bypass -File $inAny -Exakit $exakitPs1 -ArgFile $argFile 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }); $c = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous; $env:EXAKIT_HOME = $keep }
        return ("{0} {1}" -f ((@($l | Where-Object { $_.StartsWith("[") }) -join ""), $c))
    }
    $xSweep = @("-c", "-co", "-com", "-Command", "-r", "-re", "-RestArgs")
    if ($exStubIsExe) { $xSweep = $xOptions }
    foreach ($opt in $xSweep) {
        $got = @(); $want = @()
        foreach ($rest in @(@($opt), @("connect", $opt, "uninstall"))) {
            $asTyped = "[" + ($rest -join "][") + "] 3"
            $want += @($asTyped, $asTyped, $asTyped)
            $got += @((Invoke-Kit (@("exasol") + $rest)), (Invoke-Kit @("exasol") ("exasol " + ($rest -join " "))), (Invoke-Session (@("exasol") + $rest)))
        }
        foreach ($rest in @(@("status", $opt), @($opt, "5"))) { $want += "[" + ($rest -join "][") + "] 3"; $got += (Invoke-Kit (@("exasol") + $rest)) }
        Check "${opt}: bare, with a value, with a kit command, by -File, by exakit.cmd's line and in a session: the launcher's" ($want -join " ") ($got -join " ")
    }
    # A form the binder refuses before the script runs: nothing is run.
    Check "-File: an ambiguous option runs nothing" $true ((Invoke-Kit @("exasol", "status", "-o", "json")) -notmatch '\[status\]| 3$')
    Check "the line is only for exakit exasol" "" (("" + (Invoke-Kit @("catalog", "--json") "exasol status")) -replace '[^\[]*$', '' -replace '^\[.*', '')
    # Inside a PowerShell session the binder has the line first: refused with
    # one line when it took something, never run as something else.
    $inSession = Join-Path $work "in-session.ps1"
    Set-Content -Path $inSession -Encoding Ascii -Value @('param([string]$Exakit)', '& $Exakit exasol status -d starter-kit-local', 'exit $LASTEXITCODE')
    $keepHome = $env:EXAKIT_HOME; $env:EXAKIT_HOME = $xHome
    $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $isLines = @(& $rrEngine -NoProfile -ExecutionPolicy Bypass -File $inSession -Exakit $exakitPs1 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }); $isCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous; $env:EXAKIT_HOME = $keepHome }
    Check "in a session: one line, exit 2, the launcher not run" "2|exakit exasol: run it as the exakit command, so the launcher gets its arguments exactly as typed." ("{0}|{1}" -f $isCode, ($isLines -join "|"))
    # The shim itself: the word exasol alone goes to the binder, the line in a variable.
    $shimText = Get-ExakitCmdShimContent -PsTarget "C:\kit\setup\exakit.ps1"
    Check "exakit.cmd: exasol goes over as a line, everything else as before" $true ($shimText.Contains('if /i not "%~1"=="exasol" goto kit') -and $shimText.Contains("set EXAKIT_EXASOL_LINE=%*") -and $shimText.Contains("-File `"C:\kit\setup\exakit.ps1`" exasol`r`nexit /b %errorlevel%`r`n:kit`r`n") -and $shimText.TrimEnd().EndsWith("-File `"C:\kit\setup\exakit.ps1`" %*"))
    if ($onWindows) {
        $realShim = Join-Path $work "exakit.cmd"
        Set-Content -Path $realShim -Encoding Ascii -Value (Get-ExakitCmdShimContent -PsTarget $exakitPs1)
        $env:EXAKIT_HOME = $xHome
        $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $shLines = @(& cmd.exe /d /c "`"$realShim`" exasol status -d starter-kit-local -o json --x=C:\y" 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_.StartsWith("[") }); $shCode = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous; $env:EXAKIT_HOME = $keepHome }
        Check "exakit.cmd, run by cmd.exe: as typed, the launcher's exit code" "[status][-d][starter-kit-local][-o][json][--x=C:\y] 3" ("{0} {1}" -f ($shLines -join ""), $shCode)
    }
    # `exakit help exasol` is the page of exakit's own command.
    $env:EXAKIT_HOME = $xHome
    $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $helpDoc = (@(& $rrEngine -NoProfile -ExecutionPolicy Bypass -File $exakitPs1 help exasol --json 2>$null) -join "`n") | ConvertFrom-Json } catch { $helpDoc = $null }
    finally { $ErrorActionPreference = $previous; $env:EXAKIT_HOME = $keepHome }
    # Its first row is the command, and the launcher's own rows are listed as
    # exakit exasol ..., so every one can be run as it is written.
    $helpRows = @(@($helpDoc.commands) | ForEach-Object { "$($_.tool) $($_.command)" })
    Check "exakit help exasol: exakit's own command, not the launcher's" "exakit exasol|True" ("{0}|{1}" -f $helpRows[0], (@($helpRows | Where-Object { $_ -notlike "exakit exasol*" }).Count -eq 0))

    Write-Host "== the MCP step names the true reason it cannot set the server up"
    . (Join-Path $repo "setup/lib/mcp.ps1")
    function Test-McpSidecarSupported { return $false }
    function Test-ExakitComponentManaged { param($Id) return ($script:owner -eq "kit") }
    function Set-ExakitManifestValue { }
    function Get-ExakitManifestValue { return $null }
    $script:owner = "unknown"
    Remove-Item -Recurse -Force $script:PersonalDeployDir -ErrorAction SilentlyContinue
    [void](Set-McpSidecar -Quiet)
    Check "no deployment of the kit's own: says so" "This kit has no database deployment yet, so the MCP server has nothing to run beside." $script:McpSidecarProblem[0]
    New-Item -ItemType Directory -Force -Path $script:PersonalDeployDir | Out-Null
    [void](Set-McpSidecar -Quiet)
    Check "a launcher the user installed: says so" "Your own Exasol launcher has no MCP sidecar, so the MCP server cannot run beside the database." $script:McpSidecarProblem[0]
    Check "...and does not offer to update a launcher the kit does not own" $false ("$($script:McpSidecarProblem[1])".Contains("exakit update personal"))
    $script:owner = "kit"
    [void](Set-McpSidecar -Quiet)
    Check "the kit's own old launcher keeps its message and fix" "Fix: exakit update personal" $script:McpSidecarProblem[1]

    Write-Host "== the uninstall's leftover report says what its command really does"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
    $fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Write-ExakitUninstallLeftoverReport" }, $true)
    . ([scriptblock]::Create($fnAst.Extent.Text))
    $script:said = @()
    function Info([string]$Msg) { $script:said += $Msg }
    $script:PersonalTeardownLeftovers = @("x")
    $script:PersonalTeardownRemedy = "podman rm -f exasol-db-1"
    Write-ExakitUninstallLeftoverReport 6>$null
    Check "a container's removal is not said to delete data" $false (($script:said -join "|").Contains("deletes the database"))
    $script:said = @()
    $script:PersonalTeardownRemedy = "podman rm -f exasol-db-1; Remove-Item -Recurse -Force 'C:\x'"
    Write-ExakitUninstallLeftoverReport 6>$null
    Check "a remedy that removes the folder still says it deletes the data" $true (($script:said -join "|").Contains("it deletes the database and all its data"))
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "personal-scenario-x-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
