[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true)]
    [string]$octopusEnvironment,
    [Parameter(Mandatory=$true)]
    [string]$octopusServerUrl,
    [Parameter(Mandatory=$true)]
    [string]$octopusApiKey,
    [Parameter(Mandatory=$true)]
    [string]$projectName,
    [hashtable]$variables,
    [string]$sourceOctopusEnvironment,
    [ValidateSet("creating", "running")]
    [string]$environmentStatus="creating"
)

$ErrorActionPreference = "Stop"

$here = Split-Path $script:MyInvocation.MyCommand.Path
. "$here\_Find-RootDirectory.ps1"

$rootDirectory = Find-RootDirectory $here
$rootDirectoryPath = $rootDirectory.FullName

. "$rootDirectoryPath\scripts\common\Functions-OctopusDeploy.ps1"

$arguments = @{}

if (-not([string]::IsNullOrEmpty($sourceOctopusEnvironment)))
{
    $environmentToUseForCreationVersion = $sourceOctopusEnvironment
}
else
{
    $environmentToUseForCreationVersion = $octopusEnvironment
}

if ($environmentStatus -eq "creating")
{
    Write-Verbose "Environment Status is [$environmentStatus], using environment [$environmentToUseForCreationVersion] to determine initially installed version of component."
    $creationVersion = Get-LastReleaseToEnvironment -projectName $projectName -environmentName $environmentToUseForCreationVersion -octopusServerUrl $octopusServerUrl -octopusApiKey $octopusApiKey

    $arguments.Add("-Version", $creationVersion)
}

try
{

    $arguments.Add("-ProjectName", $projectName)
    $arguments.Add("-Environment", $octopusEnvironment)
    $arguments.Add("-OctopusServerUrl", $octopusServerUrl)
    $arguments.Add("-OctopusApiKey", $octopusApiKey)
    $arguments.Add("-OnlyCurrentMachine", $true)
    $arguments.Add("-Wait", $true)
    $arguments.Add("-Variables", $variables)

    New-OctopusDeployment @arguments
}
catch
{
    if ($_.Exception.Message -match "deploy.*failed")
    {
        Write-Warning "Deployment failed. This is a warning (instead of an Error/Exception) to stop the entire environment provisioning from failing. I may regret this."
        Write-Warning $_
    }
    else
    {
        throw $_
    }
}