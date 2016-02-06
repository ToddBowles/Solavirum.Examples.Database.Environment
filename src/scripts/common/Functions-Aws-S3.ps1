function UploadFileToS3
{
    param
    (
        [CmdletBinding()]
        [Parameter(Mandatory=$true)]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [string]$awsRegion,
        [Parameter(Mandatory=$true)]
        [string]$awsBucket,
        [Parameter(Mandatory=$true)]
        [System.IO.FileInfo]$file,
        [Parameter(Mandatory=$true)]
        [string]$S3FileKey
    )

    Write-Verbose "Uploading [$($file.FullName)] to [$($awsRegion):$($awsBucket):$S3FileKey]."
    (Write-S3Object -BucketName $awsBucket -Key $S3FileKey -File "$($file.FullName)" -Region $awsRegion -AccessKey $awsKey -SecretKey $awsSecret) | Write-Verbose

    return $S3FileKey
}

function DownloadFileFromS3ByKey
{
    param
    (
        [CmdletBinding()]
        [Parameter(Mandatory=$true)]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [string]$awsRegion,
        [Parameter(Mandatory=$true)]
        [string]$awsBucket,
        [Parameter(Mandatory=$true)]
        [string]$S3FileKey,
        [Parameter(Mandatory=$true)]
        [System.IO.FileInfo]$destination
    )

    if ($destination.Exists)
    {
        Write-Verbose "Destination for S3 download of [$S3FileKey] ([$($destination.FullName)]) already exists. Deleting."
        $destination.Delete()
    }

    Write-Verbose "Downloading [$($awsRegion):$($awsBucket):$S3FileKey] to [$($destinationFile.FullName)]."
    (Read-S3Object -BucketName $awsBucket -Key $S3FileKey -File "$($destination.FullName)" -Region $awsRegion -AccessKey $awsKey -SecretKey $awsSecret) | Write-Verbose

    $destination.Refresh()

    return $destination
}

function RemoveFilesFromS3ByPrefix
{
    [CmdletBinding()]
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
        [string]$awsBucket,
        [string]$prefix,
        [switch]$Force
    )

    write-verbose "Removing all objects in S3 that match [Region: $awsRegion, Location: $awsBucket\$prefix]."
    Get-S3Object -BucketName $awsBucket -KeyPrefix $prefix -Region $awsRegion -AccessKey $awsKey -SecretKey $awsSecret | ForEach-Object {
        Write-Verbose "Removing $($_.Key)."
        $result = Remove-S3Object -BucketName $awsBucket -Key $_.Key -Region $awsRegion -AccessKey $awsKey -SecretKey $awsSecret -Force:$Force
    }
}

function Ensure-S3BucketExists
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [string]$awsRegion,
        [Parameter(Mandatory=$true)]
        [string]$bucketName
    )

    Write-Verbose "Ensuring bucket [$bucketName] exists."
    $bucket = Get-S3Bucket -BucketName $bucketName -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion
    if ($bucket -eq $null)
    {
        Write-Verbose "Bucket [$bucketName] does not exist. Creating."
        $response = New-S3Bucket -BucketName $bucketName -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion
    }

    return $bucketName
}

function Clone-S3Bucket
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$sourceBucketName,
        [Parameter(Mandatory=$true)]
        [string]$destinationBucketName,
        [Parameter(Mandatory=$true)]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [string]$awsRegion
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. That's bad, its used to find dependencies." }
    $rootDirectoryPath = $rootDirectory.FullName

    . "$rootDirectoryPath\scripts\common\Functions-Aws.ps1"

    $awsCliExecutablePath = Get-AwsCliExecutablePath

    $previousAWSKey = $env:AWS_ACCESS_KEY_ID
    $previousAWSSecret = $env:AWS_SECRET_ACCESS_KEY
    $previousAWSRegion = $env:AWS_DEFAULT_REGION

    $env:AWS_ACCESS_KEY_ID = $awsKey
    $env:AWS_SECRET_ACCESS_KEY = $awsSecret
    $env:AWS_DEFAULT_REGION = $awsRegion

    Write-Verbose "Cloning bucket [$sourceBucketName] to bucket [$destinationBucketName]"
    (& $awsCliExecutablePath s3 sync s3://$sourceBucketName s3://$destinationBucketName) | Write-Debug

    $env:AWS_ACCESS_KEY_ID = $previousAWSKey
    $env:AWS_SECRET_ACCESS_KEY = $previousAWSSecret
    $env:AWS_DEFAULT_REGION = $previousAWSRegion
}

function Exist-S3Bucket
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$bucketName,
        [Parameter(Mandatory=$true)]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [string]$awsSecret,
        [Parameter(Mandatory=$true)]
        [string]$awsRegion
    )
    
    Write-Verbose "Checking bucket [$bucketName] existence."
    $bucket = Get-S3Bucket -BucketName $bucketName -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion
    if ($bucket -eq $null) 
    {
        return $false
    }
    
    return $true
}
