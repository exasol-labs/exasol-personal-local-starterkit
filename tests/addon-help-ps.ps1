$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('exakit-help-' + [guid]::NewGuid())
$script:LibDir = Join-Path $repo 'setup/lib'
$script:ExakitHome = Join-Path $work 'kit'
. (Join-Path $script:LibDir 'help.ps1')
$checks = 0
try {
    foreach ($id in Get-ExakitHelpIds) {
        $doc = Get-ExakitHelpDocument $id
        if ($doc.kind -ne 'addon') { continue }
        $text = (Show-ExakitHelpComponent $id 6>&1 | Out-String)
        if (-not $text.Contains('Parameters and options')) { throw "$id has no parameter reference" }
        if (-not $text.Contains('Example:')) { throw "$id has no examples" }
        if ($id -eq 'dbt-exasol' -and $text.Contains('dbt-exasol dbt-exasol')) { throw 'duplicated native command' }
        $checks += 2
    }
    $text = (Show-ExakitHelpCommand 'udf-build' 6>&1 | Out-String)
    if (-not $text.Contains('--yes') -or -not $text.Contains('PYTHON3_CUSTOM')) { throw 'build arguments missing' }
    $text = (Show-ExakitHelpCommand 'exakit model' 6>&1 | Out-String)
    foreach ($action in @('put','inspect','list','rm','prune','template')) {
        if (-not $text.Contains("exakit model $action")) { throw "model $action disappeared from family help" }
        $checks++
    }
    $text = (Show-ExakitHelpCommand 'udf-setup' 6>&1 | Out-String)
    if (-not $text.Contains('Exit codes') -or -not $text.Contains('--language')) { throw 'exit/argument parity missing' }
    $json = Show-ExakitHelpJson 'udf-devkit' | ConvertFrom-Json
    $put = @($json.commands | Where-Object { $_.command -eq 'exakit model put' })[0]
    if (-not (@($put.parameters | Where-Object { $_.name -like '--yes*' }).Count)) { throw 'JSON lost parameter metadata' }
    if (Test-Path $script:ExakitHome) { throw 'help created an installation' }
    Write-Host "PASS $checks add-on page/family checks, command/JSON parity and no install side effects"
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
