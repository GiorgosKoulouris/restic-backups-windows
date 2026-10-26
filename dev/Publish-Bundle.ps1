<#
.SYNOPSIS
    Stages a release of the tool and uploads it to S3.

.DESCRIPTION
    Development helper, not used at runtime. Copies the shipped files flat into
    dist\<Version> (rebuilt if it exists), writes manifest.txt and a copy of
    Install-Restic.bat with the download location filled in, then uploads them to
    BaseUrl with signed PUT requests (no AWS tools needed).

    Install-Restic.bat downloads manifest.txt, then every file it lists: "root" files
    go next to the install folder's launcher, "tools" files into its ResticTools folder.

    Credentials: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, asked for when not set;
    AWS_SESSION_TOKEN if set. They need s3:PutObject on the folder.

.PARAMETER Version
    Release version shown by the installer and written to ResticTools\version.txt, e.g. 1.2.0.

.PARAMETER BaseUrl
    Public HTTPS URL of the S3 folder the files are uploaded to,
    e.g. https://my-bucket.s3.eu-central-1.amazonaws.com/restic-tool/

.PARAMETER Region
    Signing region. Default: read from the BaseUrl host (s3.<region>.amazonaws.com).

.PARAMETER NoUpload
    Only stage dist\<Version>.

.PARAMETER Local
    Dev install without S3: stages dist\local with a file:/// download location, then runs
    that installer (it asks for elevation). No BaseUrl; Version defaults to dev-<date>-<time>.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z.-]*$')][string]$Version,
    # Checked in the body: a validation attribute also applies when -Local assigns its file:/// URL.
    [string]$BaseUrl,
    [string]$Region,
    [switch]$NoUpload,
    [switch]$Local
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Shipped files: destination in the install, path in this repository. Install-Restic.bat isn't listed: it's the downloader.
$files = @(
    @{ Dest = 'root';  Source = 'Restic-ManageSnapshots.bat' }
    @{ Dest = 'tools'; Source = 'ResticTools\Restic-ManageSnapshots.ps1' }
    @{ Dest = 'tools'; Source = 'ResticTools\HELP.md' }
)

$utf8 = New-Object System.Text.UTF8Encoding($false)

# cmd mishandles labels and goto in LF-only batch files: write .bat files with CRLF.
function Copy-Shipped([string]$Source, [string]$Destination) {
    if ($Source -like '*.bat') {
        $text = [IO.File]::ReadAllText($Source) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText($Destination, $text, $utf8)
    }
    else {
        Copy-Item -LiteralPath $Source -Destination $Destination
    }
}

function ConvertTo-Hex([byte[]]$Bytes) {
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ConvertTo-Hex $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
}

function Get-HmacSha256([byte[]]$Key, [string]$Data) {
    $hmac = New-Object Security.Cryptography.HMACSHA256 (, $Key)
    try { return , $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Data)) } finally { $hmac.Dispose() }
}

# Signature Version 4 Authorization header for one S3 request without a query string. Pure.
# Headers: every header to sign (host and x-amz-* at least), names in any case.
function Get-S3Authorization {
    param([string]$Method, [string]$CanonicalUri, [hashtable]$Headers, [string]$PayloadHash,
        [datetime]$Time, [string]$Region, [string]$AccessKey, [string]$SecretKey)

    $lower = @{}
    foreach ($name in $Headers.Keys) { $lower[$name.ToLowerInvariant()] = ([string]$Headers[$name]).Trim() }
    $names = [string[]]@($lower.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $signed = $names -join ';'
    $canonicalHeaders = -join ($names | ForEach-Object { "${_}:$($lower[$_])`n" })
    $canonical = @($Method, $CanonicalUri, '', $canonicalHeaders, $signed, $PayloadHash) -join "`n"

    $day = $Time.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
    $scope = "$day/$Region/s3/aws4_request"
    $toSign = @('AWS4-HMAC-SHA256', $Time.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture), $scope, (Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical)))) -join "`n"

    $key = Get-HmacSha256 ([Text.Encoding]::UTF8.GetBytes("AWS4$SecretKey")) $day
    $key = Get-HmacSha256 $key $Region
    $key = Get-HmacSha256 $key 's3'
    $key = Get-HmacSha256 $key 'aws4_request'
    $signature = ConvertTo-Hex (Get-HmacSha256 $key $toSign)
    return "AWS4-HMAC-SHA256 Credential=$AccessKey/$scope, SignedHeaders=$signed, Signature=$signature"
}

