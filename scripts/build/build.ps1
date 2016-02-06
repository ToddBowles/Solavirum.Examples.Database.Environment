[CmdletBinding()]
param
(
    [switch]$publish,
    [string]$nugetServerUrl,
    [string]$nugetServerApiKey,
    [switch]$teamCityPublish,
    [switch]$failOnTestFailures=$true
)

$error.Clear()

$ErrorActionPreference = "Stop"

$here = Split-Path $script:MyInvocation.MyCommand.Path

. "$here\_Find-RootDirectory.ps1"

$rootDirectory = Find-RootDirectory $here
$rootDirectoryPath = $rootDirectory.FullName

. "$rootDirectoryPath\scripts\common\Functions-Build.ps1"

$arguments = @{
    "IsMsBuild"=$false;
    "ProjectOrNuspecFileName"="Solavirum.Examples.Database.Environment.nuspec";
    "FailOnTestFailures"=$failOnTestFailures;
}

if ($teamCityPublish)
{
    $arguments.Add("TeamCityPublish", $true)
}

Build-LibraryComponent @arguments