function Get-KnownEnvironments
{
    return @("CI", "Staging", "Production")
}

function IsEnvironmentKnown
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$environmentName
    )


    $knownEnvironments = Get-KnownEnvironments
    return $knownEnvironments.Contains($environmentName)
}

function Get-StackName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$environment,
        [Parameter(Mandatory=$true)]
        [string]$uniqueComponentIdentifier
    )
    
    return "$uniqueComponentIdentifier-$environment"
}

$dependenciesS3BucketNameParametersKey = "DependenciesS3Bucket"
$defaultDependenciesS3BucketName = "solavirum.cloudformation.scratch"

$internalServicesHostRootParametersKey = "InternalServicesHostRoot"
$defaultInternalServicesHostRoot = "internal.solavirum.com"

$octopusMachineCorrelationIdParameterKey = "OctopusMachineCorrelationId"

$environmentVersionParameterKey = "EnvironmentVersion"

$teamParametersKey = "team"

function New-Environment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
		[Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
		[Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$uniqueComponentIdentifier,
        [System.IO.FileInfo]$templateFile,
        [hashtable]$additionalTemplateParameters,
        [scriptblock]$customiseEnvironmentDetailsHashtable={param([hashtable]$environmentDetailsHashtableToMutate,$stack) },
        [switch]$wait,
        [switch]$disableCleanupOnFailure,
        [scriptblock]$smokeTest
    )

    try
    {
        write-verbose "Creating New Environment $environmentName"

        if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
        $rootDirectoryPath = $rootDirectory.FullName
        $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

        $octopusEnvironment = _EnsureOctopusEnvironmentExists

        . "$commonScriptsDirectoryPath\Functions-Aws.ps1"
        Ensure-AwsPowershellFunctionsAvailable

        $stackName = Get-StackName $environmentName $uniqueComponentIdentifier

        . "$commonScriptsDirectoryPath\Functions-Hashtables.ps1"
        $dependenciesS3Bucket = Try-Get -Hashtable $additionalTemplateParameters -Key $dependenciesS3BucketNameParametersKey -Default $defaultDependenciesS3BucketName

        $user = (& whoami).Replace("\", "_")
        $date = [DateTime]::Now.ToString("yyyyMMddHHmmss")
        $buildIdentifier = "$user-$date" # Change this to a git commit or tag or something so we can track it later.

        $workingDirectoryPath = "$rootDirectoryPath\script-working\$buildIdentifier"

        . "$commonScriptsDirectoryPath\Functions-FileSystem.ps1"
        $workingDirectory = Ensure-DirectoryExists $workingDirectoryPath

        $dependenciesArchiveUrl = _CollectAndUploadDependencies -dependenciesS3BucketName $dependenciesS3Bucket -stackName $stackName -buildIdentifier $buildIdentifier -workingDirectoryPath $workingDirectoryPath

        $amiSearchRoot = "Windows_Server-2012-R2_RTM-English-64Bit-Core"
        $filter_name = New-Object Amazon.EC2.Model.Filter -Property @{Name = "name"; Value = "$amiSearchRoot*OTH-Octopus*"}
        $ec2ImageDetails = Get-EC2Image -Filter $filter_name  -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion | 
            Sort-Object Name -Descending | 
            Select-Object -first 1

        $octopusAmi = $ec2ImageDetails.ImageId

        $filter_name = New-Object Amazon.EC2.Model.Filter -Property @{Name = "name"; Value = "$amiSearchRoot*OTH-DotNetWebServer*"}
        $ec2ImageDetails = Get-EC2Image -Filter $filter_name  -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion | 
            Sort-Object Name -Descending | 
            Select-Object -first 1

        $dotNetWebServerAmi = $ec2ImageDetails.ImageId

        $adminPassword = _GeneratePassword -length 30
        Write-Verbose "Admin password auto generated to [$adminPassword]. May be overriden by supplied password."

        $proxyEnvironment = "ci"
        if (IsEnvironmentKnown $environmentName) { $proxyEnvironment = $environmentName }

        $internalServicesHostRoot = Try-Get -Hashtable $additionalTemplateParameters -Key $internalServicesHostRootParametersKey -Default $defaultInternalServicesHostRoot
        $proxy = "http://$proxyEnvironment-proxy-squid.$($internalServicesHostRoot):3128"

        # The environment type strings (exactly as is) are used inside templates to select . Don't change them.
        $defaultEnvironmenType = "other"
        $defaultShutdownOutsideBusinessHours = $true
        if ($environmentName -match "prod")
        {
            $defaultEnvironmenType = "production"
            $defaultShutdownOutsideBusinessHours = $false
        }

        $defaultParameters = @{
            "AdminPassword"=$adminPassword;
            "DependenciesS3BucketAccessKey"="$awsKey";
            "DependenciesS3BucketSecretKey"="$awsSecret";
            "DependenciesS3Bucket"=$dependenciesS3Bucket;
            "DependenciesArchiveS3Url"=$dependenciesArchiveUrl;
            "ProxyUrlAndPort"=$proxy;
            "OctopusEnvironment"="$environmentName";
            "OctopusServerURL"=$octopusServerUrl;
            "OctopusAPIKey"=$octopusApiKey;
            "OctopusAmiId"=$octopusAmi;
            "DotNetWebServerAmiId"=$dotNetWebServerAmi;
            "CurrentEnvironmentStatus"="creating";
            "ShutdownOutsideBusinessHours"=$defaultShutdownOutsideBusinessHours;
            $teamParametersKey="solavirum";
            "ComponentName"=$uniqueComponentIdentifier;
            "$octopusMachineCorrelationIdParameterKey"=[Guid]::NewGuid().ToString("N");
            "$internalServicesHostRootParametersKey"=$internalServicesHostRoot;
            "EnvironmentType"=$defaultEnvironmenType;
        }

        $parameters = Merge-Hashtables $defaultParameters $additionalTemplateParameters
        
        # It appears to be impossible to use ConvertFrom-StringData to create a hashtable with strongly typed
        # values. ConvertFrom-StringData is used to provide the environment parameter overrides in TeamCity,
        # so we need to check to make sure that it is actually a boolean.
        Write-Verbose "Ensuring that the 'ShutdownOutsideBusinessHours' parameter is actually a boolean."
        if ($parameters["ShutdownOutsideBusinessHours"].GetType() -ne [bool])
        {
            $parameters["ShutdownOutsideBusinessHours"] = [bool]::Parse($parameters["ShutdownOutsideBusinessHours"])
        }

        . "$commonScriptsDirectoryPath\Functions-Aws-CloudFormation.ps1"

        $environmentDetailsHashtable = @{}
        $environmentDetailsHashtable.Add("StackId", $null)
        $environmentDetailsHashtable.Add("Stack", $null)
        $environmentDetailsHashtable.Add("AdminPassword", $parameters["AdminPassword"])

        $tags = @()
        $tags += _MakeTag -Key "OctopusEnvironment" -Value $environmentName

        # New tags for integration into new Prod AWS account. Some overlap with existing tags (above) maintained for
        # backwards compatibility.
        $tags += _MakeTag -Key "environment" -Value $environmentName
        $tags += _MakeTag -Key "service" -Value $uniqueComponentIdentifier
        $tags += _MakeTag -Key "team" -Value $parameters[$teamParametersKey]

        $unspecifiedVersion = "UNSPECIFIED"
        $environmentVersion = Try-Get -Hashtable $parameters -Key $environmentVersionParameterKey -Default $unspecifiedVersion
        if ($environmentVersion -eq $unspecifiedVersion)
        {
            . "$rootDirectoryPath\scripts\common\Functions-Versioning.ps1"
            $environmentVersion = _GetVersion_AutomaticIncrementBasedOnCurrentUtcTimestamp -Major 0 -Minor 0

            Write-Warning "No environment version has been specified via the Parameter with key [$environmentVersionParameterKey]. This is allowed for backwards compatibility, but versions should be applied to environments just like they are applied to software"
            Write-Warning "Environment Version has been automatically set to [$environmentVersion]"

            $parameters[$environmentVersionParameterKey] = $environmentVersion
        }

        $tags += _MakeTag -Key "version" -Value $parameters[$environmentVersionParameterKey]

        if ($parameters["ShutdownOutsideBusinessHours"])
        {
            Write-Warning "This environment has been flagged to automatically shutdown outside business hours (through the 'ShutdownOutsideBusinessHours' parameter). This occurs by default for environments that do not contain the term 'prod'."
            Write-Verbose "Tagging environment with auto:start and auto:stop tags for business hours operation only."
            # These two tags are not standard cron time formats because CloudFormation
            # doesnt like the * character in its tags. The script that does the time
            # based start/stop will replace the string 'ALL' with '*' when it reads the
            # tags.
            $autoStartTag = new-object Amazon.CloudFormation.Model.Tag
            $autoStartTag.Key = "auto:start"
            $autoStartTag.Value = "0 8 ALL ALL 1-5"
            $tags += $autoStartTag

            $autoStopTag = new-object Amazon.CloudFormation.Model.Tag
            $autoStopTag.Key = "auto:stop"
            $autoStopTag.Value = "0 19 ALL ALL 1-5"
            $tags += $autoStopTag
        }

        $templateSubstitutions = @{
            "@@CMD_PROXY_SETTER_COMMANDS"=(Generate-CmdProxySetterCommands -Proxy $proxy);
            "@@POWERSHELL_PROXY_SETTER_COMMANDS"=(Generate-PowershellProxySetterCommands -Proxy $proxy);
        }

        $modifiedTemplate = New-Item -ItemType File -Path "$workingDirectoryPath\$($templateFile.Name)"

        . "$commonScriptsDirectoryPath\Functions-Configuration.ps1"
        $modifiedTemplate = ReplaceTokensInFile -Source $templateFile -Destination $modifiedTemplate -Substitutions $templateSubstitutions

        $templateS3Url = _UploadTemplate -dependenciesS3BucketName $dependenciesS3Bucket -stackName $stackName -buildIdentifier $buildIdentifier -templateFilePath $modifiedTemplate.FullName

        write-verbose "Creating stack [$stackName] using template at [$($templateFile.FullName)]."
        $stackId = New-CFNStack -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion -StackName "$stackName" -TemplateUrl $templateS3Url -Parameters (Convert-HashTableToAWSCloudFormationParametersArray $parameters) -DisableRollback:$true -Tags $tags -Capabilities CAPABILITY_IAM
        $environmentDetailsHashtable["StackId"] = $stackId

        if ($wait)
        {
            $desiredStatus = [Amazon.CloudFormation.StackStatus]::CREATE_COMPLETE

            Wait-Environment -environmentDetailsHashtableToMutate $environmentDetailsHashtable -desiredStatus $desiredStatus -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion
            $stack = $environmentDetailsHashtable["Stack"]

            if ($stack.StackStatus -eq $desiredStatus)
            {
                Write-Verbose "Updating the stack to signal that it is in the running state (to indicate that initial creation has been completed)."
                $parameters["CurrentEnvironmentStatus"] = "running"
                $stackId = Update-CFNStack -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion -StackName "$stackName" -TemplateUrl $templateS3Url -Parameters (Convert-HashTableToAWSCloudFormationParametersArray $parameters) -Capabilities CAPABILITY_IAM
                $desiredStatus = [Amazon.CloudFormation.StackStatus]::UPDATE_COMPLETE
                Wait-Environment -environmentDetailsHashtableToMutate $environmentDetailsHashtable -desiredStatus $desiredStatus -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion
                $stack = $environmentDetailsHashtable["Stack"]
            }

            if (-not ($stack.StackStatus -eq $desiredStatus))
            {
                $errorMessage = "Stack creation for [$stackId] failed."
                if ($disableCleanupOnFailure)
                {
                    $errorMessage += " [Parameter: -DisableCleanupOnFailure] was set to [$disableCleanupOnFailure] so you can investigate the stack manually. The thrown exception might have more information in it as well."
                }
                else
                {
                    $errorMessage += " [Parameter: -DisableCleanupOnFailure] was set to [$disableCleanupOnFailure] so you've only got the output from the script execution to go on. Sorry."
                }
                throw $errorMessage
            } 

            . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

            & $customiseEnvironmentDetailsHashtable -EnvironmentDetailsHashtableToMutate $environmentDetailsHashtable -Stack $stack
        }

        $result = new-object PSObject $environmentDetailsHashtable

        if ($smokeTest -ne $null)
        {
            try
            {
                Write-Verbose "A smoke test for the newly created environment has been specified. It will now be evaluated, supplying the environment creation result."
                $smokeTestResult = & $smokeTest $result
                $environmentDetailsHashtable.Add("SmokeTestResult", $smokeTestResult)

                $result = new-object PSObject $environmentDetailsHashtable
            }
            catch
            {
                throw new-object Exception("An error occurred while evaluating the smoke test [$smokeTest]. The environment creation will be considered a failure and automatically cleaned up (assuming the option is enabled)", $_.Exception)
            }
        }

        return $result
    }
    catch
    {
        try
        {
            if ($stackId -ne $null)
            {
                Write-Warning "An error occurred at some stage during environment creation. Attempting to gather additional information."
                $failingStackEvents = _TryGetFailingStackEvents -StackId $stackId -awsKey $awsKey -awsSecret $awsSecret -awsRegion $awsRegion
                $cfnInitFailureLogs = _TryExtractLogFilesFromInstanceFailingViaCfnInit -failingStackEvents $failingStackEvents -adminPassword $adminPassword -awsKey $awsKey -awsSecret $awsSecret -awsRegion $awsRegion
                $customError = @{
                    "StackId"=$stackId;
                    "Stack"=$stack;
                    "FailingStackEvents"=$failingStackEvents;
                    "CfnInitFailingInstanceLogs"=$cfnInitFailureLogs;
                }

                $failingDetails = new-object PSObject $customError
                Write-Warning (ConvertTo-Json $failingDetails)
            }
        }
        catch 
        {
            Write-Warning "An error occurred while attempting to extract more information about the environment setup failure."
            Write-Warning $_
        }

        if (!$disableCleanupOnFailure)
        {
            Write-Warning "A failure occurred and DisableCleanupOnFailure flag was set to false. Cleaning up."
            Delete-Environment -environmentName $environmentName -uniqueComponentIdentifier $uniqueComponentIdentifier -Wait -awsKey $awsKey -awsSecret $awsSecret -awsRegion $awsRegion -octopusServerUrl $octopusServerUrl -octopusApiKey $octopusApiKey
        }

        throw $_
    }
}

function Generate-PowershellProxySetterCommands
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        $proxy
    )

    $commands = @()
    $commands += '$env:HTTP_PROXY = \"' + $proxy + '\"'
    $commands += '$env:HTTPS_PROXY = \"' + $proxy + '\"'
    $commands += '$env:NO_PROXY = \"169.254.169.254\"'

    return [String]::Join('\r\n', $commands) + '\r\n'
}

