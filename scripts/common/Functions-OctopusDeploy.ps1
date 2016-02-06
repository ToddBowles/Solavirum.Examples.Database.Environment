function Get-OctopusToolsExecutable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Nuget.ps1"

    $package = "OctopusTools"
    $version = "2.6.1.46"
    $expectedDirectory = Nuget-EnsurePackageAvailable -Package $package -Version $version

    $executable = new-object System.IO.FileInfo("$expectedDirectory\octo.exe")

    return $executable
}

function Ensure-OctopusClientClassesAvailable
{
    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"
    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"
        . "$commonScriptsDirectoryPath\Functions-Nuget.ps1"

    $toolsDirectoryPath = "$rootDirectoryPath\tools"

    $nugetPackagesDirectoryPath = "$toolsDirectoryPath\packages"

    $octoPackageId = "Octopus.Client"
    $octoVersion = "3.2.16"
    $expectedOctoDirectoryPath = "$nugetPackagesDirectoryPath\$octoPackageId.$octoVersion"
    $expectedOctoDirectory = Nuget-EnsurePackageAvailable -Package $octoPackageId -Version $octoVersion

    $newtonsoftJsonDirectory = Get-ChildItem -Path $nugetPackagesDirectoryPath -Directory | 
        Where-Object { $_.FullName -match "Newtonsoft\.Json\.(.*)" } | 
        Sort-Object { $_.FullName } -Descending |
        First

    Write-Verbose "Loading Octopus .NET Client Libraries."
    Add-Type -Path "$($newtonsoftJsonDirectory.FullName)\lib\net40\Newtonsoft.Json.dll" | Write-Verbose
    Add-Type -Path "$expectedOctoDirectoryPath\lib\net40\Octopus.Client.dll" | Write-Verbose
}

function _ExecuteOctopusWithArguments
{
    param
    (
        [string]$command,
        [array]$arguments
    )

    $executable = Get-OctopusToolsExecutable
    $executablePath = $executable.FullName

    (& "$executablePath" $arguments) | Write-Verbose
    $octoReturn = $LASTEXITCODE
    if ($octoReturn -ne 0)
    {
        $message = "Octopus Command [$command] failed (non-zero exit code). Exit code [$octoReturn]."
        throw $message
    }
}

function New-OctopusRelease
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$projectName,
        [string]$releaseNotes,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$version,
        [Parameter(Mandatory=$false)]
        [hashtable]$stepPackageVersions
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $command = "create-release"
    $arguments = @()
    $arguments += $command
    $arguments += "--project"
    $arguments += $projectName
    $arguments += "--server"
    $arguments += $octopusServerUrl
    $arguments += "--apiKey" 
    $arguments += $octopusApiKey
    if (![String]::IsNullOrEmpty($releaseNotes))
    {
        $arguments += "--releasenotes"
        $arguments += "`"$releaseNotes`""
    }
    if (![String]::IsNullOrEmpty($version))
    {
        $arguments += "--version"
        $arguments += $version
        $arguments += "--packageversion"
        $arguments += $version
    }

    if ($stepPackageVersions -ne $null) {
        foreach ($stepname in $stepPackageVersions.Keys) {
            $stepPackageVersion = $stepPackageVersions[$stepname]
            $arguments += "--package=${stepname}:$stepPackageVersion"
        }
    }

    _ExecuteOctopusWithArguments $command $arguments
}

function New-OctopusDeployment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$projectName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environment,
		[string]$version,
        [switch]$onlyCurrentMachine,
        [switch]$wait,
        [System.TimeSpan]$waitTimeout=[System.TimeSpan]::FromMinutes(10),
        [hashtable]$variables
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

	if ([String]::IsNullOrEmpty($version)) {
        Write-Verbose "No version for deployment specified. Getting last version of project [$projectName] deployed to environment [$environment]."
		$version = Get-LastReleaseToEnvironment -projectName $projectName -environmentName $environment -octopusServerUrl $octopusServerUrl -octopusApiKey $octopusApiKey
	}

    $command = "deploy-release"
    $arguments = @()
    $arguments += $command
    $arguments += "--project"
    $arguments += $projectName
    $arguments += "--server"
    $arguments += $octopusServerUrl
    $arguments += "--apiKey"
    $arguments += $octopusApiKey
    $arguments += "--version"
    $arguments += $version
    $arguments += "--deployTo"
    $arguments += "`"$environment`""

    if ($onlyCurrentMachine)
    {
        $arguments += "--specificmachines"

        $machineName = $env:COMPUTERNAME
        try
        {
            # This code gets the AWS instance name, because machines are registered with their AWS instance name now, instead of
            # just machine name (for tracking purposes inside Octopus) and it was hard to actually rename the machine.
            $response = Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/instance-id" -UseBasicParsing
            if ($response.StatusCode -eq 200) { $machineName = $response.Content }
        }
        catch { }

        $arguments+= $machineName
    }

    if ($wait)
    {
        $arguments += "--waitfordeployment"
        $arguments += "--deploymenttimeout=$waitTimeout"
    }

    if ($variables -ne $null)
    {
        $variables.Keys | ForEach-Object { $arguments += "--variable"; $arguments += "$($_):$($variables.Item($_))" }
    }

    try
    {
        _ExecuteOctopusWithArguments $command $arguments
    }
    catch
    {
        Write-Warning "Deployment of version [$version] of project [$projectName] to environment [$environment] failed."
        Write-Warning $_
        
        throw new-object Exception("Deploy [$environment] Failed", $_.Exception)
    }
}

