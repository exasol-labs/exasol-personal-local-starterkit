# ps-param-placement.ps1 - a function's param() block must be the FIRST thing in
# its body, or PowerShell does not treat it as a parameter block at all.
#
# This is not a parse error, which is exactly why it is dangerous and why
# tests/ps-parse.ps1 does not catch it. Put a statement above param() and the
# parser simply reads `param(...)` as a COMMAND invocation: the file parses, the
# function defines, and the declared parameters silently do not exist. Calling it
# with the switch it appears to accept fails at run time, and reading the source
# tells you nothing is wrong.
#
# Uninstall-DashServer shipped in kit 0.2.1 in exactly that state:
#
#     function Uninstall-DashServer {
#         Resolve-DashServerPort
#         param([switch]$DryRun)
#
# so `exakit uninstall --dry-run` could not reach the dry-run path of the one
# hook whose whole contract is "narrate the plan, remove nothing".
#
# The real parser decides, not a regular expression: a param() block inside a
# nested SCRIPT BLOCK is perfectly legal and common in this repo
# ($addRow = { param($label, $state, $ids) ... } in mcp.ps1). Those parse as the
# script block's own ParamBlock and never appear as a command, so the AST
# distinguishes the two shapes for free where a grep could not.
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
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if (-not $ast) {
        $fails++
        Write-Host ("FAIL {0} could not be parsed at all" -f $rel)
        continue
    }
    $bad = @()
    $fns = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($fn in $fns) {
        # A properly placed param() becomes the body's ParamBlock. Anything
        # else that still mentions param at command position is the bug.
        if ($fn.Body -and $fn.Body.ParamBlock) { continue }
        $cmds = @($fn.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        foreach ($cmd in $cmds) {
            $name = ""
            try { $name = "" + $cmd.GetCommandName() } catch { }
            if (-not $name) {
                $text = "" + $cmd.Extent.Text
                if ($text -match '^\s*param\s*\(') { $name = "param" }
            }
            if ($name -eq "param") {
                $bad += ("{0} (line {1})" -f $fn.Name, $cmd.Extent.StartLineNumber)
                break
            }
        }
    }
    if ($bad.Count -gt 0) {
        $fails++
        Write-Host ("FAIL {0} declares param() after a statement, so the parameters do not exist: {1}" -f $rel, ($bad -join ", "))
    } else {
        Write-Host ("ok   {0} declares every param() block first" -f $rel)
    }
}

Write-Host ""
Write-Host ("{0} files, {1} failed" -f $checks, $fails)
if ($fails -gt 0) { exit 1 }
exit 0