function Generate-CmdProxySetterCommands
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        $proxy
    )

    $commands = @()
    $commands += 'netsh winhttp set proxy proxy-server=' + $proxy + ' bypass-list=\"169.254.169.254\"'
    $commands += 'SET HTTP_PROXY=' + $proxy
    $commands += 'SET HTTPS_PROXY=' + $proxy
    $commands += 'SET NO_PROXY=169.254.169.254'
    $commands += 'SETX HTTP_PROXY ' + $proxy + ' /M'
    $commands += 'SETX HTTPS_PROXY ' + $proxy + ' /M'
    $commands += 'SETX NO_PROXY 169.254.169.254' + ' /M'

    return [String]::Join('\r\n', $commands) + '\r\n'
}

function _MakeTag
{
    param
    (
        [string]$key,
        [string]$value
    )

    $tag = new-object Amazon.CloudFormation.Model.Tag
    $tag.Key = $key
    $tag.Value = $value

    return $tag
}

function _TryExtractLogFilesFromInstanceFailingViaCfnInit
{
    param
    (
        $failingStackEvents,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$adminPassword
    )

    if ($failingStackEvents -eq $null) { return "No events were supplied, could not determine if anything failed as a result of CFN-INIT failure" }

    try
    {
        if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
        $rootDirectoryPath = $rootDirectory.FullName
        $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

        $cfnInitFailedIndicator = "CFN-INIT-FAILED"
        Write-Verbose "Attempting to identify and extract information from failure events containing the string [$cfnInitFailedIndicator]"
        $instanceIdRegexExtractor = "(i\-[0-9a-zA-Z]+)"
        $cfnFailureEvent = $failingStackEvents | 
            Where {$_.ResourceStatusReason -match $cfnInitFailedIndicator} | 
            Select -First 1

        if ($cfnFailureEvent.ResourceStatusReason -match $instanceIdRegexExtractor)
        {
            $instanceId = $matches[0];
            Write-Verbose "Found a failure event for instance [$instanceId]"
            Write-Verbose "Attempting to extract some information from the logs from that machine"

            . "$commonScriptsDirectoryPath\Functions-Aws-Ec2.ps1"

            $instance = Get-AwsEc2Instance -InstanceId $instanceId -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion

            $ipAddress = $instance.PrivateIpAddress

            $remoteUser = "Administrator"
            $remotePassword = $adminPassword
            $securePassword = ConvertTo-SecureString $remotePassword -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($remoteUser, $securePassword)
            $session = New-PSSession -ComputerName $ipAddress -Credential $cred
    
            $remoteScript = {
                $lines = 200
                $cfnInitLogPath = "C:\cfn\log\cfn-init.log"
                Write-Output "------------------------------------------------------"
                Write-Output "Last [$lines] from $file"
                Get-Content $cfnInitLogPath -Tail $lines
                Write-Output "------------------------------------------------------"
                #Get-Content C:\Program Files
            }
            $remotelyExtractedData = Invoke-Command -Session $session -ScriptBlock $remoteScript
            # If you dont do this when you do a JSON convert later it spits out a whole bunch of useless
            # information about the machine the line was extracted from, files, etc.
            $remotelyExtractedData = $remotelyExtractedData | foreach { $_.ToString() }
            
            return $remotelyExtractedData
        }
        else
        {
            Write-Verbose "Could not find a failure event about CFN-INIT failing"
            return "No events failed with a reason containing the string [$cfnInitFailedIndicator]"
        }
    }
    catch
    {
        Write-Warning "An error occurred while attempting to gather more information about an environment setup failure"
        Write-Warning $_       
    }
}

