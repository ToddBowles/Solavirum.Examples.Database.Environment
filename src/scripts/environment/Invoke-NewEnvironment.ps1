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
    [string]$octopusServerUrl,
    [switch]$resultAsJson=$true,
    [switch]$disableCleanupOnFailure,
    [string]$databaseSnapshotIdentifier,
    [string]$sourceEnvironmentName,
    [hashtable]$EnvironmentParameterOverrides=@{}
)

$ErrorActionPreference = "Stop"
$Error.Clear()

$currentDirectoryPath = Split-Path $script:MyInvocation.MyCommand.Path

. "$currentDirectoryPath\_Find-RootDirectory.ps1"

$rootDirectory = Find-RootDirectory $currentDirectoryPath
$rootDirectoryPath = $rootDirectory.FullName

. "$rootDirectoryPath\scripts\common\Functions-Environment.ps1"

. "$rootDirectoryPath\scripts\environment\Solavirum.Examples.Database.Environment.Customizations.ps1"

. "$rootDirectoryPath\scripts\common\Functions-Aws.ps1"
Ensure-AwsPowershellFunctionsAvailable

. "$rootDirectoryPath\scripts\common\Functions-Hashtables.ps1"
$additionalTemplateParameters = Merge-Hashtables -First $additionalTemplateParameters -Second $EnvironmentParameterOverrides

. "$rootDirectoryPath\scripts\common\Functions-Versioning.ps1"
. "$rootDirectoryPath\scripts\common\Functions-Enumerables.ps1"

$assemblyInfo = Get-ChildItem -Recurse -Path $rootDirectoryPath -Filter SharedAssemblyInfo.cs | Single -Description "Finding the SharedAssemblyInfo.cs file within the source root, used for determining environment version"
$additionalTemplateParameters.Add("EnvironmentVersion", (Get-AssemblyVersion -AssemblyInfoFile $assemblyInfo))

$arguments = @{}
$arguments.Add("-EnvironmentName", $environmentName)
$arguments.Add("-Wait", $true)
$arguments.Add("-disableCleanupOnFailure", $disableCleanupOnFailure)
$arguments.Add("-AwsKey", $awsKey)
$arguments.Add("-AwsSecret", $awsSecret)
$arguments.Add("-AwsRegion", $awsRegion)
$arguments.Add("-OctopusApiKey", $octopusApiKey)
$arguments.Add("-OctopusServerUrl", $octopusServerUrl)
$arguments.Add("-UniqueComponentIdentifier", (& _GetUniqueComponentIdentifier))
$arguments.Add("-TemplateFile", (& _GetTemplateFile))
$arguments.Add("-CustomiseEnvironmentDetailsHashtable", { param([hashtable]$environmentDetailsHashtableToMutate,$stack) _CustomiseEnvironmentDetailsHashtable $environmentDetailsHashtableToMutate $stack })
$arguments.Add("-AdditionalTemplateParameters", $additionalTemplateParameters)
$arguments.Add("-SmokeTest", { param($environmentCreationResult) Test-ExampleDatabase @(@{"Endpoint"=$environmentCreationResult.MasterDatabaseEndpointWithPort;"Username"="master";"Password"=$additionalTemplateParameters["RdsDatabaseMasterUsernamePassword"]}) })

$result = New-Environment @arguments
if ($resultAsJson)
{
    return (ConvertTo-Json $result)
}
else
{
    return $result
}