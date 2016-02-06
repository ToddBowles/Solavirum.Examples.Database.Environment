function New-DailyPowershellScheduledTask
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$taskName,
        [string]$taskDescription,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [scriptblock]$script,
        [TimeSpan]$TimeOfDay="0:00",
        [switch]$ExecuteImmediately=$true
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    write-verbose "Creating new Powershell Scheduled Task to automatically execute [$script] every day at [$TimeOfDay]."

    $service = new-object -ComObject("Schedule.Service")
    $service.Connect()
    $rootFolder = $service.GetFolder("\")

    try
    {
        $command = "powershell.exe"
        $converted = _ConfigurePowershellScriptForScheduledTaskExecution -script $script -taskName $taskName
        $arguments = $converted.Arguments

        $TaskStartTime = [DateTime]::Now.Date.Add($TimeOfDay)
 
        $TaskDefinition = $service.NewTask(0) 
        $TaskDefinition.RegistrationInfo.Description = "$taskDescription"
        $TaskDefinition.Settings.Enabled = $true
        $TaskDefinition.Settings.AllowDemandStart = $true
 
        $triggers = $TaskDefinition.Triggers
        #http://msdn.microsoft.com/en-us/library/windows/desktop/aa383915(v=vs.85).aspx
        $trigger = $triggers.Create(2)
        $trigger.StartBoundary = $TaskStartTime.ToString("yyyy-MM-dd'T'HH:mm:ss")
        $trigger.Enabled = $true
        $trigger.DaysInterval = 1
 
        # http://msdn.microsoft.com/en-us/library/windows/desktop/aa381841(v=vs.85).aspx
        $Action = $TaskDefinition.Actions.Create(0)
        $action.Path = "$command"
        $action.Arguments = "$arguments"
 
        #http://msdn.microsoft.com/en-us/library/windows/desktop/aa381365(v=vs.85).aspx
        $registerResult = $rootFolder.RegisterTaskDefinition("$TaskName",$TaskDefinition,6,"System",$null,5)

        $task = $rootFolder.GetTask($taskName)

        if ($ExecuteImmediately)
        {
            Write-Verbose "An immediate execution of the just created Powershell Scheduled Task [$taskName] was requested. Executing now."
            $runResult = $task.Run($null)
        }
    }
    finally
    {
        $releaseResult = [System.Runtime.Interopservices.Marshal]::ReleaseComObject($service)
    }

    $result = @{
        TaskName=$taskName;
        TaskLogsDirectoryPath=$converted.LogsDirectoryPath;
    }

    return new-object PSObject $result
}

function _SanitizeTaskNameForFile
{
    param
    (
        [string]$taskName
    )

    return "$($taskName.Replace('[', '').Replace(']', '').Replace(' ', '_'))"
}

$defaultPowershellScheduledTaskFilesDirectoryPath = "C:\scheduled-tasks"

function _ConfigurePowershellScriptForScheduledTaskExecution
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$script,
        [string]$taskName,
        [string]$DI_rootLogsDirectoryPath="C:\logs\scheduled-tasks"
    )

    $taskLogsDirectoryName = _SanitizeTaskNameForFile $taskName
    $logsDirectoryPath = "$DI_rootLogsDirectoryPath\$taskLogsDirectoryName"
    $logDirectory = New-Item -ItemType Directory -Path $logsDirectoryPath -Force

    $powershellFilePath = "$defaultPowershellScheduledTaskFilesDirectoryPath\$taskLogsDirectoryName.ps1"
    if (Test-Path $powershellFilePath)
    {
        Write-Warning "The script file for Powershell Scheduled Task [$taskName] already exists at [$powershellFilePath]. It will be overwritten. If you have two tasks with the same name, this will end poorly."
    }

    $powershellFile = New-Item -Path $powershellFilePath -ItemType File -Force

    $substitutions = @{
        "@@ROOT_DIRECTORY_PATH"="$rootDirectoryPath";
        "@@LOGS_DIRECTORY_PATH"="$logsDirectoryPath";
        "@@SCRIPT"="$script";
    }

    $powershellFile = _ReplaceTokensInFile -Source "$rootDirectoryPath\scripts\common\Template-PowershellScheduledTask.ps1" -Destination $powershellFilePath -substitutions $substitutions

    $result = @{
        File=$powershellFile;
        Arguments="-ExecutionPolicy Bypass -NonInteractive -File `"$powershellFile`"";
        LogsDirectoryPath=$logsDirectoryPath;
    }

    return new-object PSObject $result
}

function _ReplaceTokensInFile
{
    [CmdletBinding()]
    param
    (
        [System.IO.FileInfo]$source,
        [System.IO.FileInfo]$destination,
        [hashtable]$substitutions
    )
        
    $content = Get-Content $source
    foreach ($token in $substitutions.Keys)
    {
        $content = $content.Replace($token, $substitutions.Get_Item($token))
    }  
    Set-Content $destination $content

    return $destination
}

function Delete-DailyPowershellScheduledTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$taskName
    )

    try
    {
        Write-Verbose "Checking to see if there is a script file for Powershell Scheduled Task [$taskName]."
        $scriptFilePath = "$defaultPowershellScheduledTaskFilesDirectoryPath\$(_SanitizeTaskNameForFile $taskName).ps1"
        if (Test-Path $scriptFilePath)
        {
            Write-Verbose "Removing script file for Powershell Scheduled Task [$taskName] from [$scriptFilePath]"
            Remove-Item -Path $scriptFilePath -Force
        }

        Write-Verbose "Removing Powershell Scheduled Task [$taskName]"
        $service = new-object -ComObject("Schedule.Service")
        $service.Connect()
        $rootFolder = $service.GetFolder("\")
        try
        {
            $rootFolder.DeleteTask($taskName, 0)
        }
        catch
        {
            if (-not ($_.Exception.Message -like "*The system cannot find the file specified*"))
            {
                throw $_.Exception
            }
        }
    }
    finally
    {
        $releaseResult = [System.Runtime.Interopservices.Marshal]::ReleaseComObject($service)
    }
}

function Get-DailyPowershellScheduledTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$taskName
    )

    try
    {
        $service = new-object -ComObject("Schedule.Service")
        $connectResult = $service.Connect()
        $rootFolder = $service.GetFolder("\")
        $task = $rootFolder.GetTask($taskName)
        return $task
    }
    finally
    {
        $releaseResult = [System.Runtime.Interopservices.Marshal]::ReleaseComObject($service)
    }
}

$TASK_RUNNING = 267009
$TASK_QUEUED = 267045

function Wait-DailyPowershellScheduledTaskFinished
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName,
        [TimeSpan]$MaxWaitTime="0.00:30"
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $commonScriptsDirectoryPath = "$($rootDirectory.FullName)\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Waiting.ps1"

    $actualValue = Wait -ScriptToFillActualValue { (Get-DailyPowershellScheduledTask -TaskName $TaskName).LastTaskResult } -Condition { $actual -ne $TASK_RUNNING -and $actual -ne $TASK_QUEUED }

    return Get-DailyPowershellScheduledTask -taskName $TaskName
}

function Execute-DailyPowershellScheduledTaskFinished
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName,
        [switch]$Wait,
        [TimeSpan]$MaxWaitTime="0.00:30"
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $commonScriptsDirectoryPath = "$($rootDirectory.FullName)\scripts\common"

    $task = Get-DailyPowershellScheduledTask -taskName $TaskName
    $result = $task.Run($null)
    if ($Wait)
    {
        $task = Wait-DailyPowershellScheduledTaskFinished -TaskName $TaskName -MaxWaitTime $MaxWaitTime
    }

    return $task
}