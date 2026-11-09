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
        if (-not $text.Contains('Manage this add-on')) { throw "$id has no standard lifecycle reference" }
        $page = Show-ExakitHelpJson $id | ConvertFrom-Json
        if ($page.management.install -ne "exakit marketplace $id" -or $page.management.uninstall_preview -ne "exakit uninstall $id --dry-run") {
            throw "$id management command drift"
        }
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
    foreach ($topic in @('model put','mlflow start','rust-udf build','notebook stop marimo')) {
        $json = Show-ExakitHelpJson $topic -CommandHelp | ConvertFrom-Json
        if ($json.commands[0].invocation -ne "exakit $topic") { throw "wrong command for $topic" }
        if (-not $json.commands[0].parameters) { throw "no arguments for $topic" }
        $checks++
    }
    $json = Show-ExakitHelpJson 'model imaginary-action' -CommandHelp | ConvertFrom-Json
    if ($json.ok -ne $false -or $json.count -ne 0 -or $script:ExakitHelpExitCode -ne 2) { throw 'unknown child guessed a parent' }
    if (Test-Path $script:ExakitHome) { throw 'help created an installation' }
    Write-Host "PASS $checks add-on page/family checks, command/JSON parity and no install side effects"
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
