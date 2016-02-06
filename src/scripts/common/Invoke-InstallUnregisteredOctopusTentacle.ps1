[CmdletBinding()]
param
(

)

$ErrorActionPreference = "Stop"

$here = Split-Path $script:MyInvocation.MyCommand.Path
write-host "Script Root Directory is [$here]."

. "$here\_Find-RootDirectory.ps1"

$rootDirectory = Find-RootDirectory $here
$rootDirectoryPath = $rootDirectory.FullName

. "$rootDirectoryPath\scripts\common\Functions-OctopusDeploy-Installation.ps1"

Install-Tentacle