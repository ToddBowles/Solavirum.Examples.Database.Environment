function Build-LibraryComponent
{
    [CmdletBinding()]
    param
    (
        [switch]$publish,
        [string]$nugetServerUrl,
        [string]$nugetServerApiKey,
        [switch]$teamCityPublish,
        [string]$subDirectory,
        [scriptblock]$DI_sourceDirectory={ return "$rootDirectoryPath\src" },
        [scriptblock]$DI_buildOutputDirectory={ return "$rootDirectoryPath\build-output" },
        [int]$buildNumber,
        [string]$versionStrategy="AutomaticIncrementBasedOnCurrentUtcTimestamp",
        [string]$projectOrNuspecFileName,
        [string[]]$listOfProjectOrNuspecFileNames,
        [switch]$isMsbuild=$true,
        [switch]$failOnTestFailures=$true
    )

    try
    {
        $error.Clear()

        $ErrorActionPreference = "Stop"

        if (-not([string]::IsNullOrEmpty($projectOrNuspecFileName)) -and $listOfProjectOrNuspecFileNames -ne $null)
        {
            throw "Both a single project or nuspec file and a group of project or nuspec files were specified. Pick one or the other."
        }

        if (-not([string]::IsNullOrEmpty($projectOrNuspecFileName)))
        {
            $listOfProjectOrNuspecFileNames = @($projectOrNuspecFileName)
        }

        $here = Split-Path $script:MyInvocation.MyCommand.Path

        . "$here\_Find-RootDirectory.ps1"

        $rootDirectory = Find-RootDirectory $here
        $rootDirectoryPath = $rootDirectory.FullName

        . "$rootDirectoryPath\scripts\common\Functions-Strings.ps1"
        . "$rootDirectoryPath\scripts\common\Functions-Versioning.ps1"
        . "$rootDirectoryPath\scripts\common\Functions-Enumerables.ps1"

        $srcDirectoryPath = & $DI_sourceDirectory
        if (![string]::IsNullOrEmpty($subDirectory))
        {
            $srcDirectoryPath = "$srcDirectoryPath\$subDirectory"
        }

        $sharedAssemblyInfo = _FindSharedAssemblyInfoForVersioning -srcDirectoryPath $srcDirectoryPath
        $versionChangeResult = Update-AutomaticallyIncrementAssemblyVersion -AssemblyInfoFile $sharedAssemblyInfo -VersionStrategy $versionStrategy -BuildNumber $buildNumber

        write-host "##teamcity[buildNumber '$($versionChangeResult.New)']"

        . "$rootDirectoryPath\scripts\common\Functions-FileSystem.ps1"
        $buildOutputRoot = & $DI_buildOutputDirectory
        if (![string]::IsNullOrEmpty($subDirectory))
        {
            $buildOutputRoot = "$buildOutputRoot\$subDirectory"
        }
        $buildDirectory = Ensure-DirectoryExists ([System.IO.Path]::Combine($rootDirectory.FullName, "$buildOutputRoot\$($versionChangeResult.New)"))

        . "$rootDirectoryPath\scripts\common\Functions-NuGet.ps1"

        if ($isMsbuild)
        {
            Write-Host "##teamcity[blockOpened name='Compiling']"
            $solutionFile = (Get-ChildItem -Path "$srcDirectoryPath" -Filter *.sln -Recurse) |
                Single -Predicate { -not ($_.FullName -match "packages") }

            NuGet-Restore $solutionFile

            $msbuildArgs = @()
            $msbuildArgs += "`"$($solutionFile.FullName)`""
            $msbuildArgs += "/t:clean,rebuild"
            $msbuildArgs += "/v:minimal"
            $msbuildArgs += "/p:Configuration=`"Release`""

            Execute-MSBuild -msBuildArgs $msbuildArgs

            Write-Host "##teamcity[progressMessage 'Compilation Successful']"
            Write-Host "##teamcity[blockClosed name='Compiling']"
        }

        _FindAndExecuteNUnitTests -testType "unit" -searchRoot $srcDirectoryPath -buildOutput $buildDirectory.FullName -ThrowOnTestFailures:$failOnTestFailures
        _FindAndExecuteNUnitTests -testType "integration" -searchRoot $srcDirectoryPath -buildOutput $buildDirectory.FullName -ThrowOnTestFailures:$failOnTestFailures

        _FindAndExecutePowershellTests -searchRootPath $srcDirectoryPath -buildOutput $buildDirectory.FullName -ThrowOnTestFailures:$failOnTestFailures

        $projectOrNuspecFiles = @()
        if ($listOfProjectOrNuspecFileNames -eq $null)
        {
            try
            {
                Write-Verbose "No project or nuspec file was specified. Attempting to automatically locate one."
                $projectFile = (Get-ChildItem -Path "$srcDirectoryPath" -Filter *.csproj -Recurse) |
                    Single -Predicate { -not ($_.FullName -match "packages" -or $_.FullName -like "*tests*") }
                $projectOrNuspecFiles += $projectFile
            }
            catch
            {
                throw new-object Exception("An acceptable project file could not be found. No package could be created.". $_.Exception)
            }
        }
        else
        {
            foreach ($projectOrNuspecFileName in $listOfProjectOrNuspecFileNames)
            {
                Write-Verbose "Finding the specified project/nuspec file [$projectOrNuspecFileName]."
                $projectFile = (Get-ChildItem -Path $srcDirectoryPath -Filter $projectOrNuspecFileName -Recurse) |
                    Single
                $projectOrNuspecFiles += $projectFile
            }
        }

        foreach ($projectFile in $projectOrNuspecFiles)
        {
            Nuget-Pack -ProjectOrNuspecFile $projectFile -OutputDirectory $buildDirectory -Version $versionChangeResult.New
        }
        
        Write-Host "##teamcity[progressMessage 'Packaging Successful']"

        # Publish
        if ($publish)
        {
            Write-Warning "Arbitrary publish not implemented."
        }

        if ($teamCityPublish)
        {
            write-host "##teamcity[publishArtifacts '$($buildDirectory.FullName)/*.nupkg']"
            Write-Host "##teamcity[progressMessage 'Publish Successful']"
        }

        $result = @{}
        $result.Add("VersionInformation", $versionChangeResult)
        $result.Add("BuildOutput", $buildDirectory.FullName)

        return $result
    }
    finally
    {
        if ($versionChangeResult -ne $null)
        {
            Write-Verbose "Restoring version to old version to avoid making permanent changes to the SharedAssemblyInfo file."
            $version = Set-AssemblyVersion $sharedAssemblyInfo $versionChangeResult.Old
        }
    }
}

