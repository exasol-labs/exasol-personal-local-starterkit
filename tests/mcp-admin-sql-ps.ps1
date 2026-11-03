#!/usr/bin/env pwsh
# mcp-admin-sql-ps.ps1 - the read-only setup's admin SQL reaches exapump as the statement's own UTF-8 bytes (#52).
# Windows PowerShell 5.1 starts a string piped into a native process with U+FEFF whatever $OutputEncoding says,
# and Exasol rejects that first character, so `exakit mcp-setup` failed on every statement. The real
# Invoke-ExapumpAdminSql from setup/lib/mcp.ps1 runs here against a stand-in exapump that records the bytes it
# reads on stdin. Runs under Windows PowerShell 5.1 and pwsh.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}

$python = (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) { Write-Host "SKIP: no Python for the stand-in exapump"; exit 0 }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-admin-sql-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $captured = Join-Path $work "stdin.bin"
    @"
import os, sys
data = sys.stdin.buffer.read()
open(os.environ["EXAKIT_TEST_CAPTURE"], "wb").write(data)
print("args: " + " ".join(sys.argv[1:]))
sys.stderr.write("1 statement executed, 0 failed\n")
sys.exit(int(os.environ.get("EXAKIT_TEST_EXIT", "0")))
"@ | Set-Content -Path (Join-Path $work "capture.py") -Encoding ascii
    $onWindows = $true
    if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $onWindows = [bool]$IsWindows }
    if ($onWindows) {
        $fake = Join-Path $work "exapump.cmd"
        "@`"$($python.Source)`" `"%~dp0capture.py`" %*" | Set-Content -Path $fake -Encoding ascii
    } else {
        $fake = Join-Path $work "exapump"
        "#!/bin/sh`nexec `"$($python.Source)`" `"$work/capture.py`" `"`$@`"" | Set-Content -Path $fake -Encoding ascii
        & chmod +x $fake
    }

    # The function under test, as shipped, with the helpers it calls stood in.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/mcp.ps1"), [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-ExapumpAdminSql" }, $true)
    function Get-ExakitExapumpBin { return $fake }
    function Fail([string]$Message) { throw $Message }
    function Test-ExapumpSucceeded { param($ExitCode, $Output) return ($ExitCode -eq 0) }
    Invoke-Expression $definition.Extent.Text

    $env:EXAKIT_TEST_CAPTURE = $captured
    # A password with non-ASCII letters (built from code points: this file stays ASCII for 5.1).
    $sql = "CREATE USER `"mcp_readonly`" IDENTIFIED BY `"p$([char]0xE4)ssw$([char]0xF6)rd-1`""
    $result = Invoke-ExapumpAdminSql -ConfigPath (Join-Path $work "config.toml") -Profile "starter-kit" -Sql $sql
    $bytes = [System.IO.File]::ReadAllBytes($captured)
    $expected = (New-Object System.Text.UTF8Encoding($false)).GetBytes($sql)
    Write-Host "== the statement reaches exapump as its own bytes =="
    Check "no byte order mark before the statement" "False" (($bytes.Length -ge 3) -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Check "exactly the statement's UTF-8 bytes, non-ASCII password included" ([Convert]::ToBase64String($expected)) ([Convert]::ToBase64String($bytes))
    Check "the profile is passed, the statement is not on the command line" "True" (($result.Output -match "args: sql -p starter-kit") -and -not ($result.Output -match "IDENTIFIED"))
    Check "a success is reported" "True" $result.Success
    Check "exapump's own words come back" "True" ($result.Output -match "1 statement executed")

    Write-Host "== a failure is reported as one =="
    $env:EXAKIT_TEST_EXIT = "3"
    $failed = Invoke-ExapumpAdminSql -ConfigPath (Join-Path $work "config.toml") -Profile "starter-kit" -Sql "SELECT 1"
    Check "the exit code comes back" 3 $failed.ExitCode
    Check "and is not a success" "False" $failed.Success
} finally {
    Remove-Item Env:\EXAKIT_TEST_CAPTURE -ErrorAction SilentlyContinue
    Remove-Item Env:\EXAKIT_TEST_EXIT -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host "mcp-admin-sql-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
