# mcp.ps1 - Exasol MCP server module: install/validate, dedicated read-only
# database user provisioning, and client config generation (Windows /
# PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1 after
# exakit-common.ps1 and exapump.ps1. Mirrors setup/lib/mcp.sh plus the
# MCP-specific functions from setup/lib/common.sh function-for-function.
#
# Guardrail layering (same as bash):
#   1. server is read-only by design
#   2. dedicated read-only database user, provisioned and posture-checked by
#      Set-McpReadonlyAccess
#   3. client configs (generated via the Python mcp package, OS-agnostic)
#      point at that user, never the admin user

$script:McpHttpPort = if ($env:EXAKIT_MCP_HTTP_PORT) { $env:EXAKIT_MCP_HTTP_PORT } else { "8123" }

# Get-UvxPath - resolve the uvx launcher to a full path. uv installs uvx into
# ~/.local/bin (or $BinDir), which is NOT on the current process's PATH right
# after install, so a bare "uvx" invocation fails during setup even though uv
# is present. Always prefer the resolved path.
function Get-UvxPath {
    $cmd = Get-Command uvx -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in @($script:BinDir, (Join-Path $HOME ".local\bin"))) {
        $candidate = Join-Path $dir "uvx.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return "uvx"
}

function Get-McpCommandPath {
    $manifestCommand = Get-ExakitManifestValue "components.mcp_server.command"
    if ($manifestCommand) { return $manifestCommand }
    return (Get-UvxPath)
}

function Get-McpSslCertValidation {
    # Disable certificate validation ONLY for the local self-signed loopback
    # runtime, keyed on the DSN host - never on the runtime.tls label alone.
    # Every runtime hardcodes tls="self-signed", so keying on the label would
    # blanket-disable validation even for a non-loopback DSN (adopted from a
    # deployment.json), sending credentials over an unvalidated channel.
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if ($dsn -match '^(127\.0\.0\.1|localhost|\[::1\]):') { return "no" }
    return "yes"
}

function Install-Mcp {
    Install-ExakitUv | Out-Null
    Info "Priming $($script:McpPackage)@$($script:McpVersion) (downloads on first use)"
    # Use the resolved uvx path, not a bare "uvx" - uv was just installed to
    # a dir that isn't on this process's PATH yet.
    # `--help` exits non-zero on server versions that demand connection env
    # before printing usage - so the exit code can't distinguish "download
    # failed" from "downloaded fine, refused to run without a database". Any
    # output from the package itself proves the prime worked (mirrors mcp.sh).
    $primeOut = ""
    $primeCode = 1
    $previousEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $primeOut = & (Get-UvxPath) "$($script:McpPackage)@$($script:McpVersion)" "--help" 2>&1 | Out-String
        $primeCode = $LASTEXITCODE
    } catch {
        $primeOut = "$_"
    } finally {
        $ErrorActionPreference = $previousEAP
    }
    if ($script:LogFile) { "uvx $($script:McpPackage)@$($script:McpVersion) --help" | Add-Content -Path $script:LogFile; $primeOut | Add-Content -Path $script:LogFile }
    if ($primeCode -eq 0 -or $primeOut -match '(?i)usage:|insufficient database connection|exasol[./\\]ai[./\\]mcp|site-packages[/\\]exasol') {
        Ok "MCP server package cached"
    } else {
        Warn2 "Could not prime the MCP server package (it will download on first client start)"
    }
    $uvBin = Get-ExakitUvBin
    if ($uvBin) { Set-ExakitManifestValue "components.mcp_server.uv_path" $uvBin }
    Set-ExakitManifestValue "components.mcp_server.command" (Get-McpCommandPath)
    Set-ExakitManifestValue "components.mcp_server.package" $script:McpPackage
    Set-ExakitManifestValue "components.mcp_server.version" $script:McpVersion
    Ok "MCP server ready to run via uvx"
}

# Get-McpCredentials - "user, password_file" for the client configs. Prefers
# the validated dedicated read-only user; falls back to the runtime admin
# user if MCP read-only provisioning has not run.
function Get-McpCredentials {
    $connectionUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $connectionPwFile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    if ($connectionUser -and $connectionPwFile) { return @{ User = $connectionUser; PasswordFile = $connectionPwFile } }
    return @{ User = (Get-ExakitManifestValue "runtime.user"); PasswordFile = (Get-ExakitManifestValue "runtime.password_file") }
}

function Resolve-McpCredentials {
    $creds = Get-McpCredentials
    $password = ""
    if ($creds.PasswordFile -and (Test-Path $creds.PasswordFile)) {
        $password = (Get-Content $creds.PasswordFile -Raw).TrimEnd("`r", "`n")
    }
    return @{ User = $creds.User; Password = $password }
}

# Test-McpServer - start the server over stdio and check it answers an MCP
# initialize handshake. Uses the same env the client configs use.
function Test-McpServer {
    Info "Validating the MCP server (stdio handshake)"
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $creds = Resolve-McpCredentials
    $command = Get-McpCommandPath
    $sslCertValidation = Get-McpSslCertValidation

    $handshakeScript = @'
import json, subprocess, sys

command, pkg, ver = sys.argv[1], sys.argv[2], sys.argv[3]
proc = subprocess.Popen(
    [command, f"{pkg}@{ver}"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True,
)
request = json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "starter-kit-validator", "version": "1.0"},
    },
}) + "\n"
try:
    out, err = proc.communicate(request, timeout=120)
except subprocess.TimeoutExpired:
    proc.kill()
    print("handshake timed out")
    sys.exit(1)
print(err)
for line in out.splitlines():
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("id") == 1 and "result" in msg:
        info = msg["result"].get("serverInfo", {})
        print(f"handshake ok: {info.get('name')} {info.get('version')}")
        sys.exit(0)
print("no initialize result in server output")
sys.exit(1)
'@

    $handshakeOk = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $env:EXA_DSN = $dsn
        $env:EXA_USER = $creds.User
        $env:EXA_PASSWORD = $creds.Password
        $env:EXA_SSL_CERT_VALIDATION = $sslCertValidation
        try {
            $out = Invoke-ExakitPython $handshakeScript $command $script:McpPackage $script:McpVersion
            $handshakeOk = $true
            if ($script:LogFile) { $out | Add-Content -Path $script:LogFile }
            break
        } catch {
            if ($script:LogFile) { "$_" | Add-Content -Path $script:LogFile }
            if ($attempt -lt 2) { Warn2 "Handshake attempt $attempt failed - retrying"; Start-Sleep -Seconds 5 }
        } finally {
            Remove-Item Env:\EXA_DSN, Env:\EXA_USER, Env:\EXA_PASSWORD, Env:\EXA_SSL_CERT_VALIDATION -ErrorAction SilentlyContinue
        }
    }
    if ($handshakeOk) {
        Ok "MCP server answers over stdio"
        Set-ExakitManifestValue "components.mcp_server.mode" "stdio"
        Set-ExakitManifestValue "components.mcp_server.validated" $true
    } else {
        Warn2 "MCP stdio validation failed (see log). The configs are still in place; clients may show more detail."
        Set-ExakitManifestValue "components.mcp_server.validated" $false
    }
}

