# envfile.ps1 - the settings file: ~/.exasol-starter-kit/exakit.env (setup/exakit.env is
# its commented template). Twin of setup/lib/envfile.sh; install.ps1 carries a copy of
# Import-ExakitEnvFile. tests/env-file-ps.ps1 keeps them the same. PowerShell 5.1 safe.

# Get-ExakitEnvFilePath - where the settings file is: EXAKIT_ENV_FILE, else exakit.env in
# the kit's home (EXAKIT_HOME, else .exasol-starter-kit in the user's profile).
function Get-ExakitEnvFilePath {
    if ($env:EXAKIT_ENV_FILE) { return $env:EXAKIT_ENV_FILE }
    $homeDir = $env:EXAKIT_HOME
    if (-not $homeDir) {
        $base = $env:USERPROFILE
        if (-not $base) { $base = $HOME }
        $homeDir = Join-Path $base ".exasol-starter-kit"
    }
    return (Join-Path $homeDir "exakit.env")
}

# Import-ExakitEnvFile - set each NAME=value of the settings file that the environment
# does not already have: a command line still wins over the file. Nothing in it is run.
# Only EXAKIT_* names and EXASOL_TELEMETRY_DISABLE are taken; a secret's name (PASSWORD,
# API_KEY, TOKEN, SECRET) and EXAKIT_HOME / EXAKIT_ENV_FILE are refused and named in
# $script:ExakitEnvFileRefused. A value may be quoted; unquoted, " #" starts a comment.
function Import-ExakitEnvFile {
    $script:ExakitEnvFileRefused = @()
    $path = Get-ExakitEnvFilePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try { $lines = [System.IO.File]::ReadAllLines($path) } catch { return }
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ')) { $line = $line.Substring(7).TrimStart() }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $name = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($name -cnotmatch '^[A-Z0-9_]+$') { continue }
        if ($name -cnotmatch '^EXAKIT_' -and $name -cne 'EXASOL_TELEMETRY_DISABLE') { continue }
        if ($name -ceq 'EXAKIT_HOME' -or $name -ceq 'EXAKIT_ENV_FILE' -or $name -cmatch 'PASSWORD|API_KEY|TOKEN|SECRET') {
            $script:ExakitEnvFileRefused += $name
            continue
        }
        if ($value -match '^"([^"]*)"') { $value = $Matches[1] }
        elseif ($value -match "^'([^']*)'") { $value = $Matches[1] }
        else {
            $hash = $value.IndexOf(' #')
            $tab = $value.IndexOf("`t#")
            if ($tab -ge 0 -and ($hash -lt 0 -or $tab -lt $hash)) { $hash = $tab }
            if ($hash -ge 0) { $value = $value.Substring(0, $hash) }
            $value = $value.TrimEnd()
        }
        if ($null -ne [Environment]::GetEnvironmentVariable($name)) { continue }
        [Environment]::SetEnvironmentVariable($name, $value)
    }
}

# Install-ExakitEnvFile -KitRoot - the template becomes the settings file on the first
# install. An existing file is never touched: it is the user's.
function Install-ExakitEnvFile {
    param([Parameter(Mandatory)][string]$KitRoot)
    $target = Get-ExakitEnvFilePath
    if (Test-Path -LiteralPath $target) { return }
    $template = Join-Path (Join-Path $KitRoot "setup") "exakit.env"
    if (-not (Test-Path -LiteralPath $template)) { return }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $template -Destination $target -ErrorAction Stop
    } catch { }
}

# Write-ExakitEnvFileNote - one line naming the settings the file may not hold.
function Write-ExakitEnvFileNote {
    if (-not $script:ExakitEnvFileRefused -or @($script:ExakitEnvFileRefused).Count -eq 0) { return }
    [Console]::Error.WriteLine("      ! $(Get-ExakitEnvFilePath) ignores $(@($script:ExakitEnvFileRefused) -join ' '): a secret, or where the file itself lives, stays in the environment")
}
