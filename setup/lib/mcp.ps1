# mcp.ps1 - Exasol MCP module: the launcher's MCP server (the sidecar beside the
# database, the only MCP server the kit runs), the dedicated read-only database
# user it connects as, and client config generation (Windows / PowerShell path).
#
# Dot-sourced by setup-windows.ps1 and setup/exakit.ps1 after
# exakit-common.ps1 and exapump.ps1. Mirrors setup/lib/mcp.sh plus the
# MCP-specific functions from setup/lib/common.sh function-for-function.
#
# Guardrail layering (same as bash):
#   1. server is read-only by design
#   2. dedicated read-only database user, provisioned and posture-checked by
#      Set-McpReadonlyAccess
#   3. client configs (generated via the Python mcp package, OS-agnostic)
#      point at that user, never the admin user

# The AI-client table: the rows a reader ticks in the selection phase are the
# rows the progress phase fills in. $null means this run has no table - a
# scripted EXAKIT_MCP_CLIENTS answer, or no console to draw one on.
# Twin of EXAKIT_MCP_TABLE_STATE in common.sh.
$script:McpTable = $null
$script:McpTableRows = @()      # the table rows the progress phase fills in
$script:McpTableIds = @()       # the client ids per client row, in row order
$script:McpTableRowFirst = 2    # the row the first client sits on
# The read-only user's "already done" flag, which only ever covers the one CLI
# call the table was drawn for. Twin of EXAKIT_MCP_READONLY_READY.
$script:McpReadonlyReady = $false

# Reset-McpClientTable - the table is finished with: drop it and the row
# bookkeeping, so nothing of this screen is left for the next one to inherit.
# There is no title or column heading to clear the way the shell twin has to:
# those travel on the table object here, so the dataset table that follows
# cannot end up wearing this one's.
# Twin of _exakit_mcp_table_release in common.sh.
function Reset-McpClientTable {
    $script:McpTable = $null
    $script:McpTableRows = @()
    $script:McpTableIds = @()
    $script:McpTableRowFirst = 2
    # And the read-only user's flag: a later run in the same process (the refresh
    # after a redeploy) must prepare the user again.
    $script:McpReadonlyReady = $false
}

# Get-McpConfiguredClients <result-json> - the client ids the run actually wrote
# a config for, straight from the CLI's own record. The table's final cells are
# built from this rather than from the exit status, which cannot tell "one
# client's config file was unusable" from "nothing was configured".
# Twin of _exakit_mcp_result_states in common.sh.
function Get-McpConfiguredClients {
    param([string]$ResultJson = "")
    if (-not $ResultJson) { return @() }
    try {
        $doc = $ResultJson | ConvertFrom-Json
        $out = @()
        if ($doc.details) {
            foreach ($client in @($doc.details.configured_clients)) {
                if ($client) { $out += ("" + $client) }
            }
        }
        return $out
    } catch {
        return @()
    }
}

