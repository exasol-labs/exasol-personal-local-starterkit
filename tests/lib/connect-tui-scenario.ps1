# Driven by tests/lib/tty-replay.py (through connect-tui-scenario-ps.sh) from
# tests/virtual-schemas.sh: the PowerShell twin of `exakit connect` with no
# arguments - the menu, one panel, the review and the live table - against the
# suite's simulated database (TUI_* from the caller). Shipping code throughout:
# ui.ps1 and virtual-schemas.ps1; only the kit around them is replaced.
param([string]$Root)
$ErrorActionPreference = "Stop"
$script:ExakitHome = $env:TUI_KIT
$script:LogFile = $env:TUI_LOG
. (Join-Path $Root "setup/lib/ui.ps1")
. (Join-Path $Root "setup/lib/core-setup.ps1")
. (Join-Path $Root "setup/lib/virtual-schemas.ps1")
if (-not (Test-Path -LiteralPath $script:LogFile)) { New-Item -ItemType File -Path $script:LogFile | Out-Null }
# The palette a Windows console with VT gets; macOS has no kernel32 to ask.
$script:UiFancy = $true
Set-ExakitPalette
function Write-ExakitLog { param($L, $M) Add-Content -LiteralPath $script:LogFile -Value "$L $M" }
function Info([string]$M) { [Console]::Write("    " + $script:UiDim + $script:UiBullet + $script:UiReset + " " + $M + "`r`n") }
function Ok([string]$M) { [Console]::Write("      " + $script:UiOk + $script:UiTick + $script:UiReset + " " + $M + "`r`n") }
function Warn2([string]$M) { [Console]::Write("      " + $script:UiWarn + "!" + $script:UiReset + " " + $M + "`r`n") }
function Test-ExakitInteractive { return $true }
function Get-ExakitVsDefs { return $env:TUI_DEFS }
function Get-PyexasolVenvPython { return (Get-Command python3).Source }
function Get-ExakitManifestValue { param([string]$Path)
    switch ($Path) { "runtime.deployment_dir" { return $env:TUI_DEPLOY } "runtime.dsn" { return "127.0.0.1:8563" }
                     "runtime.user" { return "sys" } default { return "" } } }
function Repair-PersonalSlcDns { return $true }
$env:EXAKIT_VS_FAKE_DB = Join-Path $Root "tests/lib/fake-exasol-vs.py"
$env:FAKE_VS_STATE = $env:TUI_STATE
$env:FAKE_VS_EXA = $env:TUI_EXA
$env:EXAKIT_VS_SETTLE_SECONDS = "0"
$env:EXAKIT_VS_VISIBLE_TIMEOUT = "5"
$script:ExakitVsAssumeYes = $false
exit (Invoke-ExakitVsTui)
