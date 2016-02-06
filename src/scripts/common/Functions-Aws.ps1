function Ensure-AwsPowershellFunctionsAvailable()
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Compression.ps1"

    $toolsDirectoryPath = "$rootDirectoryPath\tools"
    $nugetPackagesDirectoryPath = "$toolsDirectoryPath\packages"

    $packageId = "AWSPowershell"
    $packageVersion = "2.3.43.0"

    $expectedDirectory = "$nugetPackagesDirectoryPath\$packageId.$packageVersion"
    if (-not (Test-Path $expectedDirectory))
    {
        $extractedDir = 7Zip-Unzip "$toolsDirectoryPath\dist\$packageId.$packageVersion.7z" "$toolsDirectoryPath\packages"
    }

    if ((Get-Module | Where-Object { $_.Name -eq "AWSPowershell" }) -eq $null)
    {
        Write-Verbose "Loading [$packageId.$packageVersion] Module"
        $previousVerbosePreference = $VerbosePreference
        $VerbosePreference = "SilentlyContinue"
        $imported = Import-Module "$toolsDirectoryPath\packages\$packageId.$packageVersion\AWSPowerShell.psd1"
        $VerbosePreference = $previousVerbosePreference
    }
}

function Get-AwsCliExecutablePath
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Compression.ps1"

    $toolsDirectoryPath = "$rootDirectoryPath\tools"
    $nugetPackagesDirectoryPath = "$toolsDirectoryPath\packages"

    $packageId = "AWSCLI64"
    $packageVersion = "1.7.41"

    $expectedDirectory = "$nugetPackagesDirectoryPath\$packageId.$packageVersion"
    if (-not (Test-Path $expectedDirectory))
    {
        $extractedDir = 7Zip-Unzip "$toolsDirectoryPath\dist\$packageId.$packageVersion.7z" "$toolsDirectoryPath\packages"
    }

    $executable = "$expectedDirectory\aws.exe"

    return $executable
}

function _WaitAutoScalingGroupActivitiesComplete
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        $activities,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
        [int]$timeoutSeconds=120
    )

    write-verbose "Waiting for the specified AutoScalingGroup activities to complete."
    $incrementSeconds = 5
    $totalWaitTime = 0
    $activityIds = $activities | Select -ExpandProperty ActivityId
    while ($true)
    {
        $a = Get-ASScalingActivity -ActivityId $activityIds -Region $awsRegion -AccessKey $awsKey -SecretKey $awsSecret

        . "$rootDirectoryPath\scripts\common\Functions-Enumerables.ps1"

        Write-Verbose "Checking to see if any activities are not in the Successful state."
        if (-not($a | Any -Predicate { $_.StatusCode -ne [Amazon.AutoScaling.ScalingActivityStatusCode]::Successful }))
        {
            write-verbose "The specified AutoScalingGroup activites have all completed successfully, taking [$totalWaitTime] seconds."
            return
        }

        write-verbose "Waiting [$incrementSeconds] seconds and checking again for change."

        Sleep -Seconds $incrementSeconds
        $totalWaitTime = $totalWaitTime + $incrementSeconds
        if ($totalWaitTime -gt $timeoutSeconds)
        {
            throw "The specified AutoScalingGroup activites did not complete successfully within [$timeoutSeconds] seconds."
        }
    }
}

function TransitionAutoScalingGroupInstancesToLifecycleState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$autoScalingGroupId,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Amazon.AutoScaling.LifecycleState]$desiredState,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
        [switch]$wait
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $rootDirectoryDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Enumerables.ps1"

    . "$rootDirectoryPath\scripts\common\Functions-Aws.ps1"
    Ensure-AwsPowershellFunctionsAvailable

    $asg = Get-ASAutoScalingGroup -AutoScalingGroupName $autoScalingGroupId -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion

    $instanceIds = @()
    $standbyActivities = @()
    Write-Verbose "TransitionAutoScalingGroupInstancesToLifecycleState: Switching all instances in [$($asg.AutoScalingGroupName)] to [$desiredState]"
    $instanceIds = $asg.Instances | Where { $_.LifecycleState -ne $desiredState } | Select -ExpandProperty InstanceId
    if ($instanceIds | Any)
    {
        switch($desiredState)
        {
            ([Amazon.AutoScaling.LifecycleState]::InService) { $standbyActivities = Exit-ASStandby -AutoScalingGroupName $asg.AutoScalingGroupName -InstanceId $instanceIds -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion; break; }
            ([Amazon.AutoScaling.LifecycleState]::Standby) { $standbyActivities = Enter-ASStandby -AutoScalingGroupName $asg.AutoScalingGroupName -InstanceId $instanceIds -ShouldDecrementDesiredCapacity $true -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion; break; }
            default { throw "Unsupported desired state of [$desiredState]" }
        }
    }

    $anyStandbyActivities = $standbyActivities | Any
    if ($wait -and $anyStandbyActivities)
    {
        Write-Verbose "TransitionAutoScalingGroupInstancesToLifecycleState: Waiting for all scaling activities [? -> $desiredState] to complete"
        _WaitAutoScalingGroupActivitiesComplete -Activities $standbyActivities -awsKey $awsKey -awsSecret $awsSecret -awsRegion $awsRegion
    }
}