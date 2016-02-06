$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

$rootDirectoryPath = "@@ROOT_DIRECTORY_PATH"
$logsDirectoryPath = "@@LOGS_DIRECTORY_PATH"

. "$rootDirectoryPath\scripts\common\Functions-WriteOverrides.ps1"

Write-Output "Executing Powershell Scheduled Task"

try
{
@@SCRIPT
}
catch
{
    Write-Warning "Unexpected error occurred. The Powershell Scheduled Task has failed."
    Write-Warning $_
    if ($_.Exception -ne $null)
    {
        Write-Warning $_.Exception.ToString()
    }
    exit 1
}