$msbuildOctopackBuildEngine = {
    [CmdletBinding()]
    param
    (
        [string]$srcDirectoryPath,
        [System.IO.DirectoryInfo]$buildDirectory,
        $versionChangeResult
    )

    Write-Host "##teamcity[blockOpened name='Compiling and Packaging']"

    $solutionFile = (Get-ChildItem -Path "$srcDirectoryPath" -Filter *.sln -Recurse) |
    Single -Predicate { -not ($_.FullName -match "packages" -or ($_.FullName -match "tests")) }

    . "$rootDirectoryPath\scripts\common\Functions-NuGet.ps1"
    NuGet-Restore $solutionFile

    $msbuildArgs = @()
    $msbuildArgs += "`"$($solutionFile.FullName)`""
    $msbuildArgs += "/t:clean,rebuild"
    $msbuildArgs += "/v:minimal"
    $msbuildArgs += "/p:Configuration=`"Release`";RunOctoPack=true;OctoPackPublishPackagesToTeamCity=false;OctoPackPublishPackageToFileShare=`"$($buildDirectory.FullName)`";OctoPackPackageVersion=`"$($versionChangeResult.New)`""

    Execute-MSBuild -msBuildArgs $msbuildArgs

    Write-Host "##teamcity[blockClosed name='Compiling and Packaging']"
    Write-Host "##teamcity[progressMessage 'Compiling and Packaging Successful']"
}

$nugetBuildEngine = {
    [CmdletBinding()]
    param
    (
        [string]$srcDirectoryPath,
        [System.IO.DirectoryInfo]$buildDirectory,
        $versionChangeResult
    )

    Write-Host "##teamcity[blockOpened name='Packaging']"

    $nuspecFile = Get-ChildItem -Path $srcDirectoryPath -Filter *.nuspec | Single

    . "$rootDirectoryPath\scripts\common\Functions-NuGet.ps1"

    NuGet-Pack $nuspecFile $buildDirectory -Version $versionChangeResult.New -createSymbolsPackage:$false

    Write-Host "##teamcity[blockClosed name='Packaging']"
    Write-Host "##teamcity[progressMessage 'Packaging Successful']"
}

$buildEngines = @{
    "msbuild-octopack"=$msbuildOctopackBuildEngine;
    "nuget"=$nugetBuildEngine;
}

function Build-DeployableComponent
{
    [CmdletBinding()]
    param
    (
        [switch]$deploy,
        [string]$environment,
        [string]$octopusProjectPrefix,
        [string]$octopusServerUrl,
        [string]$octopusServerApiKey,
        [string]$subDirectory,
        [string[]]$projects,
        [ValidateSet("msbuild-octopack", "nuget")]
        [string]$buildEngineName="msbuild-octopack",
        [int]$buildNumber,
        [string]$versionStrategy="AutomaticIncrementBasedOnCurrentUtcTimestamp",
        [scriptblock]$DI_sourceDirectory={ return "$rootDirectoryPath\src" },
        [scriptblock]$DI_buildOutputDirectory={ return "$rootDirectoryPath\build-output" },
        [string]$commaSeparatedDeploymentEnvironments,
        [switch]$failOnTestFailures=$true,
        [scriptblock]$buildEngine
    )

    try
    {
        $error.Clear()
        $ErrorActionPreference = "Stop"

        Write-Host "##teamcity[blockOpened name='Setup']"

        $here = Split-Path $script:MyInvocation.MyCommand.Path

        . "$here\_Find-RootDirectory.ps1"

        $rootDirectory = Find-RootDirectory $here
        $rootDirectoryPath = $rootDirectory.FullName

        . "$rootDirectoryPath\scripts\common\Functions-Strings.ps1"
        . "$rootDirectoryPath\scripts\common\Functions-Versioning.ps1"
        . "$rootDirectoryPath\scripts\common\Functions-Enumerables.ps1"

        if ($buildEngine -eq $null)
        {
            $buildEngine = $buildEngines[$buildEngineName]
        }

        if ($deploy)
        {
            $octopusServerUrl | ShouldNotBeNullOrEmpty -Identifier "OctopusServerUrl"
            $octopusServerApiKey | ShouldNotBeNullOrEmpty -Identifier "OctopusServerApiKey"

            if ($projects -eq $null -or (-not ($projects | Any)))
            {
                if ([string]::IsNullOrEmpty($octopusProjectPrefix))
                {
                    throw "One of OctopusProjectPrefix or Projects must be set to determine which Octopus Projects to deploy to."
                }
            }

            if ((($projects -ne $null) -and ($projects | Any)) -and -not [string]::IsNullOrEmpty($octopusProjectPrefix))
            {
                Write-Warning "Both a specific list of projects and a project prefix were specified. The list will take priority for deployment purposes."
            }

            if (-not([string]::IsNullOrEmpty($environment)) -and -not([string]::IsNullOrEmpty($commaSeparatedDeploymentEnvironments)))
            {
                throw "You have specified both the singular deployment environment (obsolete) [Parameter: '-Environment', Value: [$environment]] as well as the plural deployment environments [Parameter: '-CommaSeparatedDeploymentEnvironments', Value: [$commaSeparatedDeploymentEnvironments]]. Only one may be specified."
            }

            if (-not([string]::IsNullOrEmpty($environment)))
            {
                Write-Warning "You have specified the deployment environment via [Parameter: '-Environment']. This is the obsolete way of specifying deployment targets. Use [Parameter: '-CommaSeparatedDeploymentEnvironments'] instead."
                $environments = @($environment)
            }
            else
            {
                $environments = $commaSeparatedDeploymentEnvironments.Split(@(',', ' '), [StringSplitOptions]::RemoveEmptyEntries)
            }
        
            if ($environments.Length -eq 0)
            {
                throw "No environments to deploy to were specified, but [Parameter: '-Deploy'] was specified. Use [Parameter: '-CommaSeparatedDeploymentEnvironments'] to supply deployment targets."
            }

            if ($environments.Length -gt 2)
            {
                throw "Too many environments to deploy to were specified. This script currently only supports a maximum of 2 environments, typically CI and Staging."
            }
        }

        $srcDirectoryPath = & $DI_sourceDirectory
        if (![string]::IsNullOrEmpty($subDirectory))
        {
            $srcDirectoryPath = "$srcDirectoryPath\$subDirectory"
        }

        Write-Host "##teamcity[blockOpened name='Versioning']"

        $sharedAssemblyInfo = _FindSharedAssemblyInfoForVersioning -srcDirectoryPath $srcDirectoryPath
        $versionChangeResult = Update-AutomaticallyIncrementAssemblyVersion -AssemblyInfoFile $sharedAssemblyInfo -VersionStrategy $versionStrategy -BuildNumber $buildNumber

        Write-Host "##teamcity[blockClosed name='Versioning']"

        write-host "##teamcity[buildNumber '$($versionChangeResult.New)']"

        . "$rootDirectoryPath\scripts\common\Functions-FileSystem.ps1"
        $buildOutputRoot = & $DI_buildOutputDirectory
        if (![string]::IsNullOrEmpty($subDirectory))
        {
            $buildOutputRoot = "$buildOutputRoot\$subDirectory"
        }
        $buildDirectory = Ensure-DirectoryExists ([System.IO.Path]::Combine($rootDirectory.FullName, "$buildOutputRoot\$($versionChangeResult.New)"))

        Write-Host "##teamcity[blockClosed name='Setup']"

        & $buildEngine -SrcDirectoryPath $srcDirectoryPath -BuildDirectory $buildDirectory -VersionChangeResult $versionChangeResult

        _FindAndExecuteNUnitTests -testType "unit" -searchRoot $srcDirectoryPath -buildOutput $buildDirectory.FullName -ThrowOnTestFailures:$failOnTestFailures
        _FindAndExecuteNUnitTests -testType "integration" -searchRoot $srcDirectoryPath -buildOutput $buildDirectory.FullName -ThrowOnTestFailures:$failOnTestFailures

        _FindAndExecutePowershellTests -searchRootPath $srcDirectoryPath -buildOutput $buildDirectory.FullName -ThrowOnTestFailures:$failOnTestFailures

        write-host "##teamcity[publishArtifacts '$($buildDirectory.FullName)/*.nupkg']"

        if ($deploy)
        {
            $deployedEnvironments = @()
            $initialDeploymentEnvironment = $environments[0]
            Write-Host "##teamcity[blockOpened name='Deployment ($initialDeploymentEnvironment)']"
            Write-Host "##teamcity[progressMessage 'Deploying to ($initialDeploymentEnvironment)']"

            $packages = Get-ChildItem -Path ($buildDirectory.FullName) | 
                Where { $_.FullName -like "*.nupkg" }
            $feedUrl = "$octopusServerUrl/nuget/packages"

            . "$rootDirectoryPath\scripts\common\Functions-NuGet.ps1"

            foreach ($package in $packages)
            {
                try
                {
                    NuGet-Publish -Package $package -ApiKey $octopusServerApiKey -FeedUrl $feedUrl
                }
                catch 
                {
                    # I did this hack because I had some issues with the Oth.Logging.Logstash package being uploaded more than once with exactly the same
                    # version and content due to TeamCity triggers and parallel builds. This can probably go away if we ever fix the way Logstash configurations
                    # are deployed.
                    Write-Warning $_
                    Write-Warning "A failure occurred while attempting to publish the package [$($package.FullName)] to [$feedUrl] as part of deployment."
                    Write-Warning "This failure is a warning because the most common cause is an upload of a package/version that already exists on the server."
                    Write-Warning "The upcoming release/deployment steps will fail if the failure was not related to a duplicate package, and was actually important."
                }
            }   

            . "$rootDirectoryPath\scripts\common\Functions-OctopusDeploy.ps1"
            
            if ($projects -eq $null)
            {
                Write-Verbose "No projects to deploy to have been specified. Deploying to all projects starting with [$octopusProjectPrefix]."
                $octopusProjects = Get-AllOctopusProjects -octopusServerUrl $octopusServerUrl -octopusApiKey $octopusServerApiKey | Where { $_.Name -like "$octopusProjectPrefix*" }

                if (-not ($octopusProjects | Any -Predicate { $true }))
                {
                    throw "You have elected to do a deployment, but no Octopus Projects could be found to deploy to (using prefix [$octopusProjectPrefix]."
                }

                $projects = ($octopusProjects | Select -ExpandProperty Name)
            }

            foreach ($project in $projects)
            {
                New-OctopusRelease -ProjectName $project -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusServerApiKey -Version $versionChangeResult.New -ReleaseNotes "[SCRIPT] Automatic Release created as part of Build."
                New-OctopusDeployment -ProjectName $project -Environment "$initialDeploymentEnvironment" -Version $versionChangeResult.New -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusServerApiKey -Wait
            }

            $deployedEnvironments += $initialDeploymentEnvironment

            Write-Host "##teamcity[progressMessage '($initialDeploymentEnvironment) Deploy Successful']"
            Write-Host "##teamcity[blockClosed name='Deployment ($initialDeploymentEnvironment)']"

            _FindAndExecuteNUnitTests -testType "functional" -searchRoot $srcDirectoryPath -buildOutput $buildDirectory.FullName -ThrowOnTestFailures:$failOnTestFailures

            if ($environments.Length -eq 2)
            {
                $secondaryDeploymentEnvironment = $environments[1]
                
                Write-Host "##teamcity[blockOpened name='Deployment ($secondaryDeploymentEnvironment)']"
                Write-Host "##teamcity[progressMessage 'Deploying to ($secondaryDeploymentEnvironment)']"
                
                foreach ($project in $projects)
                {
                    New-OctopusDeployment -ProjectName $project -Environment "$secondaryDeploymentEnvironment" -Version $versionChangeResult.New -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusServerApiKey -Wait
                }

                $deployedEnvironments += $secondaryDeploymentEnvironment
                Write-Host "##teamcity[progressMessage '($secondaryDeploymentEnvironment) Deploy Successful']"
                Write-Host "##teamcity[blockClosed name='Deployment ($secondaryDeploymentEnvironment)']"
            }
        }

        $result = @{}
        $result.Add("VersionInformation", $versionChangeResult)
        $result.Add("BuildOutput", $buildDirectory.FullName)

        return $result
    }
    finally
    {
        if (($deployedEnvironments -ne $null) -and ($deployedEnvironments | Any))
        {
            $commaDelimitedDeployedEnvironments = [string]::Join(", ", $deployedEnvironments)
            Write-Host "##teamcity[buildStatus text='{build.status.text}; Deployed ($commaDelimitedDeployedEnvironments)']"
        }

        Write-Host "##teamcity[blockOpened name='Cleanup']"

        if ($versionChangeResult -ne $null)
        {
            Write-Verbose "Restoring version to old version to avoid making permanent changes to the SharedAssemblyInfo file."
            $version = Set-AssemblyVersion $sharedAssemblyInfo $versionChangeResult.Old
        }

        Write-Host "##teamcity[blockClosed name='Cleanup']"
    }
}

function Execute-MSBuild
{
    [CmdletBinding()]
    param
    (
        [string[]]$msBuildArgs
    )

    $msbuild = (Get-ChildItem -Path "C:\Windows\Microsoft.NET" -Filter MSBuild.exe -Recurse) |
        Where-Object { $_.FullName -match "(.*)Framework(.*)v4.0(.*)" } | 
        Select-Object -First 1

    & "$($msbuild.FullName)" $msBuildArgs | Write-Verbose
    if($LASTEXITCODE -ne 0)
    {
        throw "MSBuild Failed."
    }
}

function _FindSharedAssemblyInfoForVersioning
{
    [CmdletBinding()]
    param
    (
        [string]$srcDirectoryPath
    )

    try
    {
        $sharedAssemblyInfo = (Get-ChildItem -Path $srcDirectoryPath -Filter SharedAssemblyInfo.cs -Recurse) | Single
    }
    catch
    {
        throw new-object Exception("A SharedAssemblyInfo file (used for versioning) could not be found when searching from [$srcDirectoryPath]", $_.Exception)
    }

    return $sharedAssemblyInfo
}

function _FindAndExecuteNUnitTests
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$testType,
        [Parameter(Mandatory=$true)]
        [System.IO.DirectoryInfo]$searchRoot,
        [Parameter(Mandatory=$true)]
        [System.IO.DirectoryInfo]$buildOutput,
        [switch]$throwOnTestFailures=$true
    )
    
    $buildOutputPath = $buildOutput.FullName
    
    function _FindTestLibraries
    {
        Write-Verbose "Finding libraries containing [$testType] tests."
        $candidateLibraries = @(Get-ChildItem -File -Path $searchRoot -Recurse -Filter "*.Test*.dll" |
            Where { $_.FullName -notmatch "obj" -and $_.FullName -notmatch "packages" -and $_.FullName -match "release" -and $_.Name -like "*$testType*" })
    
        if (-not($candidateLibraries | Any))
        {
            return $null
        }
    
        return $candidateLibraries
    }
    
    
    function _ExecuteTestsInLibraryAndCopyResultsToBuildOutput($testLibrary)
    {
        if ($testLibrary -eq $null)
        {
            Write-Warning "No test library was supplied for execution"
            return 0
        }
    
        Write-Host "##teamcity[testSuiteStarted name='$testLibrary']"
        $executionResult = OpenCover-ExecuteTests $testLibrary
        
        # put the test results in the build output directory
        $testResultFilePath = "$buildOutputPath\$testLibrary.TestResults.xml"
        $codeCoverageDirectoryPath = "$buildOutputPath\$testLibrary.CodeCoverageReport"
        Copy-Item $executionResult.TestResultsFile $testResultFilePath
        Copy-Item $executionResult.CoverageResultsDirectory $codeCoverageDirectoryPath -Recurse
        
        Write-Host "##teamcity[importData type='nunit' path='$testResultFilePath']"
        Write-Host "##teamcity[testSuiteFinished name='$testLibrary']"
        
        $result = New-Object -TypeName PSObject
        $result | Add-Member -MemberType NoteProperty -Name NumberOfFailingTests -Value $executionResult.NumberOfFailingTests
        $result | Add-Member -MemberType NoteProperty -Name TestResultsFilePath -Value $testResultFilePath
        $result | Add-Member -MemberType NoteProperty -Name CodeCoverageDirectoryPath -Value $codeCoverageDirectoryPath
        return $result
    }
    

    if ($rootDirectory -eq $null) 
    { 
        throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." 
    }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Enumerables.ps1"
    . "$rootDirectoryPath\scripts\common\Functions-OpenCover.ps1"

    $libraries = _FindTestLibraries
    foreach($library in $libraries)
    {
        Write-Host "##teamcity[blockOpened name='Automated Tests ($library)']"
        Write-Host "##teamcity[progressMessage 'Running Automated Tests ($library)']"
        if ($library -ne $null)
        {
            $result = _ExecuteTestsInLibraryAndCopyResultsToBuildOutput $library
            $numberOfFailures += $result.NumberOfFailingTests

            write-host "##teamcity[publishArtifacts '$($result.TestResultsFilePath)']"
            write-host "##teamcity[publishArtifacts '$($result.CodeCoverageDirectoryPath)']"

            if ($numberOfFailures -gt 0)
            {
                Write-Host "##teamcity[progressMessage '$library Tests Failed']"
                if ($throwOnTestFailures)
                {
                    throw "$failingTestCount failed tests in $library tests. Aborting Build since `$throwOnTestFailures was set to true"
                }
            }

            Write-Host "##teamcity[progressMessage '($library) Tests Successful']"
        }
        Write-Host "##teamcity[blockClosed name='Automated Tests ($library)']"
    }

}