function _TryGetFailingStackEvents
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$stackId,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion
    )

    try
    {
        if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
        $rootDirectoryPath = $rootDirectory.FullName
        $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"
        
        . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

        $events = Get-CFNStackEvent -StackName $stackId -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion
        $failingEvents = @($events | Where { $_.ResourceStatus.Value -match "FAILED" })
        if ($failingEvents | Any -Predicate { $true })
        {
            return $failingEvents
        }
        else
        {
            return @()
        }
    }
    catch
    {
        Write-Warning "Could not get events for stack [$stackId]."
        Write-Warning $_
    }
}

function Wait-Environment
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [hashtable]$environmentDetailsHashtableToMutate,
        [Amazon.CloudFormation.StackStatus]$desiredStatus
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $scriptFileLocation = Split-Path $script:MyInvocation.MyCommand.Path
    write-verbose "Script is located at [$scriptFileLocation]."

    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Aws-CloudFormation.ps1"

    $stackId = $environmentDetailsHashtableToMutate["StackId"]
    $failingStates = @([Amazon.CloudFormation.StackStatus]::CREATE_FAILED, [Amazon.CloudFormation.StackStatus]::UPDATE_FAILED, [Amazon.CloudFormation.StackStatus]::UPDATE_ROLLBACK_COMPLETE, [Amazon.CloudFormation.StackStatus]::DELETE_FAILED)
    $stack = Wait-CloudFormationStack -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion -StackName "$stackId" -DesiredStatus $desiredStatus -FailingStates $failingStates
    $environmentDetailsHashtableToMutate["Stack"] = $stack
}

