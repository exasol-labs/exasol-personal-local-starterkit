#!/usr/bin/env pwsh
# exapump-stdin-bom-ps.ps1 - no UTF-8 BOM ahead of the SQL the kit pipes into
# exapump's stdin, also under console code page 65001.
#
# With the console at UTF-8 (chcp 65001 - what Claude Code's Windows shell and
# other agent harnesses set), Windows PowerShell 5.1 wrote EF BB BF ahead of
# `$Sql | & $bin sql -p ...` even with a BOM-less $OutputEncoding, and Exasol
# rejected the statement ("'<U+FEFF>' character is not allowed within unquoted
# identifier"); mcp-doctor then reported bad admin credentials. The stdin
# site (Invoke-ExapumpAdminSql in mcp.ps1) sets [Console]::InputEncoding
# BOM-less around the call and restores it afterwards. The scheduler's SQL
# runs from the Python marketplace now, so it has no PowerShell pipe.
#
# Static half: both functions set it and restore it in finally (AST).
# Behavioural half: the real functions, extracted by AST, pipe "SELECT 1" into
# a stub exapump that keeps its stdin bytes; the first three must be 53 45 4C.
# On Windows the console is switched to UTF-8 first to reproduce the condition;
# on macOS/Linux pwsh never wrote the BOM, so there it is a sanity check.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/exapump-stdin-bom-ps.ps1
#   pwsh -NoProfile -File tests/exapump-stdin-bom-ps.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $condition, $detail) {
    if ($condition) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $label -- $detail" }
}

$sites = @(
    @{ File = "setup/lib/mcp.ps1"; Name = "Invoke-ExapumpAdminSql" }
)

function Get-FunctionAst([string]$File, [string]$Name) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $File), [ref]$tokens, [ref]$errors)
    return $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
}

# --- static: set BOM-less around the pipe, restored in finally ---------------
Write-Host "--- static"
foreach ($site in $sites) {
    $fn = Get-FunctionAst $site.File $site.Name
    Check "$($site.Name) is defined in $($site.File)" ($null -ne $fn) "not found"
    if ($null -eq $fn) { continue }
    $sets = @($fn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '[Console]::InputEncoding' }, $true))
    $bomless = @($sets | Where-Object { $_.Right.Extent.Text -match 'UTF8Encoding(\(\s*\$false\s*\)|\s+\$false)' })
    Check "$($site.Name) sets [Console]::InputEncoding to UTF8Encoding(`$false)" ($bomless.Count -ge 1) "assignments: $(@($sets | ForEach-Object { $_.Extent.Text }) -join ' | ')"
    $tries = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $true))
    $restored = $false
    foreach ($t in $tries) {
        $inFinally = @($t.Finally.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '[Console]::InputEncoding' -and
            $n.Right.Extent.Text -match '\$previous(ConsoleInput|InputEncoding)' }, $true))
        if ($inFinally.Count -ge 1) { $restored = $true }
    }
    Check "$($site.Name) restores [Console]::InputEncoding in a finally" $restored "no restore of the previous input encoding inside a finally block"
    # No $OutputEncoding check: the SQL goes to exapump's stdin as UTF-8 bytes
    # (#52), not through a PowerShell pipe, so $OutputEncoding never applies.
}

# --- behavioural: the first bytes exapump receives ---------------------------
Write-Host "--- behavioural"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-bom-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$got = Join-Path $work "stdin.bin"
$env:BOM_GOT = $got
$engine = (Get-Process -Id $PID).Path
$env:BOM_PS = $engine

# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
$onWindows = ($env:OS -like "*Windows*")
if ($onWindows) {
    # A .cmd stub, as the real exapump is a native binary: PowerShell pipes
    # into it the same way. It copies its raw stdin to $env:BOM_GOT.
    $stub = Join-Path $work "exapump.cmd"
    Set-Content -Path $stub -Encoding Ascii -Value @(
        "@echo off",
        ('"%BOM_PS%" -NoProfile -NonInteractive -Command "$i=[Console]::OpenStandardInput();$o=[IO.File]::Create($env:BOM_GOT);$i.CopyTo($o);$o.Close()"'),
        "exit /b 0"
    )
} else {
    $stub = Join-Path $work "exapump"
    Set-Content -Path $stub -Value @(
        "#!/bin/sh",
        'cat > "$BOM_GOT"',
        "exit 0"
    )
    & chmod +x $stub
}

# The dependencies of the two functions, stubbed.
function Get-ExakitExapumpBin { return $stub }
function Test-ExapumpSucceeded { param($ExitCode, $Output) return ($ExitCode -eq 0) }
function Fail($message) { throw $message }
$script:ExapumpProfile = "starter-kit"
foreach ($site in $sites) {
    $fn = Get-FunctionAst $site.File $site.Name
    if ($null -ne $fn) { Invoke-Expression $fn.Extent.Text }
}

function Get-FirstHex {
    if (-not (Test-Path $got)) { return "(nothing received)" }
    $bytes = [System.IO.File]::ReadAllBytes($got)
    $n = [Math]::Min(3, $bytes.Length)
    return (@($bytes[0..($n - 1)] | ForEach-Object { $_.ToString("X2") }) -join " ")
}

$conditions = @("default console")
if ($onWindows) { $conditions += "console code page 65001" }
foreach ($condition in $conditions) {
    $savedOut = $null; $savedIn = $null
    if ($condition -eq "console code page 65001") {
        try { $savedOut = [Console]::OutputEncoding; $savedIn = [Console]::InputEncoding } catch { }
        & cmd.exe /c "chcp 65001 >nul"
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    }
    try {
        $inputBefore = $null
        try { $inputBefore = [Console]::InputEncoding.WebName } catch { }

        Remove-Item -Force -ErrorAction SilentlyContinue $got
        $r = Invoke-ExapumpAdminSql -ConfigPath (Join-Path $work "config.toml") -Profile "admin" -Sql "SELECT 1"
        $hex = Get-FirstHex
        Check "Invoke-ExapumpAdminSql, $($condition): stdin starts 53 45 4C" ($hex -eq "53 45 4C") "first bytes: $hex"
        Check "Invoke-ExapumpAdminSql, $($condition): no EF BB BF" (-not $hex.StartsWith("EF BB BF")) "first bytes: $hex"
        Check "Invoke-ExapumpAdminSql, $($condition): reports success" ($r.Success -eq $true) "output: $($r.Output)"

        $inputAfter = $null
        try { $inputAfter = [Console]::InputEncoding.WebName } catch { }
        Check "[Console]::InputEncoding is restored afterwards, $($condition)" ("$inputBefore" -eq "$inputAfter") "before $inputBefore, after $inputAfter"
    } finally {
        if ($null -ne $savedOut) { try { [Console]::OutputEncoding = $savedOut } catch { } }
        if ($null -ne $savedIn) { try { [Console]::InputEncoding = $savedIn } catch { } }
    }
}

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
Write-Host ""
Write-Host "exapump-stdin-bom-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