# ---------------------------------------------------------------------------
# Dedicated read-only database user (mirrors the MCP-specific functions in
# setup/lib/common.sh)
# ---------------------------------------------------------------------------
# Get-ExakitExapumpBin - prefers the manifest-recorded exact path (in case
# PATH has more than one exapump installed), then falls back like Get-ExapumpCli.
function Get-ExakitExapumpBin {
    $manifestPath = Get-ExakitManifestValue "components.exapump.path"
    if ($manifestPath -and (Test-Path $manifestPath)) { return $manifestPath }
    $cmd = Get-Command exapump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path $script:ExapumpBinPath) { return $script:ExapumpBinPath }
    return $null
}

function ConvertTo-SqlLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value.Replace("'", "''")
}

function ConvertTo-McpRedactedText {
    param([AllowEmptyString()][string]$Text, [string[]]$Secrets = @())
    $redacted = "$Text"
    foreach ($secret in $Secrets) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $redacted = $redacted -replace [regex]::Escape($secret), "<redacted>"
        }
    }
    $redacted = $redacted -replace '(?i)(IDENTIFIED\s+BY\s+)(''[^'']*''|[A-Z][A-Z0-9]*(?:\.\.\.)?)', '$1<redacted>'
    return $redacted
}

function Get-RuntimeHost {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { return "" }
    return ($dsn -split ":", 2)[0]
}

function Get-RuntimePort {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { return "" }
    return ($dsn -split ":", 2)[1]
}

function Get-FirstSchema {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Schemas)
    $tokens = @($Schemas -split '[,\s]+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return "STARTER_KIT" }
    return $tokens[0]
}

# Invoke-ExapumpAdminSql - run one SQL statement through a specific exapump
# profile against a specific (usually temporary) config file, without
# touching the user's real %USERPROFILE%\.exapump\config.toml.
function Invoke-ExapumpAdminSql {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Sql)
    $bin = Get-ExakitExapumpBin
    if (-not $bin) { Fail "exapump is required for MCP read-only setup but was not found." }
    $previous = $env:EXAPUMP_CONFIG
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:EXAPUMP_CONFIG = $ConfigPath
        # Native exapump can write successful query summaries to stderr on
        # Windows. Do not let PowerShell convert that into a terminating
        # exception before Test-ExapumpSucceeded can evaluate the output.
        $ErrorActionPreference = "Continue"
        $out = @(& $bin sql -p $Profile $Sql 2>&1) -join "`n"
        $code = $LASTEXITCODE
        return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
    } catch {
        # A native command's stderr write can surface here as an exception
        # instead of a non-zero exit code; every caller expects this shape
        # back regardless, and checks .Success / .ExitCode itself.
        $out = "$_"
        return @{ Output = $out; ExitCode = 1; Success = (Test-ExapumpSucceeded -ExitCode 1 -Output $out) }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -ne $previous) { $env:EXAPUMP_CONFIG = $previous } else { Remove-Item Env:\EXAPUMP_CONFIG -ErrorAction SilentlyContinue }
    }
}

# Assert-ExapumpResult - log an exapump admin-SQL result and abort (Fail) if it
# did not succeed. Collapses the repeated "log ERROR_DETAIL + red Write-Host +
# Fail" block that followed every admin SQL step. Pass -Secrets to redact
# credentials from the output before it is logged or printed.
function Assert-ExapumpResult {
    param(
        [Parameter(Mandatory)][hashtable]$Result,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FailMessage,
        [string[]]$Secrets = @()
    )
    $text = if ($Secrets.Count) { ConvertTo-McpRedactedText -Text $Result.Output -Secrets $Secrets } else { $Result.Output }
    if ($script:LogFile) { $text | Add-Content -Path $script:LogFile }
    if (-not $Result.Success) {
        Write-ExakitLog "ERROR_DETAIL" "$Label failed with exit code $($Result.ExitCode): $text"
        # Tool output on the failure path: same contained gutter as everywhere
        # else, red so it reads as the error detail it is.
        Write-Host "      ! $Label error details:" -ForegroundColor Red
        "$text" -split "`n" | ForEach-Object {
            if ($script:UiFancy) { Write-Host ("      {0}{1} {2}{3}" -f $script:UiErr, $script:UiVB, $_, $script:UiReset) }
            else { Write-Host ("      | {0}" -f $_) -ForegroundColor Red }
        }
        Fail $FailMessage
    }
}

function Test-ExapumpSqlHasToken {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)][string]$Token)
    $result = Invoke-ExapumpAdminSql -ConfigPath $ConfigPath -Profile $Profile -Sql $Sql
    if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
    # These are sentinel-token status queries: the token's presence in the
    # output IS the ground-truth success signal, so match on it directly
    # rather than gating on exapump's (Windows-unreliable) exit code. A real
    # failure would print an error and never contain the sentinel.
    return $result.Output -match [regex]::Escape($Token)
}

function Test-ExakitIdentifier {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value -match '^[A-Za-z0-9_]+$'
}

function Test-ExakitSqlPasswordToken {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value -cmatch '^[A-Z][A-Z0-9]{23}$'
}