function Delete-Environment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
		[Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
		[Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusServerUrl,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$uniqueComponentIdentifier,
        [switch]$wait
    )
    
    $stackName = Get-StackName $environmentName $uniqueComponentIdentifier

    Write-Verbose "Deleting Environment [$stackName]."

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    try
    {
        $environment = Get-Environment -environmentName $environmentName -uniqueComponentIdentifier $uniqueComponentIdentifier -awsKey $awsKey -awsSecret $awsSecret -awsRegion $awsRegion
    }
    catch
    {
        Write-Warning "An error occurred while attempting to get the environment to be deleted."
        Write-Warning $_
    }

    . "$commonScriptsDirectoryPath\Functions-OctopusDeploy.ps1"

    Write-Verbose "Cleaning up Octopus environment [$environmentName]"
    $role = $stackName
    if ($environment -ne $null)
    {
        Write-Verbose "Retrieving the Octopus machine correlation ID using parameter key [$octopusMachineCorrelationIdParameterKey] in order to delete Octopus machines"
        try
        {
            . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"
            $role = ($environment.Stack.Parameters | Single -Predicate { $_.ParameterKey -eq $octopusMachineCorrelationIdParameterKey }).Value
            
            $machines = Get-OctopusMachinesByRole -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -Role $role
            $machines | ForEach-Object { $deletedMachine = Delete-OctopusMachine -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -MachineId $_.Id }
        }
        catch
        {
            Write-Warning "Octopus machine correlation ID could not be determined by searching for key [$octopusMachineCorrelationIdParameterKey] in CloudFormation Stack Parameters. It is likely a legacy environment. Machines belonging to this environment will need to be manually cleaned up"
        }
    }

    if (-not (IsEnvironmentKnown $environmentName))
    {
        try
        {
            $octopusEnvironment = Get-OctopusEnvironmentByName -EnvironmentName $environmentName -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey
            if ($octopusEnvironment -ne $null)
            {
                $deletedEnvironment = Delete-OctopusEnvironment -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -EnvironmentId $octopusEnvironment.Id
            }
        }
        catch 
        {
            Write-Warning "Octopus Environment [$environmentName] could not be deleted"
            Write-Warning $_
        }
    }

    . "$commonScriptsDirectoryPath\Functions-Aws.ps1"
    Ensure-AwsPowershellFunctionsAvailable

    . "$commonScriptsDirectoryPath\Functions-Aws-S3.ps1"

    # Because CloudFormation is crap at managing buckets (it can't delete buckets with content) we have to delete them here.
    try
    {
        if ($environment -ne $null)
        {
            $resources = Get-CFNStackResources -StackName $environment.StackId -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion
            $s3buckets = $resources | Where { $_.ResourceType -eq "AWS::S3::Bucket" }
            foreach ($s3Bucket in $s3Buckets)
            {
                try
                {
                    $bucketName = $s3Bucket.PhysicalResourceId
                    _RemoveBucket -bucketName $bucketName -awsKey $awsKey -awsSecret $awsSecret -awsRegion $awsRegion
                }
                catch
                {
                    Write-Warning "Error occurred while trying to delete bucket [$bucketName] prior to stack destruction."
                    Write-Warning $_
                }
            }
        }
    }
    catch
    {
        Write-Warning "Error occurred while attempting to get S3 buckets to delete from the CloudFormation stack."
        Write-Warning $_
    }

    try
    {
        . "$commonScriptsDirectoryPath\Functions-Aws-CloudFormation.ps1"
        Remove-CFNStack -StackName "$stackName" -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion -Force
    }
    catch
    {
        Write-Warning "Error occurred while trying to delete CFN stack for environment [$environmentName]."
        Write-Warning $_
    }

    if ($wait)
    {
        try
        {
            $failureStates = @([Amazon.CloudFormation.StackStatus]::DELETE_FAILED)
            $stack = Wait-CloudFormationStack -StackName "$stackName" -DesiredStatus ([Amazon.CloudFormation.StackStatus]::DELETE_COMPLETE) -FailingStates $failureStates -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion
        }
        catch
        {
            if (-not($_.Exception.Message -like "Stack*does not exist"))
            {
                throw
            }
        }
    }

    try
    {
        . "$commonScriptsDirectoryPath\Functions-Aws-S3.ps1"
        . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

        if ($environment -ne $null)
        {
            $parameter = $environment.Stack.Parameters | Single -Predicate { $_.ParameterKey -eq $dependenciesS3BucketNameParametersKey }
            RemoveFilesFromS3ByPrefix -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion -AwsBucket $parameter.ParameterValue -Prefix $stackName -Force
        }
        else
        {
            Write-Warning "Could not remove files for environment [$environmentName] from S3. The location of the dependencies files could not be found."
        }
    }
    catch
    {
        Write-Warning "Error occurred while trying to remove files for environment [$environmentName] from S3."
        Write-Warning $_
    }
}

