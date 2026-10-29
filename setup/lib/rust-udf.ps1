# Rust UDF command twin of rust-udf.sh; Python owns the build/deploy rules.
function Invoke-CmdRustUdf {
    param([string[]]$CmdArgs = @())
    if ($CmdArgs.Count -lt 2 -or $CmdArgs[0] -notin @("new", "build", "deploy")) {
        Deny-ExakitInput "Use: exakit rust-udf new|build|deploy <name> [--json]"
    }
    if (-not (Get-UdfDevkitInstalledVersion)) {
        Exit-UdfModel -Code 4 -Message "The UDF dev kit is not installed." -Remedy "exakit marketplace udf-devkit"
    }
    $bucket = ""; $root = ""; $launcher = ""; $deployment = ""
    if ($CmdArgs[0] -eq "deploy") {
        $found = Get-UdfBucketLocation
        if (-not $found.Error) { $bucket = $found.Dir; $root = $found.UdfRoot }
        $launcher = Get-PersonalCli
        $deployment = $script:PersonalDeployDir
    }
    $oldBucket = [Environment]::GetEnvironmentVariable("EXAKIT_RUST_BUCKET_DIR", "Process")
    $oldRoot = [Environment]::GetEnvironmentVariable("EXAKIT_RUST_UDF_ROOT", "Process")
    $oldLauncher = [Environment]::GetEnvironmentVariable("EXAKIT_RUST_LAUNCHER", "Process")
    $oldDeployment = [Environment]::GetEnvironmentVariable("EXAKIT_RUST_DEPLOYMENT", "Process")
    try {
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_BUCKET_DIR", $bucket, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_UDF_ROOT", $root, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_LAUNCHER", $launcher, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_DEPLOYMENT", $deployment, "Process")
        $result = Invoke-UdfTool -Script "rust_udf_tool.py" -ToolArgs $CmdArgs
    } finally {
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_BUCKET_DIR", $oldBucket, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_UDF_ROOT", $oldRoot, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_LAUNCHER", $oldLauncher, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_DEPLOYMENT", $oldDeployment, "Process")
    }
    foreach ($line in @($result[1])) { Write-Output $line }
    if ($result[0] -ne 0) {
        # Write-Error becomes a terminating exception under the launcher's
        # ErrorActionPreference=Stop, hiding the Python tool's precise exit code.
        if ($result[2]) { [Console]::Error.WriteLine($result[2]) }
        exit ([int]$result[0])
    }
}