function New-ExakitSqlPasswordToken {
    # Generate alphanumeric password (A-Z, 0-9 only, no underscores) for maximum SQL compatibility
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".ToCharArray()
    $bytes = New-Object byte[] 23
    # See the comment on New-ExakitPassword in exakit-common.ps1: Fill() is
    # .NET 6+/Core-only, Windows PowerShell 5.1 needs Create()+GetBytes().
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return "A" + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

# Assert-McpReadonlyPosture <config> <user> <comma-or-space-separated schemas>
# Verifies CREATE SESSION only, SELECT on every configured schema, and no
# object privileges outside those schemas - across the whole schema list, not
# just the first one, so posture checks cannot miss drift on additional
# schemas (or false-positive on their legitimate SELECT grants).
function Assert-McpReadonlyPosture {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$ReadonlyUser, [Parameter(Mandatory)][string]$Schemas)
    $identifierUser = ConvertTo-UpperInvariantString $ReadonlyUser
    $identifierLit = ConvertTo-SqlLiteral $identifierUser

    # The read-only user's system privileges must be EXACTLY the read set:
    # CREATE SESSION + USE ANY SCHEMA + SELECT ANY TABLE, and nothing more -
    # which is what guarantees no write/DDL/admin privilege. Mirrors common.sh.
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE = 'CREATE SESSION') THEN 'EXAKIT_CREATE_SESSION_OK' ELSE 'EXAKIT_CREATE_SESSION_MISSING' END AS STATUS" "EXAKIT_CREATE_SESSION_OK")) {
        Fail "The MCP read-only user is missing CREATE SESSION."
    }
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE = 'USE ANY SCHEMA') THEN 'EXAKIT_USE_ANY_SCHEMA_OK' ELSE 'EXAKIT_USE_ANY_SCHEMA_MISSING' END AS STATUS" "EXAKIT_USE_ANY_SCHEMA_OK")) {
        Fail "The MCP read-only user is missing USE ANY SCHEMA (needed to read every schema)."
    }
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE = 'SELECT ANY TABLE') THEN 'EXAKIT_SELECT_ANY_TABLE_OK' ELSE 'EXAKIT_SELECT_ANY_TABLE_MISSING' END AS STATUS" "EXAKIT_SELECT_ANY_TABLE_OK")) {
        Fail "The MCP read-only user is missing SELECT ANY TABLE (needed to read every table)."
    }
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_SYS_PRIV_SCOPE_OK' ELSE 'EXAKIT_SYS_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE NOT IN ('CREATE SESSION', 'USE ANY SCHEMA', 'SELECT ANY TABLE')" "EXAKIT_SYS_PRIV_SCOPE_OK")) {
        Fail "The MCP read-only user has system privileges beyond the read-only set (CREATE SESSION, USE ANY SCHEMA, SELECT ANY TABLE)."
    }

    # No object privilege may be anything other than SELECT.
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_OBJ_PRIV_SCOPE_OK' ELSE 'EXAKIT_OBJ_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE <> 'SELECT'" "EXAKIT_OBJ_PRIV_SCOPE_OK")) {
        Fail "The MCP read-only user has a write object privilege; it must be read-only."
    }

    # Live proof the user cannot write: a CREATE TABLE in the default schema
    # (which USE ANY SCHEMA lets it OPEN) MUST be rejected.
    $probeSchemaUc = ConvertTo-UpperInvariantString (Get-FirstSchema $Schemas)
    $probe = Invoke-ExapumpAdminSql -ConfigPath $ConfigPath -Profile "mcp_readonly" -Sql "CREATE TABLE $probeSchemaUc.EXAKIT_MCP_PERMISSION_PROBE (ID DECIMAL)"
    if ($script:LogFile) { $probe.Output | Add-Content -Path $script:LogFile }
    # .Success (exit-code-quirk-aware) rather than raw ExitCode: if the CREATE
    # actually went through, that is a real read-only violation and we must
    # catch it regardless of exapump's exit-code behavior.
    if ($probe.Success) {
        $cleanup = Invoke-ExapumpAdminSql -ConfigPath $ConfigPath -Profile "admin" -Sql "DROP TABLE $probeSchemaUc.EXAKIT_MCP_PERMISSION_PROBE"
        if ($script:LogFile) { $cleanup.Output | Add-Content -Path $script:LogFile }
        Fail "Security check failed: the MCP read-only user was able to write to schema $probeSchemaUc, but it must be read-only. Setup stopped to protect your database."
    }
}

