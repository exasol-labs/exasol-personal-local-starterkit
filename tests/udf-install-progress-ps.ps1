$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('exakit-udf-progress-' + [guid]::NewGuid())
$env:EXAKIT_HOME = Join-Path $work 'kit'
$env:EXAKIT_BIN_DIR = Join-Path $work 'bin'
. (Join-Path $repo 'setup/lib/exakit-common.ps1')
. (Join-Path $repo 'setup/lib/udf-devkit.ps1')
function Info($m) { }
function Get-ExakitServiceIds { @() }
$script:UiFancy = $false
$script:ExakitAddonTable = New-ExakitTable -Title 'Add-ons' -Col1 'Add-on'
$table = $script:ExakitAddonTable
[void](Add-ExakitTableRow -Kind group -Label 'Select All' -Table $table)
[void](Add-ExakitTableRow -Kind corner -Label 'udf-devkit' -Table $table)
$script:ExakitAddonTableRow = 2
Set-ExakitAddonProgress -Id udf-devkit -Pct 0 -Ceiling 65 -Secs 40 -Phase installing
$script:UdfYes = $true
$script:UdfProgressSection = 'primary'
function Wait-PersonalReady {
    if ($script:ExakitAddonTable.Rows[1].Phase -ne 'Waiting for database restart') { throw 'restart phase missing' }
}
try {
    $ok = Invoke-UdfWithRestart 'Installing official PYTHON3 container' {
        if ($table.Rows[1].Phase -ne 'Installing official PYTHON3 container') { throw 'real launcher step hidden' }
        $true
    }
    if (-not $ok) { throw 'fixture install failed' }
    $first = $table.Rows[1].Pct
    $script:UdfProgressSection = 'ml'
    Set-UdfInstallStage download 'Downloading Python ML container (842 MB)'
    if ($table.Rows[1].Pct -le $first) { throw 'ML download did not advance' }
    Set-UdfInstallStage verify 'Verifying download checksum'
    Set-UdfInstallStage prepare 'Preparing the Python ML runtime'
    [void](Invoke-UdfWithRestart 'Installing PYTHON3_ML container' { $true })
    Set-UdfInstallStage smoke 'Checking packages in PYTHON3_ML'
    if ($table.Rows[1].Pct -ne 63 -or $table.Activity -ne 'Checking packages in PYTHON3_ML') { throw 'package verification phase missing' }
    $script:UdfProgressSection = ''
    Set-ExakitAddonProgress -Id udf-devkit -Pct 65 -Ceiling 90 -Secs 8 -Phase validating
    Set-UdfInstallStage smoke 'Validation checks'
    if ($table.Rows[1].Pct -ne 65) { throw 'validation progress went backwards' }
    Write-Host 'PASS real launcher/restart boundaries and ML milestones; no validation regression'
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
