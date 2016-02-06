[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.IO.DirectoryInfo]$directory,
    [scriptblock]$Filter={ $true },
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$ipAddress,
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$username,
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$password,
    [string]$remoteDirectory="C:\temp",
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$awsKey,
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$awsSecret,
    [string]$awsRegion="ap-southeast-2",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$currentDirectoryPath = Split-Path $script:MyInvocation.MyCommand.Path

. "$currentDirectoryPath\_Find-RootDirectory.ps1"

$rootDirectory = Find-RootDirectory $currentDirectoryPath
$rootDirectoryPath = $rootDirectory.FullName

try
{
    $bucketName = [Guid]::NewGuid().ToString("N")

    . "$rootDirectoryPath\scripts\common\Functions-Remoting.ps1"
    . "$rootDirectoryPath\scripts\common\Functions-Aws.ps1"
    . "$rootDirectoryPath\scripts\common\Functions-Aws-S3.ps1"

    Ensure-AwsPowershellFunctionsAvailable

    $bucketName = Ensure-S3BucketExists -BucketName $bucketName -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion

    $session = Create-PSSession -ComputerName $ipAddress -Username $username -Password $password
    Transfer-DirectoryToRemoteMachineViaS3Bucket -Directory $directory -Filter $filter -Session $session -S3Bucket $bucketName -RemoteDirectory $remoteDirectory -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion -WhatIf:$WhatIf
}
finally
{
    if (![string]::IsNullOrEmpty($bucketName))
    {
        try
        {
            Write-Verbose "Deleting temporary bucket [$bucketName]"
            Remove-S3Bucket -BucketName $bucketName -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion -Force -DeleteBucketContent
        }
        catch
        {
            Write-Warning "An error occurred while trying to delete the temporary S3 bucket used for file transfer."
            Write-Warning $_
        }
    }

    if ($session -ne $null)
    {
        Remove-PSSession $session
    }
}
