function Wait-CloudFormationStack
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$stackName,
        [Amazon.CloudFormation.StackStatus]$desiredStatus,
        [Amazon.CloudFormation.StackStatus[]]$failingStates=@(),
        [int]$timeoutSeconds=3000
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Aws.ps1"

    Ensure-AwsPowershellFunctionsAvailable

    write-verbose "Waiting up to [$timeoutSeconds] seconds for the CloudFormation Stack with Id [$($stackName)] to reach [$desiredStatus]."
    $incrementSeconds = 30
    $totalWaitTime = 0
    while ($true)
    {
        $a = Get-CFNStack -StackName $stackName -Region $awsRegion -AccessKey $awsKey -SecretKey $awsSecret
        $status = $a.StackStatus

        if ($status -eq $desiredStatus)
        {
            write-verbose "The CloudFormation Stack with Id [$stackName] has entered [$desiredStatus] taking [$totalWaitTime] seconds."
            return $a
        }

        . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"
        if ($failingStates | Select | Any -Predicate { $_ -eq $status })
        {
            throw "The CloudFormation Stack with Id [$stackName] entered a failing state [$status] taking [$totalWaitTime] seconds."
        }

        write-verbose "Current status of CloudFormation Stack with Id [$stackName] is [$status]. Waited [$totalWaitTime] seconds so far. Waiting [$incrementSeconds] seconds and checking again for [$desiredStatus]."

        Sleep -Seconds $incrementSeconds
        $totalWaitTime = $totalWaitTime + $incrementSeconds
        if ($totalWaitTime -gt $timeoutSeconds)
        {
            throw "The CloudFormation Stack with Id [$stackName] did not enter [$desiredStatus] status within [$timeoutSeconds] seconds."
        }
    }
}

function Convert-HashTableToAWSCloudFormationParametersArray
{
    param
    (
        [CmdletBinding()]
        [hashtable]$paramsHashtable
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Aws.ps1"

    Ensure-AwsPowershellFunctionsAvailable

    $parameters = @()
    foreach ($p in $paramsHashtable.Keys)
    {
        $param = new-object Amazon.CloudFormation.Model.Parameter
        $param.ParameterKey = $p
        $param.ParameterValue = $paramsHashtable.Item($p)
            
        $parameters += $param
    }

    return $parameters
}