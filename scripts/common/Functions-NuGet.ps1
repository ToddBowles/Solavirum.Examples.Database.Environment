function Get-NuGetExecutable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-FileSystem.ps1"

    $nugetExecutablePath = "$rootDirectoryPath\tools\nuget.exe"

    return Test-FileExists $nugetExecutablePath
}

function NuGet-EnsurePackageAvailable
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$package,
        [string]$version="latest",
        [scriptblock]$DI_nugetInstall={ 
            param
            (
                [string]$package, 
                [string]$version, 
                [string]$installDirectory,
                [string]$source
            ) 
            
            Nuget-Install -PackageId $package -Version $version -OutputDirectory $installDirectory -Source $source
        }
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $packagesDir = "$rootDirectoryPath\tools\packages"
    if ($version -ne "latest")
    {
        $expectedDirectory = "$packagesDir\$package.$version"

        if (-not (Test-Path $expectedDirectory))
        {
            Write-Verbose "Package [$package.$version] was not available at [$expectedDirectory]"

            $localSourceDirectory = "$rootDirectoryPath\tools\nuget"

            Write-Verbose "Attempting to install package [$package.$version] via Nuget, but using the directory [$localSourceDirectory] as the source"
            try
            {
                if (-not(Test-Path $localSourceDirectory))
                {
                    $sourceDirectoryCreationResult = [System.IO.Directory]::CreateDirectory($localSourceDirectory)
                }
                $distributedNugetPackagesPath = "$rootDirectoryPath\tools\dist\nuget"
        
                $distributedFilePath = "$package.$version.zip"
                $sourceFilePath = "$package.$version.nupkg"
                if (-not(Test-Path "$localSourceDirectory\$sourceFilePath"))
                {
                    Write-Verbose "Checking directory [$distributedNugetPackagesPath] for the zip file for package [$package.$version] because Nuget won't let me put nupkg files into a nuget package, so I had to add them as zip files."
                    Copy-Item -Path "$distributedNugetPackagesPath\$distributedFilePath" -Destination "$localSourceDirectory\$sourceFilePath"
                }

                & $DI_nugetInstall -Package $package -Version $version -InstallDirectory $packagesDir -Source $localSourceDirectory
                $success = $true
            }
            catch
            {
                Write-Verbose "The installation of package from the local directory failed. This is not hugely important as its just an optimisation"
                Write-Verbose $_
            }

            if ($success) { return $expectedDirectory }
        }
        else
        {
            return $expectedDirectory
        }
    }

    Write-Verbose "Attempting to install package [$package.$version] via Nuget"
    $maxAttempts = 5
    $waitSeconds = 1
    $success = $false
    $attempts= 1

    while (-not $success -and $attempts -lt $maxAttempts)
    {
        try
        {
            & $DI_nugetInstall -Package $package -Version $version -InstallDirectory $packagesDir
            $success = $true
        }
        catch
        {
            Write-Warning "An error occurred while attempting to install the package [$package.$version]. Trying again in [$waitSeconds] seconds. This was attempt number [$attempts]."
            Write-Warning $_

            $attempts++
            if ($attempts -lt $maxAttempts) { Sleep -Seconds $waitSeconds }

            $waitSeconds = $waitSeconds * 2
        }
    }

    if (-not($success))
    {
        throw "The package [$package.$version] was not installed and will not be available. Check previous log messages for details."
    }

    if ($version -eq "latest")
    {
        $directory = @(Get-ChildItem -Path $packagesDir -Filter "$package*" -Directory | Sort-Object -Property Name -Descending)[0]
        return $directory.FullName
    }
    else
    {
        return $expectedDirectory
    }
}

function NuGet-Restore
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [System.IO.FileInfo]$solutionOrProjectFile
    )

    $nugetExecutable = Get-NuGetExecutable

    $command = "restore"
    $arguments = @()
    $arguments += $command
    $arguments += "`"$($solutionOrProjectFile.FullName)`""

    write-verbose "Restoring NuGet Packages for [$($solutionOrProjectFile.FullName)]."
    (& "$($nugetExecutable.FullName)" $arguments) | Write-Verbose
    $return = $LASTEXITCODE
    if ($return -ne 0)
    {
        throw "NuGet '$command' failed. Exit code [$return]."
    }
}

function NuGet-Publish
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [System.IO.FileInfo]$package,
        [Parameter(Mandatory=$true)]
        [string]$apiKey,
        [Parameter(Mandatory=$true)]
        [string]$feedUrl,
        [scriptblock]$DI_ExecutePublishUsingNuGetExeAndArguments={ 
            param
            (
                [System.IO.FileInfo]$nugetExecutable, 
                [array]$arguments
            ) 
            
            (& "$($nugetExecutable.FullName)" $arguments) | Write-Verbose 
        }
    )

    begin
    {
        $nugetExecutable = Get-NuGetExecutable
    }
    process
    {
        $command = "push"
        $arguments = @()
        $arguments += $command
        $arguments += "`"$($package.FullName)`""
        $arguments += "-ApiKey"
        $arguments += "`"$apiKey`""
        $arguments += "-Source"
        $arguments += "`"$feedUrl`""
        $arguments += "-Timeout"
        $arguments += "600"

        write-verbose "Publishing package[$($package.FullName)] to [$feedUrl]."
        & $DI_ExecutePublishUsingNuGetExeAndArguments $nugetExecutable $arguments
        $return = $LASTEXITCODE
        if ($return -ne 0)
        {
            throw "NuGet '$command' failed. Exit code [$return]."
        }
    }
}