# Set-McpReadonlyAccess - create (or refresh) the dedicated read-only
# database user, grant database-wide read (USE ANY SCHEMA + SELECT ANY TABLE),
# validate its login, and assert the read-only posture. Safe to re-run.
function Set-McpReadonlyAccess {
    # Ensure exapump is on PATH for this session
    $exapumpBin = Get-ExakitExapumpBin
    if ($exapumpBin) {
        $binDir = Split-Path -Parent $exapumpBin
        Ensure-ExakitOnPath $binDir
    }
    
    $runtimeUser = Get-ExakitManifestValue "runtime.user"
    if (-not $runtimeUser) { Fail "runtime.user is missing; cannot prepare the MCP read-only database user." }
    $runtimePwFile = Get-ExakitManifestValue "runtime.password_file"
    $adminPassword = ""
    if ($runtimePwFile -and (Test-Path $runtimePwFile)) {
        $adminPassword = (Get-Content $runtimePwFile -Raw).TrimEnd("`r", "`n")
    }
    # Fallback (mirrors common.sh): recover the admin password from the exapump
    # profile the data step already validated. Covers adopted deployments whose
    # secrets couldn't be read, including re-runs where the exapump step is
    # skipped as "already done". Persist it forward so later runs find it.
    if (-not $adminPassword) {
        $adminPassword = Get-ExapumpProfilePassword $script:ExapumpProfile
        if ($adminPassword) {
            Set-ExakitCredential "runtime_sys_password" $adminPassword
            Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "runtime_sys_password")
        }
    }
    if (-not $adminPassword) { Fail "No runtime database password is available (runtime.password_file is missing and the exapump '$($script:ExapumpProfile)' profile has none). Set it with 'exapump profile init $($script:ExapumpProfile)', then re-run." }
    $dbHost = Get-RuntimeHost
    $dbPort = Get-RuntimePort
    if (-not $dbHost) { Fail "runtime.dsn is missing a host; cannot prepare the MCP read-only database user." }
    if (-not $dbPort) { Fail "runtime.dsn is missing a port; cannot prepare the MCP read-only database user." }

    $readonlyUser = $script:McpReadonlyUser
    # The MCP user gets database-wide READ (USE ANY SCHEMA + SELECT ANY TABLE),
    # so it can query every schema and table - bundled datasets, your own
    # uploads, and anything you create later - with no per-schema grant. This
    # list is now only the connection's DEFAULT schema (the landing spot for
    # local uploads); it must exist so the exapump profile can OPEN it on
    # connect, and it is the schema the write-rejection probe targets. Mirrors
    # common.sh.
    $readonlySchemas = $script:McpReadonlySchemas
    $defaultSchema = Get-FirstSchema $readonlySchemas
    $readonlyPassword = Get-ExakitCredential "mcp_readonly_password"
    if (-not (Test-ExakitSqlPasswordToken $readonlyPassword)) {
        $readonlyPassword = New-ExakitSqlPasswordToken
        Set-ExakitCredential "mcp_readonly_password" $readonlyPassword
    }

    $identifierUser = ConvertTo-UpperInvariantString $readonlyUser
    $defaultSchemaUc = ConvertTo-UpperInvariantString $defaultSchema
    if (-not (Test-ExakitIdentifier $identifierUser)) { Fail "Invalid EXAKIT_MCP_READONLY_USER: $readonlyUser" }

    $tempConfig = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).toml"
    # try/finally guarantees the credential-bearing temp TOML is deleted on
    # every exit path - success, a thrown Fail, or any other exception - so no
    # individual step has to remember to clean it up.
    try {
        Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "admin" -Host_ $dbHost -Port $dbPort -User $runtimeUser -Password $adminPassword
        Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "mcp_readonly" -Host_ $dbHost -Port $dbPort -User $readonlyUser -Password $readonlyPassword -Schema $defaultSchemaUc

        # Verify the TOML config was created and is readable
        if (-not (Test-Path $tempConfig)) {
            Fail "Failed to create temporary exapump configuration file: $tempConfig"
        }
        Write-ExakitLog "DEBUG" "TOML config created at: $tempConfig"
        if ($script:LogFile) {
            Write-ExakitLog "DEBUG" "TOML config contents (passwords redacted):"
            $redactedConfig = (Get-Content $tempConfig -Raw) -replace '(?m)^(password\s*=\s*").*(")\s*$', '$1<redacted>$2'
            $redactedConfig | Add-Content -Path $script:LogFile
        }

        # Test basic connectivity before attempting user creation
        Info "Testing database connectivity with admin user"
        $connTestResult = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "SELECT 1 AS connection_test"
        Assert-ExapumpResult -Result $connTestResult -Label "Database connection test" -FailMessage "Cannot connect to database with admin credentials. Check database status and credentials."
        Ok "Database connection successful"

        $identifierLit = ConvertTo-SqlLiteral $identifierUser
        if (-not (Test-ExapumpSqlHasToken $tempConfig "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '$identifierLit') THEN 'EXAKIT_MCP_USER_PRESENT' ELSE 'EXAKIT_MCP_USER_MISSING' END AS STATUS" "EXAKIT_MCP_USER_PRESENT")) {
            Info "Creating the dedicated MCP read-only database user ($readonlyUser)"
            Write-ExakitLog "SQL" "CREATE USER $identifierUser IDENTIFIED BY <redacted>"
            $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "CREATE USER $identifierUser IDENTIFIED BY $readonlyPassword"
            Assert-ExapumpResult -Result $r -Label "CREATE USER" -FailMessage "Could not create the MCP read-only database user." -Secrets @($readonlyPassword, $adminPassword)
        }

        Write-ExakitLog "SQL" "ALTER USER $identifierUser IDENTIFIED BY <redacted>"
        $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "ALTER USER $identifierUser IDENTIFIED BY $readonlyPassword"
        Assert-ExapumpResult -Result $r -Label "ALTER USER" -FailMessage "Could not refresh the MCP read-only database password." -Secrets @($readonlyPassword, $adminPassword)

        $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "GRANT CREATE SESSION TO $identifierUser"
        Assert-ExapumpResult -Result $r -Label "GRANT CREATE SESSION" -FailMessage "Could not grant CREATE SESSION to the MCP read-only database user."

        # Make sure the connection's default schema exists - exapump OPENs it on
        # connect, and the write-rejection probe targets it.
        $schemaTokens = @($readonlySchemas -split '[,\s]+' | Where-Object { $_ })
        $defaultSchemaUc = ConvertTo-UpperInvariantString $defaultSchema
        if (-not (Test-ExakitIdentifier $defaultSchemaUc)) { Fail "Invalid MCP default schema name: $defaultSchema" }
        $defaultSchemaLit = ConvertTo-SqlLiteral $defaultSchemaUc
        if (-not (Test-ExapumpSqlHasToken $tempConfig "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$defaultSchemaLit') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" "EXAKIT_SCHEMA_PRESENT")) {
            Info "Creating default schema $defaultSchemaUc for MCP-safe querying"
            Write-ExakitLog "SQL" "CREATE SCHEMA $defaultSchemaUc"
            $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "CREATE SCHEMA $defaultSchemaUc"
            Assert-ExapumpResult -Result $r -Label "CREATE SCHEMA $defaultSchemaUc" -FailMessage "Could not create schema $defaultSchemaUc for MCP access."
        }

        # Database-wide READ: USE ANY SCHEMA (see every schema) + SELECT ANY
        # TABLE (read contents in any schema). Together they let the AI client
        # query every schema and table - present and future, including ones you
        # create by hand - without a per-schema grant. Neither permits any write
        # or DDL, so the read-only guarantee holds (re-checked below).
        # SELECT ANY DICTIONARY is deliberately NOT granted, so system
        # dictionaries (audit logs, sessions, other users) stay private.
        Write-ExakitLog "SQL" "GRANT USE ANY SCHEMA TO $identifierUser"
        $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "GRANT USE ANY SCHEMA TO $identifierUser"
        Assert-ExapumpResult -Result $r -Label "GRANT USE ANY SCHEMA" -FailMessage "Could not grant USE ANY SCHEMA to the MCP read-only database user."
        Write-ExakitLog "SQL" "GRANT SELECT ANY TABLE TO $identifierUser"
        $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "GRANT SELECT ANY TABLE TO $identifierUser"
        Assert-ExapumpResult -Result $r -Label "GRANT SELECT ANY TABLE" -FailMessage "Could not grant SELECT ANY TABLE to the MCP read-only database user."

        Info "Validating dedicated MCP read-only login"
        if (-not (Test-ExapumpSqlHasToken $tempConfig "mcp_readonly" "SELECT CURRENT_USER AS EXAKIT_CURRENT_USER" $identifierUser)) {
            Fail "The MCP read-only user could not log in with the generated credentials."
        }
        if (-not (Test-ExapumpSqlHasToken $tempConfig "mcp_readonly" "SELECT 'EXAKIT_MCP_READONLY_OK' AS STATUS" "EXAKIT_MCP_READONLY_OK")) {
            Fail "The MCP read-only user did not pass the validation query."
        }
        Assert-McpReadonlyPosture -ConfigPath $tempConfig -ReadonlyUser $readonlyUser -Schemas $readonlySchemas

        Set-ExakitManifestValue "components.mcp_server.connection.user" $readonlyUser
        Set-ExakitManifestValue "components.mcp_server.connection.password_file" (Join-Path $script:CredsDir "mcp_readonly_password")
        Set-ExakitManifestValue "components.mcp_server.connection.schemas" $schemaTokens
        Set-ExakitManifestValue "components.mcp_server.connection.validated" $true
    } finally {
        Remove-Item -Force $tempConfig -ErrorAction SilentlyContinue
    }
    Ok "Dedicated MCP read-only access is configured and validated"
}

