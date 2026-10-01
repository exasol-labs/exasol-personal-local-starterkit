# ps-parse.ps1 - every .ps1 in this repo must PARSE under Windows PowerShell 5.1.
#
# This guard exists because a file that does not parse is not a broken feature,
# it is a broken PRODUCT: setup/exakit.ps1 dot-sources the library and the
# marketplace modules at startup, so one parse error anywhere in that set makes
# EVERY exakit command on Windows fail before it runs a line.
#
# Nothing already in CI catches it. The undefined-function sweep and the
# uninstall suite both extract function definitions and Invoke-Expression them
# inside try/catch, so a definition that will not parse is silently skipped and
# the suite stays green while the shipped command is dead. That is exactly how
# a misplaced param() block in Uninstall-DashServer reached a released kit.
#
# The real parser, not a regular expression: PowerShell's own rules about what
# may precede a param() block, where a script block's param() is legal and a
# function's is not, are not something a grep can be trusted to model.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -Path $root -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and
                   $_.FullName -notmatch '[\\/]\.claude[\\/]' } |
    Sort-Object FullName)

$checks = 0
$fails = 0
foreach ($file in $files) {
    $checks++
    $rel = $file.FullName.Substring($root.Length + 1)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and @($errors).Count -gt 0) {
        $fails++
        Write-Host ("FAIL {0} does not parse" -f $rel)
        foreach ($e in @($errors)) {
            Write-Host ("       line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Host ("ok   {0} parses" -f $rel)
    }
}

Write-Host ""
Write-Host ("{0} files, {1} failed" -f $checks, $fails)
if ($fails -gt 0) { exit 1 }
exit 0