function NuGet-Pack
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [System.IO.FileInfo]$projectOrNuspecFile,
        [Parameter(Mandatory=$true)]
        [System.IO.DirectoryInfo]$outputDirectory,
        [Version]$version,
        [string]$configuration="Release",
        [string[]]$additionalArguments,
        [scriptblock]$DI_ExecutePackUsingNuGetExeAndArguments={ 
            param
            (
                [System.IO.FileInfo]$nugetExecutable, 
                [array]$arguments
            ) 
            
            (& "$($nugetExecutable.FullName)" $arguments) | Write-Verbose 
        },
        [switch]$createSymbolsPackage=$true
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $nugetExecutable = Get-NuGetExecutable

    $command = "pack"
    $arguments = @()
    $arguments += $command
    $arguments += "`"$($projectOrNuspecFile.FullName)`""
    $arguments += "-OutputDirectory"
    $arguments += "`"$($outputDirectory.FullName)`""
    if ($version -ne $null -and $version -ne "latest")
    {
        $arguments += "-Version"
        $arguments += "$($version.ToString())"
    }
    
    $arguments += "-Properties"
    $arguments += "Configuration=$configuration"
    
    if ($createSymbolsPackage)
    {
        $arguments += "-Symbols"
    }
    
    $arguments += "-Verbose"
    $arguments += "-Verbosity"
    $arguments += "detailed"

    $arguments = $arguments + $additionalArguments

    write-verbose "Packing [$($projectOrNuspecFile.FullName)] to [$($outputDirectory.FullName)]."
    & $DI_ExecutePackUsingNuGetExeAndArguments $nugetExecutable $arguments
    $return = $LASTEXITCODE
    if ($return -ne 0)
    {
        throw "NuGet '$command' failed. Exit code [$return]."
    }

    # Sometimes the project or Nuspec file might not match exactly with the created package (which may have
    # used the default namespace/output name). We use the project/nuspec file specified, but strip the 
    # extension and add a match all to the start (to deal with the situation where the file is a shortened
    # version of the package).
    $packageMatcher = "*$([System.IO.Path]::GetFileNameWithoutExtension($projectOrNuspecFile.Name)).*.nupkg"
    
    if ($createSymbolsPackage)
    {
        # The -Symbols option creates two packages in the output directory.
        # TeamCity is stupid, and won't let you upload both the normal and symbols packages.
        # So we delete the non symbols package, and rename the symbols package.

        Write-Verbose "Correcting the situation where Nuget pack with -Symbols enabled creates two packages (one with symbols, one without)."

        Write-Verbose "Finding packages using the expression [$packageMatcher], to delete those packages that are NOT symbols packages"
        Get-ChildItem -Path $outputDirectory -Filter $packageMatcher |
            Where { $_.FullName -notmatch "symbols" } |
            Remove-Item

        . "$rootDirectoryPath\scripts\common\Functions-Enumerables.ps1"
        Write-Verbose "Locating the single symbols file using the expression [$packageMatcher], to rename it and remove the .symbols component of the name."
        $symbolsPackageFile = Get-ChildItem -Path $outputDirectory -Filter $packageMatcher | 
            Single

        $newName = $symbolsPackageFile.Name.Replace(".symbols", "")

        $package = Rename-Item $symbolsPackageFile.FullName $newName
    }
    else
    {
        $package = Get-ChildItem -Path $outputDirectory -Filter $packageMatcher | 
            Single
    }
    
    return $package
}

function NuGet-Install
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$packageId,
        [string]$version,
        [Parameter(Mandatory=$true)]
        [string]$outputDirectory,
        [string]$source
    )

    
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $nugetExecutable = Get-NuGetExecutable

    $command = "install"
    $arguments = @()
    $arguments += $command
    $arguments += "`"$packageId`""
    if (-not([string]::IsNullOrEmpty($version)) -and ($version -ne "latest"))
    {
        $arguments += "-Version"
        $arguments += $version
    }

    $arguments += "-OutputDirectory"
    $arguments += "`"$outputDirectory`""
    $arguments += "-NoCache"

    if (-not([String]::IsNullOrEmpty($source)))
    {
        $arguments += "-Source"
        $arguments += "`"$source`""
    }
    else
    {
        $configFilePath = _LocateNugetConfigFile
        if ($configFilePath -ne $null)
        {
            $arguments += "-Config"
            $arguments += "`"$configFilePath`""
        }
    }

    write-verbose "Installing NuGet Package [$packageId.$version] into [$outputDirectory] using config [$configFilePath]."

    # If you write this to debug, for some ungodly reason, it will fail when it is run
    # on an AWS instance. God only knows why (invalid UTF 8 contination byte).
    (& "$($nugetExecutable.FullName)" $arguments) | Write-Debug

    $return = $LASTEXITCODE
    if ($return -ne 0)
    {
        throw "NuGet '$command' failed. Exit code [$return]."
    }
}

function _LocateNugetConfigFile
{
    Write-Verbose "Attempting to locate Nuget config file"
    $standardPath = "$rootDirectoryPath\tools\nuget.config"
    if (Test-Path $standardPath)
    {
        Write-Verbose "Config file found at [$standardPath]"
        return $standardPath
    }
    
    $searchRootPath = "$rootDirectoryPath\src"
    Write-Verbose "Searching for Nuget config files recursively in [$searchRootPath]"
    $configFiles = Get-ChildItem -Path $searchRootPath -Recurse -Filter "nuget.config"
    if ($configFiles.Length -ne 0)
    {
        Write-Verbose "Some nuget configuration files were found in the directory [$searchRootPath]. Selecting the first one in the list"
        return ($configFiles | Select -First 1).FullName
    }

    Write-Verbose "No Nuget config file found. Thats okay, it will just use the defaults."

    return $null
}
