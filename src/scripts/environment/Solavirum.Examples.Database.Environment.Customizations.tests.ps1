$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -ireplace "tests.", ""
. "$here\$sut"

. "$currentDirectoryPath\_Find-RootDirectory.ps1"
$rootDirectory = Find-RootDirectory $here

. "$($rootDirectory.FullName)\scripts\common\Functions-Credentials.ps1"

function Get-ScratchDatabaseCredentials
{
    $endpointLookup = "POSTGRESQL_SCRATCH_DATABASE_ENDPOINT"
    $usernameLookup = "POSTGRESQL_SCRATCH_DATABASE_USERNAME"
    $passwordLookup = "POSTGRESQL_SCRATCH_DATABASE_PASSWORD"

    $creds = @{
        Endpoint = (Get-CredentialByKey $endpointLookup);
        Username = (Get-CredentialByKey $usernameLookup);
        Password = (Get-CredentialByKey $passwordLookup);
    }
    return New-Object PSObject -Property $creds
}

Describe "Solavirum.Examples.Database.Environment.Customisations" -Tags @("RequiresCredentials") {
    Context "Test-DatabaseConnection" {
        It "Correctly returns true when a connection can be established to the specified PostgreSQL database" {
            $creds = Get-ScratchDatabaseCredentials

            $result = Test-DatabaseConnection -Endpoint $creds.Endpoint -Username $creds.Username -Password $creds.Password

            $result | Should Be $true
        }
    }

    Context "Test-ExampleDatabase" {
        It "Connects to all databases specified and returns a true if all connections were successful" {
            $creds = Get-ScratchDatabaseCredentials

            $database = @{Endpoint=$creds.Endpoint;Username=$creds.Username;Password=$creds.Password;}
            $result = Test-ExampleDatabase @($database, $database)

            $result | Should Be $true
        }

        It "Throws an exception if all databases could not be connected to within the timeout period" {
            $creds = Get-ScratchDatabaseCredentials

            $database = @{Endpoint="This endpoint does not exist";Username=$creds.Username;Password=$creds.Password;}
            try
            {
                Test-ExampleDatabase @($database) -TimeoutSeconds 4 -IncrementSeconds 2
            }
            catch
            {
                $ex = $_.Exception
            }

            $ex | Should Not Be $null
        }
    }
}