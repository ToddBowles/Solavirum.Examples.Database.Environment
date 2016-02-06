function Get-OpenCoverExecutable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Nuget.ps1"

    $package = "OpenCover"
    $version = "4.5.3522"
    $expectedDirectory = Nuget-EnsurePackageAvailable -Package $package -Version $version

    $executable = new-object System.IO.FileInfo("$expectedDirectory\OpenCover.Console.exe")

    return $executable
}

function Get-ReportGeneratorExecutable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Nuget.ps1"

    $package = "ReportGenerator"
    $version = "2.1.0.0"
    $expectedDirectory = Nuget-EnsurePackageAvailable -Package $package -Version $version

    $executable = new-object System.IO.FileInfo("$expectedDirectory\ReportGenerator.exe")

    return $executable
}

function OpenCover-ExecuteTests
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.IO.FileInfo]$testLibrary
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $rootDirectoryPath = $rootDirectory.FullName
    . "$rootDirectoryPath\scripts\common\Functions-NUnit.ps1"

    if ($testLibrary.FullName -match "x86")
    {
        $nunitRunnerPath = (Get-NUnitConsolex86Executable).FullName
    }
    else
    {
        $nunitRunnerPath = (Get-NUnitConsoleExecutable).FullName
    }

    $executable = Get-OpenCoverExecutable
    $executablePath = $executable.FullName

    $libraryDirectoryPath = $testLibrary.Directory.FullName

    $testResultsFilePath = "$libraryDirectoryPath\$($testLibrary.Name).TR.xml"
    $coverageResultsFilePath = "$libraryDirectoryPath\_CCR.xml"

    $arguments = @()
    $arguments += "-target:`"$nunitRunnerPath`""
    $arguments += "-targetargs:`"$($testLibrary.FullName)`" /noshadow /framework:net-4.5 /xml:`"$testResultsFilePath`""
    $arguments += "-register:user"
    $arguments += "-returntargetcode"
    $arguments += "-output:`"$coverageResultsFilePath`""

    Write-Verbose "OpenCover-ExecuteTests $executablePath $arguments"
    (& "$executablePath" $arguments) | Write-Verbose
    $numberOfFailedTests = $LASTEXITCODE

    if ($numberOfFailedTests -lt 0)
    {
        throw "OpenCover returned an exit code less than 0. This indicates a failure of some description above and beyond test failures. Check Verbose output, or rerun with -Verbose enabled for more information."
    }

    $reportGeneratorPath = (Get-ReportGeneratorExecutable).FullName
    $coverageReportDirectoryPath = "$libraryDirectoryPath\CCR"

    $reportGeneratorArgs = @()
    $reportGeneratorArgs += "-reports:`"$coverageResultsFilePath`""
    $reportGeneratorArgs += "-targetdir:`"$coverageReportDirectoryPath`""

    Write-Verbose "OpenCover-ExecuteTests $reportGeneratorPath $reportGeneratorArgs"
    & "$reportGeneratorPath" $reportGeneratorArgs

    $results = @{}
    $results.Add("LibraryName", $($testLibrary.Name))
    $results.Add("TestResultsFile", "$testResultsFilePath")
    $results.Add("CoverageResultsDirectory", "$coverageReportDirectoryPath")
    $results.Add("NumberOfFailingTests", $numberOfFailedTests)

    return new-object PSObject $results
}