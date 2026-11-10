# Public PowerShell Rust UDF command contract.
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-rust-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "kit"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:UV_CACHE_DIR = Join-Path $work "uv-cache"
$env:EXAKIT_VERSION_POLICY = "pinned"
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME, $env:EXAKIT_BIN_DIR | Out-Null
$hostBin = if ($PSVersionTable.PSEdition -eq "Desktop") { "powershell" } else { "pwsh" }
function Run([string[]]$Words) {
    $script:OutputLines = @(& $hostBin -NoProfile -File (Join-Path $repo "setup/exakit.ps1") "rust-udf" @Words 2>&1 |
        ForEach-Object { "$_" })
    $script:Code = $LASTEXITCODE
    $jsonLine = @($script:OutputLines | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    if ($jsonLine.Count -ne 1) { throw "Rust UDF did not return JSON: $($script:OutputLines -join '; ')" }
    return ($jsonLine[0] | ConvertFrom-Json)
}
try {
    $missing = Run @("build", "score_model", "--json")
    if ($Code -ne 4 -or $missing.ok -or $missing.remedy -ne "exakit marketplace udf-devkit") {
        throw "Missing UDF devkit refusal differs on PowerShell"
    }
    [System.IO.File]::WriteAllText((Join-Path $env:EXAKIT_HOME "manifest.json"),
        '{"components":{"udf_devkit":{"version":"0.1.0"}}}')
    $created = Run @("new", "score_model", "--json")
    if ($Code -ne 0 -or -not $created.ok -or @($created.features).Count -ne 1 -or
        $created.features[0] -ne "VALUE_") { throw "Rust UDF project creation failed on PowerShell" }
    if (-not (Test-Path (Join-Path $env:EXAKIT_HOME "rust-udfs/score_model/src/lib.rs"))) {
        throw "Rust UDF source was not created"
    }
    Write-Output "rust-udf public PowerShell CLI: OK"
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