# Region from an AWS S3 host: s3.<region>.amazonaws.com, <bucket>.s3.<region>.amazonaws.com, s3-<region>, dualstack.
function Get-S3Region([string]$HostName) {
    if ($HostName -match '(^|\.)s3[.-](dualstack\.)?([a-z0-9-]+)\.amazonaws\.com$') { return $Matches[3] }
    if ($HostName -match '(^|\.)s3\.amazonaws\.com$') { return 'us-east-1' }
    return $null
}

function Read-Secret([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Temporary keys (ASIA..., e.g. from the SSO portal) only work with their session token;
# long-term keys (AKIA...) fail with one, so a leftover AWS_SESSION_TOKEN is ignored for them.
function Get-AwsCredentials {
    $accessKey = $env:AWS_ACCESS_KEY_ID
    $secretKey = $env:AWS_SECRET_ACCESS_KEY
    $sessionToken = $env:AWS_SESSION_TOKEN
    if ($accessKey) { Write-Host 'AWS access key ID: from AWS_ACCESS_KEY_ID' }
    else { $accessKey = (Read-Host 'AWS access key ID').Trim() }
    if ($secretKey) { Write-Host 'AWS secret access key: from AWS_SECRET_ACCESS_KEY' }
    else { $secretKey = Read-Secret 'AWS secret access key' }
    if (-not $accessKey -or -not $secretKey) { throw 'No AWS credentials.' }

    if ($accessKey.StartsWith('ASIA')) {
        if ($sessionToken) { Write-Host 'AWS session token: from AWS_SESSION_TOKEN' }
        else { $sessionToken = Read-Secret 'AWS session token (temporary key)' }
        if (-not $sessionToken) { throw "$accessKey is a temporary key: it needs its session token." }
    }
    elseif ($sessionToken) {
        Write-Host "AWS session token: AWS_SESSION_TOKEN ignored, $accessKey is a long-term key." -ForegroundColor Yellow
        $sessionToken = $null
    }
    return [pscustomobject]@{ AccessKey = $accessKey; SecretKey = $secretKey; SessionToken = $sessionToken }
}

function Send-S3Object([string]$Url, [string]$Path, [string]$Region, $Credentials) {
    $uri = [Uri]$Url
    $body = [IO.File]::ReadAllBytes($Path)
    $hash = Get-Sha256Hex $body
    $time = [DateTime]::UtcNow
    $amzDate = $time.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $canonicalUri = '/' + (($uri.AbsolutePath.TrimStart('/') -split '/' | ForEach-Object { [Uri]::EscapeDataString([Uri]::UnescapeDataString($_)) }) -join '/')

    # The installer downloads anonymously: every object is public-read.
    $headers = @{ 'host' = $uri.Host; 'x-amz-acl' = 'public-read'; 'x-amz-content-sha256' = $hash; 'x-amz-date' = $amzDate }
    if ($Credentials.SessionToken) { $headers['x-amz-security-token'] = $Credentials.SessionToken }
    $authorization = Get-S3Authorization -Method 'PUT' -CanonicalUri $canonicalUri -Headers $headers -PayloadHash $hash `
        -Time $time -Region $Region -AccessKey $Credentials.AccessKey -SecretKey $Credentials.SecretKey

    $request = [Net.HttpWebRequest]::Create($uri)
    $request.Method = 'PUT'
    # Browsers download a .bat served as octet-stream instead of showing it.
    $request.ContentType = 'text/plain; charset=utf-8'
    if ($Path -like '*.bat') { $request.ContentType = 'application/octet-stream' }
    $request.ContentLength = $body.Length
    foreach ($name in $headers.Keys) { if ($name -ne 'host') { $request.Headers.Add($name, $headers[$name]) } }
    $request.Headers.Add('Authorization', $authorization)

    try {
        $stream = $request.GetRequestStream()
        try { $stream.Write($body, 0, $body.Length) } finally { $stream.Close() }
        $request.GetResponse().Close()
    }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        $detail = $ex.Message
        if ($ex -is [Net.WebException] -and $ex.Response) {
            $reader = New-Object IO.StreamReader($ex.Response.GetResponseStream())
            try { $xml = $reader.ReadToEnd() } finally { $reader.Close() }
            if ($xml -match '<Code>([^<]*)</Code>') { $detail = $Matches[1] }
            if ($xml -match '<Message>([^<]*)</Message>') { $detail += ": $($Matches[1])" }
            if ($xml -match '<Code>AccessControlListNotSupported</Code>') {
                $detail += " Enable ACLs on the bucket (Permissions > Object Ownership > ACLs enabled)."
            }
            elseif ($xml -match '<Code>AccessDenied</Code>') {
                $detail += " The keys need s3:PutObject and s3:PutObjectAcl; Block public access must allow public ACLs."
            }
        }
        throw "Upload of $Url failed. $detail"
    }
}

$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ($Local) {
    if (-not $Version) { $Version = 'dev-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) }
    $out = Join-Path $repo 'dist\local'
    # Net.WebClient reads file:/// URLs like https ones. AbsoluteUri escapes spaces and uses forward slashes.
    $BaseUrl = ([Uri]($out + '\')).AbsoluteUri
    if ($BaseUrl -match "['\s]") { throw "Can't use $out as a download location: $BaseUrl" }
    $NoUpload = $true
}
else {
    if (-not $Version) { throw 'Pass -Version.' }
    if (-not $BaseUrl) { throw 'Pass -BaseUrl, or -Local for a dev install.' }
    if ($BaseUrl -notmatch '^https://[^''\s]+$') { throw "-BaseUrl must be an https URL without spaces or quotes: $BaseUrl" }
    $out = Join-Path $repo "dist\$Version"
}
if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
if (-not $NoUpload -and -not $Region) {
    $Region = Get-S3Region ([Uri]$BaseUrl).Host
    if (-not $Region) { throw "Can't read the region from $BaseUrl. Pass -Region." }
}

$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'ResticTools\Restic-ManageSnapshots.ps1'), [ref]$null, [ref]$errors) | Out-Null
if ($errors) { throw "ResticTools\Restic-ManageSnapshots.ps1 doesn't parse: $($errors[0].Message)" }

if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

$manifest = @("version $Version")
$upload = @()
foreach ($file in $files) {
    $source = Join-Path $repo $file.Source
    $name = Split-Path -Leaf $source
    Copy-Shipped $source (Join-Path $out $name)
    $manifest += "$($file.Dest) $name"
    $upload += $name
}
[IO.File]::WriteAllText((Join-Path $out 'manifest.txt'), ($manifest -join "`n") + "`n", $utf8)

$installer = Join-Path $out 'Install-Restic.bat'
Copy-Shipped (Join-Path $repo 'Install-Restic.bat') $installer
$text = [IO.File]::ReadAllText($installer)
if (([regex]::Matches($text, '__BASE_URL__')).Count -ne 1) { throw 'Install-Restic.bat must contain __BASE_URL__ exactly once.' }
[IO.File]::WriteAllText($installer, $text.Replace('__BASE_URL__', $BaseUrl), $utf8)
Write-Host "Staged $Version in $out"

if ($Local) {
    # The batch head elevates in a new window when needed.
    & "$env:SystemRoot\System32\cmd.exe" /c $installer
    exit $LASTEXITCODE
}
if ($NoUpload) {
    Write-Host "Upload every file in it to $BaseUrl (replace the existing ones)."
}
else {
    $credentials = Get-AwsCredentials
    # Manifest after the files it lists, installer last: a download mid-upload never sees a manifest ahead of its files.
    foreach ($name in @($upload) + 'manifest.txt' + 'Install-Restic.bat') {
        Write-Host "Uploading $name"
        Send-S3Object ($BaseUrl + $name) (Join-Path $out $name) $Region $credentials
    }
    Write-Host "Uploaded $Version to $BaseUrl"
}
Write-Host "Installer link: $($BaseUrl)Install-Restic.bat"
