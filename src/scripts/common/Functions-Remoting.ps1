function Create-PSSession
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$computerName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$username,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$password
    )

    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($username, $securePassword)

    $session = New-PSSession -ComputerName $computerName -Credential $cred

    return $session
}

function Transfer-DirectoryToRemoteMachineViaS3Bucket
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [System.Management.Automation.Runspaces.PSSession]$session,
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [System.IO.DirectoryInfo]$directory,
        [scriptblock]$Filter= { $true },
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [string]$remoteDirectory,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$s3bucket,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
		[Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsRegion,
        [switch]$WhatIf
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $rootDirectoryDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryDirectoryPath\scripts\common"

    $user = (& whoami).Replace("\", "_")
    $date = [DateTime]::Now.ToString("yyyyMMddHHmmss")
    $tempS3RootKey = "$user.$date"

    . "$commonScriptsDirectoryPath\Functions-Aws-S3.ps1"

    $s3Files = @()
    $root = $directory.FullName
    $files = (Get-ChildItem -Recurse -Path "$($directory.FullName)" -File | Where -FilterScript $Filter)

    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"
    if (-not ($files | Any))
    {
        return
    }

    foreach ($file in $files)
    {
        $filePathBelowRoot = $file.FullName.Replace($root, '')
        $key = "$tempS3RootKey\$filePathBelowRoot"
        if ($WhatIf)
        {
            Write-Verbose "WhatIf: Would be uploading [$($file.FullName)] to bucket [$s3Bucket] using key [$key]"
        }
        else
        {
            $key = UploadFileToS3 -AwsBucket $s3bucket -File $file.FullName -S3FileKey $key -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion
        }

        $fileInfo = @{
            FilePathBelowRoot=$filePathBelowRoot;
            Key=$key;
            S3Path="https://s3-ap-southeast-2.amazonaws.com/$s3bucket/$key";
        }

        $s3Files += new-object PSObject $fileInfo
    }

    $remoteScript = {
        [CmdletBinding()]
        param
        (
            $s3Files,
            [string]$rootDirectory,
            [string]$s3Bucket,
            [string]$awsKey,
            [string]$awsSecret,
            [string]$awsRegion,
            [bool]$WhatIf
        )

        foreach ($s3File in $s3Files)
        {
            $localFilePath = "$rootDirectory\$($s3File.FilePathBelowRoot)"
            Write-Verbose "Downloading [$($s3File.S3Path)] to [$localFilePath]."

            if ($WhatIf)
            {
                Write-Output "WhatIf: Would be downloading key [$($s3File.Key)] from bucket [$s3Bucket] to [$localFilePath] here."
            }
            else
            {
                Read-S3Object -BucketName $s3Bucket -Key $s3File.Key -File $localFilePath -Region $awsRegion -AccessKey $awsKey -SecretKey $awsSecret
            }
        }
    }

    Write-Verbose "Remotely executing download of files via supplied session."
    Invoke-Command -Session $session -ScriptBlock $remoteScript -ArgumentList $s3Files, $remoteDirectory, $s3bucket, $awsKey, $awsSecret, $awsRegion, $WhatIf
}