function _RemoveBucket
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$bucketName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion
    )

    Write-Verbose "Removing bucket [$bucketName] outside stack teardown to prevent issues with bucket deletion (involving writing to the bucket after its cleared but before its deleted, which prevents its deletion)."
    try
    {
        if (Exist-S3Bucket -BucketName $bucketName -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion)
        {
            Remove-S3Bucket -BucketName $bucketName -AccessKey $awskey -SecretKey $awsSecret -Region $awsRegion -DeleteObjects -Force
        }
        else
        {
            Write-Warning "The bucket [$bucketName] could not be removed because it does not exist."
        }
    }
    catch 
    {
        Write-Warning "Bucket [$bucketName] could not be removed."
        Write-Warning $_
    }
}

function Get-Environment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
		[Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$uniqueComponentIdentifier,
        [scriptblock]$customiseEnvironmentDetailsHashtable={param([hashtable]$environmentDetailsHashtableToMutate,$stack) }
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Aws.ps1"
    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

    Ensure-AwsPowershellFunctionsAvailable

    $stackName = Get-StackName $environmentName $uniqueComponentIdentifier

    $stack = Get-CFNStack -AccessKey $awsKey -SecretKey $awsSecret -StackName $stackName -Region $awsRegion

    $resultHash = @{}
    $resultHash.Add("StackId", $stack.StackId)
    $resultHash.Add("Stack", $stack)

    & $customiseEnvironmentDetailsHashtable -EnvironmentDetailsHashtableToMutate $resultHash -Stack $stack

    $result = new-object PSObject $resultHash

    return $result
}