# Confirm-McpReadonlyPosture - re-run the grant-posture check against the
# database using the credentials already on file, without re-provisioning
# anything. Used by `exakit mcp-doctor` so privilege drift
# after install (e.g. someone widening a grant by hand) is actually caught.
function Confirm-McpReadonlyPosture {
    $runtimeUser = Get-ExakitManifestValue "runtime.user"
    $runtimePwFile = Get-ExakitManifestValue "runtime.password_file"
    $readonlyUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $readonlyPwFile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    $schemas = @(Get-ExakitManifestValue "components.mcp_server.connection.schemas")

    if (-not $runtimeUser -or -not $runtimePwFile -or -not $readonlyUser -or -not $readonlyPwFile -or $schemas.Count -eq 0) {
        return $true
    }
    if (-not (Test-Path $runtimePwFile)) { Warn2 "Runtime password file missing; skipping MCP grant-posture re-check."; return $false }
    if (-not (Test-Path $readonlyPwFile)) { Warn2 "MCP read-only password file missing; skipping MCP grant-posture re-check."; return $false }

    $schemasCsv = $schemas -join ","
    $adminPassword = (Get-Content $runtimePwFile -Raw).TrimEnd("`r", "`n")
    $readonlyPassword = (Get-Content $readonlyPwFile -Raw).TrimEnd("`r", "`n")
    $dbHost = Get-RuntimeHost
    $dbPort = Get-RuntimePort
    $defaultSchema = Get-FirstSchema $schemasCsv

    $tempConfig = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).toml"
    Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "admin" -Host_ $dbHost -Port $dbPort -User $runtimeUser -Password $adminPassword
    Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "mcp_readonly" -Host_ $dbHost -Port $dbPort -User $readonlyUser -Password $readonlyPassword -Schema $defaultSchema

    Info "Re-checking MCP read-only grant posture against the database"
    try {
        Assert-McpReadonlyPosture -ConfigPath $tempConfig -ReadonlyUser $readonlyUser -Schemas $schemasCsv
        Ok "MCP read-only grant posture is still correct"
        return $true
    } catch {
        Warn2 "MCP read-only grant posture has drifted from the expected read-only set (see log). Run 'exakit mcp-repair' or review grants manually."
        return $false
    } finally {
        Remove-Item -Force $tempConfig -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Config generation / operations (shell out to the OS-agnostic Python mcp
# package - the same code macOS/Linux/WSL use, invoked the same way)
# ---------------------------------------------------------------------------
# Test-ExakitSystemPythonForMcp - the mcp package requires Python 3.11+ (it
# imports the stdlib `tomllib`, added in 3.11, at module load time via the
# Codex adapter). A system `python` that's older - or the Windows "App
# execution alias" stub that resolves as `python` but isn't a real
# interpreter - must NOT be used to run the module, or it fails on import.
function Test-ExakitSystemPythonForMcp {
    if (-not (Test-ExakitSystemPython)) { return $false }
    try {
        $v = & python -c "import sys; print(1 if sys.version_info >= (3, 11) else 0)" 2>$null
        return (("$v").Trim() -eq "1")
    } catch {
        return $false
    }
}

function Invoke-McpModule {
    param([Parameter(Mandatory)][string[]]$ModuleArgs)
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { return $null }
    Push-Location $repoRoot
    $previousPythonPath = $env:PYTHONPATH
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:PYTHONPATH = if ($previousPythonPath) { "$repoRoot;$previousPythonPath" } else { $repoRoot }
        # Under the module-global $ErrorActionPreference = 'Stop', 2>&1 turns
        # the module's FIRST stderr write into a terminating error that tears
        # the pipeline down - killing the CLI mid-run and reporting a bogus
        # ExitCode 1 with only that first line as Output, even when the module
        # would have succeeded (Python warnings and pip/uv notices go to
        # stderr). 'Continue' captures the full output and lets the real exit
        # code through. Same fix as Invoke-Exapump / Invoke-ExapumpAdminSql.
        $ErrorActionPreference = "Continue"
        if (Test-ExakitSystemPythonForMcp) {
            $out = & python -m mcp @ModuleArgs 2>&1 | Out-String
        } else {
            # Fall back to the managed uv Python (pinned to 3.12), which is
            # guaranteed to satisfy the 3.11+ requirement. uv is already a
            # hard dependency here (the MCP server itself runs via uvx).
            $uv = Install-ExakitUv
            $out = & $uv run --python $script:ManagedPythonVersion --no-project python -m mcp @ModuleArgs 2>&1 | Out-String
        }
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Output = "$_"; ExitCode = 1 }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -ne $previousPythonPath) { $env:PYTHONPATH = $previousPythonPath } else { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue }
        Pop-Location
    }
}

function Invoke-McpSetupCli {
    param([Parameter(Mandatory)][string[]]$Clients)
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not find the MCP package source to configure MCP clients."; return $null }
    try { Set-McpReadonlyAccess } catch { return $null }
    $result = Invoke-McpModule (@("setup-runtime-clients", "--runtime-root", $script:ExakitHome, "--clients") + $Clients)
    if ($result.ExitCode -ne 0) {
        if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
        Warn2 "MCP client setup failed (see log)."
        return $null
    }
    return $result.Output
}

function Invoke-McpOperationCli {
    param([Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][string[]]$Clients, [string]$SnapshotId = "")
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not find the MCP package source to manage MCP clients."; return $null }
    if ($Operation -in @("validate", "repair", "doctor")) {
        try { Set-McpReadonlyAccess } catch { return $null }
    }
    $args = @("run-runtime-operation", $Operation, "--runtime-root", $script:ExakitHome)
    if ($SnapshotId) { $args += @("--snapshot-id", $SnapshotId) }
    $args += "--clients"
    $args += $Clients
    $result = Invoke-McpModule $args
    if ($result.ExitCode -ne 0) {
        if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
        Warn2 "MCP $Operation failed (see log)."
        return $null
    }
    return $result.Output
}