function Get-OctopusProjectByName
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$projectName
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    write-verbose "Retrieving Octopus Projects."
    $result = $repository.Projects.FindByName($projectName)

    return $result
}

function Get-AllOctopusProjects
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    write-verbose "Retrieving Octopus Projects."
    $result = $repository.Projects.FindAll()

    return $result
}

function Get-LastReleaseToEnvironment
{
	[CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$projectName,
		[Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"
    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

    Ensure-OctopusClientClassesAvailable $octopusServerUrl $octopusApiKey

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl, $octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    $env = $repository.Environments.FindByName($environmentName)
    $project = $repository.Projects.FindByName($projectName)
    $deployments = $repository.Deployments.FindMany({ param($x) $x.EnvironmentId -eq $env.Id -and $x.ProjectId -eq $project.Id })

    if ($deployments | Any)
    {
        Write-Verbose "Deployments of project [$projectName] to environment [$environmentName] were found. Selecting the most recent successful deployment."
        $latestDeployment = $deployments |
            Sort -Descending -Property Created |
            First -Predicate { $repository.Tasks.Get($_.TaskId).FinishedSuccessfully -eq $true } -Default "latest"

        $release = $repository.Releases.Get($latestDeployment.ReleaseId)
    }
    else
    {
        Write-Verbose "No deployments of project [$projectName] to environment [$environmentName] were found."
    }

    $version = if ($release -eq $null) { "latest" } else { $release.Version }

    Write-Verbose "The version of the recent successful deployment of project [$projectName] to environment [$environmentName] was [$version]. 'latest' indicates no successful deployments, and will mean the very latest release version is used."

    return $version
}

function New-OctopusEnvironment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName,
        [string]$environmentDescription="[SCRIPT] Environment automatically created by Powershell script."
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    $properties = @{Name="$environmentName";Description=$environmentDescription}
 
    $environment = New-Object Octopus.Client.Model.EnvironmentResource -Property $properties

    write-verbose "Creating Octopus Environment with Name [$environmentName]."
    $result = $repository.Environments.Create($environment)

    return $result
}

function Get-OctopusEnvironmentByName
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    write-verbose "Retrieving Octopus Environment with Name [$environmentName]."
    $result = $repository.Environments.FindByName($environmentName)

    return $result
}

function Delete-OctopusEnvironment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentId
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    write-verbose "Deleting Octopus Environment with Id [$environmentId]."
    $result = $repository.Environments.Delete($repository.Environments.Get($environmentId))

    return $result
}

function Get-OctopusMachinesByRole
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$role
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    $machines = $repository.Machines.FindAll() | Where-Object { $_.Roles -contains $role }

    return $machines
}

function Get-OctopusMachinesByEnvironment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentId
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    $machines = $repository.Machines.FindAll() | Where-Object { $_.EnvironmentIds -contains $environmentId }

    return $machines
}

function Delete-OctopusMachine
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$machineId
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    Ensure-OctopusClientClassesAvailable

    $endpoint = new-object Octopus.Client.OctopusServerEndpoint $octopusServerUrl,$octopusApiKey
    $repository = new-object Octopus.Client.OctopusRepository $endpoint

    write-verbose "Deleting Octopus Machine with Id [$machineId]."
    $result = $repository.Machines.Delete($repository.Machines.Get($machineId))

    return $result
}