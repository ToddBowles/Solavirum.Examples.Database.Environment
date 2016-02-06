[CmdletBinding()]
param
(
    [string]$specificTestNames="*",
    [hashtable]$globalCredentialsLookup,
    [string]$rootOutputFileDirectory,
    [string[]]$excludeTags,
    [string]$searchRootPath
)

$error.Clear()

$ErrorActionPreference = "Stop"

$currentDirectoryPath = Split-Path $script:MyInvocation.MyCommand.Path

. "$currentDirectoryPath\_Find-RootDirectory.ps1"

$rootDirectoryPath = (Find-RootDirectory $currentDirectoryPath).FullName
$scriptsDirectoryPath = "$rootDirectoryPath\scripts"
$commonScriptsDirectoryPath = "$scriptsDirectoryPath\common"

. "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"
. "$commonScriptsDirectoryPath\Functions-Nulls.ps1"

$toolsDirectoryPath = "$rootDirectoryPath\tools"
$nuget = "$toolsDirectoryPath\nuget.exe"

$nugetPackagesDirectoryPath = "$toolsDirectoryPath\packages"
$packageId = "Pester"
$packageVersion = "3.3.9"
& $nuget install $packageId -Version $packageVersion -OutputDirectory $nugetPackagesDirectoryPath | Write-Verbose

$pesterDirectoryPath = ((Get-ChildItem -Path $nugetPackagesDirectoryPath -Directory -Filter "$packageId.$packageVersion") | Single).FullName

Write-Verbose "Loading [$packageId.$packageVersion] Module"
$previousVerbosePreference = $VerbosePreference
$VerbosePreference = "SilentlyContinue"
Import-Module "$pesterDirectoryPath\tools\Pester.psm1"
$VerbosePreference = $previousVerbosePreference

if ([String]::IsNullOrEmpty($searchRootPath))
{
    Write-Warning "No search root was specified in the parameters [Parameter: searchRootPath]. Test search will start at the detected repository root [$rootDirectoryPath] instead."
    $searchRootPath = $rootDirectoryPath
}

$testScriptFilePaths = @(Get-ChildItem -Path $searchRootPath -Recurse -Filter "*.tests.ps1" |
    Where { $_.FullName -notmatch "packages" } |
    Select -ExpandProperty FullName)

if ($testScriptFilePaths.Length -eq 0)
{
    Write-Verbose "No test script files were found. Tests have not been executed."
    $resultSummary = @{
        TotalPassed=0;
        TotalFailed=0;
        TotalTime=[Timespan]::Zero;
        AllResults=@()
    }

    return $resultSummary
}

$pesterArgs = @{
    "-Strict"=$true;
    "-Script"=$testScriptFilePaths;
    "-TestName"=$specificTestNames;
    "-PassThru"=$true;
    "-ExcludeTag"=$excludeTags;
}

if (-not([string]::IsNullOrEmpty($rootOutputFileDirectory)))
{
    $outputFilePath = "$rootOutputFileDirectory\Tests.Powershell.Results.xml"
    $pesterArgs.Add("-OutputFile", $outputFilePath)
    $pesterArgs.Add("-OutputFormat", "NUnitXml")
}

$results = Invoke-Pester @pesterArgs

$testResult = new-object PSObject @{
    "TestDirectory"=$directoryWithTests.FullName;
    "OutputFile"=$outputFilePath;
    "TestResults"=$results;
}

$resultSummary = @{
    TotalPassed=$testResult.TestResults.PassedCount;
    TotalFailed=$testResult.TestResults.FailedCount;
    TotalTime=$testResult.TestResults.Time;
    AllResults=@($testResult)
}

return $resultSummary