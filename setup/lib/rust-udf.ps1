# Rust UDF command twin of rust-udf.sh; Python owns the build/deploy rules.
function Invoke-CmdRustUdf {
    param([string[]]$CmdArgs = @())
    if ($CmdArgs.Count -lt 2 -or $CmdArgs[0] -notin @("new", "build", "deploy")) {
        Deny-ExakitInput "Use: exakit rust-udf new|build|deploy <name> [--json]"
    }
    if (-not (Get-UdfDevkitInstalledVersion)) {
        Exit-UdfModel -Code 4 -Message "The UDF dev kit is not installed." -Remedy "exakit marketplace udf-devkit"
    }
    $bucket = ""; $root = ""
    if ($CmdArgs[0] -eq "deploy") {
        $found = Get-UdfBucketLocation
        if ($found.Error) { Exit-UdfModel -Code 3 -Message $found.Error -Remedy "exakit status" }
        $bucket = $found.Dir; $root = $found.UdfRoot
    }
    $oldBucket = [Environment]::GetEnvironmentVariable("EXAKIT_RUST_BUCKET_DIR", "Process")
    $oldRoot = [Environment]::GetEnvironmentVariable("EXAKIT_RUST_UDF_ROOT", "Process")
    try {
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_BUCKET_DIR", $bucket, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_UDF_ROOT", $root, "Process")
        $result = Invoke-UdfTool -Script "rust_udf_tool.py" -ToolArgs $CmdArgs
    } finally {
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_BUCKET_DIR", $oldBucket, "Process")
        [Environment]::SetEnvironmentVariable("EXAKIT_RUST_UDF_ROOT", $oldRoot, "Process")
    }
    foreach ($line in @($result[1])) { Write-Output $line }
    if ($result[0] -ne 0) {
        # Write-Error becomes a terminating exception under the launcher's
        # ErrorActionPreference=Stop, hiding the Python tool's precise exit code.
        if ($result[2]) { [Console]::Error.WriteLine($result[2]) }
        exit ([int]$result[0])
    }
}
