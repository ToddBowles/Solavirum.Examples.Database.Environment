function _GetUniqueComponentIdentifier
{
    return "ExampleDatabase"
}

function _GetTemplateFile
{
    return "$($rootDirectory.FullName)\template\Solavirum.Examples.Database.Environment.template"
}

function _CustomiseEnvironmentDetailsHashtable
{
    param
    (
        [hashtable]$environmentDetailsHashtableToMutate,
        $stack
    )

    $environmentDetailsHashtableToMutate["MasterDatabaseEndpointWithPort"] = ($stack.Outputs | Where-Object { $_.OutputKey -eq "MasterDatabaseEndpointWithPort" } | Single).OutputValue
}

function Test-ExampleDatabase
{
    [CmdletBinding()]
    param
    (
        [array]$databases,
        [int]$timeoutSeconds=900,
        [int]$incrementSeconds=60
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Waiting.ps1"
    $waitParameters = @{
        ScriptToFillActualValue={ $databases | foreach { Test-DatabaseConnection -Endpoint $_.Endpoint -Username $_.Username -Password $_.Password } };
        Condition={ $actual | All -Predicate { $_ -eq $true } };
        TimeoutSeconds=$timeoutSeconds;
        IncrementSeconds=$incrementSeconds;
    }
    $result = Wait @waitParameters

    return $result
}

function Test-DatabaseConnection
{
    [CmdletBinding()]
    param
    (
        [string]$endpoint,
        [string]$username,
        [string]$password
    )

    Ensure-NpgsqlAvailable

    $split = $endpoint.Split(",")
    $conn = new-object Npgsql.NpgsqlConnection("Server=$($split[0]);Port=$($split[1]);User Id=$username;Password=$password;Database=postgres;")
    try
    {
        $conn.Open();
        $conn.Close();
        return $true
    }
    catch
    {
        Write-Warning "A failed attempting was made to connect to a PostgreSQL database at [$endpoint]"
        Write-Warning $_
        return $false
    }
}

function Ensure-NpgsqlAvailable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"
    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"
    . "$commonScriptsDirectoryPath\Functions-Nuget.ps1"

    $toolsDirectoryPath = "$rootDirectoryPath\tools"

    $nugetPackagesDirectoryPath = "$toolsDirectoryPath\packages"

    $packageId = "Npgsql"
    $version = "3.0.5"
    $expectedDirectoryPath = "$nugetPackagesDirectoryPath\$packageId.$version"
    $expectedDirectory = Nuget-EnsurePackageAvailable -Package $packageId -Version $version

    Write-Verbose "Loading Npgsql Libraries"
    Add-Type -Path "$expectedDirectory\lib\net45\Npgsql.dll" | Write-Verbose
    Write-Verbose "Npgsql Libraries loaded"
}