# Get-McpClientStates - hashtable of client id -> state, straight from the
# adapters' own detection: "pending" (installed, no managed config yet),
# "connected" (has a managed config), or "missing" (not installed). Returns
# $null when discovery is unavailable so the caller can fall back to the
# static everything-selectable menu. Twin of exakit_mcp_discover_status in
# common.sh.
function Get-McpClientStates {
    $result = Invoke-McpModule -ModuleArgs @("discover-clients", "--runtime-root", $script:ExakitHome)
    if (-not $result -or $result.ExitCode -ne 0) { return $null }
    try {
        $doc = $result.Output | ConvertFrom-Json
        $states = @{}
        foreach ($client in @($doc.clients)) {
            if ($client.configured) { $states[$client.id] = "connected" }
            elseif ($client.detected) { $states[$client.id] = "pending" }
            else { $states[$client.id] = "missing" }
        }
        return $states
    } catch {
        return $null
    }
}

$script:McpClientLabels = @{ claude_desktop = "Claude"; claude_code = "Claude Code (CLI)"; cursor = "Cursor"; codex = "Codex"; vscode_copilot = "GitHub Copilot"; gemini_cli = "Gemini CLI"; opencode = "OpenCode"; continue = "Continue" }

function Show-McpSetupSummary {
    param([Parameter(Mandatory)][string]$ResultJson)
    $doc = $ResultJson | ConvertFrom-Json
    $clients = @($doc.selected_clients) | ForEach-Object { if ($script:McpClientLabels.ContainsKey($_)) { $script:McpClientLabels[$_] } else { $_ } }
    # Same rounded panel as the install plan / connection details (ui.ps1).
    Write-Host ""
    Start-ExakitPanel "MCP setup summary"
    Write-ExakitPanelLine "Mode:     managed"
    Write-ExakitPanelLine "Meaning:  wrote managed MCP entries into the selected client config files"
    Write-ExakitPanelLine "Clients:  $(if ($clients) { $clients -join ', ' } else { 'none' })"
    Write-ExakitPanelLine "Status:   $($doc.status)"
    foreach ($artifact in @($doc.artifacts)) {
        $label = if ($script:McpClientLabels.ContainsKey($artifact.client)) { $script:McpClientLabels[$artifact.client] } else { $artifact.client }
        Write-ExakitPanelLine "File:     $label -> $($artifact.path)"
    }
    if (@($doc.findings).Count -gt 0) {
        Write-ExakitPanelLine ""
        Write-ExakitPanelLine "Notes:"
        foreach ($f in @($doc.findings)) { Write-ExakitPanelLine "- $($f.message)" }
    }
    if (@($doc.next_actions).Count -gt 0) {
        Write-ExakitPanelLine ""
        Write-ExakitPanelLine "Next:"
        foreach ($a in @($doc.next_actions)) { Write-ExakitPanelLine "- $($a.message)" }
    }
    Complete-ExakitPanel
}

function Show-McpReadyPanel {
    param([string]$Mode = "")
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $mcpUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $mcpPackage = Get-ExakitManifestValue "components.mcp_server.package"
    if (-not $mcpPackage) { $mcpPackage = $script:McpPackage }
    $mcpVersion = Get-ExakitManifestValue "components.mcp_server.version"
    if (-not $mcpVersion) { $mcpVersion = $script:McpVersion }
    $mcpCommand = Get-ExakitManifestValue "components.mcp_server.command"
    if (-not $mcpCommand) { $mcpCommand = "uvx" }
    $tls = Get-ExakitManifestValue "runtime.tls"

    Write-Host ""
    Start-ExakitPanel "MCP is ready"
    Write-ExakitPanelLine "Server name:   exasol"
    Write-ExakitPanelLine "How it runs:   your AI client starts it on demand over stdio"
    Write-ExakitPanelLine "Command:       $mcpCommand $mcpPackage@$mcpVersion"
    Write-ExakitPanelLine "Database:      $(if ($dsn) { $dsn } else { 'unknown' })"
    Write-ExakitPanelLine "DB user:       $(if ($mcpUser) { $mcpUser } else { 'mcp_readonly' }) (read-only)"
    if ($tls -eq "self-signed") { Write-ExakitPanelLine "TLS:           local self-signed certificate accepted for 127.0.0.1" }
    Write-ExakitPanelLine "Managed state: $script:McpDir"
    Complete-ExakitPanel
    Info "Config files updated - restart the selected client now."
    Info "After the restart, look for an MCP server named: exasol"
    Write-Host ""
    Start-ExakitPanel "First prompt to try in your AI client"
    Write-ExakitPanelLine """Use the exasol MCP server connected to my local Exasol database."
    Write-ExakitPanelLine "List the available schemas and tables first. Then answer my"
    Write-ExakitPanelLine "questions with read-only SQL only, show me the SQL before you run"
    Write-ExakitPanelLine "it, and do not create, update, or delete anything."""
    Complete-ExakitPanel
    # Best-effort: put the prompt straight on the clipboard so the first thing
    # the user does in their AI client is just paste. Silent when unavailable.
    $firstPrompt = 'Use the exasol MCP server connected to my local Exasol database. List the available schemas and tables first. Then answer my questions with read-only SQL only, show me the SQL before you run it, and do not create, update, or delete anything.'
    try {
        Set-Clipboard -Value $firstPrompt
        Ok "This prompt is copied to your clipboard - paste it after restarting your client."
    } catch { }
}

