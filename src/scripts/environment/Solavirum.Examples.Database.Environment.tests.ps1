$here = Split-Path -Parent $MyInvocation.MyCommand.Path

. "$currentDirectoryPath\_Find-RootDirectory.ps1"
$rootDirectory = Find-RootDirectory $here

. "$($rootDirectory.FullName)\scripts\common\Functions-Credentials.ps1"

function Create-UniqueEnvironmentName
{
    $currentUtcDateTime = [DateTime]::UtcNow
    $a = $currentUtcDateTime.ToString("yy") + $currentUtcDateTime.DayOfYear.ToString("000")
    $b = ([int](([int]$currentUtcDateTime.Subtract($currentUtcDateTime.Date).TotalSeconds) / 2)).ToString("00000")
    return "T$a$b"
}

function Get-AwsCredentials
{
    $keyLookup = "ENVIRONMENT_AWS_KEY"
    $secretLookup = "ENVIRONMENT_AWS_SECRET"

    $awsCreds = @{
        AwsKey = (Get-CredentialByKey $keyLookup);
        AwsSecret = (Get-CredentialByKey $secretLookup);
    }
    return New-Object PSObject -Property $awsCreds
}

function Get-OctopusCredentials
{
    $keyLookup = "ENVIRONMENT_OCTOPUS_API_KEY"
    $urlLookup = "ENVIRONMENT_OCTOPUS_URL"

    $creds = @{
        ApiKey = (Get-CredentialByKey $keyLookup);
        Url = (Get-CredentialByKey $urlLookup);
    }
    return New-Object PSObject -Property $creds
}

Describe "Invoke-NewEnvironment" {
    Context "When executed with appropriate parameters" {
        It "The environment is created without encountering any errors" {
            $creds = Get-AWSCredentials
            $octopusCreds = Get-OctopusCredentials
            $environmentName = Create-UniqueEnvironmentName
            $password = [Guid]::NewGuid().ToString("N")

            $EnvironmentParameterOverrides = @{
                "RdsDatabaseMasterUsernamePassword"="$password";
            }

            try
            {
                $newEnvironmentParameters = @{
                    EnvironmentName=$environmentName;
                    ResultAsJson=$false;
                    AwsKey=$creds.AwsKey;
                    AwsSecret=$creds.AwsSecret;
                    OctopusApiKey=$octopusCreds.ApiKey;
                    OctopusServerUrl=$octopusCreds.Url;
                    disableCleanupOnFailure=$true;
                    EnvironmentParameterOverrides=$EnvironmentParameterOverrides;
                }
                $environmentCreationResult = & "$here\Invoke-NewEnvironment.ps1" @newEnvironmentParameters

                Write-Verbose (ConvertTo-Json $environmentCreationResult)
            }
            finally
            {
                & "$here\Invoke-DeleteEnvironment.ps1" -EnvironmentName $environmentName -AwsKey $creds.AwsKey -AwsSecret $creds.AwsSecret -OctopusApiKey $octopusCreds.ApiKey -OctopusServerUrl $octopusCreds.Url
            }
        }
    }
}