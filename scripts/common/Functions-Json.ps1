function Ensure-JsonNetClassesAvailable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"
    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"
    . "$commonScriptsDirectoryPath\Functions-Nuget.ps1"

    $toolsDirectoryPath = "$rootDirectoryPath\tools"

    $nugetPackagesDirectoryPath = "$toolsDirectoryPath\packages"

    $packageId = "Newtonsoft.Json"
    $packageVersion = "6.0.8"
    $expectedDirectoryPath = "$nugetPackagesDirectoryPath\$packageId.$packageVersion"
    $expectedDirectory = Nuget-EnsurePackageAvailable -Package $packageId -Version $packageVersion

    Write-Verbose "Loading JSON.NET classes."
    $addTypeResult = Add-Type -Path "$expectedDirectory\lib\net40\Newtonsoft.Json.dll" | Write-Verbose
}

function Convert-ToJsonViaNewtonsoft
{
    [CmdletBinding()]
    param
    (
        $object
    )

    
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-JsonNetClassesAvailable

    return [Newtonsoft.Json.JsonConvert]::SerializeObject($object, [Newtonsoft.Json.Formatting]::Indented)
}