function _FindAndExecutePowershellTests
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$searchRootPath,
        [Parameter(Mandatory=$true)]
        [System.IO.DirectoryInfo]$buildOutput,
        [switch]$throwOnTestFailures=$true
    )
    $testType = "Powershell"
    Write-Host "##teamcity[blockOpened name='Automated Tests ($testType)']"
    Write-Host "##teamcity[progressMessage 'Running Automated Tests ($testType)']"
    Write-Host "##teamcity[testSuiteStarted name='$testType']"

    if ($rootDirectory -eq $null) 
    { 
        throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." 
    }
    $rootDirectoryPath = $rootDirectory.FullName

    $testResults = & "$rootDirectoryPath\scripts\common\Invoke-PesterTests.ps1" -globalCredentialsLookup $globalCredentialsLookup -rootOutputFileDirectory ($buildOutput.FullName) -excludeTags @("Ignore") -searchRootPath $searchRootPath

    foreach ($result in $testResults.AllResults)
    {
        if (-not([string]::IsNullOrEmpty($result.OutputFile)))
        {
            Write-Host "##teamcity[importData type='nunit' path='$($result.OutputFile)']"
            write-host "##teamcity[publishArtifacts '$($result.OutputFile)']"
        }
    }
    
    Write-Host "##teamcity[testSuiteFinished name='$testType']"
    Write-Host "##teamcity[blockClosed name='Automated Tests ($testType)']"

    if ($testResults.TotalFailed -gt 0)
    {
        Write-Warning "Test Results"
        Write-Warning "------------------------------------------------"
        Write-Warning (ConvertTo-Json $testResults)
        Write-Warning "------------------------------------------------"
        if ($throwOnTestFailures)
        {
            throw "[$($testResults.TotalFailed)] tests failed"
        }
    }

    Write-Host "##teamcity[progressMessage '($testType) Tests Successful']"
}