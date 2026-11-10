#!/usr/bin/env pwsh
# env-file-ps.ps1 - the Windows twin of tests/env-file.sh: setup/lib/envfile.ps1 reads the
# settings file as written (nothing run, the environment wins, only EXAKIT_* names, secrets
# refused), the shipped template sets nothing and refuses nothing, the first install copies
# it once, and install.ps1 carries the same loader. Runs under Windows PowerShell 5.1 and pwsh.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-envfile-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
$names = @("EXAKIT_DB_PORT", "EXAKIT_PERSONA", "EXAKIT_DATASETS_MIRROR", "EXAKIT_REF", "EXAKIT_LOCAL_KIT",
           "EXAKIT_PROVIDER_API_KEY", "EXAKIT_VERSION_POLICY", "EXAKIT_VERSIONS_URL", "EXAKIT_ENV_FILE")
# Remove-Item, not SetEnvironmentVariable($n, $null): PowerShell passes that $null on as "",
# which leaves the name set (and the loader rightly leaves a set name alone).
function Clear-Names { foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue } }
try {
    . (Join-Path $repo "setup/lib/envfile.ps1")
    Write-Host "== the loader =="
    $ran = Join-Path $work "ran"
    $lines = @('# a comment', '', '  EXAKIT_DB_PORT=9563     # an inline comment', 'export EXAKIT_PERSONA=general',
               'EXAKIT_DATASETS_MIRROR="C:\a dir\#x"', "EXAKIT_REF='feat/x'", "EXAKIT_LOCAL_KIT=`$(New-Item $ran)",
               'PATH=C:\nowhere', 'EXAKIT_PROVIDER_API_KEY=sk-1', 'EXAKIT_HOME=C:\elsewhere', 'exakit_lower=1',
               'EXAKIT_VERSION_POLICY=pinned', 'EXAKIT_VERSIONS_URL=https://h/p#frag', 'not a setting')
    $case = Join-Path $work "case.env"
    [System.IO.File]::WriteAllText($case, ($lines -join "`r`n") + "`r`n")
    Clear-Names
    $env:EXAKIT_ENV_FILE = $case
    $env:EXAKIT_VERSION_POLICY = "latest"
    $path = $env:PATH
    Import-ExakitEnvFile
    Check "a line with spaces and an inline comment (CRLF too)" "9563" $env:EXAKIT_DB_PORT
    Check "export NAME=value" "general" $env:EXAKIT_PERSONA
    Check "a double-quoted value keeps its spaces and #" "C:\a dir\#x" $env:EXAKIT_DATASETS_MIRROR
    Check "a single-quoted value" "feat/x" $env:EXAKIT_REF
    Check "nothing is run: `$(...) stays text" "`$(New-Item $ran)" $env:EXAKIT_LOCAL_KIT
    Check "...and ran nothing" $false (Test-Path -LiteralPath $ran)
    Check "PATH is not the file's to set" $path $env:PATH
    Check "a secret is refused" $true ($null -eq $env:EXAKIT_PROVIDER_API_KEY)
    Check "the environment wins over the file" "latest" $env:EXAKIT_VERSION_POLICY
    Check "a # inside an unquoted URL is kept" "https://h/p#frag" $env:EXAKIT_VERSIONS_URL
    Check "the refused names are named" "EXAKIT_PROVIDER_API_KEY EXAKIT_HOME" (@($script:ExakitEnvFileRefused) -join ' ')

    Write-Host "== the template =="
    Clear-Names
    $before = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'EXAKIT_*' -or $_.Name -eq 'EXASOL_TELEMETRY_DISABLE' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'
    $env:EXAKIT_ENV_FILE = Join-Path $repo "setup/exakit.env"
    Import-ExakitEnvFile
    Remove-Item Env:EXAKIT_ENV_FILE
    $after = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'EXAKIT_*' -or $_.Name -eq 'EXASOL_TELEMETRY_DISABLE' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'
    Check "as shipped (all commented) it sets nothing" $before $after
    $all = Join-Path $work "all.env"
    $uncommented = Get-Content -LiteralPath (Join-Path $repo "setup/exakit.env") | ForEach-Object { $_ -replace '^# (EXAKIT_[A-Z0-9_]+=|EXASOL_TELEMETRY_DISABLE=)', '$1' }
    [System.IO.File]::WriteAllLines($all, [string[]]$uncommented)
    $env:EXAKIT_ENV_FILE = $all
    Remove-Item Env:EXAKIT_DB_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:EXAKIT_VERSION_POLICY -ErrorAction SilentlyContinue
    Import-ExakitEnvFile
    Check "uncommented, every line is accepted (it lists no secret)" "" (@($script:ExakitEnvFileRefused) -join ' ')
    Check "...and the values are the defaults, comments cut off" "8563|manifest" "$($env:EXAKIT_DB_PORT)|$($env:EXAKIT_VERSION_POLICY)"
    Remove-Item Env:EXAKIT_ENV_FILE

    Write-Host "== the first install copies it, once =="
    $kit = Join-Path $work "kit"
    New-Item -ItemType Directory -Force -Path (Join-Path $kit "setup") | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo "setup/exakit.env") -Destination (Join-Path $kit "setup")
    $env:EXAKIT_HOME = Join-Path $work "home"
    Install-ExakitEnvFile -KitRoot $kit
    $target = Join-Path $env:EXAKIT_HOME "exakit.env"
    Check "the template is in the kit home" (Get-FileHash (Join-Path $repo "setup/exakit.env")).Hash (Get-FileHash $target).Hash
    [System.IO.File]::WriteAllText($target, "EXAKIT_DB_PORT=1`n")
    Install-ExakitEnvFile -KitRoot $kit
    Check "the user's copy is never overwritten" "EXAKIT_DB_PORT=1" ((Get-Content -LiteralPath $target -Raw).Trim())
    Remove-Item Env:EXAKIT_HOME

    Write-Host "== install.ps1 carries the same loader =="
    $own = Get-Content -LiteralPath (Join-Path $repo "setup/lib/envfile.ps1") -Raw
    $copy = Get-Content -LiteralPath (Join-Path $repo "install.ps1") -Raw
    $part = $own.Substring($own.IndexOf("# Get-ExakitEnvFilePath"), $own.IndexOf("# Install-ExakitEnvFile") - $own.IndexOf("# Get-ExakitEnvFilePath"))
    Check "the same functions, character for character" $true ($copy.Replace("`r`n", "`n").Contains($part.Replace("`r`n", "`n")))
    $common = (Get-Content -LiteralPath (Join-Path $repo "setup/lib/exakit-common.ps1") -Raw).Replace("`r`n", "`n")
    $load = $common.IndexOf("Import-ExakitEnvFile")
    $telemetry = $common.IndexOf("`nSet-ExakitTelemetryDefault`n")
    Check "exakit-common.ps1 reads it before the telemetry default" $true ($load -ge 0 -and $telemetry -gt $load)
} finally {
    Clear-Names
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "env-file-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
