function Get-NUnitConsoleExecutable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Nuget.ps1"

    $package = "NUnit.Runners"
    $version = "2.6.4"
    $expectedDirectory = Nuget-EnsurePackageAvailable -Package $package -Version $version

    $executable = new-object System.IO.FileInfo("$expectedDirectory\tools\nunit-console.exe")

    return $executable
}

function Get-NUnitConsolex86Executable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Nuget.ps1"

    $package = "NUnit.Runners"
    $version = "2.6.4"
    $expectedDirectory = Nuget-EnsurePackageAvailable -Package $package -Version $version

    $executable = new-object System.IO.FileInfo("$expectedDirectory\tools\nunit-console-x86.exe")

    return $executable
}