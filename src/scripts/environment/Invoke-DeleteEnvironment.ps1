[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$environmentName,
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$awsKey,
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$awsSecret,
    [string]$awsRegion="ap-southeast-2",
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$octopusApiKey,
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$octopusServerUrl
)

$ErrorActionPreference = "Stop"
$Error.Clear()

$currentDirectoryPath = Split-Path $script:MyInvocation.MyCommand.Path

. "$currentDirectoryPath\_Find-RootDirectory.ps1"

$rootDirectory = Find-RootDirectory $currentDirectoryPath
$rootDirectoryPath = $rootDirectory.FullName

. "$rootDirectoryPath\scripts\common\Functions-Environment.ps1"

. "$rootDirectoryPath\scripts\common\Functions-Aws.ps1"
Ensure-AwsPowershellFunctionsAvailable

. "$rootDirectoryPath\scripts\environment\Solavirum.Examples.Database.Environment.Customizations.ps1"

$arguments = @{}
$arguments.Add("-EnvironmentName", $environmentName)
$arguments.Add("-Wait", $true)
$arguments.Add("-AwsKey", $awsKey)
$arguments.Add("-AwsSecret", $awsSecret)
$arguments.Add("-AwsRegion", $awsRegion)
$arguments.Add("-OctopusApiKey", $octopusApiKey)
$arguments.Add("-OctopusServerUrl", $octopusServerUrl)
$arguments.Add("-UniqueComponentIdentifier", (& _GetUniqueComponentIdentifier))

Delete-Environment @arguments