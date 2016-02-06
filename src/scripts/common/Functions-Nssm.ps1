function Get-NssmExecutable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-FileSystem.ps1"

    $executablePath = "$rootDirectoryPath\tools\dist\nssm-x64-2.24.exe"

    return Test-FileExists $executablePath
}

function Nssm-Stop
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$service
    )

    $serviceController = Get-Service -Name $service
    if ($serviceController.Status -eq "Running")
    {
        Write-Verbose "Stopping service [$service] via normal service management."
        $serviceController.Stop()
        $desiredState = "Stopped"
        $stoppedTimeout = [Timespan]::FromSeconds(30)
        try
        {
            $serviceController.WaitForStatus($desiredState, $stoppedTimeout)
        }
        catch
        {
            throw new-object System.Exception("The NSSM service [$service] did not reach the [$desiredState] state within [$stoppedTimeout].", $_.Exception)
        }
    }
    else
    {
        Write-Verbose "Service is not running. No need to issue stop command."
    }
}

function Nssm-Remove
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$service
    )

    Nssm-Stop $service

    Write-Verbose "Removing service [$serviceName] via NSSM."
    $executable = Get-NssmExecutable

    $command = "remove"
    $arguments = @()
    $arguments += $command
    $arguments += """$service"""
    $arguments += "confirm"

    write-verbose "Executing command [$command] Service [$service] via Nssm."
    try
    {
        (& "$($executable.FullName)" $arguments) | _WriteVerboseNssmOutput
        $return = $LASTEXITCODE
        if ($return -ne 0)
        {
            throw "Nssm '$command' failed. Exit code [$return]."
        }
    }
    catch 
    {
        throw _SanitizeMessageFromNssm($_.Exception.Message)
    }

    Write-Verbose "Waiting for service [$service] to not be found (to give NSSM time to delete the service and clean itself up)."
        
    . "$rootDirectoryPath\scripts\common\Functions-Waiting.ps1"

    $result = Wait -ScriptToFillActualValue { Get-Process -Name $service -ErrorAction SilentlyContinue } -Condition { $actual -eq $null }
}

function Nssm-Install
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$service,
        [System.IO.FileInfo]$program,
        [int]$maxLogFileSizeBytesBeforeRotation=10000000,
        [System.IO.DirectoryInfo]$DI_LogFilesDirectory="C:\logs",
        [string]$DI_NssmCommand="install"
    )

    try
    {
        if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
        $rootDirectoryPath = $rootDirectory.FullName

        Write-Verbose "Installing service [$serviceName] for executable [$($program.FullName)] via NSSM."
        $executable = Get-NssmExecutable

        $command = $DI_NssmCommand
        $arguments = @()
        $arguments += $command
        $arguments += """$service"""
        $arguments += """$($program.FullName)"""

        write-verbose "Executing command [$command] Service [$service] via Nssm."
        (& "$($executable.FullName)" $arguments) | _WriteVerboseNssmOutput
        $return = $LASTEXITCODE
        if ($return -ne 0)
        {
            throw "Nssm '$command' failed. Exit code [$return]."
        }

        . "$rootDirectoryPath\scripts\common\Functions-FileSystem.ps1"

        $logDirectoryPath = "$($DI_LogFilesDirectory.FullName)\nssm\$service\"
        Ensure-DirectoryExists $logDirectoryPath

        $logFile = "$logDirectoryPath\output.log"

        (& $executable set "$service" AppStdout "$logFile") | _WriteVerboseNssmOutput
        (& $executable set "$service" AppStderr "$logFile") | _WriteVerboseNssmOutput
        (& $executable set "$service" AppStdoutCreationDisposition  4) | _WriteVerboseNssmOutput
        (& $executable set "$service" AppStderrCreationDisposition  4) | _WriteVerboseNssmOutput
        (& $executable set "$service" AppRotateFiles  1) | _WriteVerboseNssmOutput
        (& $executable set "$service" AppRotateOnline  1) | _WriteVerboseNssmOutput
        (& $executable set "$service" AppRotateBytes  $maxLogFileSizeBytesBeforeRotation) | _WriteVerboseNssmOutput

        $result = @{
            "ServiceName"="$service";
            "LogFilePath"="$logFile";
            "ProgramPath"="$($program.FullName)";
        }

        return new-object PSObject $result
    }
    catch
    {
        throw _SanitizeMessageFromNssm($_.Exception.Message)
    }
}

function Nssm-Start
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$service
    )

    $serviceController = Get-Service -Name $service
    if ($serviceController.Status -eq "Stopped")
    {
        Write-Verbose "Starting service [$service] via normal service management."
        $serviceController.Start()
        $desiredState = "Running"
        $stoppedTimeout = [Timespan]::FromSeconds(30)
        try
        {
            $serviceController.WaitForStatus($desiredState, $stoppedTimeout)
        }
        catch
        {
            throw new-object System.Exception("The NSSM service [$service] did not reach the [$desiredState] state within [$stoppedTimeout].", $_.Exception)
        }
    }
    else
    {
        Write-Verbose "Service is not stopped. No need to issue start command."
    }
}

function _GetInvalidXmlCharacters
{
    $invalid = @()
    $invalid += [char]0x0
    $invalid += [char]0x1
    $invalid += [char]0x2
    $invalid += [char]0x3
    $invalid += [char]0x4
    $invalid += [char]0x5
    $invalid += [char]0x6
    $invalid += [char]0x7
    $invalid += [char]0x8
    $invalid += [char]0x9

    return $invalid
}

function _SanitizeMessageFromNssm
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$message
    )

    foreach ($char in _GetInvalidXmlCharacters)
    {
        $message = $message.Replace([string]$char, "")
    }

    return $message
}

function _WriteVerboseNssmOutput
{
    $sanitized = _SanitizeMessageFromNssm($input)
    if (![string]::IsNullOrEmpty($sanitized))
    {
        Write-Verbose $sanitized
    }
}