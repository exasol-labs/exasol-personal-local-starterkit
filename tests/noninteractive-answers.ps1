# noninteractive-answers.ps1 - PowerShell-native twin of
# tests/noninteractive-answers.sh. Proves the Windows install path resolves the
# same pre-set environment answers an agent-driven or scripted install relies
# on, so the documented EXAKIT_MCP_CLIENTS contract cannot silently drift from
# the bash side (as it had - the .ps1 path used to ignore these vars entirely).
#
# Pure logic: dot-sources the Windows lib chain against a throwaway state dir
# and exercises ConvertTo-McpClientSelection (what EXAKIT_MCP_CLIENTS feeds).
# No installs, no database, no changes to the real machine.
#
#   pwsh tests/noninteractive-answers.ps1        # PowerShell 7+
#   powershell tests/noninteractive-answers.ps1  # Windows PowerShell 5.1

$ErrorActionPreference = "Stop"
$lib = Join-Path $PSScriptRoot "..\setup\lib"

# Point the kit's state + bin dirs at a throwaway location so loading the libs
# never touches the real ~/.exasol-starter-kit.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-nia-" + [guid]::NewGuid().ToString("N"))
$env:EXAKIT_HOME = $tmp
$env:EXAKIT_BIN_DIR = Join-Path $tmp "bin"

$script:Pass = 0
$script:Fail = 0
function Check {  # Check <label> <expected> <actual (array or string)>
    param([string]$Label, [string]$Expected, $Actual)
    $got = ($Actual -join ",")
    if ($got -eq $Expected) {
        $script:Pass++; Write-Host ("  ok   {0} = {1}" -f $Label, $got)
    } else {
        $script:Fail++; Write-Host ("  FAIL {0}: expected {1}, got {2}" -f $Label, $Expected, $got)
    }
}

try {
    . (Join-Path $lib "exakit-common.ps1")
    . (Join-Path $lib "exapump.ps1")
    . (Join-Path $lib "mcp.ps1")

    Write-Host "EXAKIT_MCP_CLIENTS - client selection parses names, 'all', and numbers:"
    # "claude" (or 1) expands to both Claude surfaces (desktop app + Claude Code
    # CLI); "all" covers every supported client. Keep these in lockstep with
    # ConvertTo-McpClientSelection in setup/lib/mcp.ps1 and the bash twin.
    Check "claude,cursor" "claude_desktop,claude_code,cursor" (ConvertTo-McpClientSelection "claude,cursor")
    Check "all"           "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" (ConvertTo-McpClientSelection "all")
    Check "1,2"           "claude_desktop,claude_code,codex" (ConvertTo-McpClientSelection "1,2")
    Check "opencode"      "opencode" (ConvertTo-McpClientSelection "opencode")
    Check "number 6"      "opencode" (ConvertTo-McpClientSelection "6")
    Check "continue"      "continue" (ConvertTo-McpClientSelection "continue")
    Check "number 7"      "continue" (ConvertTo-McpClientSelection "7")
    Check "dedupes"       "claude_desktop,claude_code" (ConvertTo-McpClientSelection "claude,1,claude")
    Check "single surface" "claude_code" (ConvertTo-McpClientSelection "claude_code")
    Check "copilot"       "vscode_copilot" (ConvertTo-McpClientSelection "copilot")
    Check "gemini"        "gemini_cli" (ConvertTo-McpClientSelection "gemini")

    $invalid = ConvertTo-McpClientSelection "bogus"
    if ($null -eq $invalid) {
        $script:Pass++; Write-Host "  ok   invalid rejected = rejected"
    } else {
        $script:Fail++; Write-Host ("  FAIL invalid rejected: expected rejected, got {0}" -f ($invalid -join ","))
    }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:EXAKIT_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:EXAKIT_BIN_DIR -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("noninteractive-answers (ps): {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -ne 0) { exit 1 }