# Assumes that there are variables in scope containing AWS credentials.
function _CollectAndUploadDependencies
{
    param
    (
        [string]$dependenciesS3BucketName,
        [string]$stackName,
        [string]$buildIdentifier,
        [string]$workingDirectoryPath
    )

    Write-Verbose "Gathering environment setup dependencies into single zip archive for distribution to S3 for usage by CloudFormation."
    $directories = Get-ChildItem -Directory -Path $($rootDirectory.FullName) |
        Where-Object { $_.Name -like "scripts" -or $_.Name -like "tools" }

    $archive = "$workingDirectoryPath\dependencies.zip"

    . "$($rootDirectory.FullName)\scripts\common\Functions-Compression.ps1"

    $archive = 7Zip-ZipDirectories $directories $archive -SubdirectoriesToExclude @("script-working","test-working", "packages")
    $archive = 7Zip-ZipFiles "$($rootDirectory.FullName)\script-root-indicator" $archive -Additive

    Write-Verbose "Uploading dependencies archive to S3 for usage by CloudFormation."

    $dependenciesArchiveS3Key = "$stackName/$buildIdentifier/dependencies.zip"

    . "$($rootDirectory.FullName)\scripts\common\Functions-Aws-S3.ps1"

    $dependenciesArchiveS3Key = UploadFileToS3 -AwsBucket $dependenciesS3BucketName  -File $archive -S3FileKey $dependenciesArchiveS3Key -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion 

    return "https://s3-ap-southeast-2.amazonaws.com/$dependenciesS3BucketName/$dependenciesArchiveS3Key"
}