function Show-McpOperationSummary {
    param([Parameter(Mandatory)][string]$ResultJson)
    $doc = $ResultJson | ConvertFrom-Json
    $clients = @($doc.selected_clients) | ForEach-Object { if ($script:McpClientLabels.ContainsKey($_)) { $script:McpClientLabels[$_] } else { $_ } }
    Write-Host ""
    Write-Host "  MCP operation summary"
    Write-Host "  Operation: $($doc.operation)"
    Write-Host "  Clients:   $(if ($clients) { $clients -join ', ' } else { 'all managed clients' })"
    Write-Host "  Status:    $($doc.status)"
    Write-Host "  Summary:   $($doc.summary)"
    if ($doc.backup_reference) { Write-Host "  Snapshot:  $($doc.backup_reference)" }
    # Doctor carries per-client discovery plus the managed-artifact list:
    # render a state map in the same vocabulary as the setup menu, so "not
    # installed" reads as expected state instead of a warning (mirrors
    # exakit_print_mcp_operation_summary in common.sh).
    $discovered = @()
    if ($doc.details -and $doc.details.discovered_clients) { $discovered = @($doc.details.discovered_clients) }
    if ($discovered.Count -gt 0) {
        $managed = @($doc.artifacts) | ForEach-Object { $_.client }
        $groups = [ordered]@{ "connected" = @(); "available" = @(); "needs attention" = @(); "not installed" = @() }
        foreach ($entry in $discovered) {
            $name = if ($script:McpClientLabels.ContainsKey($entry.client)) { $script:McpClientLabels[$entry.client] } else { $entry.client }
            if ($entry.detected -and $managed -contains $entry.client) { $groups["connected"] += $name }
            elseif ($entry.detected) { $groups["available"] += $name }
            elseif ($managed -contains $entry.client) { $groups["needs attention"] += $name }
            else { $groups["not installed"] += $name }
        }
        $hints = @{ "available" = "-> connect with: exakit mcp-setup"; "needs attention" = "-> managed entry, client missing (exakit mcp-remove)" }
        Write-Host ""; Write-Host "  Client state:"
        foreach ($label in $groups.Keys) {
            $names = $groups[$label]
            if (@($names).Count -gt 0) {
                $hint = if ($hints.ContainsKey($label)) { "   " + $hints[$label] } else { "" }
                Write-Host ("    {0,-15} {1}{2}" -f $label, ($names -join ', '), $hint)
            }
        }
    }
    if (@($doc.changes).Count -gt 0) {
        Write-Host ""; Write-Host "  Changes:"
        foreach ($c in @($doc.changes)) { Write-Host "  - $($c.kind) $($c.path)" }
    }
    # Absent-client INFO findings are already represented in the state map
    # above; repeating them as notes made a healthy machine read like a
    # problem report.
    $notes = @($doc.findings) | Where-Object {
        -not ($discovered.Count -gt 0 -and $_.severity -eq "info" -and $_.code -eq "client_not_detected")
    }
    if (@($notes).Count -gt 0) {
        Write-Host ""; Write-Host "  Notes:"
        foreach ($f in @($notes)) { Write-Host "  - $($f.message)" }
    }
    if (@($doc.next_actions).Count -gt 0) {
        Write-Host ""; Write-Host "  Next:"
        foreach ($a in @($doc.next_actions)) { Write-Host "  - $($a.message)" }
    }
}

function ConvertTo-McpClientSelection {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    $tokens = @(($Raw -replace '[,/]', ' ') -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return $null }
    if ($tokens.Count -eq 1 -and $tokens[0] -match '^(all|ALL|All)$') { return @("claude_desktop", "claude_code", "cursor", "codex", "vscode_copilot", "gemini_cli", "opencode", "continue") }
    $result = @()
    foreach ($token in $tokens) {
        # "claude" (or 1) covers both Claude surfaces - the desktop app and the
        # Claude Code CLI - one user choice, two configs. The explicit ids
        # (claude_desktop / claude_code) still address a single surface.
        $clients = switch ($token) {
            { $_ -in @("1", "claude") } { @("claude_desktop", "claude_code") }
            "claude_desktop" { @("claude_desktop") }
            "claude_code" { @("claude_code") }
            { $_ -in @("2", "codex") } { @("codex") }
            { $_ -in @("3", "cursor") } { @("cursor") }
            { $_ -in @("4", "copilot", "vscode", "vscode_copilot") } { @("vscode_copilot") }
            { $_ -in @("5", "gemini", "gemini_cli") } { @("gemini_cli") }
            { $_ -in @("6", "opencode") } { @("opencode") }
            { $_ -in @("7", "continue") } { @("continue") }
            default { $null }
        }
        if (-not $clients) { return $null }
        foreach ($client in $clients) {
            if ($result -notcontains $client) { $result += $client }
        }
    }
    if ($result.Count -eq 0) { return $null }
    return $result
}

function Get-McpClientsFromArgs {
    param([string[]]$InputArgs = @())
    if ($InputArgs.Count -eq 0) { return @("claude_desktop", "claude_code", "cursor", "codex", "vscode_copilot", "gemini_cli", "opencode", "continue") }
    return ConvertTo-McpClientSelection ($InputArgs -join " ")
}

