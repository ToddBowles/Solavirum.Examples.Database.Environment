function InitialiseCommonLogsDirectory
{
    [CmdletBinding()]
    param
    (
        [string]$directoryPath="C:\logs"
    )
    
    if (-not (Test-Path $directoryPath))
    {
        Write-Verbose "Creating common logs directory at [$directoryPath]"
        New-Item $directoryPath -Type Directory 
    }

    Write-Verbose "Making common logs directory [$directoryPath] writeable by everyone."
    $Acl = Get-Acl $directoryPath

    $Ar = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")

    $Acl.SetAccessRule($Ar)
    Set-Acl $directoryPath $Acl
}

function CreateLogsClearingTask
{
    [CmdletBinding()]
    param
    (
        [string]$taskName="Clear Old Logs",
        [string]$logsDirectory="C:\logs",
        [int]$daysOld=7
    )

    if ([string]::IsNullOrEmpty($logsDirectory))
    {
        throw "Logs directory must not be null or empty."
    }
    
    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $rootDirectoryDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-ScheduledTasks.ps1"

    Write-Verbose "Removing existing scheduled task named [$taskName] if it exists."
    $delete = Delete-DailyPowershellScheduledTask -TaskName $taskName

    $deleteScript = " 
        `$toDelete = (Get-ChildItem $logsDirectory -File -Recurse |  Where LastWriteTime -lt (Get-Date).AddDays(-$daysOld))
        Write-Output `"[`$(`$toDelete.Length)] files will be deleted by this cleanup.`"
        `$toDelete | ForEach {
            Write-Output `"Deleting file [`$(`$_.FullName)]`"; 
            Remove-Item -Path `$_.FullName -Force;
        }
    "
    $deleteScript = [scriptblock]::Create($deleteScript)
    $taskDescription = "Clears log files from [$logsDirectory] (recursively) that were last written to more than [$daysOld] days ago"
 
    New-DailyPowershellScheduledTask -Script $deleteScript -taskName $taskName -taskDescription $taskDescription -TimeOfDay "0:00"
}