# Get-UvxPath - resolve the uvx launcher to a full path: the one beside the uv
# the kit vetted (Get-ExakitUvUvx), never a bare name resolved through PATH,
# which could be an old copy the kit refused - or nothing at all right after
# an install, since $BinDir is not on the current process's PATH yet. The
# PATH and installer-directory lookups remain as fallbacks for a kit copy
# that cannot resolve uv at all.
function Get-UvxPath {
    $vetted = Get-ExakitUvUvx
    if ($vetted) { return $vetted }
    $cmd = Get-Command uvx -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Where uv's own installer used to write: %USERPROFILE%\.local\bin, not
    # PowerShell's $HOME, which on a redirected home is a directory nothing
    # ever installed into.
    foreach ($dir in @($script:BinDir, (Join-Path (Get-ExakitProfileHome) ".local\bin"))) {
        $candidate = Join-Path $dir "uvx.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return "uvx"
}

# Get-McpCommandPath - the uvx the AI clients are told to launch. The vetted
# uvx comes FIRST, ahead of the manifest record: the record is whatever a
# previous run wrote, and after a uv below the floor was shadowed by the kit's
# own copy, a record that still names the old uvx would put the refused binary
# straight back into every client config. Twin of mcp_command_path.
function Get-McpCommandPath {
    $vetted = Get-ExakitUvUvx
    if ($vetted) { return $vetted }
    $manifestCommand = Get-ExakitManifestValue "components.mcp_server.command"
    if ($manifestCommand) { return $manifestCommand }
    return (Get-UvxPath)
}

# Set-McpClientsToKitUv - after uv moved (exakit update uv), make the AI
# clients that reach the MCP server through the bridge (Claude Desktop runs
# `uvx mcp-proxy`) use the uvx the kit vetted. The record is rewritten first
# because the config renderer reads it; then every already-connected client is
# refreshed. Clients the user never connected are left alone, as always. Twin
# of mcp_point_clients_at_kit_uv.
function Set-McpClientsToKitUv {
    $uvx = Get-ExakitUvUvx
    if (-not $uvx) { return $false }
    if (-not (Test-Path $script:ManifestPath)) { return $true }
    if ((Get-ExakitManifestValue "components.mcp_server.backend") -ne "sidecar") { return $true }
    Set-ExakitManifestValue "components.mcp_server.command" $uvx
    Set-ExakitManifestValue "components.mcp_server.uv_path" (Get-ExakitUvBin)
    return (Update-McpClients)
}

# Set by Invoke-McpOperationCli: whether the last runtime operation exited
# non-zero (a report that FOUND something also exits non-zero), and the system
# privileges the MCP user was last seen holding (Confirm-McpReadonlyPosture).
$script:McpLastRunFailed = $false
$script:McpReadonlyPrivileges = @()

# Get-McpCredentials - "user, password_file" for the client configs. Prefers
# the validated dedicated read-only user; falls back to the runtime admin
# user if MCP read-only provisioning has not run.
# A THIRD FIELD, Kind: which credential this actually is. The fallback below
# hands back the ADMIN account, and it did so indistinguishably from the
# read-only one - so the status line went on printing "(read-only)" about a
# full-privilege session, inverting the kit's central safety claim in the one
# direction that matters. The fallback stays, because it is what lets a
# half-provisioned kit still be repaired; it just can no longer pass itself off
# as the read-only user. Twin of mcp_credentials in mcp.sh.
function Get-McpCredentials {
    $connectionUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $connectionPwFile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    if ($connectionUser -and $connectionPwFile) {
        return @{ User = $connectionUser; PasswordFile = $connectionPwFile; Kind = "readonly" }
    }
    Write-ExakitLog "WARN" "No read-only MCP credential is recorded; falling back to the ADMIN account. Repair with: exakit mcp-setup"
    return @{ User = (Get-ExakitManifestValue "runtime.user"); PasswordFile = (Get-ExakitManifestValue "runtime.password_file"); Kind = "admin-fallback" }
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
    if (-not $bin) { Fail 'MCP initialisation failed: the read-only database user your AI clients sign in with could not be created, because exapump is not installed (the kit creates that user with it). Fix: exakit update exapump, then: exakit mcp-setup' }
    $previous = $env:EXAPUMP_CONFIG
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:EXAPUMP_CONFIG = $ConfigPath
        # Native exapump can write successful query summaries to stderr on
        # Windows. Do not let PowerShell convert that into a terminating
        # exception before Test-ExapumpSucceeded can evaluate the output.
        $ErrorActionPreference = "Continue"
        # STDIN, NOT ARGV - the twin of _exakit_run_exapump_sql in common.sh,
        # whose comment spells out why: two of the statements that come through
        # here are CREATE/ALTER USER ... IDENTIFIED BY <password>, and an argv
        # is readable by anything running as this user.
        #
        # On Windows that is worse than on unix, not better. A command line is
        # readable through Win32_Process by any process in the session, is
        # captured by EDR agents, and where "Include command line in process
        # creation events" is on - a common enterprise baseline - it is written
        # permanently into Security event 4688 and forwarded to the SIEM.
        # PowerShell script-block logging catches it as well. So the read-only
        # database password was being recorded durably outside the ACL'd
        # credential file the rest of this kit works to protect.
        #
        # exapump's own help documents the stdin path: "[SQL]  SQL statement to
        # execute (reads from stdin if omitted or if '-' is given)". Sending it
        # this way also retires the ConvertTo-ExakitNativeArgs quoting dance -
        # nothing goes through the 5.1 command-line rules any more, so quoted
        # identifiers arrive intact by construction rather than by escaping.
        #
        # Bytes, not a pipe (#52): Windows PowerShell 5.1 starts a string piped into a native process with
        # U+FEFF whatever $OutputEncoding says, and Exasol rejects that first character, so every statement
        # failed and the read-only user was never made. The statement's UTF-8 bytes go to exapump's stdin
        # straight from memory - never through a file, since two of them carry a password - as
        # Invoke-ExapumpSqlFileCapture does; both output streams are read as they come, so a full pipe
        # cannot stall it.
        $out = ""
        $code = 1
        $previousInputEncoding = $null
        try {
            # Process writes the preamble of [Console]::InputEncoding to stdin the moment it opens it - on
            # 5.1 that is the BOM, before a single statement byte. So the console's input encoding is UTF-8
            # without one while exapump starts (best effort: it throws where there is no console), and is
            # restored after. Invoke-ExapumpSqlFileCapture does the same.
            try {
                $previousInputEncoding = [Console]::InputEncoding
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
            } catch { $previousInputEncoding = $null }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $bin
            $psi.Arguments = "sql -p `"$Profile`""
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $proc = [System.Diagnostics.Process]::Start($psi)
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Sql)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.Close()
            $proc.WaitForExit()
            $out = ($stdoutTask.Result + $stderrTask.Result).TrimEnd()
            $code = $proc.ExitCode
        } catch {
            $out = "$_"
        } finally {
            if ($previousInputEncoding) {
                try { [Console]::InputEncoding = $previousInputEncoding } catch { }
            }
        }
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

    # NOR MAY IT REACH ANYTHING THROUGH A ROLE. A privilege held via a granted
    # role is attributed to the ROLE, not to the user, so every check above is
    # blind to `GRANT <role> TO MCP_READONLY`. Twin of the role query in
    # _exakit_assert_mcp_readonly_posture; PUBLIC is excluded because every
    # user holds it by definition.
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_ROLE_SCOPE_OK' ELSE 'EXAKIT_ROLE_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_ROLE_PRIVS WHERE GRANTEE = '$identifierLit' AND GRANTED_ROLE NOT IN ('PUBLIC')" "EXAKIT_ROLE_SCOPE_OK")) {
        Fail "The MCP read-only user holds a database ROLE, which can carry privileges these checks cannot see. Rebuild it with: exakit mcp-setup"
    }

    # No object privilege may be anything other than SELECT.
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_OBJ_PRIV_SCOPE_OK' ELSE 'EXAKIT_OBJ_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE <> 'SELECT'" "EXAKIT_OBJ_PRIV_SCOPE_OK")) {
        Fail "The MCP read-only user has a write object privilege; it must be read-only."
    }

    # What every user holds through PUBLIC reaches this login too (SEC-17):
    # logged, not shown and not refused - PUBLIC is the database owner's to set.
    # Twin of the same check in _exakit_assert_mcp_readonly_posture.
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN (SELECT COUNT(*) FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = 'PUBLIC' AND PRIVILEGE NOT IN ('CREATE SESSION', 'USE ANY SCHEMA', 'SELECT ANY TABLE')) + (SELECT COUNT(*) FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = 'PUBLIC' AND PRIVILEGE <> 'SELECT') = 0 THEN 'EXAKIT_PUBLIC_SCOPE_OK' ELSE 'EXAKIT_PUBLIC_SCOPE_TOO_WIDE' END AS STATUS" "EXAKIT_PUBLIC_SCOPE_OK")) {
        Write-ExakitLog "WARN" "The database grants PUBLIC more than read access, so every login - the AI client's read-only one included - has it. See: SELECT * FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = 'PUBLIC' (and EXA_DBA_OBJ_PRIVS)."
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
# Four lines became one. Creating the user, creating the schema and validating
# the login are phases of a single outcome - the read-only access exists and
# works - and the tick at the end already said all three happened.
# Twin of exakit_configure_mcp_readonly_access in common.sh.
function Set-McpReadonlyAccess {
    $cmraPrevQuiet = $script:ExakitQuietDetail
    $cmraT0 = Get-Date
    if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }
    # try/finally, not a plain restore at the end: every Fail in this
    # function throws, the MCP step is a SOFT step, and a caught throw
    # would leave ExakitQuietDetail set - silencing every step after it.
    try {
        # Ensure exapump is on PATH for this session
        $exapumpBin = Get-ExakitExapumpBin
        if (-not $exapumpBin) { Fail 'MCP initialisation failed: the read-only database user your AI clients sign in with could not be created, because exapump is not installed (the kit creates that user with it). Fix: exakit update exapump, then: exakit mcp-setup' }
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
            # Created empty and locked first. GetTempPath() honours %TMP%, so on
            # a machine where TEMP is redirected to a share or a folder-
            # redirected profile the inherited ACL is not owner-only - and both
            # the ADMIN and the read-only password are about to be written into
            # this file. Set-ExapumpTomlSection protects its own staging file
            # too; this covers the destination name itself.
            New-Item -ItemType File -Path $tempConfig -Force | Out-Null
            Protect-ExakitFile $tempConfig
            Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "admin" -Host_ $dbHost -Port $dbPort -User $runtimeUser -Password $adminPassword -Fingerprint (Get-ExakitTlsFingerprint)
            Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "mcp_readonly" -Host_ $dbHost -Port $dbPort -User $readonlyUser -Password $readonlyPassword -Schema $defaultSchemaUc -Fingerprint (Get-ExakitTlsFingerprint)
            Protect-ExakitFile $tempConfig

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
            Info "Testing database connectivity"
            $connTestResult = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "SELECT 1 AS connection_test"
            Assert-ExapumpResult -Result $connTestResult -Label "Database connection test" -FailMessage "Cannot connect to database with admin credentials. Check database status and credentials."
            Ok "Database connection successful"

            $identifierLit = ConvertTo-SqlLiteral $identifierUser
            if (-not (Test-ExapumpSqlHasToken $tempConfig "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '$identifierLit') THEN 'EXAKIT_MCP_USER_PRESENT' ELSE 'EXAKIT_MCP_USER_MISSING' END AS STATUS" "EXAKIT_MCP_USER_PRESENT")) {
                $script:ExakitActiveLabel = "Creating the dedicated MCP read-only database user"
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
                $script:ExakitActiveLabel = "Creating the default schema for MCP-safe querying"
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

            $script:ExakitActiveLabel = "Validating the dedicated MCP read-only login"
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
            # THE SAME FACT, SPELLED SO IT CANNOT BE MISREAD. schemas: ["STARTER_KIT"]
            # reads as "this user can only see STARTER_KIT" - and an agent checking
            # the install record before querying concluded exactly that, while the
            # MCP user was in fact returning every loaded schema quite happily. The
            # array stays (internal readers parse it); these two say what it means.
            Set-ExakitManifestValue "components.mcp_server.connection.default_schema" ($schemaTokens | Select-Object -First 1)
            Set-ExakitManifestValue "components.mcp_server.connection.read_scope" `
                "every schema (USE ANY SCHEMA + SELECT ANY TABLE); 'schemas' is the connection default, not a limit"
            Set-ExakitManifestValue "components.mcp_server.connection.validated" $true
        } finally {
            Remove-Item -Force $tempConfig -ErrorAction SilentlyContinue
        }
        OkStep "Dedicated MCP read-only access is configured and validated ($([int]((Get-Date) - $cmraT0).TotalSeconds)s)"
    } finally {
        $script:ExakitQuietDetail = $cmraPrevQuiet
    }
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
    Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "admin" -Host_ $dbHost -Port $dbPort -User $runtimeUser -Password $adminPassword -Fingerprint (Get-ExakitTlsFingerprint)
    Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "mcp_readonly" -Host_ $dbHost -Port $dbPort -User $readonlyUser -Password $readonlyPassword -Schema $defaultSchema -Fingerprint (Get-ExakitTlsFingerprint)

    Info "Re-checking MCP read-only grant posture against the database"
    try {
        Assert-McpReadonlyPosture -ConfigPath $tempConfig -ReadonlyUser $readonlyUser -Schemas $schemasCsv
        # The list itself, as the MCP user sees it: proving the boundary used to
        # mean opening your own connection with the password file. Doctor prints
        # it here and `--json` carries it as mcp_privileges.
        $script:McpReadonlyPrivileges = @(Get-McpReadonlyPrivileges -ConfigPath $tempConfig)
        if ($script:McpReadonlyPrivileges.Count -gt 0) {
            Ok "MCP read-only grant posture is still correct - $readonlyUser holds exactly: $($script:McpReadonlyPrivileges -join ', ')"
        } else {
            Ok "MCP read-only grant posture is still correct"
        }
        return $true
    } catch {
        Warn2 "MCP read-only grant posture has drifted from the expected read-only set (see log). Run 'exakit mcp-doctor' or review grants manually."
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
# Get-McpReadonlyPrivileges <config> - the system privileges the MCP user holds,
# read as that user from SYS.EXA_USER_SYS_PRIVS (the probe the skills teach).
function Get-McpReadonlyPrivileges {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $result = Invoke-ExapumpAdminSql -ConfigPath $ConfigPath -Profile "mcp_readonly" -Sql "SELECT PRIVILEGE FROM SYS.EXA_USER_SYS_PRIVS ORDER BY 1"
    if (-not $result.Success) { return @() }
    $privs = @()
    foreach ($line in ("$($result.Output)" -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq "PRIVILEGE" -or $t.StartsWith("[") -or $t -match 'statement') { continue }
        if ($t -match '^[A-Z][A-Z ]+$') { $privs += $t }
    }
    return $privs
}

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
            $out = & python -m mcp @ModuleArgs 2>&1 | Out-String -Width 4096
        } else {
            # Fall back to the managed uv Python (pinned to 3.12), which is
            # guaranteed to satisfy the 3.11+ requirement. uv is already a
            # hard dependency here (the MCP server itself runs via uvx).
            $uv = Install-ExakitUv
            $out = & $uv run --python $script:ManagedPythonVersion --no-project python -m mcp @ModuleArgs 2>&1 | Out-String -Width 4096
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
    if (-not $repoRoot) { Warn2 "Could not find the MCP package source to configure your AI clients."; return $null }
    # The caller may have prepared the read-only user already: it narrates as it
    # goes, and the client table is animating by the time this runs, so nothing
    # may print. ONE call only - the flag is cleared here, so a later run in the
    # same process (the refresh after a redeploy) prepares the user again.
    if ($script:McpReadonlyReady) {
        $script:McpReadonlyReady = $false
    } else {
        try { Set-McpReadonlyAccess } catch { return $null }
    }
    # The server behind the entries: the launcher's MCP sidecar as the read-only
    # user, healed where it can be. Quiet - the client table may be animating; a
    # failure is kept for Invoke-McpSetup to say after the table. Twin of the
    # mcp_sidecar_apply call in exakit_run_mcp_setup_cli.
    try { [void](Set-McpSidecar -Quiet) } catch { Write-ExakitLog "WARN" "MCP sidecar: $_" }
    $result = Invoke-McpModule (@("setup-runtime-clients", "--runtime-root", $script:ExakitHome, "--clients") + $Clients)
    if ($result.ExitCode -ne 0) {
        if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
        # First, not last: the client table may be animating, and its next frame
        # moves the cursor up and clears - which would wipe this warning off the
        # screen before anyone could read it. Fail() stops the animation for the
        # same reason.
        Stop-ExakitAnimation
        Warn2 "Could not write the MCP entry for this AI client. What failed: exakit logs setup. Retry with: exakit mcp-setup"
        return $null
    }
    return $result.Output
}

function Invoke-McpOperationCli {
    param([Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][string[]]$Clients, [string]$SnapshotId = "", [string]$ServerName = "")
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not find the MCP package source to manage your AI clients."; return $null }
    if ($Operation -in @("validate", "repair", "doctor")) {
        try { Set-McpReadonlyAccess } catch { return $null }
    }
    # Repair puts the server behind the entries right too, healing what it can;
    # diagnosis only reads. Quiet under the spinner: Invoke-McpOperation says
    # what could not be healed.
    if ($Operation -eq "repair") {
        try { [void](Set-McpSidecar -Quiet) } catch { Write-ExakitLog "WARN" "MCP sidecar: $_" }
    }
    $args = @("run-runtime-operation", $Operation, "--runtime-root", $script:ExakitHome)
    if ($SnapshotId) { $args += @("--snapshot-id", $SnapshotId) }
    # One named entry only, so removing an add-on leaves the exasol server
    # (and any other add-on) in the same config file alone.
    if ($ServerName) { $args += @("--servers", $ServerName) }
    $args += "--clients"
    $args += $Clients
    $result = Invoke-McpModule $args
    $script:McpLastRunFailed = ($result.ExitCode -ne 0)
    if ($result.ExitCode -ne 0) {
        if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
        # A diagnosis that FOUND something is not a diagnosis that failed to run.
        # The runtime exits non-zero for both; doctor's drift report used to be
        # thrown away here as "MCP doctor failed (see log)" - nothing shown,
        # nothing repaired, and the log's own advice was "run exakit mcp-doctor".
        # Twin of _exakit_mcp_reported in common.sh.
        if (Test-McpResultReported -Text $result.Output) { return $result.Output }
        Warn2 "MCP $Operation did not complete. The reason: exakit logs setup. Retry with: exakit mcp-setup"
        return $null
    }
    return $result.Output
}

# Test-McpResultReported <text> - a result document carrying an operation and a
# status: the runtime ran and is telling you something.
function Test-McpResultReported {
    param([string]$Text)
    if (-not "$Text".Trim()) { return $false }
    try {
        $doc = "$Text" | ConvertFrom-Json
        return [bool]($doc -and $doc.PSObject.Properties["operation"] -and $doc.PSObject.Properties["status"])
    } catch {
        return $false
    }
}

# Test-McpResultRepairable <text> - a WARNING or ERROR finding carries a code the
# repair operation acts on. Twin of _exakit_mcp_result_repairable.
function Test-McpResultRepairable {
    param([string]$Text)
    $codes = @("permission_drift", "manifest_drift_hash_mismatch", "manifest_drift_missing_artifact", "managed_artifact_missing", "managed_entry_outdated")
    try {
        $doc = "$Text" | ConvertFrom-Json
        foreach ($finding in @($doc.findings)) {
            if ($null -eq $finding) { continue }
            $severity = "$($finding.severity)".ToLowerInvariant()
            if (($codes -contains "$($finding.code)") -and ($severity -in @("warning", "error", "critical"))) { return $true }
        }
    } catch { }
    return $false
}

# Add-McpResultStamp <text> [privileges] - the discriminators every --json state
# answer carries (`installed`, `remedy`) added to the subsystem's own document,
# which is never otherwise touched. The remedy is the recommended_action of the
# worst WARNING-or-above finding, a finding about a FILE ahead of one about an
# absent client; null when none names one. Twin of _exakit_stamp_mcp_json.
function Add-McpResultStamp {
    param([string]$Text, [string[]]$Privileges = @())
    try {
        $doc = "$Text" | ConvertFrom-Json
        if (-not $doc) { return $Text }
        if (-not $doc.PSObject.Properties["installed"]) { $doc | Add-Member -NotePropertyName installed -NotePropertyValue $true }
        if (-not $doc.PSObject.Properties["remedy"]) {
            $rank = @{ critical = 0; error = 1; warning = 2 }
            $bestScore = $null
            $bestAction = $null
            $index = 0
            foreach ($finding in @($doc.findings)) {
                $index++
                if ($null -eq $finding -or -not $finding.recommended_action) { continue }
                $severity = "$($finding.severity)".ToLowerInvariant()
                if (-not $rank.ContainsKey($severity)) { continue }
                $aboutFile = 1
                if ($finding.scope -and $finding.scope.path) { $aboutFile = 0 }
                $score = ($rank[$severity] * 1000000) + ($aboutFile * 100000) + $index
                if ($null -eq $bestScore -or $score -lt $bestScore) { $bestScore = $score; $bestAction = "$($finding.recommended_action)" }
            }
            # No client connected at all: the gap status reports without a
            # finding gets the command that closes it (AGT-13).
            if ($null -eq $bestAction -and "$($doc.operation)" -eq "status" -and $doc.details -and $doc.details.PSObject.Properties["clients"]) {
                if (@($doc.details.clients | Where-Object { $_ -and $_.state -eq "configured" }).Count -eq 0) { $bestAction = "exakit mcp-setup" }
            }
            $doc | Add-Member -NotePropertyName remedy -NotePropertyValue $bestAction
        }
        if ($Privileges.Count -gt 0 -and -not $doc.PSObject.Properties["mcp_privileges"]) {
            $doc | Add-Member -NotePropertyName mcp_privileges -NotePropertyValue @($Privileges)
        }
        return ($doc | ConvertTo-Json -Depth 32)
    } catch {
        return $Text
    }
}

# Invoke-McpAddonCli - register the MCP endpoints of installed add-ons with the
# clients that are already connected. Twin of exakit_run_mcp_addon_cli in
# common.sh.
#
# Deliberately NOT Invoke-McpSetupCli: that path prepares the read-only database
# user first, so an add-on install would have started depending on a running
# database to finish. An add-on endpoint is a loopback URL with no credential in
# it, so this touches neither.
function Invoke-McpAddonCli {
    param([Parameter(Mandatory)][string[]]$Clients)
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not find the MCP package source to register the add-on endpoint."; return $null }
    $result = Invoke-McpModule (@("register-addon-servers", "--runtime-root", $script:ExakitHome, "--clients") + $Clients)
    if ($result.ExitCode -ne 0) {
        if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
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

# Show-McpSetupSummary - what MCP setup did, in the fewest lines that still tell
# the reader everything they have to act on.
#
# This was a twenty-line panel: a Mode row, a Meaning row explaining the Mode
# row, a Status row, and one File: row per client. None of that is actionable,
# and every word of it is one `exakit mcp-status` away. What IS actionable - the
# clients configured, the plaintext-credential warning, and the per-client
# "restart it like this" lines, which differ per client - stays, as plain lines
# rather than boxed rows. Twin of exakit_print_mcp_setup_summary in common.sh.
function Show-McpSetupSummary {
    param([Parameter(Mandatory)][string]$ResultJson, [bool]$TableShown = $false)
    $doc = $ResultJson | ConvertFrom-Json
    $clients = @($doc.selected_clients) | ForEach-Object { if ($script:McpClientLabels.ContainsKey($_)) { $script:McpClientLabels[$_] } else { $_ } }
    if ($clients) { $clientList = ($clients -join ', ') } else { $clientList = "no clients" }
    if ("$($doc.status)".StartsWith("success")) {
        # The table already named every client and what happened to it, so this
        # line would be the same fact twice, the second time less precisely.
        if (-not $TableShown) { Ok "MCP configured for $clientList" }
    } else {
        Warn2 "MCP setup finished as '$($doc.status)' for $clientList"
    }
    # A client whose own config file could not be used is skipped on its own;
    # the other clients are still configured, so name it rather than leave a
    # silent gap.
    $skippedClients = @()
    if ($doc.details -and $doc.details.skipped_clients) { $skippedClients = @($doc.details.skipped_clients) }
    foreach ($skipped in $skippedClients) {
        $skippedLabel = if ($script:McpClientLabels.ContainsKey($skipped.client)) { $script:McpClientLabels[$skipped.client] } else { $skipped.client }
        $reason = $skipped.reason
        if (-not $reason) { $reason = "unknown reason" }
        Warn2 "Skipped ${skippedLabel}: $reason"
    }
    # The plaintext-credential finding is a standing property of how every MCP
    # client stores a credential, not something this run did or the reader can
    # act on - and it is the READ-ONLY user's password, not the admin one.
    # Raising it as a warning on every single install taught people to read past
    # warnings. It stays in the result JSON and in the logfile, and
    # `exakit help mcp` documents it in full.
    # Twin of the same filter in exakit_print_mcp_setup_summary (common.sh).
    foreach ($f in @($doc.findings)) {
        if ($f.code -eq "plaintext_credential_reference") {
            # Suppressing the line is the point; losing the record is not, and
            # dropping it outright left the only trace in the result JSON, which
            # is deleted when this function returns.
            if ($f.message) { Write-ExakitLog "INFO" "$($f.message)" }
            continue
        }
        # Severity decides the glyph - twin of the same rule in
        # exakit_print_mcp_setup_summary. An INFO finding is a fact about a
        # client, not a fault of this run, and is printed as a note.
        if ($f.severity -eq "info") {
            if ($f.message) { Info "$($f.message)" }
            continue
        }
        if ($f.message) { Warn2 "$($f.message)" }
    }
    # One "restart your client" line per configured client says the same thing
    # four times over, in four wordings, for an action the reader takes once.
    # The skills step closes the same install with the generic form already.
    # Every adapter tags these kind="restart_client" (json_config.py covers
    # Cursor), so dropping that kind drops exactly them - a repair's
    # next_actions carry the finding code as their kind and are untouched.
    foreach ($a in @($doc.next_actions)) {
        if ($a.kind -eq "restart_client") {
            if ($a.message) { Write-ExakitLog "INFO" "$($a.message)" }
            continue
        }
        if ($a.message) { Info "$($a.message)" }
    }
    # Already in the closing panel, verbatim in effect:
    #   MCP configs:  in each AI client's config (list: exakit mcp-status)
    # so the pointer survives without being given twice.
    Write-ExakitLog "INFO" "Config file paths and per-client state: exakit mcp-status"
}

function Show-McpReadyPanel {
    param([string]$Mode = "")
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    # THROUGH THE RESOLVER, not a direct manifest read. Reading
    # connection.user here meant this panel could not tell "the read-only user
    # is recorded" from "there is none and the client is about to be handed the
    # admin account" - the two cases whose difference this line exists to
    # report. Get-McpCredentials answers both in one call.
    $mcpCreds = Get-McpCredentials
    $mcpUser = $mcpCreds.User
    $mcpUserKind = $mcpCreds.Kind
    $mcpUrl = Get-ExakitManifestValue "components.mcp_server.url"
    $mcpVersion = Get-ExakitManifestValue "components.mcp_server.version"
    $tls = Get-ExakitManifestValue "runtime.tls"

    # An eight-row panel of reference values became one line. The server's
    # address and version and the managed-state directory are what `exakit
    # mcp-status` is for; what the reader needs here is that the server exists,
    # what it is called, and that it reaches the database read-only. The whole
    # panel still goes to the logfile, so nothing is unrecoverable.
    if ($script:LogFile) {
        "DATA  MCP server: $mcpUrl (exasol/mcp-server $mcpVersion, beside the database)" | Add-Content -Path $script:LogFile
        "DATA  MCP managed state: $script:McpDir" | Add-Content -Path $script:LogFile
        "DATA  MCP TLS: $tls" | Add-Content -Path $script:LogFile
    }
    if ($dsn) { $dsnShown = $dsn } else { $dsnShown = "unknown" }
    # The user that was RESOLVED, not a default that assumes the good case:
    # "mcp_readonly" was printed even when the resolution had fallen back to
    # the admin account, which is exactly when the reader needed to know.
    if ($mcpUser) { $userShown = $mcpUser } else { $userShown = "unknown" }
    if ($mcpUserKind -eq "admin-fallback") {
        Warn2 "MCP server 'exasol' - $dsnShown as $userShown - this is the ADMIN account, NOT the read-only user."
        Info "No read-only MCP credential is recorded, so writes from your AI client would NOT be rejected by the database."
        Info "Fix it with: exakit mcp-setup"
    } else {
        Ok "MCP server 'exasol' - $dsnShown as $userShown (read-only), served beside the database at $mcpUrl"
    }

    # The prompt is only PRINTED when it could not be handed over: on the
    # clipboard it is four lines nobody has to read, and off a console (an
    # agent, CI) the clipboard is not ours to take, so the text is the only way
    # to pass it on. Never both.
    $firstPrompt = 'Use the exasol MCP server connected to my local Exasol database. List the available schemas and tables first. Then answer my questions with read-only SQL only, show me the SQL before you run it, and do not create, update, or delete anything.'
    $copied = $false
    if (Test-ExakitInteractive) {
        try { Set-Clipboard -Value $firstPrompt; $copied = $true } catch { $copied = $false }
    }
    if ($copied) {
        Ok "A first prompt for your AI client is on your clipboard - paste it after the restart."
    } else {
        Write-Host ""
        Start-ExakitPanel "First prompt to try in your AI client"
        Write-ExakitPanelLine """Use the exasol MCP server connected to my local Exasol database."
        Write-ExakitPanelLine "List the available schemas and tables first. Then answer my"
        Write-ExakitPanelLine "questions with read-only SQL only, show me the SQL before you run"
        Write-ExakitPanelLine "it, and do not create, update, or delete anything."""
        Complete-ExakitPanel
    }
}

function Show-McpOperationSummary {
    param([Parameter(Mandatory)][string]$ResultJson)
    $doc = $ResultJson | ConvertFrom-Json

    # `mcp-status` is a STATE QUERY, and the operation summary answers a
    # different question: it listed every client the kit SUPPORTS and reduced the
    # per-client records to a count. A reader asking "is my Claude set up?" got
    # the kit's capabilities. Mirrors exakit_print_mcp_operation_summary.
    $statusClients = @()
    if ($doc.details -and $doc.details.clients) { $statusClients = @($doc.details.clients) }
    if ($doc.operation -eq "status" -and $statusClients.Count -gt 0) {
        $stateLabels = @{ "configured" = "configured"; "not_set_up" = "not set up"; "not_installed" = "not installed" }
        $rows = @()
        foreach ($entry in $statusClients) {
            $name = if ($script:McpClientLabels.ContainsKey($entry.client)) { $script:McpClientLabels[$entry.client] } else { $entry.client }
            $state = if ($stateLabels.ContainsKey($entry.state)) { $stateLabels[$entry.state] } else { $entry.state }
            $note = ""
            if ($entry.state -eq "configured") {
                # One shortener for the kit, not a third hand-rolled copy of
                # it: Get-ExakitTilde knows about %USERPROFILE% and compares
                # ordinally, which this line did neither of.
                $note = Get-ExakitTilde "$($entry.path)"
            } elseif ($entry.state -eq "not_set_up") {
                $note = "run: exakit mcp-setup"
            }
            $rows += ,@{ Name = $name; State = $state; Note = $note }
        }
        $width = 0; $stateW = 0
        foreach ($r in $rows) {
            if ($r.Name.Length -gt $width) { $width = $r.Name.Length }
            if ($r.State.Length -gt $stateW) { $stateW = $r.State.Length }
        }
        # Keep the row inside 80 columns: a real config path is long enough on
        # its own to push the table past any terminal, and a wrapped row loses
        # the alignment that makes it readable. The file name identifies it, so
        # the middle goes rather than the end.
        $budget = 80 - (2 + $width + 2 + $stateW + 2)
        foreach ($r in $rows) {
            if ($r.Note.Length -gt $budget -and $r.Note.Contains("/")) {
                $parts = $r.Note -split "/"
                $keep = 1
                while ($keep -lt $parts.Count) {
                    $candidate = $parts[0] + "/.../" + (($parts[-($keep + 1)..-1]) -join "/")
                    if ($candidate.Length -gt $budget) { break }
                    $keep += 1
                }
                $short = $parts[0] + "/.../" + (($parts[-$keep..-1]) -join "/")
                if ($short.Length -gt $budget) { $short = ".../" + $parts[-1] }
                $r.Note = $short
            }
        }
        # The kit's own panel, not hand-drawn dashes: Start-ExakitPanel owns the
        # glyphs, so this screen matches every other box and degrades to ASCII on
        # a plain console with nothing here spelling a border character.
        #
        # Only the clients that ARE configured. Rows of "not installed" answered
        # what this machine does not have, which is not what a status screen is
        # for; `exakit mcp-setup` is where the full roster belongs, because there
        # the list IS the choice.
        # Twin of the same block in exakit_print_mcp_operation_summary.
        Write-Host ""
        Start-ExakitPanel "MCP clients"
        Write-ExakitPanelLine ("Client".PadRight($width) + "  " + "State".PadRight($stateW) + "  Config")
        $shown = 0
        foreach ($r in $rows) {
            if ($r.State -ne "configured") { continue }
            Write-ExakitPanelLine (($r.Name.PadRight($width) + "  " + $r.State.PadRight($stateW) + "  " + $r.Note).TrimEnd())
            $shown++
        }
        if ($shown -eq 0) {
            Write-ExakitPanelLine "Nothing configured yet. Connect a client with: exakit mcp-setup"
        }
        Complete-ExakitPanel
        Write-Host ""
        return
    }

    $clients = @($doc.selected_clients) | ForEach-Object { if ($script:McpClientLabels.ContainsKey($_)) { $script:McpClientLabels[$_] } else { $_ } }
    Write-Host ""
    Write-Host "  MCP operation summary"
    Write-Host "  Operation: $($doc.operation)"
    Write-Host "  Clients:   $(if ($clients) { $clients -join ', ' } else { 'all managed clients' })"
    Write-Host "  Status:    $($doc.status)"
    Write-Host "  Summary:   $($doc.summary)"
    if ($doc.backup_reference) { Write-Host "  Snapshot:  $($doc.backup_reference)" }
    # Clients left alone because their own config file could not be used. The
    # rest of the selection is still configured, so report this per client
    # (mirrors exakit_print_mcp_operation_summary in common.sh).
    $skippedClients = @()
    if ($doc.details -and $doc.details.skipped_clients) { $skippedClients = @($doc.details.skipped_clients) }
    if ($skippedClients.Count -gt 0) {
        Write-Host ""; Write-Host "  Skipped clients:"
        foreach ($skipped in $skippedClients) {
            $skippedLabel = if ($script:McpClientLabels.ContainsKey($skipped.client)) { $script:McpClientLabels[$skipped.client] } else { $skipped.client }
            $reason = $skipped.reason
            if (-not $reason) { $reason = "unknown reason" }
            Write-Host "  - ${skippedLabel}: $reason"
        }
    }
    # Doctor carries per-client discovery plus the managed-artifact list:
    # render a state map in the same vocabulary as the setup menu, so "not
    # installed" reads as expected state instead of a warning (mirrors
    # exakit_print_mcp_operation_summary in common.sh).
    $discovered = @()
    if ($doc.details -and $doc.details.discovered_clients) { $discovered = @($doc.details.discovered_clients) }
    $clientStates = @()
    if ($doc.details -and $doc.details.clients) { $clientStates = @($doc.details.clients) }
    if ($doc.operation -eq "doctor" -and $clientStates.Count -gt 0) {
        # The doctor derives each client's state from HEALTH (see _doctor in
        # mcp/service.py); rebuilding it here from "an artifact exists" called a
        # client connected with its entry deleted. Twin of the same branch in
        # exakit_print_mcp_operation_summary.
        $groups = [ordered]@{ "connected" = @(); "needs attention" = @(); "configured, not installed" = @(); "available" = @(); "not installed" = @() }
        $stateToGroup = @{ connected = "connected"; needs_attention = "needs attention"; configured_client_missing = "configured, not installed"; not_set_up = "available"; not_installed = "not installed" }
        foreach ($entry in $clientStates) {
            $name = if ($script:McpClientLabels.ContainsKey($entry.client)) { $script:McpClientLabels[$entry.client] } else { $entry.client }
            $group = "not installed"
            if ($stateToGroup.ContainsKey("$($entry.state)")) { $group = $stateToGroup["$($entry.state)"] }
            $groups[$group] += $name
        }
        $hints = @{ "available" = "-> connect with: exakit mcp-setup"; "needs attention" = "-> the findings below say what; exakit mcp-doctor repairs drift"; "configured, not installed" = "-> the client is gone; its entry stays until: exakit mcp-doctor" }
        Write-Host ""; Write-Host "  Client state:"
        foreach ($label in $groups.Keys) {
            $names = $groups[$label]
            if (@($names).Count -gt 0) {
                $hint = if ($hints.ContainsKey($label)) { "   " + $hints[$label] } else { "" }
                Write-Host ("    {0,-26} {1}{2}" -f $label, ($names -join ', '), $hint)
            }
        }
        $discovered = @()
    }
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
        $hints = @{ "available" = "-> connect with: exakit mcp-setup"; "needs attention" = "-> managed entry, client missing (exakit mcp-doctor)" }
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
    # About to create/verify the read-only database user: a stopped database
    # here used to surface as a bare connection failure - heal it first.
    if (Get-Command Confirm-ExakitRuntimeRunning -ErrorAction SilentlyContinue) {
        Confirm-ExakitRuntimeRunning
    }

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
        if ($env:EXAKIT_MCP_CLIENTS -match '^\s*(all|ALL|All)\s*$') {
            # "all" means every client ON THIS MACHINE - the set the menu offers -
            # not every client the kit knows. The full list wrote the read-only
            # password into config files for tools that were not installed. A
            # client named explicitly is still configured, installed or not.
            # Twin of the same rule in exakit_mcp_setup.
            $allStates = Get-McpClientStates
            if ($allStates) {
                $detectedClients = @($clients | Where-Object { $allStates[$_] -in @("connected", "pending") })
                $skippedClients = @($clients | Where-Object { $_ -notin $detectedClients })
                if ($detectedClients.Count -gt 0) {
                    $clients = $detectedClients
                    if ($skippedClients.Count -gt 0) {
                        Info "EXAKIT_MCP_CLIENTS=all - not installed here, skipped: $($skippedClients -join ',') (name one explicitly to configure it anyway)"
                    }
                }
            }
        }
        Info "Configuring MCP clients from EXAKIT_MCP_CLIENTS: $($clients -join ',')"
    }

    Reset-McpClientTable
    if (-not $clients) {
        # Show the FULL list of supported clients so the user sees everything the
        # kit can connect: pending clients (installed, not connected yet) are
        # selectable and pre-selected; clients that are already connected or not
        # installed on this machine appear as DISABLED rows with the reason and
        # cannot be checked. One "Claude" row covers both Claude surfaces
        # (desktop app + Claude Code CLI) while their states match; when they
        # differ, each surface gets its own row. Falls back to everything
        # selectable when discovery is unavailable.
        $states = Get-McpClientStates
        if ($null -eq $states) {
            $states = @{}
            foreach ($id in @("claude_desktop", "claude_code", "codex", "cursor", "vscode_copilot", "gemini_cli", "opencode", "continue")) { $states[$id] = "pending" }
        }
        $menuLabels = New-Object 'System.Collections.Generic.List[string]'
        $menuIds = New-Object 'System.Collections.Generic.List[object]'
        $menuNotes = New-Object 'System.Collections.Generic.List[string]'
        # One client row: pending rows carry their ids and are selectable;
        # connected and missing rows carry no id and a note saying why, which is
        # what makes them a disabled row in the table.
        $addRow = {
            param($label, $state, $ids)
            [void]$menuLabels.Add($label)
            switch ($state) {
                "pending"   { [void]$menuIds.Add($ids); [void]$menuNotes.Add("") }
                "connected" { [void]$menuIds.Add(@()); [void]$menuNotes.Add("already connected") }
                default     { [void]$menuIds.Add(@()); [void]$menuNotes.Add("not installed") }
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
        $connectedCount = 0
        foreach ($note in $menuNotes) { if ($note -eq "already connected") { $connectedCount++ } }
        if ($pendingCount -eq 0) {
            # NOTHING CONNECTED IS NOT EVERYTHING CONNECTED. Every row can be
            # "not installed" - a fresh machine with no AI client on it at all -
            # and the claim below was printed for that case too, telling the
            # reader their clients were wired up over MCP when the kit had not
            # touched a single config. Zero of zero is not success; say which
            # of the two happened. Twin of the same branch in exakit_mcp_setup.
            if ($connectedCount -eq 0) {
                Info "No AI client was found on this machine, so there is nothing to connect yet."
                Info "Install one (Claude, Codex, Cursor, Copilot, Gemini CLI, OpenCode, Continue) and run 'exakit mcp-setup'."
                return $true
            }
            Ok "All AI clients found on this machine are already connected over MCP."
            Info "Check them with 'exakit mcp-status'; new clients appear here once installed."
            return $true
        }
        # The read-only database user is prepared BEFORE the table is drawn.
        # Everything it does narrates itself, and from the moment the table is on
        # screen a line printed under it shifts the frame out from under the
        # cursor arithmetic that redraws it: the animator's first frame would then
        # repaint over its own table instead of the menu's, and the top of a stale
        # table is left stranded above it. It is the kit's own database user, not
        # any client's, so preparing it before the choice costs a skipped run
        # nothing but an idle user - and it is what the next 'exakit mcp-setup'
        # needs anyway.
        # A failure in here has already said what went wrong - Fail() prints its
        # own card - so this only has to stop the step, not restate it. Twin of
        # the shell's `exakit_configure_mcp_readonly_access || return 1`.
        try { Set-McpReadonlyAccess } catch { return $false }
        $script:McpReadonlyReady = $true

        # ONE table for the whole step, the same component the dataset load uses
        # (the Get/Set-ExakitTable* family in ui.ps1): the rows a reader ticks are
        # the rows that then fill in, so nobody has to map one screen onto
        # another. Twin of the same table in exakit_mcp_setup (common.sh).
        $clientCount = $menuLabels.Count
        $rowFirst = 2
        $rowLast = $rowFirst + $clientCount - 1
        $rowSkip = $rowLast + 1
        $script:McpTableRowFirst = $rowFirst
        $script:McpTableIds = $menuIds.ToArray()
        $script:McpTable = New-ExakitTable -Title "AI clients to connect" -Col1 "Client"
        [void](Add-ExakitTableRow -Kind "group" -Label "Select All" -Table $script:McpTable)
        for ($i = 0; $i -lt $clientCount; $i++) {
            if ($i -eq ($clientCount - 1)) { $kind = "corner" } else { $kind = "tee" }
            [void](Add-ExakitTableRow -Kind $kind -Label $menuLabels[$i] -Table $script:McpTable)
        }
        [void](Add-ExakitTableRow -Kind "plain" -Label "Skip" -Table $script:McpTable)
        # Pre-select every pending client, and the group row with them: under the
        # all-or-none parent it is ticked exactly while every pickable child is.
        # A client with no id is one this machine cannot offer - it becomes a
        # disabled row carrying the reason, so the list is the whole answer rather
        # than a list that quietly omits things.
        # $env:EXAKIT_MCP_PRESELECT (the personas' clients, from `exakit persona
        # add`) ticks only the pending clients it names; "all" is every one.
        # Twin of the same rule in exakit_mcp_setup.
        $filter = [bool]($env:EXAKIT_MCP_PRESELECT -and $env:EXAKIT_MCP_PRESELECT -notmatch '^\s*(all|ALL|All)\s*$')
        $pre = @()
        if ($filter) { $pre = @(ConvertTo-McpClientSelection $env:EXAKIT_MCP_PRESELECT | Where-Object { $_ }) }
        $defaults = @()
        $every = $true
        for ($i = 0; $i -lt $clientCount; $i++) {
            $rowAt = $rowFirst + $i
            if (@($menuIds[$i]).Count -gt 0) {
                $want = $true
                if ($filter) {
                    $want = [bool](@($menuIds[$i]) | Where-Object { $pre -contains $_ })
                }
                if ($want) { $defaults += $rowAt } else { $every = $false }
            }
            else { Disable-ExakitTableRow -Row $rowAt -Note $menuNotes[$i] -Table $script:McpTable }
        }
        if ($defaults.Count -eq 0) { $defaults = @($rowSkip) }
        elseif ($every) { $defaults = @(1) + $defaults }
        Write-Host ""
        # Loop so a not-confirmed skip returns the user to the menu.
        $onScreen = 0
        $selection = @()
        while ($true) {
            $selection = @(Invoke-ExakitTableMenu -Table $script:McpTable -Defaults $defaults `
                -ExclusiveIndex $rowSkip -GroupParent 1 -GroupFirst $rowFirst `
                -GroupLast $rowLast -GroupMode "all" -OnScreen $onScreen)
            if ($selection -contains $rowSkip) {
                # Taken without asking (UI_TABLE_AUTO): none of the clients named
                # is on this machine to connect, which is no question. Twin of
                # the same branch in exakit_mcp_setup.
                if ($env:UI_TABLE_AUTO -eq "1") {
                    Info "None of the AI clients named is waiting to be connected here - connect one any time with: exakit mcp-setup"
                    Reset-McpClientTable
                    return $true
                }
                Warn2 "No AI client will be connected to your database."
                if (Confirm-ExakitPrompt "Are you sure you want to continue without an AI client?" $true) {
                    Info "Okay - you can connect one any time with: exakit mcp-setup"
                    Show-ExakitNoAiPanel
                    Reset-McpClientTable
                    return $true
                }
                # Back into the SAME table, not a second one under it: the frame is
                # still on screen with the warning and the question below it (one
                # line each), so the menu is told how far up its own top border is.
                $onScreen = [int]$script:McpTable.Lines + 2
                continue
            }
            break
        }
        $clients = @()
        $pickedRows = @()
        foreach ($row in $selection) {
            if ($row -lt $rowFirst -or $row -gt $rowLast) { continue }
            $ids = @($menuIds[$row - $rowFirst])
            if ($ids.Count -eq 0) { continue }        # disabled rows carry no id
            foreach ($id in $ids) { if ($clients -notcontains $id) { $clients += $id } }
            $pickedRows += $row
        }
        $script:McpTableRows = $pickedRows
        if ($clients.Count -eq 0) {
            # Enter needs a selection and the group row can never be the only one
            # ticked, so this is the impossible answer rather than a real one.
            # Still: never call the setup CLI with an empty client list.
            Info "No AI client selected - connect one any time with: exakit mcp-setup"
            Reset-McpClientTable
            return $true
        }
    }

    $tableShown = $false
    if ($null -ne $script:McpTable -and @($script:McpTableRows).Count -gt 0) {
        foreach ($row in $script:McpTableRows) {
            Set-ExakitTableRow -Row $row -State "waiting" -Table $script:McpTable
        }
        if (Start-ExakitTable -Table $script:McpTable) {
            $tableShown = $true
            # The bar sits on the GROUP row, not on a client row: ONE python
            # process configures every selected client, so there is no per-client
            # checkpoint a per-client bar could be honest about. The client rows
            # wait, and each one's final cell is read out of the result
            # afterwards - nothing on screen calls a client done before the run
            # says it is.
            Set-ExakitTableRow -Row 1 -State "running" -Pct 5 -Ceiling 90 -Secs 20 `
                -Phase "writing client configs" -Table $script:McpTable
        }
    }
    # No live table to say what is happening: say it in a line, as before. With
    # the table there is nothing to add - and a line printed here would land
    # between the menu's frame and the animator's first frame, which is the one
    # place on this screen where nothing may be printed.
    if (-not $tableShown) { Info "Applying MCP setup" }
    $resultJson = Invoke-McpSetupCli -Clients $clients
    if ($tableShown) {
        # What each row ends up saying comes from the result, client by client:
        # one client can be skipped on its own (an unparseable config file of its
        # own) while every other client is configured, and the exit status cannot
        # tell those two apart.
        $configured = Get-McpConfiguredClients -ResultJson $resultJson
        $okRows = 0
        $selRows = 0
        foreach ($row in $script:McpTableRows) {
            $selRows++
            $ids = @($script:McpTableIds[$row - $script:McpTableRowFirst])
            $idOk = 0
            foreach ($id in $ids) { if ($configured -contains $id) { $idOk++ } }
            if ($idOk -eq 0) {
                Set-ExakitTableRow -Row $row -State "failed" -Final "not configured" -Table $script:McpTable
            } elseif ($idOk -eq $ids.Count) {
                Set-ExakitTableRow -Row $row -State "done" -Final "configured" -Table $script:McpTable
                $okRows++
            } else {
                # The Claude row is two surfaces behind one label; say which
                # rather than call a half-written row configured.
                Set-ExakitTableRow -Row $row -State "done" -Table $script:McpTable `
                    -Final ("configured " + $script:UiMidDot + " $idOk of $($ids.Count)")
                $okRows++
            }
        }
        if ($selRows -eq 1) { $unit = "client" } else { $unit = "clients" }
        if ($okRows -eq $selRows) {
            Set-ExakitTableRow -Row 1 -State "done" -Table $script:McpTable `
                -Final ("configured " + $script:UiMidDot + " $selRows $unit")
        } else {
            Set-ExakitTableRow -Row 1 -State "failed" -Table $script:McpTable `
                -Final "$okRows of $selRows $unit configured"
        }
        # Normally still animating. A failed CLI stops the animation itself before
        # it warns, so that its warning is not painted into the frame - and then
        # the frame on screen is already the last one.
        if ($script:UiTableLive) { Stop-ExakitTable -Table $script:McpTable }
    }
    if ($resultJson) { Show-McpSetupSummary -ResultJson $resultJson -TableShown $tableShown }
    Reset-McpClientTable
    # What the MCP server's apply could not heal, now that the table is done.
    Show-McpSidecarProblem
    if (-not $resultJson) { return $false }
    Show-McpReadyPanel "permanent"
    # The panel above IS the guidance; announcing that it exists, directly
    # under it, told the reader nothing they had not just read.
    return $true
}

function Invoke-McpOperation {
    param([Parameter(Mandatory)][string]$Operation, [string[]]$InputArgs = @())
    $clients = Get-McpClientsFromArgs $InputArgs
    if (-not $clients) { Warn2 "Please choose valid MCP clients: claude_desktop, cursor, codex, or all."; return $false }
    # JSON mode (EXAKIT_MCP_RESULT_JSON=1): the operation result is already the
    # machine-readable truth the summary renders - print it verbatim and keep
    # every human line off stdout. Twin of the same branch in
    # exakit_mcp_operation (common.sh).
    if ($env:EXAKIT_MCP_RESULT_JSON -eq "1") {
        $resultJson = Invoke-McpOperationCli -Operation $Operation -Clients $clients 6>$null
        $ok = [bool]$resultJson
        if ($ok -and $script:McpLastRunFailed) { $ok = $false }
        $privileges = @()
        if ($Operation -in @("doctor", "validate")) {
            if (-not (Confirm-McpReadonlyPosture 6>$null)) { $ok = $false }
            $privileges = @($script:McpReadonlyPrivileges)
        }
        # Straight to the console stream, past the caller: Invoke-CmdMcpOperation
        # reads this function's boolean through `if (-not (...))`, which swallowed
        # every pipeline object with it - `exakit mcp-doctor --json` and
        # `mcp-status --json` printed nothing and exited 0.
        if ($resultJson) {
            [Console]::Out.WriteLine((Add-McpResultStamp -Text $resultJson -Privileges $privileges))
        } else {
            [Console]::Out.WriteLine("{`"installed`": true, `"status`": `"error`", `"remedy`": `"exakit logs setup`", `"error`": `"the MCP $Operation operation produced no result (see log)`"}")
        }
        return $ok
    }
    # Quieted BEFORE the Info, or the line prints and the spinner then says the
    # same thing underneath it. On a console the animation is the narration and
    # the logfile keeps the record; redirected there is no spinner, so the line
    # stays and nothing is lost.
    $mcpPrevQuiet = $script:ExakitQuietDetail
    if (Test-ExakitStdoutIsTerminal) { $script:ExakitQuietDetail = $true }
    Info "Running MCP $Operation"
    Start-ExakitSpinner "Running MCP $Operation"
    try {
        $resultJson = Invoke-McpOperationCli -Operation $Operation -Clients $clients
    } finally {
        Stop-ExakitSpinner
        $script:ExakitQuietDetail = $mcpPrevQuiet
    }
    if ($resultJson) { Show-McpOperationSummary $resultJson }
    $ok = [bool]$resultJson
    if ($ok -and $script:McpLastRunFailed) { $ok = $false }
    # Doctor REPAIRS what it can act on - a drifted or deleted entry, a loosened
    # file mode - and re-checks, as its own report promises ("exakit mcp-doctor
    # repairs drift"). This side only ever diagnosed: the drift finding came back
    # with recommended_action "Run: exakit mcp-doctor", and the wrapper exited 1.
    # Twin of the EXAKIT_MCP_LAST_REPAIRABLE branch in exakit_mcp_operation.
    if ($Operation -eq "doctor" -and $resultJson -and (Test-McpResultRepairable -Text $resultJson)) {
        Info "Repairing what doctor found"
        $repairJson = Invoke-McpOperationCli -Operation "repair" -Clients $clients
        Show-McpSidecarProblem
        if ($repairJson -and -not $script:McpLastRunFailed) {
            Ok "Repair applied - re-checking"
            $recheck = Invoke-McpOperationCli -Operation "doctor" -Clients $clients
            if ($recheck) {
                Show-McpOperationSummary $recheck
                $ok = (-not $script:McpLastRunFailed) -and -not (Test-McpResultRepairable -Text $recheck)
            }
        } else {
            Warn2 "Repair did not complete (see log). Re-connect the client with: exakit mcp-setup"
            $ok = $false
        }
    }
    if ($Operation -in @("doctor", "validate")) {
        if (-not (Confirm-McpReadonlyPosture)) { $ok = $false }
    }
    # A diagnosis is only useful next to its remedy. Doctor is the command people run
    # when something looks wrong with an AI client, and the answer is almost always
    # the same one - so name it rather than making them go and find it.
    if ($Operation -eq "doctor") {
        Info "Connect or re-connect AI clients any time with:  exakit mcp-setup"
    }
    return $ok
}

# Get-McpManagedClients - the client ids that already carry a managed MCP entry.
# Empty when nothing is connected or the status operation is unavailable, which
# callers treat as "nothing to refresh". Twin of mcp_managed_clients in
# setup/lib/mcp.sh.
function Get-McpManagedClients {
    $resultJson = Invoke-McpOperationCli -Operation "status" -Clients @(
        "claude_desktop", "claude_code", "cursor", "codex",
        "vscode_copilot", "gemini_cli", "opencode", "continue")
    if (-not $resultJson) { return @() }
    try {
        $doc = $resultJson | ConvertFrom-Json
        $clients = @()
        foreach ($artifact in @($doc.artifacts)) {
            if ($artifact.client -and ($clients -notcontains $artifact.client)) { $clients += $artifact.client }
        }
        return $clients
    } catch {
        return @()
    }
}

# Update-McpClients - re-render the managed entry in the clients that are
# already connected: after the MCP server moved (a new port, the first switch of
# a kit from before to the server beside the database) or the uvx the bridge
# runs through changed. This is the configure operation (what `exakit mcp-setup`
# runs), because configure re-renders unconditionally.
#
# Scoped to already-managed clients on purpose: configure would happily create a
# config for a client the user never chose to connect. Twin of
# mcp_refresh_clients in setup/lib/mcp.sh.
function Update-McpClients {
    $clients = Get-McpManagedClients
    if (@($clients).Count -eq 0) {
        Info "No AI client is connected yet - connect one any time with: exakit mcp-setup"
        return $true
    }
    Info "Refreshing the AI client configs"
    $resultJson = Invoke-McpSetupCli -Clients $clients
    if (-not $resultJson) {
        Warn2 "Could not refresh the AI client configs - run exakit mcp-setup to finish."
        return $false
    }
    Show-McpSetupSummary $resultJson
    Ok "AI client configs point at $(Get-ExakitManifestValue 'components.mcp_server.url')"
    return $true
}

# Register-ExakitAddonMcpServers <label> - put an installed add-on's MCP endpoint
# into the clients that are already connected. Twin of
# mcp_register_addon_servers in setup/lib/mcp.sh.
#
# Scoped to already-managed clients for the same reason Update-McpClients is:
# configure would happily create a config for a client the user never chose to
# connect. Nothing here is fatal - an add-on that installed correctly is
# installed, whether or not an AI client is wired to it yet, and the endpoint is
# one `exakit mcp-setup` away in any case.
function Register-ExakitAddonMcpServers {
    param([string]$Label = "the add-on")
    $clients = Get-McpManagedClients
    if (@($clients).Count -eq 0) {
        Info "No AI client is connected yet - connect one any time with: exakit mcp-setup"
        return $true
    }
    $resultJson = Invoke-McpAddonCli -Clients $clients
    if (-not $resultJson) {
        Write-ExakitAddonNote "warn" "Could not register the $Label MCP endpoint with your AI clients - run: exakit mcp-setup"
        return $false
    }
    $configured = @()
    try {
        $doc = $resultJson | ConvertFrom-Json
        if ($doc.dash_server) { $configured = @($doc.dash_server.configured_clients) }
    } catch {
        $configured = @()
    }
    $configured = @($configured | Where-Object { $_ })
    if ($configured.Count -gt 0) {
        # Nothing on screen - twin of the same silence in mcp.sh. Registering the
        # endpoint is part of installing the add-on, not a step of its own, and
        # the marketplace row already reported the install. On this side the line
        # was landing mid-redraw badly enough to duplicate the table's top border
        # and spill its own tail across the closing one.
        Write-ExakitLog "OK" "$Label MCP endpoint registered with: $($configured -join ', ')"
        return $true
    }
    # Every connected client was skipped: the two that cannot express a remote
    # MCP server (Codex, Claude) are the usual reason, and that is a fact about
    # the client, not a failure of this install.
    Write-ExakitAddonNote "info" "No connected AI client can take a remote MCP endpoint - drive $Label with: exakit help dash-server"
    return $true
}

# Unregister-ExakitMcpServerEntry <server> <label> - the mirror image, for an
# add-on being removed: drop just that one entry, so the exasol server (and any
# other add-on) stays where it is. Twin of mcp_unregister_server_entry in
# setup/lib/mcp.sh.
function Unregister-ExakitMcpServerEntry {
    param([Parameter(Mandatory)][string]$ServerName, [string]$Label = "")
    if (-not $Label) { $Label = $ServerName }
    $clients = Get-McpManagedClients
    if (@($clients).Count -eq 0) { return $true }
    $resultJson = Invoke-McpOperationCli -Operation "uninstall" -Clients $clients -ServerName $ServerName
    if (-not $resultJson) {
        Warn2 "The $Label MCP entry may still be in your AI client configs - check with: exakit mcp-status"
        return $false
    }
    return $true
}

# Request-ExakitMcpSetupOffer - connect the user's AI client(s) during
# install. A required step: the client TABLE handles the choice (every client
# this machine can still connect is preselected), and non-interactive installs
# keep those defaults inside Invoke-ExakitTableMenu.
function Request-ExakitMcpSetupOffer {
    if ((Get-ExakitManifestValue "components.mcp_server.client_setup.completed") -eq $true) { return }
    # EXAKIT_SKIP_MCP=1 lets a scripted/agent install skip client wiring
    # entirely (twin of the same hatch in common.sh's exakit_maybe_offer_mcp_setup).
    if ($env:EXAKIT_SKIP_MCP -eq "1") {
        Info "Skipping MCP client setup (EXAKIT_SKIP_MCP=1). Run it any time with: exakit mcp-setup"
        return
    }
    # No lead-in: the ticks directly above already said the runtime and the
    # server are ready, and this restated them in a sentence.
    if (-not (Invoke-McpSetup)) {
        Warn2 "Your local runtime is installed, but MCP client setup did not finish cleanly."
        Warn2 "Retry any time with: exakit mcp-setup"
    }
}

# --- the launcher's MCP server (Exasol Personal 2.4.0+) ---------------------
# Twin of the same section in mcp.sh: the launcher's MCP sidecar, written whole
# by the kit (pinned image, loopback, --no-auth) and connected as the kit's
# read-only MCP user instead of the deployment's SYS, applied with
# `exasol start`. It is the only MCP server the kit runs: there is no fallback.
# What would stop it serving is healed here (the read-only user, a taken port,
# a deployment that needs one restart, a container that did not start), and
# what cannot be healed is said with its fix - the record stays, so the clients
# keep the URL and `exakit mcp-doctor` can finish the job later.
$script:McpSidecarName = if ($env:EXAKIT_MCP_SIDECAR) { $env:EXAKIT_MCP_SIDECAR } else { "mcp" }
$script:McpSidecarPort = if ($env:EXAKIT_MCP_SIDECAR_PORT) { [int]$env:EXAKIT_MCP_SIDECAR_PORT } else { 4896 }
$script:SidecarPyYaml = if ($env:EXAKIT_SIDECAR_PYYAML) { $env:EXAKIT_SIDECAR_PYYAML } else { "PyYAML==6.0.3" }
$script:McpSidecarImageFallback = "docker.io/exasol/mcp-server:2.4.0@sha256:ae13d5430dff463aa0817f5a188211820fb8c2565e95e477d5ca71b04bb50b68"
$script:McpBridgeFallback = "mcp-proxy@0.13.0"
# The last apply's failure as the lines to show (the error, then its fix), for
# a caller that ran it under -Quiet while a table owned the screen.
$script:McpSidecarProblem = @()

function Test-McpSidecarSupported {
    if ((Get-ExakitManifestValue "runtime.type") -ne "personal") { return $false }
    if (-not (Get-Command Get-PersonalCli -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Test-Path -LiteralPath $script:PersonalDeployDir)) { return $false }
    return ((Test-PersonalLauncherSupports "sidecar") -and (Test-PersonalLauncherSupports "mcp"))
}

function Get-McpSidecarStatus {
    $text = "" + (Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @("mcp", "status", "--json") -TimeoutSeconds 60)
    try { $doc = $text | ConvertFrom-Json } catch { return $null }
    if ($doc -is [array]) { $doc = $doc | Select-Object -First 1 }
    return $doc
}

# Get-McpSidecarStatusDetail <status> - what the launcher says went wrong (its
# message, error or reason), at most 200 characters; "" when it says nothing.
function Get-McpSidecarStatusDetail($Status) {
    if (-not $Status) { return "" }
    foreach ($key in @("message", "error", "reason")) {
        $value = "" + $Status.$key
        if ($value.Trim()) {
            $value = $value.Trim() -replace "\s+", " "
            if ($value.Length -gt 200) { $value = $value.Substring(0, 200) }
            return $value
        }
    }
    return ""
}

# Get-McpSidecarImage - the launcher's MCP server image, by digest, from THIS KIT
# COPY's versions.json (SEC-13); Get-McpSidecarImageVersion is its tag, the
# version that image is. Twins of mcp_sidecar_image / mcp_sidecar_image_version.
function Get-McpSidecarImage {
    $image = Get-ExakitVersionsPin -Path "components.mcp.sidecar_image"
    if ("$image" -notlike "*@sha256:*") { $image = $script:McpSidecarImageFallback }
    return "$image"
}
function Get-McpSidecarImageVersion {
    return (Get-McpSidecarImage).Split("@")[0].Split(":")[-1]
}

# Get-McpSidecarPort - the host port the MCP server is published on: the one
# recorded (a self-heal may have moved it), else EXAKIT_MCP_SIDECAR_PORT, else
# 4896. Twin of mcp_sidecar_port.
function Get-McpSidecarPort {
    $recorded = "" + (Get-ExakitManifestValue "components.mcp_server.port")
    if ($recorded -match '^[0-9]+$') { return [int]$recorded }
    return [int]$script:McpSidecarPort
}

function Get-McpSidecarDefinitionJson([string]$User, [string]$PasswordFile, [int]$Port = 0) {
    if ($Port -le 0) { $Port = Get-McpSidecarPort }
    $image = Get-McpSidecarImage
    $ref = { param($k) @{ secretKeyRef = @{ name = "exasol-database"; key = $k } } }
    $settings = [ordered]@{ default_row_limit = 1000; enable_read_query = $true; enable_summarize_table = $true
        enable_query_profiling = $true; enable_preprocessor_tools = $false; enable_write_query = $false
        enable_read_bucketfs = $false; enable_write_bucketfs = $false; views = @{ enable = $true } }
    $definition = [ordered]@{
        enabled = $true
        container = [ordered]@{
            image = "$image"; imagePullPolicy = "IfNotPresent"; restartPolicy = "Always"
            args = @("--host", "0.0.0.0", "--port", "4896", "--no-auth")
            env = @(
                @{ name = "EXASOL_DB_HOST"; valueFrom = (& $ref "host") },
                @{ name = "EXASOL_DB_PORT"; valueFrom = (& $ref "port") },
                @{ name = "EXA_DSN"; value = '$(EXASOL_DB_HOST):$(EXASOL_DB_PORT)' },
                @{ name = "EXA_USER"; value = $User },
                @{ name = "EXA_PASSWORD"; valueFile = $PasswordFile },
                @{ name = "EXA_SSL_CERT_VALIDATION"; value = "false" },
                @{ name = "FASTMCP_HTTP_HOST_ORIGIN_PROTECTION"; value = "true" },
                @{ name = "EXA_MCP_SETTINGS"; value = ($settings | ConvertTo-Json -Compress -Depth 4) },
                @{ name = "EXASOL_TELEMETRY_DISABLE"; value = "1" })
            ports = @(@{ name = "mcp"; containerPort = 4896; hostPort = $Port; hostIP = "127.0.0.1" })
            readinessProbe = @{ httpGet = @{ path = "/health"; port = "mcp" }; periodSeconds = 10; failureThreshold = 6 }
        }
        endpoints = @(@{ port = "mcp"; scheme = "http"; path = "/mcp" })
    }
    return ($definition | ConvertTo-Json -Depth 8)
}

# Write-McpSidecarDefinition <user> <password file> <port> - the definition put
# into <deployment>/sidecars.yaml by the kit's editor: "changed", "unchanged",
# or $null when it could not be written. Twin of _mcp_sidecar_put.
function Write-McpSidecarDefinition([string]$User, [string]$PasswordFile, [int]$Port, [string]$Uv, [string]$Root) {
    $defFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $defFile -Encoding UTF8 -Value (Get-McpSidecarDefinitionJson $User $PasswordFile $Port)
        $changed = ("" + (& $Uv run --no-project --quiet --with $script:SidecarPyYaml python `
            (Join-Path $Root "setup/lib/sidecar_definition.py") put `
            (Join-Path $script:PersonalDeployDir "sidecars.yaml") $script:McpSidecarName $defFile 2>$null)).Trim()
        if ($LASTEXITCODE -ne 0) { return $null }
        return $changed
    } finally { Remove-Item -LiteralPath $defFile -Force -ErrorAction SilentlyContinue }
}

# Wait-McpSidecarServing <budget> - poll `exasol mcp status` every 3s until it
# serves ("serving"), asks for a restart ("restart"), or the budget runs out
# ("timeout"). The last status is left in $script:McpSidecarLastStatus.
$script:McpSidecarLastStatus = $null
function Wait-McpSidecarServing([int]$Budget) {
    $waited = 0
    while ($true) {
        $status = Get-McpSidecarStatus
        $script:McpSidecarLastStatus = $status
        if ($status -and $status.restartRequired -eq $true) { return "restart" }
        if ($status -and $status.health -eq "serving") { return "serving" }
        if ($waited -ge $Budget) { return "timeout" }
        Start-Sleep -Seconds 3
        $waited += 3
    }
}

# Set-McpSidecar [-Quiet] - twin of mcp_sidecar_apply: make the launcher's MCP
# server the one behind every client entry, connected as the kit's read-only
# user, healing what stands in the way. $true when it serves (recorded);
# $false otherwise, with the error and its fix said - or, under -Quiet (a table
# owns the screen), logged and kept in $script:McpSidecarProblem for the caller
# to show. A failure never clears the record: the clients keep the URL.
function Set-McpSidecar {
    param([switch]$Quiet)
    $script:McpSidecarProblem = @()
    $script:McpSidecarTargetPort = $null
    $say = {
        param([string]$Kind, [string]$Msg)
        Write-ExakitLog $Kind "MCP: $Msg"
        if (-not $Quiet) { if ($Kind -eq "INFO") { Info $Msg } }
    }
    $fail = {
        param([string]$Msg, [string]$Fix)
        Write-ExakitLog "ERROR" "MCP: $Msg Fix: $Fix"
        $script:McpSidecarProblem = @($Msg, "Fix: $Fix")
        # Once the port is known, a failure still records where the server will
        # answer (the clients are pointed there, and work the moment it serves),
        # with validated=false. Twin of _mcp_sidecar_unhealed.
        if ($script:McpSidecarTargetPort) {
            Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
            Set-ExakitManifestValue "components.mcp_server.port" "$($script:McpSidecarTargetPort)"
            Set-ExakitManifestValue "components.mcp_server.url" "http://127.0.0.1:$($script:McpSidecarTargetPort)/mcp"
        }
        if ((Get-ExakitManifestValue "components.mcp_server.backend") -eq "sidecar") {
            Set-ExakitManifestValue "components.mcp_server.validated" $false
        }
        if (-not $Quiet) { Show-McpSidecarProblem }
    }
    # 1. The launcher has no sidecar: not healed here, a launcher update can
    #    carry a data migration.
    if (-not (Test-McpSidecarSupported)) {
        & $fail "The Exasol Personal launcher here has no MCP sidecar (it predates 2.4.0)." "exakit update personal"
        return $false
    }
    # 2. The read-only user it connects as.
    $user = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $pwFile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    if (-not $user -or -not $pwFile -or -not (Test-Path -LiteralPath $pwFile)) {
        & $say "INFO" "Self-heal: the read-only MCP user is not ready - setting it up"
        try { if ($Quiet) { Set-McpReadonlyAccess *> $null } else { Set-McpReadonlyAccess } } catch { Write-ExakitLog "WARN" "MCP: read-only setup: $_" }
        $user = Get-ExakitManifestValue "components.mcp_server.connection.user"
        $pwFile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
        if (-not $user -or -not $pwFile -or -not (Test-Path -LiteralPath $pwFile)) {
            if (-not (Get-ExakitExapumpBin)) {
                & $fail "MCP initialisation failed: the read-only database user your AI clients sign in with could not be created, because exapump is not installed (the kit creates that user with it)." "exakit update exapump, then: exakit mcp-setup"
                return $false
            }
            & $fail "The read-only MCP user could not be set up." "exakit mcp-setup"
            return $false
        }
    }
    # 3. uv, for the definition editor.
    $uv = Get-ExakitUvBin
    if (-not $uv) { try { $uv = Install-ExakitUv } catch { $uv = $null } }
    if (-not $uv) { & $fail "uv is not available to write the MCP server's definition." "exakit update uv"; return $false }
    $root = Get-ExakitRepoRoot
    if (-not $root) { & $fail "The kit's own files were not found." "exakit update"; return $false }
    # 4. The port: something else listening there while the server is not
    #    serving means it can never bind - move to the first free one.
    $port = Get-McpSidecarPort
    $status = Get-McpSidecarStatus
    $serving = ($status -and $status.health -eq "serving")
    if (-not $serving -and (Test-ExakitPortInUse -Port $port)) {
        $free = 0
        for ($candidate = $port + 1; $candidate -le $port + 20; $candidate++) {
            if (-not (Test-ExakitPortInUse -Port $candidate)) { $free = $candidate; break }
        }
        if ($free -eq 0) {
            & $fail "Port $port is in use by another program, and so are the next 20." "free port $port, or set EXAKIT_MCP_SIDECAR_PORT to a free one"
            return $false
        }
        & $say "INFO" "Self-heal: port $port is in use by another program - the MCP server moves to $free"
        $port = $free
        Set-ExakitManifestValue "components.mcp_server.port" "$port"
    }
    # 5. The definition, applied by `exasol start` when it changed or the
    #    server is not serving.
    $script:McpSidecarTargetPort = $port
    $changed = Write-McpSidecarDefinition $user $pwFile $port $uv $root
    if ($null -eq $changed) { & $fail "The MCP server's definition could not be written into the deployment." "exakit mcp-doctor"; return $false }
    if ($changed -eq "changed" -or -not $serving) {
        if ((Invoke-ExakitLogged (Get-PersonalCli) "start") -ne 0) {
            & $fail "exasol start did not apply the MCP server." "exakit mcp-doctor (details: exasol mcp status)"
            return $false
        }
    }
    # 6-7. Wait; heal a deployment that needs one restart, and a container
    #      that did not start, once each.
    $budget = if ($env:EXAKIT_MCP_SIDECAR_WAIT) { [int]$env:EXAKIT_MCP_SIDECAR_WAIT } else { 120 }
    $restarted = $false
    $recreated = $false
    while ($true) {
        $outcome = Wait-McpSidecarServing $budget
        if ($outcome -eq "serving") { break }
        if ($outcome -eq "restart") {
            if ($restarted) {
                & $fail "The deployment still asks for a restart before it serves the MCP server." "exakit stop && exakit start"
                return $false
            }
            $restarted = $true
            & $say "INFO" "Self-heal: this deployment serves the MCP server only after one restart - restarting the database (your data is kept)"
            try {
                if ($Quiet) { Stop-Personal *> $null; Start-Personal *> $null } else { Stop-Personal; Start-Personal }
            } catch {
                & $fail "The database could not be restarted: $_" "exakit stop && exakit start"
                return $false
            }
            continue
        }
        if ($recreated) { break }
        $recreated = $true
        & $say "INFO" "Self-heal: the MCP server did not start - recreating it"
        [void](Invoke-ExakitLogged (Get-PersonalCli) "sidecar" "disable" $script:McpSidecarName)
        if ($null -eq (Write-McpSidecarDefinition $user $pwFile $port $uv $root)) {
            & $fail "The MCP server's definition could not be written into the deployment." "exakit mcp-doctor"
            return $false
        }
        [void](Invoke-ExakitLogged (Get-PersonalCli) "start")
    }
    $status = $script:McpSidecarLastStatus
    if (-not ($status -and $status.health -eq "serving")) {
        $health = if ($status -and $status.health) { "" + $status.health } else { "unknown" }
        $detail = Get-McpSidecarStatusDetail $status
        $msg = "The MCP server beside your database did not start (status: $health)."
        if ($detail) { $msg += " $detail" }
        & $fail $msg "exakit mcp-doctor (details: exasol mcp status)"
        return $false
    }
    # 8. Serving: the record every client entry is rendered from.
    $url = "" + (@($status.endpoints) | Where-Object { $_.url } | Select-Object -First 1).url
    if ($url -notlike "http://127.0.0.1:*") { $url = "http://127.0.0.1:$port/mcp" }
    $bridge = Get-ExakitVersionsValue "components.mcp.bridge"
    if (-not $bridge) { $bridge = $script:McpBridgeFallback }
    Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
    Set-ExakitManifestValue "components.mcp_server.url" $url
    Set-ExakitManifestValue "components.mcp_server.port" "$port"
    Set-ExakitManifestValue "components.mcp_server.bridge" "$bridge"
    # The absolute uv/uvx Claude Desktop runs the bridge through, and the
    # bridge fetched now, so its first start is not a download. Twin of
    # mcp_sidecar_apply.
    Set-ExakitManifestValue "components.mcp_server.uv_path" $uv
    $uvx = Get-McpCommandPath
    Set-ExakitManifestValue "components.mcp_server.command" $uvx
    if ($env:EXAKIT_MCP_BRIDGE_PREFETCH -ne "0") {
        try { & $uvx "$bridge" --help *> $null } catch { Write-ExakitLog "INFO" "MCP: the Claude Desktop bridge was not fetched ahead" }
    }
    $tag = Get-McpSidecarImageVersion
    if ($tag -match '^[0-9]') { Set-ExakitManifestValue "components.mcp_server.version" $tag }
    Set-ExakitManifestValue "components.mcp_server.validated" $true
    Write-ExakitLog "OK" "MCP: the launcher's MCP server answers at $url as $user"
    return $true
}

# Show-McpSidecarProblem - the last apply's error and its fix, on screen, once.
function Show-McpSidecarProblem {
    $lines = @($script:McpSidecarProblem)
    if ($lines.Count -eq 0) { return }
    Write-ExakitError $lines[0]
    if ($lines.Count -gt 1) { Info $lines[1] }
    $script:McpSidecarProblem = @()
}

# Install-McpSidecarStep - the install's AI-bridge step: the launcher's MCP
# server as the read-only user. $true when it serves (the step's one line says
# where); $false when it does not, with the error and its fix said - the step
# fails soft and the install goes on. Twin of _exakit_install_mcp.
function Install-McpSidecarStep {
    $script:McpStepT0 = Get-Date
    $ready = $true
    try { Set-McpReadonlyAccess } catch { $ready = $false; Write-ExakitLog "WARN" "MCP: read-only setup: $_" }
    Start-ExakitSpinner "Starting the MCP server and checking it answers"
    $served = $false
    try { $served = Set-McpSidecar -Quiet } catch { Write-ExakitLog "WARN" "MCP sidecar: $_" }
    Stop-ExakitSpinner
    if (-not $served) {
        # The reason the soft step records, then the error and its fix on screen.
        $why = @($script:McpSidecarProblem)
        if ($why.Count -gt 0) { Set-ExakitFailureReason $why[0] } else { Set-ExakitFailureReason "the MCP server beside the database did not start" }
        Show-McpSidecarProblem
        return $false
    }
    if ($ready) { $script:McpReadonlyReady = $true }
    Set-ExakitComponentOwnership "mcp" "kit"
    $secs = [int]((Get-Date) - $script:McpStepT0).TotalSeconds
    OkStep "MCP server answering at $(Get-ExakitManifestValue 'components.mcp_server.url') as the read-only user (${secs}s)"
    return $true
}

# Remove-McpSidecar [-DryRun] - uninstall: the MCP sidecar the kit set up, on a
# deployment that stays, and its record. Twin of mcp_sidecar_remove.
function Remove-McpSidecar {
    param([switch]$DryRun)
    if ((Get-ExakitManifestValue "components.mcp_server.backend") -ne "sidecar") { return }
    if (-not (Test-Path -LiteralPath $script:PersonalDeployDir) -or -not (Get-Command Get-PersonalCli -ErrorAction SilentlyContinue)) { return }
    if ($DryRun) { Info "  will remove: the MCP server the kit set up beside your database (sidecar '$($script:McpSidecarName)')"; return }
    if ((Invoke-ExakitLogged (Get-PersonalCli) "sidecar" "disable" $script:McpSidecarName "--remove") -ne 0) {
        Warn2 "Removing the MCP sidecar reported issues (continuing uninstall): exasol sidecar disable $($script:McpSidecarName) --remove"
    }
    foreach ($key in @("backend", "url", "port", "bridge", "validated")) { Remove-ExakitManifestValue "components.mcp_server.$key" }
}