function Invoke-McpSetup {
    Info "MCP setup will edit the selected AI client config files."

    # EXAKIT_MCP_CLIENTS lets an agent-driven or scripted install pick clients
    # without a prompt (e.g. "claude", "claude,cursor", "all", or "1,2") - the
    # Windows twin of the same hatch in common.sh's exakit_mcp_setup. "skip" or
    # "none" opts out entirely. Without a tty the menu just keeps its defaults,
    # so this env var is the only way an agent can actually steer the choice.
    $clients = $null
    if ($env:EXAKIT_MCP_CLIENTS) {
        if ($env:EXAKIT_MCP_CLIENTS -match '^\s*(skip|none)\s*$') {
            Info "Skipping MCP client setup (EXAKIT_MCP_CLIENTS=$($env:EXAKIT_MCP_CLIENTS)) - run 'exakit mcp-setup' any time."
            return $true
        }
        $clients = ConvertTo-McpClientSelection $env:EXAKIT_MCP_CLIENTS
        if (-not $clients) {
            Warn2 "EXAKIT_MCP_CLIENTS='$($env:EXAKIT_MCP_CLIENTS)' is not valid (use claude, codex, cursor, copilot, gemini, opencode, continue, all, skip, or numbers 1-7)."
            return $false
        }
        Info "Configuring MCP clients from EXAKIT_MCP_CLIENTS: $($clients -join ',')"
    }

    if (-not $clients) {
    Write-Host ""
    # Show the FULL list of supported clients so the user sees everything the
    # kit can connect: pending clients (installed, not connected yet) are
    # selectable and pre-selected; clients that are already connected or not
    # installed on this machine appear greyed out with the reason and cannot
    # be checked. One "Claude" row covers both Claude surfaces (desktop app +
    # Claude Code CLI) while their states match; when they differ, each
    # surface gets its own row. Falls back to everything selectable when
    # discovery is unavailable.
    $states = Get-McpClientStates
    if ($null -eq $states) {
        $states = @{}
        foreach ($id in @("claude_desktop", "claude_code", "codex", "cursor", "vscode_copilot", "gemini_cli", "opencode", "continue")) { $states[$id] = "pending" }
    }
    $menuLabels = New-Object 'System.Collections.Generic.List[string]'
    $menuIds = New-Object 'System.Collections.Generic.List[object]'
    $dot = [char]0xB7
    # One client row: pending rows carry their ids and count as selectable;
    # connected and missing rows are disabled ("!" prefix) with no ids.
    $addRow = {
        param($label, $state, $ids)
        switch ($state) {
            "pending"   { [void]$menuLabels.Add($label); [void]$menuIds.Add($ids) }
            "connected" { [void]$menuLabels.Add(("!{0} {1} already connected" -f $label, $dot)); [void]$menuIds.Add(@()) }
            default     { [void]$menuLabels.Add(("!{0} {1} not installed" -f $label, $dot)); [void]$menuIds.Add(@()) }
        }
    }
    $stateOf = {
        param($id)
        if ($states.ContainsKey($id)) { $states[$id] } else { "missing" }
    }
    $cdState = & $stateOf "claude_desktop"
    $ccState = & $stateOf "claude_code"
    if ($cdState -eq $ccState) { & $addRow "Claude" $cdState @("claude_desktop", "claude_code") }
    else {
        & $addRow "Claude (desktop app)" $cdState @("claude_desktop")
        & $addRow "Claude Code (CLI)" $ccState @("claude_code")
    }
    & $addRow "Codex" (& $stateOf "codex") @("codex")
    & $addRow "Cursor" (& $stateOf "cursor") @("cursor")
    & $addRow "GitHub Copilot" (& $stateOf "vscode_copilot") @("vscode_copilot")
    & $addRow "Gemini CLI" (& $stateOf "gemini_cli") @("gemini_cli")
    & $addRow "OpenCode" (& $stateOf "opencode") @("opencode")
    & $addRow "Continue" (& $stateOf "continue") @("continue")
    $pendingCount = 0
    foreach ($ids in $menuIds) { if (@($ids).Count -gt 0) { $pendingCount++ } }
    if ($pendingCount -eq 0) {
        Ok "All AI clients found on this machine are already connected over MCP."
        Info "Check them with 'exakit mcp-status'; new clients appear here once installed."
        return $true
    }
    [void]$menuLabels.Add("Skip for now (no MCP client changes)")
    $skipIdx = $menuLabels.Count
    # Pre-select every pending client - never a disabled row, never Skip.
    $defaults = @()
    for ($i = 1; $i -lt $skipIdx; $i++) {
        if (@($menuIds[$i - 1]).Count -gt 0) { $defaults += $i }
    }
    $selection = Read-ExakitCheckboxMenu -Title "Select the AI clients to connect (MCP)" `
        -Options $menuLabels.ToArray() -Defaults $defaults -ExclusiveIndex $skipIdx
    if ($selection -contains $skipIdx) {
        Warn2 "No AI client will be connected to your database."
        if (-not (Confirm-ExakitPrompt "Are you sure you want to continue without an AI client?" $true)) {
            return (Invoke-McpSetup)   # back to the menu
        }
        Info "Okay - skipping AI client setup. Connect one any time with: exakit mcp-setup."
        Show-ExakitNoAiPanel
        return $true
    }
    $clients = @($selection | Where-Object { $_ -lt $skipIdx } | ForEach-Object { $menuIds[$_ - 1] } | ForEach-Object { $_ })
    }

    Info "Applying MCP setup"
    $resultJson = Invoke-McpSetupCli -Clients $clients
    if ($resultJson) { Show-McpSetupSummary $resultJson }
    if (-not $resultJson) { return $false }
    Show-McpReadyPanel "permanent"
    Ok "MCP setup guidance is ready."
    return $true
}

function Invoke-McpOperation {
    param([Parameter(Mandatory)][string]$Operation, [string[]]$InputArgs = @())
    $clients = Get-McpClientsFromArgs $InputArgs
    if (-not $clients) { Warn2 "Please choose valid MCP clients: claude_desktop, cursor, codex, or all."; return $false }
    Info "Running MCP $Operation"
    $resultJson = Invoke-McpOperationCli -Operation $Operation -Clients $clients
    if ($resultJson) { Show-McpOperationSummary $resultJson }
    $ok = [bool]$resultJson
    if ($Operation -in @("doctor", "validate")) {
        if (-not (Confirm-McpReadonlyPosture)) { $ok = $false }
    }
    return $ok
}

function Invoke-McpRestore {
    param([string]$SnapshotId = "")
    Info "Running MCP restore"
    $resultJson = Invoke-McpOperationCli -Operation "restore" -Clients @("claude_desktop", "claude_code", "cursor", "codex", "vscode_copilot", "gemini_cli", "opencode", "continue") -SnapshotId $SnapshotId
    if ($resultJson) { Show-McpOperationSummary $resultJson }
    return [bool]$resultJson
}

function New-McpUpdateSnapshot {
    $resultJson = Invoke-McpOperationCli -Operation "backup" -Clients @("claude_desktop", "claude_code", "cursor", "codex", "vscode_copilot", "gemini_cli", "opencode", "continue")
    if (-not $resultJson) { Warn2 "MCP pre-update snapshot was not created; generated configs will still be refreshed."; return "" }
    Show-McpOperationSummary $resultJson
    try {
        $doc = $resultJson | ConvertFrom-Json
        if ($doc.backup_reference) {
            Set-ExakitManifestValue "backups.mcp_update.latest" $doc.backup_reference
            return $doc.backup_reference
        }
    } catch { }
    return ""
}

# Request-ExakitMcpSetupOffer - connect the user's AI client(s) during
# install. A required step: the client checkbox menu handles the choice
# (Claude + Codex preselected), and non-interactive installs keep those
# defaults inside Read-ExakitCheckboxMenu.
function Request-ExakitMcpSetupOffer {
    if ((Get-ExakitManifestValue "components.mcp_server.client_setup.completed") -eq $true) { return }
    # EXAKIT_SKIP_MCP=1 lets a scripted/agent install skip client wiring
    # entirely (twin of the same hatch in common.sh's exakit_maybe_offer_mcp_setup).
    if ($env:EXAKIT_SKIP_MCP -eq "1") {
        Info "Skipping MCP client setup (EXAKIT_SKIP_MCP=1). Run it any time with: exakit mcp-setup"
        return
    }
    Info "The Exasol runtime and MCP server are ready."
    if (-not (Invoke-McpSetup)) {
        Warn2 "Your local runtime is installed, but MCP client setup did not finish cleanly."
        Warn2 "Retry any time with: exakit mcp-setup"
    }
}
