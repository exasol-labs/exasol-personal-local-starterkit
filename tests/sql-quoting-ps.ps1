#!/usr/bin/env pwsh
# sql-quoting-ps.ps1 - WIN-05: `exakit sql` hands the statement to exapump with its double quotes, on
# the --json branch as on the plain one, and takes it on stdin (the way to keep a quote from Windows
# PowerShell 5.1, which drops it from an argument before exakit.cmd runs). A stub exapump records the
# argument vector it was given; on Windows PowerShell it is a compiled program, so the real Windows
# command-line parser is the one that reads it. Runs under Windows PowerShell 5.1 and pwsh.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
$engine = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-sqlq-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$seen = Join-Path $work "argv"
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
try {
    # The stub: each argument it received on a line of its own after a marker, then "[]" for -f json.
    if ($onWindows) {
        $stub = Join-Path $work "exapump.exe"
        $source = @"
using System; using System.IO; using System.Text;
public static class Stub { public static int Main(string[] args) {
    var b = new StringBuilder(); foreach (var a in args) { b.Append("<<").Append(a).Append(">>\n"); }
    File.WriteAllText(Environment.GetEnvironmentVariable("SQLQ_OUT"), b.ToString(), new UTF8Encoding(false));
    Console.WriteLine("[]"); return 0; } }
"@
        Add-Type -TypeDefinition $source -OutputAssembly $stub -OutputType ConsoleApplication
    } else {
        $stub = Join-Path $work "exapump"
        Set-Content -Path $stub -Encoding ascii -Value @(
            "#!/bin/sh",
            ": > `"`$SQLQ_OUT`"",
            "for a in `"`$@`"; do printf '<<%s>>\n' `"`$a`" >> `"`$SQLQ_OUT`"; done",
            "echo '[]'")
        & chmod +x $stub
    }
    $kitHome = Join-Path $work "kit-home"
    New-Item -ItemType Directory -Force -Path $kitHome | Out-Null
    Set-Content -Path (Join-Path $kitHome "manifest.json") -Encoding ascii -Value '{"runtime":{"type":"personal","dsn":"127.0.0.1:8563"}}'
    $env:EXAKIT_HOME = $kitHome
    $env:EXAKIT_EXAPUMP_BIN = $stub
    $env:EXAKIT_NO_UPDATE_NOTICE = "1"
    $env:SQLQ_OUT = $seen
    $cli = Join-Path $repo "setup/exakit.ps1"
    function Statement-Seen {
        if (-not (Test-Path $seen)) { return "<nothing>" }
        $lines = @([System.IO.File]::ReadAllText($seen) -split "`n" | Where-Object { $_ })
        return ($lines[$lines.Count - 1] -replace '^<<', '' -replace '>>$', '')
    }
    $q = 'SELECT "name", ''it''''s'' FROM "s1"."t2"'

    # A Continue window: on 5.1 a native command's redirected stderr is otherwise a terminating error.
    $ErrorActionPreference = "Continue"
    Write-Host "== an argument keeps its double quotes =="
    Remove-Item $seen -ErrorAction SilentlyContinue
    $out = (& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cli sql --json $q 2>$null | Out-String).Trim()
    Check "--json: exapump receives the statement as written" $q (Statement-Seen)
    Check "--json: one JSON answer" '{"ok":true,"rows":[]}' $out
    Remove-Item $seen -ErrorAction SilentlyContinue
    [void](& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cli sql $q 2>$null)
    Check "plain: exapump receives the statement as written" $q (Statement-Seen)

    Write-Host "== a statement on stdin =="
    Remove-Item $seen -ErrorAction SilentlyContinue
    $out = ($q | & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cli sql --json 2>$null | Out-String).Trim()
    Check "stdin: exapump receives the statement as written" $q (Statement-Seen)
    Check "stdin: one JSON answer" '{"ok":true,"rows":[]}' $out

    $ErrorActionPreference = "Stop"
    Write-Host "== the 5.1 rules, applied only where they hold =="
    . (Join-Path $repo "setup/lib/exakit-common.ps1") *> $null
    $saved = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
    if ($PSVersionTable.PSVersion.Major -ge 7) { $PSNativeCommandArgumentPassing = "Legacy" }
    Check "a quote is escaped" 'SELECT \"a\"' @(ConvertTo-ExakitNativeArgs @('SELECT "a"'))[0]
    Check "a trailing backslash in a spaced argument is doubled" 'LIKE C:\\' @(ConvertTo-ExakitNativeArgs @('LIKE C:\'))[0]
    Check "...but not in one without a space (5.1 does not wrap it)" 'C:\' @(ConvertTo-ExakitNativeArgs @('C:\'))[0]
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $PSNativeCommandArgumentPassing = "Standard"
        Check "a passed-through vector is left alone" 'LIKE C:\' @(ConvertTo-ExakitNativeArgs @('LIKE C:\'))[0]
        if ($saved) { $PSNativeCommandArgumentPassing = $saved }
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
