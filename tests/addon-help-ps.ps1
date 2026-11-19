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
    $text = (Show-ExakitHelpCommand 'uninstall' 6>&1 | Out-String)
    if (-not $text.Contains('--yes') -or -not $text.Contains('--dry-run')) { throw 'uninstall arguments missing' }
    $text = (Show-ExakitHelpCommand 'data-load' 6>&1 | Out-String)
    if (-not $text.Contains('Exit codes') -or -not $text.Contains('--force')) { throw 'exit/argument parity missing' }
    $json = Show-ExakitHelpJson 'json-tables' | ConvertFrom-Json
    $ingest = @($json.commands | Where-Object { $_.command -eq 'exasol-json-tables ingest' })[0]
    if (-not (@($ingest.parameters | Where-Object { $_.name -like '--input*' }).Count)) { throw 'JSON lost parameter metadata' }
    foreach ($topic in @('exakit uninstall','exakit connect','exapump profile init','exasol mcp status')) {
        $json = Show-ExakitHelpJson $topic -CommandHelp | ConvertFrom-Json
        if ($json.commands[0].invocation -ne $topic) { throw "wrong command for $topic" }
        $checks++
    }
    $json = Show-ExakitHelpJson 'connect imaginary-action' -CommandHelp | ConvertFrom-Json
    if ($json.ok -ne $false -or $json.count -ne 0 -or $script:ExakitHelpExitCode -ne 2) { throw 'unknown child guessed a parent' }
    if (Test-Path $script:ExakitHome) { throw 'help created an installation' }
    Write-Host "PASS $checks add-on page/family checks, command/JSON parity and no install side effects"
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