# Assumes that there are variables in scope containing AWS credentials.
function _UploadTemplate
{
    param
    (
        [string]$dependenciesS3BucketName,
        [string]$stackName,
        [string]$templateFilePath,
        [string]$buildIdentifier
    )

    $directories = Get-ChildItem -Directory -Path $($rootDirectory.FullName) |
        Where-Object { $_.Name -like "scripts" -or $_.Name -like "tools" }

    Write-Verbose "Uploading CloudFormation template to S3 for usage by CloudFormation." 
    $templateS3Key = "$stackName/$buildIdentifier/CloudFormation.template"

    . "$($rootDirectory.FullName)\scripts\common\Functions-Aws-S3.ps1"

    $templateS3Key = UploadFileToS3 -AwsBucket $dependenciesS3BucketName -File $templateFilePath -S3FileKey $templateS3Key -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion 

    return "https://s3-ap-southeast-2.amazonaws.com/$dependenciesS3BucketName/$templateS3Key"
}

function _GeneratePassword
{
    [CmdletBinding()]
    param
    (
        [int]$length=20
    )

    $sourceLetters = @()
    $sourceNumbers = @()

    # All upper and lower case characters.
    For ($a=65;$a 僕e 90;$a++) { $sourceLetters+=,[char][byte]$a }
    For ($a=97;$a 僕e 122;$a++) { $sourceLetters+=,[char][byte]$a }

    For ($a=48;$a 僕e 57;$a++) { $sourceNumbers+=,[char][byte]$a }

    for ($loop=1; $loop 僕e $length; $loop = $loop + 2) 
    {
        $password += ($sourceLetters | Get-Random)
        $password += ($sourceNumbers | Get-Random)
    }

    return $password
}

function _EnsureOctopusEnvironmentExists
{
    . "$commonScriptsDirectoryPath\Functions-OctopusDeploy.ps1"

    if (-not(IsEnvironmentKnown $environmentName))
    {
        write-warning "You have specified an environment [$environmentName] that is not in the list of known environments [$((Get-KnownEnvironments) -join ", ")]. The script will temporarily create an environment in Octopus, and then delete it at the end."

        try
        {
            $octopusEnvironment = New-OctopusEnvironment -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -EnvironmentName $environmentName -EnvironmentDescription "[SCRIPT] Environment automatically created because it did not already exist and the New-Environment Powershell function was being executed."
        }
        catch 
        {
            Write-Warning "Octopus Environment [$environmentName] could not be created."
            Write-Warning $_
        }
    }

    $octopusEnvironment = Get-OctopusEnvironmentByName -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -EnvironmentName $environmentName

    return $octopusEnvironment
}