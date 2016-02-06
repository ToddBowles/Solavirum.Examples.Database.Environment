function Get-AssemblyVersionRegexString
{
    return "^(\[assembly: AssemblyVersion\()(`")(.*)(`"\)\])$"
}

function Get-AssemblyFileVersionRegexString
{
    return "^(\[assembly: AssemblyFileVersion\()(`")(.*)(`"\)\])$"
}

function Get-AssemblyInformationalVersionRegexString
{
    return "^(\[assembly: AssemblyInformationalVersion\()(`")(.*)(`"\)\])$"
}

function Update-AutomaticallyIncrementAssemblyVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Position=0, Mandatory=$true)]
        [System.IO.FileInfo]$assemblyInfoFile,
        [int]$buildNumber=9999,
        [string]$versionStrategy="AutomaticIncrementBasedOnCurrentUtcTimestamp"
    )

    $existingVersion = Get-AssemblyVersion -AssemblyInfoFile $assemblyInfoFile

    $splitVersion = $existingVersion.Split(@("."))
 
    write-verbose ("Current version is [" + $existingVersion + "].")
 
    if ($versionStrategy -eq "AutomaticIncrementBasedOnCurrentUtcTimestamp")
    {
        $newVersion = _GetVersion_AutomaticIncrementBasedOnCurrentUtcTimestamp $splitVersion[0] $splitVersion[1]
    }
    elseif ($versionStrategy -eq "DerivedFromYearMonthAndBuildNumber")
    {
        $newVersion = _GetVersion_DerivedFromYearMonthAndBuildNumber $splitVersion[0] $buildNumber
    }
    else
    {
        throw "The version number generation strategy [$versionStrategy] is unknown."
    }
    $newVersion = Set-AssemblyVersion $assemblyInfoFile $newVersion

    $result = new-object psobject @{ "Old"=$existingVersion; "New"=$newVersion }
    return $result
}

function _GetVersion_AutomaticIncrementBasedOnCurrentUtcTimestamp
{
    param
    (
        [int]$major,
        [int]$minor,
        [scriptblock]$DI_getSystemUtcDateTime={ return [System.DateTime]::UtcNow }
    )

    $currentUtcDateTime = & $DI_getSystemUtcDateTime

    $major = $major
    $minor = $minor
    $build = $currentUtcDateTime.ToString("yy") + $currentUtcDateTime.DayOfYear.ToString("000")
    $revision = ([int](([int]$currentUtcDateTime.Subtract($currentUtcDateTime.Date).TotalSeconds) / 2)).ToString()
 
    $newVersion = [System.String]::Format("{0}.{1}.{2}.{3}", $major, $minor, $build, $revision)

    return $newVersion
}

function _GetVersion_DerivedFromYearMonthAndBuildNumber
{
    param
    (
        [int]$major,
        [int]$buildNumber,
        [scriptblock]$DI_getSystemUtcDateTime={ return [System.DateTime]::UtcNow }
    )

    $currentUtcDateTime = & $DI_getSystemUtcDateTime

    $major = $major
    $minor = $currentUtcDateTime.ToString("yy").PadLeft(2, "0")
    $build = $currentUtcDateTime.Month.ToString("000")
    $revision = $buildNumber.ToString("0000")
 
    $newVersion = [System.String]::Format("{0}.{1}.{2}.{3}", $major, $minor, $build, $revision)

    return $newVersion
}

function Set-AssemblyVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Position=0, Mandatory=$true)]
        [System.IO.FileInfo]$assemblyInfoFile,
        [Parameter(Position=1, Mandatory=$true)]
        [string]$newVersion
    )

    $fullyQualifiedAssemblyInfoPath = $assemblyInfoFile.FullName
    $assemblyVersionRegex = Get-AssemblyVersionRegexString
    $assemblyFileVersionRegex = Get-AssemblyFileVersionRegexString
    $assemblyInformationalVersionRegex = Get-AssemblyInformationalVersionRegexString
 
    write-verbose ("New version is [" + $newVersion + "].")
 
    write-verbose ("Replacing AssemblyVersion in [" + $fullyQualifiedAssemblyInfoPath + "] with new version.")
    $replacement = '$1"' + $newVersion + "`$4"

    $fileContent = (get-content $fullyQualifiedAssemblyInfoPath) |
        foreach {
            if ($_ -match $assemblyVersionRegex) { $_ -replace $assemblyVersionRegex, $replacement }
            elseif ($_ -match $assemblyFileVersionRegex) { $_ -replace $assemblyFileVersionRegex, $replacement }
            elseif ($_ -match $assemblyInformationalVersionRegex) { $_ -replace $assemblyInformationalVersionRegex, $replacement }
            else { $_ }
        } |
    set-content $fullyQualifiedAssemblyInfoPath

    return $newVersion
}

function Get-AssemblyVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.IO.FileInfo]$assemblyInfoFile
    )

    $fullyQualifiedAssemblyInfoPath = $assemblyInfoFile.FullName
    $assemblyVersionRegex = Get-AssemblyVersionRegexString

    try
    {
        $existingVersion = (select-string -Path "$fullyQualifiedAssemblyInfoPath" -Pattern $assemblyVersionRegex).Matches[0].Groups[3].Value
    }
    catch
    {
        throw new-object Exception("Unable to determine old version from file [$fullyQualifiedAssemblyInfoPath]. Check to make sure there is a line that matches [$assemblyVersionRegex].", $_.Exception)
    }

    return $existingVersion
}
