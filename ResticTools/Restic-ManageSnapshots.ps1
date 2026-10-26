<#
.SYNOPSIS
    Manages restic backups of this machine to its per-host repository on S3.

.DESCRIPTION
    Without -Mode an interactive menu is shown. Scheduled runs use -Mode Backup, which
    backs up all enabled jobs and then runs whatever maintenance (forget/prune/check) is due.
    -Mode Gui opens a window with the backup status and every menu action (the console menu
    opens instead where Windows Forms is unavailable); its Settings dialog edits the configuration
    file and runs Setup.

    Exit codes: 0 = success, 1 = failure, 3 = completed with warnings.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Setup', 'Backup', 'Maintenance', 'Forget', 'Prune', 'Check', 'List', 'Restore', 'Gui')]
    [string]$Mode = 'Menu'
)

$ErrorActionPreference = 'Stop'

# Resolved here rather than as a param default: Windows PowerShell 5.1 can leave $PSScriptRoot empty there.
$script:ScriptPath = $MyInvocation.MyCommand.Path
# Always next to the script: the installer locks that folder, and the SYSTEM task trusts this file.
$script:ConfigPath = Join-Path (Split-Path -Parent $script:ScriptPath) 'restic-config.json'

# restic writes UTF-8; without this, non-ASCII paths are garbled in the console and log.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

try { Add-Type -AssemblyName System.Security } catch { }

$script:LogFile = $null
# Set in a GUI worker runspace: a ConcurrentQueue that Write-Log feeds instead of the console.
$script:LogSink = $null
$script:ResticReady = $false
$script:RepositoryChecked = $false
# What an operation leaves for its front end besides statuses (e.g. the forget preview); a GUI action returns it as Data.
$script:ActionData = $null
# The Help window's state (Show-HelpWindow) while it is open.
$script:Help = $null

#region Logging

function Write-Log {
    param(
        [AllowEmptyString()][string]$Message = '',
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Detail')][string]$Level = 'Info'
    )

    $colors = @{ Success = 'Green'; Warning = 'Yellow'; Error = 'Red'; Detail = 'DarkGray' }
    # A worker runspace has no console; the GUI thread drains the sink into its output pane.
    if ($script:LogSink) { $script:LogSink.Enqueue([pscustomobject]@{ Level = $Level; Message = $Message }) }
    elseif ($Level -eq 'Info') { Write-Host $Message }
    else { Write-Host $Message -ForegroundColor $colors[$Level] }

    if ($script:LogFile) {
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level.ToUpper(), $Message
        [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
}

function Start-Log {
    param([string]$Directory, [int]$RetentionDays, [string]$Name)

    # Runs before the data directory is checked or locked: never write or delete logs through a link.
    foreach ($path in @((Split-Path -Parent $Directory), $Directory)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$path is a link (reparse point). Remove it, then run Setup."
        }
    }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $script:LogFile = Join-Path $Directory ('{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), $Name)

    if ($RetentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        # Only names this function gives: the folder may hold other logs if dataDirectory was set to a used folder.
        Get-ChildItem -LiteralPath $Directory -Filter '*.log' -File |
            Where-Object { $_.Name -match '^\d{8}-\d{6}-[a-z]+\.log$' -and $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region Configuration and state

function Get-Setting {
    param($Object, [string]$Name, $Default = $null)

    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

# Like Get-Setting, but an empty or blank value also means the default (the editor saves a cleared box as "").
function Get-PathSetting {
    param($Object, [string]$Name, [string]$Default)

    $value = [string](Get-Setting $Object $Name '')
    if (-not $value.Trim()) { return $Default }
    return $value
}

function Get-DefaultDataDirectory {
    return Join-Path $env:ProgramData 'Restic'
}

# Offered by the editor's 'Add suggested' button, and the excludes of a new configuration.
function Get-SuggestedExcludes {
    return @(
        '*.tmp', '~$*', 'Thumbs.db', 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys',
        '$RECYCLE.BIN', 'System Volume Information', 'Windows\Temp',
        'AppData\Local\Temp', 'AppData\Local\Microsoft\Windows\INetCache'
    )
}

function Get-StringList {
    param($Object, [string]$Name)

    return @(Get-Setting $Object $Name @() |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [string]$_ })
}

# AWS only: the region's endpoint is s3.<region>.amazonaws.com. Shared by every run and the Settings preview.
function Get-RepositoryUrl {
    param([string]$Region, [string]$Bucket, [string]$Hostname = $env:COMPUTERNAME)

    return "s3:s3.$Region.amazonaws.com/$Bucket/$Hostname"
}

function Read-ConfigDocument {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path. See HELP.md next to the script: First-time setup."
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-Config {
    param([string]$Path)

    return ConvertTo-Config (Read-ConfigDocument $Path)
}

# Validates the parsed JSON document and returns the normalized configuration.
function ConvertTo-Config {
    param($Raw)

    # Identify this machine
    $hostname = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($hostname)) {
        $hostname = [System.Net.Dns]::GetHostName()
    }

    $repository = Get-Setting $raw 'repository'
    $region = [string](Get-Setting $repository 'region')
    $bucket = [string](Get-Setting $repository 'bucket')
    if (-not $region -or -not $bucket) {
        throw "repository.region and repository.bucket are required in the configuration file."
    }
    if ($region -cnotmatch '^[a-z]{2}(-[a-z]+)+-[0-9]+$') {
        throw "repository.region '$region' is not an AWS region, e.g. eu-central-1."
    }

    $jobs = @()
    $names = @{}
    foreach ($job in @(Get-Setting $raw 'jobs' @())) {
        $name = [string](Get-Setting $job 'name')
        if ($name -notmatch '^[A-Za-z0-9_.-]+$') {
            throw "Job name '$name' is invalid. Use letters, digits, '.', '_' or '-'."
        }
        if ($names.ContainsKey($name)) { throw "Duplicate job name: $name" }
        $names[$name] = $true

        $paths = @(Get-StringList $job 'paths')
        if ($paths.Count -eq 0) { throw "Job '$name' has no paths." }

        $tags = @(Get-StringList $job 'tags')
        foreach ($tag in $tags) {
            if ($tag -match '[,\s]') { throw "Tag '$tag' in job '$name' must not contain commas or spaces." }
            # A second job: tag would put the job's snapshots in another job's retention group.
            if ($tag -like 'job:*') { throw "Tag '$tag' in job '$name' must not start with 'job:'. The job tag is added automatically." }
        }

        $jobs += [pscustomobject]@{
            Name     = $name
            Enabled  = [bool](Get-Setting $job 'enabled' $true)
            Paths    = @($paths)
            Tags     = @($tags)
            Excludes = @(Get-StringList $job 'excludes')
        }
    }

    if ($jobs.Count -eq 0) { throw "No jobs defined in the configuration file." }

    # Setup locks it and every run writes and deletes logs in it: never a folder others rely on. Checked on every
    # run, so Start-Log never touches such a folder either. Setup also checks its contents (Initialize-DataDirectory).
    $dataDirectory = Get-PathSetting $raw 'dataDirectory' (Get-DefaultDataDirectory)
    if ($dataDirectory -notmatch '^[A-Za-z]:\\') {
        throw "dataDirectory '$dataDirectory' must be a full local path, e.g. $(Get-DefaultDataDirectory)."
    }
    $dataDirectory = [System.IO.Path]::GetFullPath($dataDirectory)
    # Not a root's: C: alone means the current folder on C.
    if ($dataDirectory.Length -gt 3) { $dataDirectory = $dataDirectory.TrimEnd('\') }
    $reason = Get-SystemFolderReason $dataDirectory
    $installRoot = Split-Path -Parent (Split-Path -Parent $script:ScriptPath)
    foreach ($folder in @((Join-Path $env:SystemDrive 'Users'), $installRoot)) {
        if (-not $reason -and (Test-PathWithin $dataDirectory $folder)) { $reason = "$dataDirectory is in $folder." }
    }
    if ($reason) {
        throw "dataDirectory: $reason Use a folder of its own, e.g. $(Get-DefaultDataDirectory). See Help: Moving the folder."
    }
    $restoreRoot = Get-PathSetting $raw 'restoreRoot' 'C:\Restore'
    if ($restoreRoot -notmatch '^[A-Za-z]:\\') { throw "restoreRoot '$restoreRoot' must be a full local path, e.g. C:\Restore." }

    return [pscustomobject]@{
        Hostname         = $hostname
        Repository       = Get-RepositoryUrl $region $bucket $hostname
        DataDirectory    = $dataDirectory
        SecretsFile      = Join-Path $dataDirectory 'secrets.dat'
        StateFile        = Join-Path $dataDirectory 'state.json'
        LogDirectory     = Join-Path $dataDirectory 'logs'
        LogRetentionDays = [int](Get-Setting $raw 'logRetentionDays' 30)
        UseVss           = [bool](Get-Setting $raw 'useVss' $true)
        RestoreRoot      = $restoreRoot
        GlobalExcludes   = @(Get-StringList $raw 'globalExcludes')
        Retention        = Get-Setting $raw 'retention'
        Maintenance      = Get-Setting $raw 'maintenance'
        Schedule         = Get-Setting $raw 'schedule'
        Jobs             = $jobs
    }
}

function Read-State {
    if (Test-Path -LiteralPath $script:Config.StateFile -PathType Leaf) {
        return Get-Content -LiteralPath $script:Config.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return [pscustomobject]@{}
}

function Save-StateValue {
    param([string]$Name, [string]$Value)

    $state = Read-State
    $state | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Write-FileAtomic $script:Config.StateFile ((New-Object System.Text.UTF8Encoding $false).GetBytes(($state | ConvertTo-Json) + "`n"))
}

# Writes <Path>.tmp, then swaps it in: a crash leaves the old or the new file, never a partial one. Retries briefly
# while another run (GUI and scheduled task) reads or writes it. Initialize-DataDirectory accepts a leftover .tmp.
function Write-FileAtomic {
    param([string]$Path, [byte[]]$Bytes)

    $temp = "$Path.tmp"
    for ($attempt = 1; ; $attempt++) {
        try {
            $stream = [System.IO.FileStream]::new($temp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $stream.Write($Bytes, 0, $Bytes.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            # [NullString]: PowerShell passes $null to a string parameter as '' (no backup file wanted).
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($temp, $Path) }
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 5) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Save-StateTimestamp {
    param([string]$Name)

    Save-StateValue $Name (Get-Date).ToString('o')
}

# The repository Setup last set up (state 'repository') when the configuration now points elsewhere:
# the region, the bucket or the computer name changed. $null when unchanged or nothing is recorded yet.
function Get-RepositoryChange {
    param($State = (Read-State))

    $recorded = [string](Get-Setting $State 'repository' '')
    if ($recorded -and $recorded -ne $script:Config.Repository) { return $recorded }
    return $null
}

function Assert-RepositoryUnchanged {
    $previous = Get-RepositoryChange
    if ($previous) {
        throw "The repository changed from $previous to $($script:Config.Repository) (the region, bucket or computer name changed). " +
            'Run Setup to switch to it (it can copy the snapshots), or change the configuration back. See Help: Switching repositories.'
    }
}

function Format-StateTimestamp {
    param($State, [string]$Name)

    $value = Get-Setting $State $Name
    if (-not $value) { return 'never' }
    return '{0:yyyy-MM-dd HH:mm}' -f [datetime]$value
}

#endregion

#region Permissions

# The task runs as SYSTEM: whoever can change a path it trusts can run code as SYSTEM or read the secrets.
# The rules match the installer's (Get-UntrustedHolders, Lock-Path): keep them identical. The constants live in the
# functions so GUI worker runspaces get them.

function Get-AccountName {
    param([Security.Principal.SecurityIdentifier]$Sid)

    try { return $Sid.Translate([Security.Principal.NTAccount]).Value } catch { return $Sid.Value }
}

# Why $Path isn't safe for SYSTEM to trust, as messages; none = trusted. Unsafe: missing, a link (reparse point),
# owned by an untrusted account, or an allow entry giving an untrusted account rights that change it.
# Inherit-only entries apply to what's inside, not to $Path. Callers wrap the result in @().
function Test-TrustedPath {
    param([string]$Path)

    # SYSTEM, Administrators, CREATOR OWNER, TrustedInstaller.
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    # WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes, Delete,
    # ChangePermissions, TakeOwnership, GenericAll, GenericWrite.
    $changeRights = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $sidType = [Security.Principal.SecurityIdentifier]

    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return "$Path doesn't exist." }
    catch { return "Can't read ${Path}: $($_.Exception.Message)" }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return "$Path is a link (reparse point)." }
    try { $acl = Get-Acl -LiteralPath $Path }
    catch { return "Can't read the permissions of ${Path}: $($_.Exception.Message)" }

    $problems = @()
    $owner = $acl.GetOwner($sidType)
    if ($null -eq $owner) { $problems += "$Path has no owner." }
    elseif ($trusted -notcontains $owner.Value) { $problems += "$Path is owned by $(Get-AccountName $owner)." }
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if (([int]$rule.FileSystemRights -band $changeRights) -eq 0) { continue }
        if ($trusted -contains $rule.IdentityReference.Value) { continue }
        $text = "$(Get-AccountName $rule.IdentityReference) can change $Path."
        if ($problems -notcontains $text) { $problems += $text }
    }
    return $problems
}

# Throws unless every path passes Test-TrustedPath. Setup locks the data directory (Initialize-DataDirectory).
function Assert-TrustedPath {
    param([string[]]$Path)

    $problems = @()
    foreach ($item in $Path) { $problems += @(Test-TrustedPath $item) }
    if ($problems.Count -gt 0) {
        throw "Unsafe permissions: $($problems -join ' ') Run Setup to reset them. See Help: Security."
    }
}

# Sets owner Administrators and the DACL (SDDL) on one file or folder. By name, so it follows a link: callers skip links.
# Setting a folder's DACL also updates what inherits below it, without following links (tested).
function Set-TrustedSecurity {
    param([IO.FileSystemInfo]$Item, [string]$Dacl)

    $path = $Item.FullName
    $isFolder = $Item -is [IO.DirectoryInfo]
    $sections = [Security.AccessControl.AccessControlSections]'Owner, Access'
    for ($attempt = 1; ; $attempt++) {
        if ($isFolder) { $acl = New-Object Security.AccessControl.DirectorySecurity }
        else { $acl = New-Object Security.AccessControl.FileSecurity }
        $acl.SetSecurityDescriptorSddlForm("O:BA$Dacl", $sections)
        try {
            if ($isFolder) { [IO.Directory]::SetAccessControl($path, $acl) }
            else { [IO.File]::SetAccessControl($path, $acl) }
            return
        }
        catch [UnauthorizedAccessException] {
            if ($attempt -gt 1) { throw "Can't set the permissions of ${path}: $($_.Exception.Message)" }
        }
        # Another owner left Administrators no access. takeown enables the privilege that allows taking ownership;
        # the owner may then set the DACL, but not the owner (already Administrators).
        & takeown.exe /F $path /A | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Can't take ownership of $path (takeown exit code $LASTEXITCODE)." }
        $sections = [Security.AccessControl.AccessControlSections]::Access
    }
}

# Locks $Path for SYSTEM: owner Administrators, full control for SYSTEM and Administrators only, nothing inherited
# (the installer's Lock-Path without its Users read entry). Everything inside gets owner Administrators and only
# what it inherits. Refuses a link; links inside are logged and skipped, not followed. Throws on failure.
function Lock-TrustedPath {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is a link (reparse point). Refusing to lock it." }
    if (-not $item.PSIsContainer) {
        Set-TrustedSecurity $item 'D:PAI(A;;FA;;;SY)(A;;FA;;;BA)'
        return
    }
    Set-TrustedSecurity $item 'D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'

    # Top down: each folder is locked before its contents, so no other account can swap an entry for a link meanwhile.
    $folders = New-Object System.Collections.Stack
    $folders.Push($item.FullName)
    while ($folders.Count -gt 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $folders.Pop() -Force)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Log "Not locking $($child.FullName): it's a link (reparse point)." -Level Warning
                continue
            }
            Set-TrustedSecurity $child 'D:AI'
            if ($child.PSIsContainer) { $folders.Push($child.FullName) }
        }
    }
}

# True when $Path is $Folder or inside it. Both full paths; compares the text only (no 8.3 names or links resolved).
function Test-PathWithin {
    param([string]$Path, [string]$Folder)

    $Path = $Path.TrimEnd('\')
    $Folder = $Folder.TrimEnd('\')
    return $Path -eq $Folder -or $Path.StartsWith("$Folder\", [StringComparison]::OrdinalIgnoreCase)
}

# Why an admin must not lock (dataDirectory) or restore over (in place) $Path, a full path; $null if nothing speaks
# against it. Refused: a drive root, Program Files, ProgramData or the Users folder itself, the Windows folder and
# anything in it.
function Get-SystemFolderReason {
    param([string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.TrimEnd('\') -eq [System.IO.Path]::GetPathRoot($full).TrimEnd('\')) { return "$full is a drive root." }
    $full = $full.TrimEnd('\')
    if (Test-PathWithin $full $env:SystemRoot) { return "$full is in the Windows folder." }
    $folders = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData, (Join-Path $env:SystemDrive 'Users'))
    foreach ($folder in $folders) {
        if ($folder -and $full -eq $folder.TrimEnd('\')) { return "$full is a system folder." }
    }
    return $null
}

#endregion

#region Secrets

function Save-Secrets {
    param([hashtable]$Secrets)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Secrets | ConvertTo-Json -Compress))
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    Write-FileAtomic $script:Config.SecretsFile $protected
}

function Read-Secrets {
    $path = $script:Config.SecretsFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Secrets file not found: $path. Run Setup first."
    }
    # Any process that can read it can decrypt it (DPAPI LocalMachine), and whoever wrote it chose the keys.
    Assert-TrustedPath @($script:Config.DataDirectory, $path)

    try {
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            [System.IO.File]::ReadAllBytes($path), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    }
    catch { throw "The secrets file can't be decrypted ($($_.Exception.GetBaseException().Message.Trim())). Run Setup to store them again." }
    return [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Read-PlainSecret {
    param([string]$Prompt)

    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

#endregion

#region Restic

# The restic release Setup installs into <dataDirectory>\bin. Generated by dev\Get-ResticPin.ps1 -Version 0.19.1.
function Get-ResticPin {
    return @{
        Version = '0.19.1'
        amd64 = @{ Zip = 'DA948AD707ED690426473AABA2046CD61F8F90F6F0E7DAB6BE0D5796531DE67D'; Exe = 'B0DD1FD21EEA5D8FE1325F55F7118213C21F36DE8A261E04C0624A5AB9FD7830' }
    }
}

# The pinned restic for this machine: Version, Arch, ZipName, ExeName (inside the zip), Url, ZipHash, ExeHash, Path.
function Get-ResticTarget {
    param([string]$DataDirectory = $script:Config.DataDirectory)

    $pin = Get-ResticPin
    # The machine value: a 32-bit or emulated PowerShell reports its own architecture in the process variable.
    $arch = ([string][Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')).ToLower()
    if (-not $pin.ContainsKey($arch)) {
        throw "restic $($pin.Version) is not available for this machine's architecture ($arch). Supported: $(@($pin.Keys | Where-Object { $_ -ne 'Version' }) -join ', ')."
    }

    $version = $pin.Version
    $name = "restic_${version}_windows_$arch"
    return [pscustomobject]@{
        Version = $version
        Arch    = $arch
        ZipName = "$name.zip"
        ExeName = "$name.exe"
        Url     = "https://github.com/restic/restic/releases/download/v$version/$name.zip"
        ZipHash = $pin[$arch].Zip
        ExeHash = $pin[$arch].Exe
        Path    = Join-Path (Join-Path $DataDirectory 'bin') "restic-$version.exe"
    }
}

function Test-FileHash {
    param([string]$Path, [string]$Hash)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash
}

# The installed pinned restic, checked against its hash and permissions on every call. Only Setup installs it.
function Find-ResticExe {
    $target = Get-ResticTarget
    if (-not (Test-Path -LiteralPath $target.Path -PathType Leaf)) {
        throw "restic $($target.Version) is not installed ($($target.Path)). Run Setup."
    }
    Assert-TrustedPath @($script:Config.DataDirectory, (Split-Path -Parent $target.Path), $target.Path)
    if (-not (Test-FileHash $target.Path $target.ExeHash)) {
        throw "$($target.Path) doesn't match the expected hash of restic $($target.Version). Run Setup to reinstall it."
    }
    return $target.Path
}

# Opens $script:ResticExe and checks its hash from that handle. While the handle is open nobody can replace,
# rename or delete the file, so restic runs what was checked. Dispose it once restic has exited.
function Open-ResticExe {
    $target = Get-ResticTarget
    $stream = New-Object System.IO.FileStream($script:ResticExe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '' }
    catch { $stream.Dispose(); throw }
    finally { $sha.Dispose() }
    if ($hash -ne $target.ExeHash) {
        $stream.Dispose()
        throw "$($script:ResticExe) doesn't match the expected hash of restic $($target.Version). Run Setup to reinstall it."
    }
    return $stream
}

# Setup only. Locking replaces the permissions of everything in the folder, so it must be new, empty or hold only
# what this tool puts there (also after copying secrets.dat and state.json over). ConvertTo-Config refuses system folders.
function Initialize-DataDirectory {
    $path = $script:Config.DataDirectory
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$path is a link (reparse point). Refusing to lock it." }
        if (-not $item.PSIsContainer) { throw "$path is a file. dataDirectory must be a folder." }
        $ours = @('bin', 'logs', 'secrets.dat', 'state.json', 'secrets.dat.tmp', 'state.json.tmp')
        $other = @(Get-ChildItem -LiteralPath $path -Force | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($ours -notcontains $_.Name -and $_.Name -notlike 'install-*')
            } | ForEach-Object { $_.Name })
        if ($other.Count -gt 0) {
            $names = @($other | Select-Object -First 5) -join ', '
            if ($other.Count -gt 5) { $names += ", ... ($($other.Count) in all)" }
            throw "$path holds files that aren't this tool's, or links ($names). Setup locks the data directory and everything in it: " +
                'use a new or empty folder. See Help: Moving the folder.'
        }
    }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Lock-TrustedPath $path
}

# Installs the pinned restic into <dataDirectory>\bin unless it's already there. The release zip comes from
# ZipPath, else from the script's folder, else from GitHub; the zip and the exe are both checked against
# the pinned hashes. Then removes the other versions. Throws on failure.
function Install-Restic {
    param([string]$ZipPath = '')

    $target = Get-ResticTarget
    $bin = Split-Path -Parent $target.Path
    $installed = (Test-Path -LiteralPath $target.Path -PathType Leaf) -and (Test-FileHash $target.Path $target.ExeHash)

    if ($installed) {
        Write-Log "restic $($target.Version) is installed." -Level Success
    }
    else {
        Initialize-DataDirectory
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $work = Join-Path $bin "install-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
            $local = Join-Path (Split-Path -Parent $script:ScriptPath) $target.ZipName
            if ($ZipPath) { $zip = $ZipPath }
            elseif (Test-Path -LiteralPath $local -PathType Leaf) { $zip = $local }
            else {
                $zip = Join-Path $work $target.ZipName
                Write-Log "Downloading $($target.Url)"
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $client = New-Object System.Net.WebClient
                $client.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                $client.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
                try { $client.DownloadFile($target.Url, $zip) }
                catch { throw "Downloading restic $($target.Version) failed: $($_.Exception.GetBaseException().Message)" }
                finally { $client.Dispose() }
            }

            if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "File not found: $zip" }
            Write-Log "Checking $zip"
            if (-not (Test-FileHash $zip $target.ZipHash)) {
                throw "$zip doesn't match the expected hash of $($target.ZipName). Use the official release zip."
            }

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $exe = Join-Path $work $target.ExeName
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $entry = $archive.Entries | Where-Object { $_.FullName -eq $target.ExeName } | Select-Object -First 1
                if (-not $entry) { throw "$zip doesn't contain $($target.ExeName)." }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $exe, $true)
            }
            finally { $archive.Dispose() }

            if (-not (Test-FileHash $exe $target.ExeHash)) { throw "$($target.ExeName) doesn't match its expected hash." }
            Move-Item -LiteralPath $exe -Destination $target.Path -Force
            Write-Log "restic $($target.Version) installed to $($target.Path)" -Level Success
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # By name: FullName is the long form of a path the configuration may spell differently (8.3, case).
    $keep = Split-Path -Leaf $target.Path
    foreach ($old in @(Get-ChildItem -LiteralPath $bin -Filter 'restic-*.exe' -File | Where-Object { $_.Name -ne $keep })) {
        try {
            Remove-Item -LiteralPath $old.FullName -Force
            Write-Log "Removed $($old.Name)."
        }
        catch { Write-Log "Couldn't remove $($old.FullName): $($_.Exception.Message)" -Level Warning }
    }
}

function Initialize-Restic {
    if ($script:ResticReady) { return }

    $script:ResticExe = Find-ResticExe
    $secrets = Read-Secrets
    $env:AWS_ACCESS_KEY_ID = $secrets.awsAccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $secrets.awsSecretAccessKey
    $env:RESTIC_PASSWORD = $secrets.resticPassword
    $env:RESTIC_REPOSITORY = $script:Config.Repository

    $script:ResticReady = $true
}

function Invoke-Restic {
    param([string[]]$Arguments, [switch]$Quiet)

    Write-Log "> restic $($Arguments -join ' ')" -Level Detail

    $exe = Open-ResticExe
    # Windows PowerShell turns native stderr lines into errors; keep them as plain output.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $script:ResticExe @Arguments 2>&1 | ForEach-Object {
            if (-not $Quiet -or $_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Log ([string]$_)
            }
        }
    }
    finally {
        $ErrorActionPreference = $previous
        $exe.Dispose()
    }

    return $LASTEXITCODE
}

# -Lines: the command prints one JSON document per line (e.g. 'ls'); returns one object per line.
# -Log: logs the command and restic's messages (stderr), like Invoke-Restic; otherwise they are dropped.
function Invoke-ResticJson {
    param([string[]]$Arguments, [switch]$Lines, [switch]$Log)

    if ($Log) { Write-Log "> restic $($Arguments -join ' ') --json" -Level Detail }
    $exe = Open-ResticExe
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Log) {
            $output = @(& $script:ResticExe @Arguments --json 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Log ([string]$_) } else { [string]$_ }
            })
        }
        else { $output = & $script:ResticExe @Arguments --json 2>$null }
    }
    finally {
        $ErrorActionPreference = $previous
        $exe.Dispose()
    }

    if ($LASTEXITCODE -ne 0) {
        throw "restic $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    if ($Lines) { return ConvertFrom-JsonLines $output }
    $text = $output -join "`n"
    if (-not $text.Trim()) { return }
    # PS 5.1 emits a JSON array as one pipeline object; assigning and returning it unrolls the items.
    $parsed = $text | ConvertFrom-Json
    return $parsed
}

function ConvertFrom-JsonLines {
    param([string[]]$Text)

    return @($Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

# Returns the exit code of 'restic cat config': 0 = OK, 10 = repository missing, other = access problem.
function Get-RepositoryStatus {
    return Invoke-Restic @('cat', 'config') -Quiet
}

function Assert-Repository {
    if ($script:RepositoryChecked) { return }

    $code = Get-RepositoryStatus
    if ($code -eq 10) { throw "Repository $($script:Config.Repository) is not initialized. Run Setup first." }
    if ($code -ne 0) { throw "Cannot access the repository (restic exit code $code). Check the credentials and password." }

    $script:RepositoryChecked = $true
}

function Format-PathArgument {
    param([string]$Path)

    # A trailing backslash would escape the closing quote when the argument is passed to restic.
    if ($Path.Length -gt 3) { return $Path.TrimEnd('\') }
    return $Path
}

# C:\Users\name -> /C/Users/name, the form restic uses inside Windows snapshots.
function ConvertTo-SnapshotPath {
    param([string]$Path)

    $full = Format-PathArgument ([System.IO.Path]::GetFullPath($Path))
    if ($full -notmatch '^[A-Za-z]:') { throw "Only local drive paths are supported: $Path" }
    return '/' + $full.Substring(0, 1).ToUpper() + ($full.Substring(2).TrimEnd('\') -replace '\\', '/')
}

# /C/Users/name -> C:\Users\name; /C -> C:\. The inverse of ConvertTo-SnapshotPath.
function ConvertFrom-SnapshotPath {
    param([string]$Path)

    if ($Path -notmatch '^/([A-Za-z])(/.*)?$') { throw "Not a drive path of a Windows snapshot: $Path" }
    $drive = $Matches[1].ToUpper()
    $rest = ''
    if ($Matches[2]) { $rest = $Matches[2].TrimEnd('/') -replace '/', '\' }
    if (-not $rest) { return "$($drive):\" }
    return "$($drive):$rest"
}

# /C/a/b -> /C/a; /C -> /
function Get-SnapshotParentPath {
    param([string]$Path)

    $index = $Path.TrimEnd('/').LastIndexOf('/')
    if ($index -le 0) { return '/' }
    return $Path.Substring(0, $index)
}

function Get-SnapshotLeaf {
    param([string]$Path)

    $trimmed = $Path.TrimEnd('/')
    return $trimmed.Substring($trimmed.LastIndexOf('/') + 1)
}

function ConvertTo-LocalTime {
    param($Value)

    if ($Value -is [datetime]) { return $Value.ToLocalTime() }
    # restic emits nanoseconds; .NET parses at most 7 fractional digits.
    $text = [string]$Value -replace '(\.\d{7})\d+', '$1'
    return [datetimeoffset]::Parse($text, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime
}

function Get-ExitCode {
    param([string[]]$Statuses)

    if ($Statuses -contains 'Failed') { return 1 }
    if ($Statuses -contains 'Warning') { return 3 }
    return 0
}

#endregion

#region Operations

function Invoke-BackupJob {
    param($Job)

    $config = $script:Config

    Write-Log ('=' * 60)
    Write-Log "Job:   $($Job.Name)"
    Write-Log "Paths: $($Job.Paths -join ', ')"
    Write-Log "Tags:  $(@("job:$($Job.Name)") + $Job.Tags -join ', ')"
    Write-Log ('=' * 60)

    $paths = @()
    $missing = 0
    foreach ($path in $Job.Paths) {
        if (Test-Path -LiteralPath $path) { $paths += (Format-PathArgument $path) }
        else {
            Write-Log "Path not found; skipping: $path" -Level Warning
            $missing++
        }
    }

    if ($paths.Count -eq 0) {
        Write-Log "Job '$($Job.Name)' has no existing paths." -Level Error
        return 'Failed'
    }

    # Construct the Restic arguments
    $arguments = @('backup', '--verbose', '--tag', "job:$($Job.Name)")
    foreach ($tag in $Job.Tags) { $arguments += @('--tag', $tag) }
    if ($config.UseVss) { $arguments += '--use-fs-snapshot' }
    foreach ($pattern in @($config.GlobalExcludes) + @($Job.Excludes)) { $arguments += @('--iexclude', $pattern) }
    $arguments += $paths

    $code = Invoke-Restic $arguments

    switch ($code) {
        0 {
            if ($missing -gt 0) { return 'Warning' }
            Write-Log "Backup completed: $($Job.Name)" -Level Success
            return 'Success'
        }
        3 {
            Write-Log "Snapshot created for '$($Job.Name)', but some files could not be read (exit code 3)." -Level Warning
            return 'Warning'
        }
        default {
            Write-Log "Backup failed: $($Job.Name) (exit code $code)" -Level Error
            return 'Failed'
        }
    }
}

# No JobNames = all enabled jobs. Named jobs are backed up even when disabled, in config order.
function Invoke-Backup {
    param([string[]]$JobNames)

    if ($JobNames.Count -gt 0) {
        foreach ($name in $JobNames) {
            if (-not ($script:Config.Jobs | Where-Object Name -eq $name)) { throw "Unknown job: $name" }
        }
        $jobs = @($script:Config.Jobs | Where-Object { $JobNames -contains $_.Name })
    }
    else {
        $jobs = @($script:Config.Jobs | Where-Object Enabled)
        if ($jobs.Count -eq 0) {
            Write-Log 'No enabled jobs in the configuration.' -Level Warning
            return 'Warning'
        }
    }

    $results = @()
    foreach ($job in $jobs) {
        $results += [pscustomobject]@{ Job = $job.Name; Status = (Invoke-BackupJob $job) }
        Write-Log ''
    }

    # Report results
    $levels = @{ Success = 'Success'; Warning = 'Warning'; Failed = 'Error' }
    Write-Log ('=' * 60)
    Write-Log 'Backup run finished.'
    foreach ($result in $results) {
        Write-Log ('  {0,-20} {1}' -f $result.Job, $result.Status) -Level $levels[$result.Status]
    }

    return @($results | ForEach-Object { $_.Status })
}

function Get-RetentionArguments {
    param($Retention = $script:Config.Retention)

    $map = [ordered]@{
        keepLast    = '--keep-last'
        keepHourly  = '--keep-hourly'
        keepDaily   = '--keep-daily'
        keepWeekly  = '--keep-weekly'
        keepMonthly = '--keep-monthly'
        keepYearly  = '--keep-yearly'
        keepWithin  = '--keep-within'
    }

    $result = @()
    foreach ($key in $map.Keys) {
        $value = [string](Get-Setting $Retention $key)
        if ($value -eq '' -or $value -eq '0') { continue }
        $result += @($map[$key], $value)
    }

    if ($result.Count -eq 0) { throw 'No retention policy configured; refusing to run forget.' }
    return $result
}

# Applies retention (or with -DryRun only works out what it would forget) and logs it as one table, kept snapshots
# with their reasons included (-Quiet: no table). Leaves @{ Preview (ConvertFrom-ForgetJson rows); NoPolicy;
# Snapshots (-DryRun only: a fresh Get-SnapshotList) } in $script:ActionData. Without a retention policy, -DryRun
# returns Warning (NoPolicy) and a real run throws.
function Invoke-Forget {
    param([switch]$DryRun, [switch]$Quiet)

    $script:ActionData = $null
    try { $policy = @(Get-RetentionArguments) }
    catch {
        if (-not $DryRun) { throw }
        Write-Log 'No retention policy is configured.' -Level Warning
        $script:ActionData = @{ Preview = $null; NoPolicy = $true; Snapshots = @(Get-SnapshotList) }
        return 'Warning'
    }
    $failed = $false
    $rows = @()

    # Retention is applied per job, so snapshots stay grouped even if a job's paths or tags change.
    # Snapshots without a job tag (e.g. from removed jobs) are never touched.
    foreach ($job in $script:Config.Jobs) {
        if ($DryRun) { Write-Log "Checking retention of job '$($job.Name)'..." }
        else { Write-Log "Applying retention to job '$($job.Name)'..." }
        $arguments = @('forget', '--tag', "job:$($job.Name)", '--group-by', 'host') + $policy
        if ($DryRun) { $arguments += '--dry-run' }

        try { $rows += @(ConvertFrom-ForgetJson (Invoke-ResticJson $arguments -Log)) }
        catch {
            Write-Log "Forget failed for job '$($job.Name)': $($_.Exception.Message)" -Level Error
            $failed = $true
        }
    }

    if (-not $Quiet) {
        Write-Log ''
        foreach ($line in @(Format-ForgetTable $rows -All)) { Write-Log $line }
    }
    $snapshots = $null
    if ($DryRun) { $snapshots = @(Get-SnapshotList) }
    $script:ActionData = @{ Preview = $rows; NoPolicy = $false; Snapshots = $snapshots }

    if ($failed) { return 'Failed' }
    if (-not $DryRun) {
        Save-StateTimestamp 'lastForget'
        Write-Log "Forgot $(@($rows | Where-Object { $_.Action -eq 'Remove' }).Count) snapshots." -Level Success
    }
    return 'Success'
}

# restic's 'forget --json' output (groups with keep, remove and reasons) as one row per snapshot: the
# Get-SnapshotList properties plus Action (Remove | Keep) and Reason (why retention keeps it, e.g. 'daily snapshot').
function ConvertFrom-ForgetJson {
    param($Groups)

    return @(foreach ($group in @($Groups)) {
        if (-not $group) { continue }
        $reasons = @{}
        foreach ($reason in @($group.reasons)) {
            if ($reason -and $reason.snapshot) { $reasons[[string]$reason.snapshot.id] = @($reason.matches) -join ', ' }
        }
        foreach ($snapshot in @($group.keep)) {
            if ($snapshot) { New-ForgetRow (ConvertFrom-ResticSnapshot $snapshot) 'Keep' ([string]$reasons[[string]$snapshot.id]) }
        }
        foreach ($snapshot in @($group.remove)) {
            if ($snapshot) { New-ForgetRow (ConvertFrom-ResticSnapshot $snapshot) 'Remove' }
        }
    })
}

function New-ForgetRow {
    param($Snapshot, [string]$Action, [string]$Reason = '', [string]$Warning = '')

    return [pscustomobject]@{
        Id = $Snapshot.Id; ShortId = $Snapshot.ShortId; Time = $Snapshot.Time; Job = $Snapshot.Job; Host = $Snapshot.Host
        Paths = $Snapshot.Paths; Tags = $Snapshot.Tags; Action = $Action; Reason = $Reason; Warning = $Warning
    }
}

# What a forget removes, for the Forget dialog, the menu and the log (pure). Mode: Retention (the Remove rows of
# Preview), Job (every snapshot of Job; '' = those without a job tag), Selected (Ids), Everything. Snapshots:
# Get-SnapshotList objects; Preview: ConvertFrom-ForgetJson rows, $null = unknown; NoPolicy: no retention configured.
# Returns Rows (every snapshot, Remove or Keep, with retention's reason and a warning when one is due), RemoveIds,
# Warnings (about the whole plan) and Missing (Ids that aren't in Snapshots).
function Get-ForgetPlan {
    param([string]$Mode, $Snapshots, $Preview, [string]$Job, [string[]]$Ids, $Jobs, [bool]$NoPolicy)

    $Snapshots = @($Snapshots | Where-Object { $_ })
    $names = @($Jobs | ForEach-Object { $_.Name })
    $retention = @{}
    foreach ($row in @($Preview)) { if ($row) { $retention[$row.Id] = $row } }
    $known = @{}
    foreach ($snapshot in $Snapshots) { $known[$snapshot.Id] = $true }

    $remove = @{}
    $missing = @()
    switch ($Mode) {
        'Retention'  { foreach ($row in @($Preview)) { if ($row -and $row.Action -eq 'Remove' -and $known[$row.Id]) { $remove[$row.Id] = $true } } }
        'Job'        { foreach ($snapshot in $Snapshots) { if ([string]$snapshot.Job -ceq $Job) { $remove[$snapshot.Id] = $true } } }
        'Selected' {
            foreach ($id in @($Ids)) {
                if ($known[$id]) { $remove[$id] = $true } elseif ($id) { $missing += $id }
            }
        }
        'Everything' { foreach ($snapshot in $Snapshots) { $remove[$snapshot.Id] = $true } }
        default      { throw "Unknown forget mode: $Mode" }
    }

    # The newest snapshot of each configured job, and how many of them stay.
    $newest = @{}
    $left = @{}
    foreach ($snapshot in $Snapshots) {
        $name = [string]$snapshot.Job
        if (-not $name -or $names -cnotcontains $name) { continue }
        if (-not $newest.ContainsKey($name) -or $snapshot.Time -gt $newest[$name].Time) { $newest[$name] = $snapshot }
        if (-not $left.ContainsKey($name)) { $left[$name] = 0 }
        if (-not $remove[$snapshot.Id]) { $left[$name]++ }
    }

    $rows = @(foreach ($snapshot in $Snapshots) {
        $name = [string]$snapshot.Job
        $kept = $retention[$snapshot.Id]
        $reason = ''
        if ($kept -and $kept.Action -eq 'Keep') { $reason = $kept.Reason }
        elseif (-not $name -or $names -cnotcontains $name) { $reason = 'outside retention' }

        $warning = ''
        if ($remove[$snapshot.Id]) {
            $warnings = @()
            if ($Mode -ne 'Retention' -and $kept -and $kept.Action -eq 'Keep') { $warnings += 'retention keeps it' }
            if ($newest.ContainsKey($name) -and $newest[$name].Id -eq $snapshot.Id) { $warnings += "newest of job '$name'" }
            $warning = $warnings -join '; '
            New-ForgetRow $snapshot 'Remove' $reason $warning
        }
        else { New-ForgetRow $snapshot 'Keep' $reason }
    })

    $planWarnings = @()
    if ($NoPolicy -and $Mode -ne 'Retention') { $planWarnings += 'No retention policy is configured: nothing forgets snapshots automatically.' }
    $keptCount = @($rows | Where-Object { $_.Action -eq 'Remove' -and $_.Warning -like '*retention keeps it*' }).Count
    if ($keptCount -gt 0) { $planWarnings += "$keptCount of these snapshots would be kept by the retention policy." }
    foreach ($name in $names) {
        if (-not $newest.ContainsKey($name) -or -not $remove[$newest[$name].Id]) { continue }
        if ($left[$name] -eq 0) { $planWarnings += "Job '$name' is left without snapshots." }
        else { $planWarnings += "The newest snapshot of job '$name' is forgotten." }
    }
    if ($missing.Count -gt 0) { $planWarnings += "$($missing.Count) of the chosen snapshots no longer exist." }

    return [pscustomobject]@{
        Rows      = $rows
        RemoveIds = [string[]]@($rows | Where-Object { $_.Action -eq 'Remove' } | ForEach-Object { $_.Id })
        Warnings  = $planWarnings
        Missing   = $missing
    }
}

# Per job (Format-SnapshotGroupLabel order: by label): Label, Remove, Keep.
function Get-ForgetTotals {
    param($Rows)

    return @(@($Rows | Where-Object { $_ }) | Group-Object { Format-SnapshotGroupLabel $_.Job } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Label  = $_.Name
            Remove = @($_.Group | Where-Object { $_.Action -eq 'Remove' }).Count
            Keep   = @($_.Group | Where-Object { $_.Action -ne 'Remove' }).Count
        }
    })
}

# Forget rows as aligned text lines (log and console): the ones to forget (-All: kept ones too, with their
# reasons), by job and newest first, then the totals per job (of the jobs that lose snapshots, or all with -All).
function Format-ForgetTable {
    param($Rows, [switch]$All)

    $Rows = @($Rows | Where-Object { $_ })
    $shown = @($Rows | Where-Object { $All -or $_.Action -eq 'Remove' } |
        Sort-Object @{ Expression = { Format-SnapshotGroupLabel $_.Job } }, @{ Expression = 'Time'; Descending = $true })
    if ($Rows.Count -eq 0) { return @('  No snapshots.') }

    $lines = @()
    if ($shown.Count -gt 0) {
        $jobWidth = [Math]::Max(3, (@($shown | ForEach-Object { (Format-SnapshotGroupLabel $_.Job).Length }) | Measure-Object -Maximum).Maximum)
        $hostWidth = [Math]::Max(4, (@($shown | ForEach-Object { ([string]$_.Host).Length }) | Measure-Object -Maximum).Maximum)
        $format = "  {0,-$jobWidth}  {1,-16}  {2,-8}  {3,-$hostWidth}  {4,-6}  {5}"
        $lines += $format -f 'Job', 'Time', 'ID', 'Host', 'Action', 'Reason'
        $lines += $format -f ('-' * $jobWidth), ('-' * 16), ('-' * 8), ('-' * $hostWidth), ('-' * 6), ('-' * 6)
        foreach ($row in $shown) {
            $action = 'keep'
            if ($row.Action -eq 'Remove') { $action = 'FORGET' }
            $note = $row.Reason
            if ($row.Warning) { $note = (@($note, "(!) $($row.Warning)") | Where-Object { $_ }) -join '  ' }
            $lines += $format -f (Format-SnapshotGroupLabel $row.Job), ('{0:yyyy-MM-dd HH:mm}' -f $row.Time), $row.ShortId, $row.Host, $action, $note
        }
        $lines += ''
    }
    foreach ($total in @(Get-ForgetTotals $Rows | Where-Object { $All -or $_.Remove -gt 0 })) {
        $lines += '  {0}: {1} to forget, {2} kept' -f $total.Label, $total.Remove, $total.Keep
    }
    return $lines
}

# The text the user must type to confirm a forget, or $null when a yes is enough: the job's name for all of a job
# ('no job tag' for the snapshots without one), the computer name for everything.
function Get-ForgetConfirmation {
    param([string]$Mode, [string]$Job, [string]$Hostname)

    switch ($Mode) {
        'Job' {
            if ($Job) { return $Job }
            return 'no job tag'
        }
        'Everything' { return $Hostname }
    }
    return $null
}

# Forgets snapshots by full ID (the Forget dialog's or the menu's choice), on a fresh snapshot list: IDs that no
# longer exist are skipped. -Retention: the IDs are the retention policy's, so success counts as the last forget.
function Invoke-SnapshotForget {
    param([string[]]$Ids, [switch]$Retention)

    $plan = Get-ForgetPlan 'Selected' @(Get-SnapshotList) $null '' $Ids $script:Config.Jobs
    if ($plan.Missing.Count -gt 0) { Write-Log "$($plan.Missing.Count) of the chosen snapshots no longer exist; skipping them." -Level Warning }
    $count = $plan.RemoveIds.Count
    if ($count -eq 0) {
        Write-Log 'Nothing to forget.'
        return 'Success'
    }

    Write-Log "Forgetting $count snapshots:"
    foreach ($line in @(Format-ForgetTable $plan.Rows)) { Write-Log $line }
    $code = Invoke-ResticForIds @('forget') $plan.RemoveIds -Quiet
    if ($code -ne 0) {
        Write-Log "Forget failed (exit code $code)." -Level Error
        return 'Failed'
    }

    if ($Retention) { Save-StateTimestamp 'lastForget' }
    Write-Log "Forgot $count snapshots." -Level Success
    return 'Success'
}

function Invoke-Prune {
    Write-Log 'Pruning unreferenced data...'
    $code = Invoke-Restic @('prune')
    if ($code -ne 0) {
        Write-Log "Prune failed (exit code $code)." -Level Error
        return 'Failed'
    }

    Save-StateTimestamp 'lastPrune'
    Write-Log 'Prune completed.' -Level Success
    return 'Success'
}

function Invoke-Check {
    $arguments = @('check')
    $subset = [string](Get-Setting $script:Config.Maintenance 'checkReadDataSubset' '')
    if ($subset) { $arguments += @('--read-data-subset', $subset) }

    Write-Log 'Checking repository integrity...'
    $code = Invoke-Restic $arguments
    if ($code -ne 0) {
        Write-Log "Check failed (exit code $code)." -Level Error
        return 'Failed'
    }

    Save-StateTimestamp 'lastCheck'
    Write-Log 'Check completed.' -Level Success
    return 'Success'
}

function Test-MaintenanceDue {
    param([string]$Name, [double]$IntervalDays)

    if ($IntervalDays -le 0) { return $false }

    $last = Get-Setting (Read-State) $Name
    if (-not $last) { return $true }

    # Two hours of slack, so a daily run that starts slightly earlier than yesterday's still counts as due.
    return ((Get-Date) - [datetime]$last).TotalHours -ge ($IntervalDays * 24 - 2)
}

function Invoke-DueMaintenance {
    $maintenance = $script:Config.Maintenance
    $statuses = @()

    if (Test-MaintenanceDue 'lastForget' (Get-Setting $maintenance 'forgetEveryDays' 0)) { $statuses += Invoke-Forget }
    if (Test-MaintenanceDue 'lastPrune' (Get-Setting $maintenance 'pruneEveryDays' 0)) { $statuses += Invoke-Prune }
    if (Test-MaintenanceDue 'lastCheck' (Get-Setting $maintenance 'checkEveryDays' 0)) { $statuses += Invoke-Check }

    if ($statuses.Count -eq 0) { Write-Log 'No maintenance due.' }
    return $statuses
}

# Newest first. -Repository: another repository than RESTIC_REPOSITORY (its password in RESTIC_PASSWORD).
function Get-SnapshotList {
    param([string]$Repository)

    $arguments = @('snapshots')
    if ($Repository) { $arguments += @('--repo', $Repository) }
    return @(Invoke-ResticJson $arguments | ForEach-Object { ConvertFrom-ResticSnapshot $_ } | Sort-Object Time -Descending)
}

# A snapshot of restic's JSON output (snapshots, forget) as a Get-SnapshotList object.
function ConvertFrom-ResticSnapshot {
    param($Snapshot)

    return [pscustomobject]@{
        Id      = [string]$Snapshot.id
        ShortId = ([string]$Snapshot.id).Substring(0, 8)
        Time    = ConvertTo-LocalTime $Snapshot.time
        Job     = [string](@($Snapshot.tags) | Where-Object { $_ -like 'job:*' } | Select-Object -First 1) -replace '^job:', ''
        Host    = [string]$Snapshot.hostname
        Paths   = @($Snapshot.paths) -join ', '
        Tags    = [string[]]@($Snapshot.tags | ForEach-Object { [string]$_ })
    }
}

function Format-SnapshotGroupLabel {
    param([string]$Job)

    if ($Job) { return $Job }
    return '(no job tag)'
}

# The snapshots per job tag: Job ('' = no job tag), Label, Count, Newest, Configured. The configured jobs first (in
# config order, only those with snapshots), then the other job tags (removed or renamed jobs), the untagged last.
function Get-SnapshotJobGroups {
    param($Jobs, $Snapshots)

    $names = @($Jobs | ForEach-Object { $_.Name })
    # Tags are case-sensitive in restic.
    $groups = [hashtable]::new([StringComparer]::Ordinal)
    foreach ($snapshot in @($Snapshots | Where-Object { $_ })) {
        $job = [string]$snapshot.Job
        $group = $groups[$job]
        if (-not $group) {
            $group = [pscustomobject]@{
                Job = $job; Label = Format-SnapshotGroupLabel $job; Count = 0; Newest = $null; Configured = [bool]($job -and $names -ccontains $job)
            }
            $groups[$job] = $group
        }
        $group.Count++
        if (-not $group.Newest -or $snapshot.Time -gt $group.Newest) { $group.Newest = $snapshot.Time }
    }

    $result = @(foreach ($name in $names) { if ($groups.ContainsKey($name)) { $groups[$name] } })
    $result += @(foreach ($key in @($groups.Keys | Where-Object { $_ -and $names -cnotcontains $_ } | Sort-Object -CaseSensitive)) { $groups[$key] })
    if ($groups.ContainsKey('')) { $result += $groups[''] }
    return $result
}

# Snapshots that no configured job gives retention: those of removed or renamed jobs, and those without a
# job tag (Job ''). One group per job tag, the untagged last (Get-SnapshotJobGroups objects).
function Get-UnmanagedSnapshotGroups {
    param($Jobs, $Snapshots)

    return @(Get-SnapshotJobGroups $Jobs $Snapshots | Where-Object { -not $_.Configured })
}

# What a cleanup does. Actions: @{ Job ('' = the snapshots without a job tag); Action = Delete | KeepNewest | Retag;
# Target (Retag: a configured job) }. Returns one step per action with the full IDs it acts on (Ids); KeepNewest
# keeps the newest snapshot of each host. Throws for a configured job: its snapshots get retention.
function Get-CleanupPlan {
    param($Actions, $Snapshots, $Jobs)

    $names = @($Jobs | ForEach-Object { $_.Name })
    return @(foreach ($action in @($Actions)) {
        $job = [string]$action.Job
        $label = Format-SnapshotGroupLabel $job
        $target = [string]$action.Target
        if ($job -and $names -ccontains $job) { throw "Job '$job' is configured; its snapshots already get retention." }
        if ($action.Action -notin @('Delete', 'KeepNewest', 'Retag')) { throw "Unknown cleanup action: $($action.Action)" }
        if ($action.Action -eq 'Retag' -and $names -cnotcontains $target) {
            throw "Can't assign the snapshots of $label to '$target': there is no such job."
        }

        $group = @($Snapshots | Where-Object { [string]$_.Job -ceq $job })
        if ($action.Action -eq 'KeepNewest') {
            $keep = @($group | Group-Object Host | ForEach-Object { ($_.Group | Sort-Object Time -Descending | Select-Object -First 1).Id })
            $ids = @($group | Where-Object { $keep -notcontains $_.Id } | ForEach-Object { $_.Id })
        }
        else { $ids = @($group | ForEach-Object { $_.Id }) }

        [pscustomobject]@{ Job = $job; Label = $label; Action = [string]$action.Action; Target = $target; Ids = $ids }
    })
}

function Format-CleanupStep {
    param($Step)

    $count = @($Step.Ids).Count
    switch ($Step.Action) {
        'Delete'     { return "$($Step.Label): forget all $count snapshots" }
        'KeepNewest' { return "$($Step.Label): keep the newest snapshot, forget $count" }
        'Retag'      { return "$($Step.Label): assign $count snapshots to job '$($Step.Target)'" }
    }
}

function Test-CleanupRemoves {
    param($Actions)

    return [bool](@($Actions) | Where-Object { $_.Action -in @('Delete', 'KeepNewest') })
}

# Runs restic once per 100 IDs: a Windows command line holds 32,767 characters, a full ID is 64. Returns the
# first non-zero exit code, or 0.
function Invoke-ResticForIds {
    param([string[]]$Arguments, [string[]]$Ids, [switch]$Quiet)

    for ($i = 0; $i -lt $Ids.Count; $i += 100) {
        $last = [Math]::Min($i + 100, $Ids.Count) - 1
        $code = Invoke-Restic ($Arguments + $Ids[$i..$last]) -Quiet:$Quiet
        if ($code -ne 0) { return $code }
    }
    return 0
}

# The Cleanup operation (see Get-CleanupPlan), on a fresh snapshot list.
function Invoke-SnapshotCleanup {
    param([object[]]$Actions)

    $statuses = @()
    foreach ($step in @(Get-CleanupPlan $Actions (Get-SnapshotList) $script:Config.Jobs)) {
        Write-Log (Format-CleanupStep $step)
        if ($step.Ids.Count -eq 0) {
            Write-Log 'Nothing to do.'
            continue
        }

        # restic writes changed tags as new snapshots, so retagged snapshots get new IDs.
        if ($step.Action -eq 'Retag') {
            $arguments = @('tag', '--add', "job:$($step.Target)")
            if ($step.Job) { $arguments += @('--remove', "job:$($step.Job)") }
        }
        else { $arguments = @('forget') }

        $code = Invoke-ResticForIds $arguments $step.Ids
        if ($code -ne 0) {
            Write-Log "Cleanup of $($step.Label) failed (exit code $code)." -Level Error
            $statuses += 'Failed'
        }
        else { $statuses += 'Success' }
    }

    if ($statuses.Count -eq 0) { return 'Success' }
    return $statuses
}

# The menu's front end of Cleanup: asks what to do with each group of snapshots outside retention.
function Invoke-Cleanup {
    $jobs = @($script:Config.Jobs)
    $snapshots = @(Get-SnapshotList)
    $groups = @(Get-UnmanagedSnapshotGroups $jobs $snapshots)
    if ($groups.Count -eq 0) {
        Write-Log 'Every snapshot belongs to a configured job.' -Level Success
        return 'Success'
    }

    Write-Host ''
    Write-Host 'Configured jobs:'
    for ($i = 0; $i -lt $jobs.Count; $i++) { Write-Host ('{0,4}. {1}' -f ($i + 1), $jobs[$i].Name) }
    Write-Host ''
    Write-Host 'Snapshots outside retention (no configured job forgets them):'
    $actions = @()
    foreach ($group in $groups) {
        Write-Host ('  {0}: {1} snapshots, newest {2:yyyy-MM-dd HH:mm}' -f $group.Label, $group.Count, $group.Newest)
        while ($true) {
            $answer = (Read-Host '  [K]eep, [D]elete all, keep the [N]ewest only, or a job number to assign them to (Enter = keep)').Trim()
            $number = 0
            if ($answer -match '^(k|keep)?$') { break }
            if ($answer -match '^(d|delete)$') { $actions += @{ Job = $group.Job; Action = 'Delete' }; break }
            if ($answer -match '^(n|newest)$') { $actions += @{ Job = $group.Job; Action = 'KeepNewest' }; break }
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $jobs.Count) {
                $actions += @{ Job = $group.Job; Action = 'Retag'; Target = $jobs[$number - 1].Name }
                break
            }
            Write-Host '  Unknown choice.' -ForegroundColor Yellow
        }
    }
    if ($actions.Count -eq 0) {
        Write-Log 'Nothing changed.'
        return 'Success'
    }

    Write-Host ''
    foreach ($step in @(Get-CleanupPlan $actions $snapshots $jobs)) { Write-Host "  $(Format-CleanupStep $step)" }
    if ((Read-Host 'Apply? Forgotten snapshots cannot be restored. [y/N]') -notmatch '^(y|yes)$') {
        Write-Log 'Cleanup cancelled.'
        return 'Success'
    }

    $statuses = @(Invoke-SnapshotCleanup -Actions $actions)
    if ((Get-ExitCode $statuses) -eq 0 -and (Test-CleanupRemoves $actions) -and
        (Read-Host 'Prune now to free the space? Otherwise the next scheduled prune does. [y/N]') -match '^(y|yes)$') {
        $statuses += Invoke-Prune
    }
    return $statuses
}

# Menu input like "1,3,5-8" (numbers from 1 to Count) as sorted 0-based indexes, or $null when invalid or empty.
function ConvertTo-NumberSelection {
    param([string]$Text, [int]$Count)

    $picked = @{}
    foreach ($part in ($Text -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -notmatch '^(\d+)(?:-(\d+))?$') { return $null }
        $first = [int]$Matches[1]
        $last = $first
        if ($Matches[2]) { $last = [int]$Matches[2] }
        if ($first -lt 1 -or $last -gt $Count -or $first -gt $last) { return $null }
        for ($i = $first; $i -le $last; $i++) { $picked[$i - 1] = $true }
    }
    if ($picked.Count -eq 0) { return $null }
    return , [int[]]@($picked.Keys | Sort-Object)
}

# The menu's front end of forgetting (the window's Forget dialog in text form): retention, all of a job, picked
# snapshots or everything. Shows what goes with the same warnings, asks (typing the job or computer name for the
# bulk choices), forgets by ID, then offers to prune.
function Invoke-ForgetMenu {
    Write-Host ''
    Write-Host '  1. Apply the retention policy'
    Write-Host '  2. All snapshots of a job'
    Write-Host '  3. Snapshots you pick'
    Write-Host '  4. Everything in this repository'
    $modes = @{ '1' = 'Retention'; '2' = 'Job'; '3' = 'Selected'; '4' = 'Everything' }
    $choice = (Read-Host 'Select (Enter to cancel)').Trim()
    if (-not $modes.ContainsKey($choice)) {
        Write-Log 'Forget cancelled.'
        return 'Success'
    }
    $mode = $modes[$choice]
    $jobs = @($script:Config.Jobs)

    # Retention needs the dry run; picking uses it to show and warn about what retention keeps.
    $statuses = @()
    $preview = $null
    $noPolicy = $false
    if ($mode -in @('Retention', 'Selected')) {
        $statuses = @(Invoke-Forget -DryRun -Quiet:($mode -eq 'Selected'))
        if ((Get-ExitCode $statuses) -eq 1) { return $statuses }
        $preview = $script:ActionData.Preview
        $noPolicy = $script:ActionData.NoPolicy
        $snapshots = @($script:ActionData.Snapshots)
        if ($mode -eq 'Retention' -and $noPolicy) { return $statuses }
    }
    else { $snapshots = @(Get-SnapshotList) }
    if ($snapshots.Count -eq 0) {
        Write-Log 'The repository has no snapshots.'
        return $statuses + 'Success'
    }

    $job = ''
    $ids = @()
    if ($mode -eq 'Job') {
        $groups = @(Get-SnapshotJobGroups $jobs $snapshots)
        Write-Host ''
        for ($i = 0; $i -lt $groups.Count; $i++) {
            $group = $groups[$i]
            $note = ''
            if (-not $group.Configured) { $note = ', outside retention' }
            Write-Host ('{0,4}. {1} ({2} snapshots, newest {3:yyyy-MM-dd HH:mm}{4})' -f ($i + 1), $group.Label, $group.Count, $group.Newest, $note)
        }
        $answer = (Read-Host 'Job number (Enter to cancel)').Trim()
        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $groups.Count) {
            Write-Log 'Forget cancelled.'
            return $statuses + 'Success'
        }
        $job = $groups[$number - 1].Job
    }
    elseif ($mode -eq 'Selected') {
        $retention = @{}
        foreach ($row in @($preview)) { $retention[$row.Id] = $row }
        $names = @($jobs | ForEach-Object { $_.Name })
        $jobWidth = [Math]::Max(3, (@($snapshots | ForEach-Object { (Format-SnapshotGroupLabel $_.Job).Length }) | Measure-Object -Maximum).Maximum)
        $format = "{0,4}  {1,-16}  {2,-8}  {3,-$jobWidth}  {4}"
        Write-Host ''
        Write-Host ($format -f '#', 'Time', 'ID', 'Job', 'Retention')
        for ($i = 0; $i -lt $snapshots.Count; $i++) {
            $s = $snapshots[$i]
            $row = $retention[$s.Id]
            if ($row -and $row.Action -eq 'Remove') { $text = 'forgets it' }
            elseif ($row) { $text = "keeps it: $($row.Reason)" }
            elseif ($s.Job -and $names -ccontains $s.Job) { $text = '' }
            else { $text = 'outside retention' }
            Write-Host ($format -f ($i + 1), ('{0:yyyy-MM-dd HH:mm}' -f $s.Time), $s.ShortId, (Format-SnapshotGroupLabel $s.Job), $text)
        }
        while ($true) {
            $answer = (Read-Host 'Snapshot numbers, e.g. 1,3,5-8 (Enter to cancel)').Trim()
            if (-not $answer) {
                Write-Log 'Forget cancelled.'
                return $statuses + 'Success'
            }
            $indexes = ConvertTo-NumberSelection $answer $snapshots.Count
            # Not just if ($indexes): @(0) is false.
            if ($null -ne $indexes) { break }
            Write-Host 'Unknown selection.' -ForegroundColor Yellow
        }
        $ids = @($indexes | ForEach-Object { $snapshots[$_].Id })
    }

    $plan = Get-ForgetPlan $mode $snapshots $preview $job $ids $jobs $noPolicy
    $count = $plan.RemoveIds.Count
    if ($count -eq 0) {
        Write-Log 'Nothing to forget.' -Level Success
        return $statuses + 'Success'
    }
    Write-Host ''
    foreach ($line in @(Format-ForgetTable $plan.Rows)) { Write-Host $line }
    foreach ($warning in @($plan.Warnings)) { Write-Host "  (!) $warning" -ForegroundColor Yellow }
    Write-Host ''

    $confirmation = Get-ForgetConfirmation $mode $job $script:Config.Hostname
    if ($confirmation) {
        Write-Host "Forget all $count snapshots? Forgotten snapshots can't be restored." -ForegroundColor Yellow
        $confirmed = (Read-Host "Type $confirmation to continue").Trim() -eq $confirmation
    }
    else { $confirmed = (Read-Host "Forget these $count snapshots? Forgotten snapshots can't be restored. [y/N]") -match '^(y|yes)$' }
    if (-not $confirmed) {
        Write-Log 'Forget cancelled.'
        return $statuses + 'Success'
    }

    $statuses = @(Invoke-SnapshotForget -Ids $plan.RemoveIds -Retention:($mode -eq 'Retention'))
    if ((Get-ExitCode $statuses) -eq 0) {
        $question = 'Prune now to free the space? Otherwise the next scheduled prune does.'
        # Freeing the space is the point of forgetting a whole job or everything.
        if ($mode -in @('Job', 'Everything')) { $prune = (Read-Host "$question [Y/n]") -notmatch '^(n|no)$' }
        else { $prune = (Read-Host "$question [y/N]") -match '^(y|yes)$' }
        if ($prune) { $statuses += Invoke-Prune }
    }
    return $statuses
}

# Full IDs of the newest snapshot of each configured job (Get-SnapshotList objects).
function Select-NewestSnapshotIds {
    param($Jobs, $Snapshots)

    return @(foreach ($job in @($Jobs)) {
        $newest = @($Snapshots | Where-Object { $_.Job -ceq $job.Name } | Sort-Object Time -Descending | Select-Object -First 1)
        if ($newest.Count -gt 0) { $newest[0].Id }
    })
}

# Setup's copy step: snapshots of the repository From (password FromPassword, the same AWS keys) into this one.
# Scope Latest = the newest snapshot of each configured job, All = every snapshot. restic skips snapshots that
# are already there, so a retry only copies what's missing.
function Copy-RepositorySnapshots {
    param([string]$From, [string]$FromPassword, [string]$Scope)

    $arguments = @('copy', '--from-repo', $From)
    if ($Scope -eq 'Latest') {
        Write-Log "Reading the snapshots of $From"
        $password = $env:RESTIC_PASSWORD
        $env:RESTIC_PASSWORD = $FromPassword
        try { $snapshots = @(Get-SnapshotList -Repository $From) }
        finally { $env:RESTIC_PASSWORD = $password }
        $ids = @(Select-NewestSnapshotIds $script:Config.Jobs $snapshots)
        if ($ids.Count -eq 0) {
            Write-Log "$From has no snapshots of the configured jobs; nothing to copy." -Level Warning
            return 'Warning'
        }
        $arguments += $ids
    }

    Write-Log "Copying snapshots from $From"
    $env:RESTIC_FROM_PASSWORD = $FromPassword
    try { $code = Invoke-Restic $arguments }
    finally { Remove-Item Env:RESTIC_FROM_PASSWORD -ErrorAction SilentlyContinue }
    if ($code -ne 0) {
        Write-Log "Copying the snapshots failed (exit code $code)." -Level Error
        return 'Failed'
    }
    Write-Log 'Snapshots copied.' -Level Success
    return 'Success'
}

# Direct children of a snapshot directory, from the nodes printed by 'restic ls --json'.
function Select-SnapshotChildren {
    param($Nodes, [string]$Path)

    if ($Path -ne '/') { $Path = $Path.TrimEnd('/') }
    return @($Nodes | Where-Object {
            # The first line describes the snapshot itself; 0.17 marks lines with struct_type, later versions with message_type.
            ((Get-Setting $_ 'struct_type') -eq 'node' -or (Get-Setting $_ 'message_type') -eq 'node') -and
            (Get-SnapshotParentPath $_.path) -eq $Path
        } | ForEach-Object {
            $mtime = Get-Setting $_ 'mtime'
            [pscustomobject]@{
                Name  = [string]$_.name
                Type  = [string]$_.type
                Path  = [string]$_.path
                Size  = [long](Get-Setting $_ 'size' 0)
                MTime = if ($mtime) { ConvertTo-LocalTime $mtime } else { $null }
            }
        })
}

# Path is a snapshot path such as /C/Users, or / for the drives at the top level.
function Get-SnapshotChildren {
    param([string]$SnapshotId, [string]$Path)

    return Select-SnapshotChildren @(Invoke-ResticJson @('ls', $SnapshotId, $Path) -Lines) $Path
}

# Builds the restore command. Source is a Windows path (empty = the whole snapshot), SourceType 'dir' or 'file'.
function Get-RestoreArguments {
    param(
        [string]$SnapshotId, [string]$Source, [string]$SourceType, [bool]$InPlace,
        [string]$RestoreRoot, [datetime]$Timestamp
    )

    $base = Join-Path $RestoreRoot ('{0}-{1:yyyyMMdd-HHmmss}' -f $SnapshotId.Substring(0, 8), $Timestamp)

    if (-not $Source) {
        if ($InPlace) { throw 'An in-place restore needs a specific folder or file.' }
        return [pscustomobject]@{ Arguments = @('restore', $SnapshotId, '--target', $base); Spec = $SnapshotId; Target = $base }
    }

    $full = Format-PathArgument ([System.IO.Path]::GetFullPath($Source))
    if ($InPlace) {
        $reason = Get-SystemFolderReason $full
        if ($reason) { throw "In place is refused: $reason Restore to a new folder." }
    }
    switch ($SourceType) {
        'dir'  { $folder = $full; $include = $null }
        'file' { $folder = [System.IO.Path]::GetDirectoryName($full); $include = '/' + [System.IO.Path]::GetFileName($full) }
        default { throw "Unknown source type '$SourceType'; expected 'dir' or 'file'." }
    }

    # A file is restored from its folder with --include; with the <id>:<subfolder> syntax,
    # include patterns are relative to that subfolder (/f.txt), so the file lands in <target>\f.txt.
    $snapshotFolder = ConvertTo-SnapshotPath $folder
    if ($InPlace) { $target = Format-PathArgument $folder }
    else { $target = Join-Path $base (Get-SnapshotLeaf $snapshotFolder) }

    $arguments = @('restore', "$($SnapshotId):$snapshotFolder", '--target', $target)
    $spec = "$($SnapshotId):$snapshotFolder"
    if ($include) {
        $arguments += @('--include', $include)
        $spec += $include
    }
    return [pscustomobject]@{ Arguments = $arguments; Spec = $spec; Target = $target }
}

# What an in-place restore of $Path (a folder or file) would write through into other files: file symbolic links,
# and files with more than one hard link. restic replaces folder links with real folders (tested), so they are
# neither followed nor reported; other reparse points (deduplicated, cloud files) hold the file's own data.
# LinkType opens each file to count its links. Callers wrap the result in @().
function Find-FileLinks {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    $found = @()
    $folders = New-Object System.Collections.Stack
    $entries = @($item)
    while ($true) {
        foreach ($entry in $entries) {
            if ($entry.PSIsContainer) {
                if (-not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $folders.Push($entry.FullName) }
                continue
            }
            switch ([string]$entry.LinkType) {
                'SymbolicLink' { $found += "$($entry.FullName) (symbolic link)" }
                'Junction'     { $found += "$($entry.FullName) (junction)" }
                'HardLink'     { $found += "$($entry.FullName) (hard link)" }
            }
        }
        if ($folders.Count -eq 0) { break }
        $entries = @(Get-ChildItem -LiteralPath $folders.Pop() -Force)
    }
    return $found
}

# New-folder restores: restored files inherit the restore root's permissions (restic keeps only explicit entries),
# and restic writes through file links planted in it. Creates it locked (SYSTEM and Administrators only); an
# existing one is checked, never changed. Returns the problems (Test-TrustedPath); callers wrap the result in @().
function Initialize-RestoreRoot {
    $path = $script:Config.RestoreRoot
    if (-not (Test-Path -LiteralPath $path)) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm('O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)', [System.Security.AccessControl.AccessControlSections]'Owner, Access')
        # Created with its permissions: no moment in which it inherits. If someone else created it meanwhile, this
        # returns theirs and the check below refuses it.
        [void][System.IO.Directory]::CreateDirectory($path, $acl)
        Write-Log "Created $path (SYSTEM and Administrators only)."
    }
    return Test-TrustedPath $path
}

function Invoke-RestoreSnapshot {
    param([string]$SnapshotId, [string]$Source = '', [string]$SourceType = '', [bool]$InPlace = $false)

    $restore = Get-RestoreArguments -SnapshotId $SnapshotId -Source $Source -SourceType $SourceType -InPlace $InPlace `
        -RestoreRoot $script:Config.RestoreRoot -Timestamp (Get-Date)

    if ($InPlace) {
        $path = Format-PathArgument ([System.IO.Path]::GetFullPath($Source))
        Write-Log "Checking $path for file links"
        $links = @(Find-FileLinks $path)
        if ($links.Count -gt 0) {
            $list = @($links | Select-Object -First 10) -join '; '
            if ($links.Count -gt 10) { $list += "; ... ($($links.Count) in all)" }
            Write-Log ("In place is refused: restic would write through these links into other files: $list. " +
                'Remove them, or restore to a new folder. See Help: Restore details.') -Level Error
            return 'Failed'
        }
    }
    else {
        $problems = @(Initialize-RestoreRoot)
        if ($problems.Count -gt 0) {
            Write-Log ("The restore root isn't safe: $($problems -join ' ') Restored files inherit its permissions. " +
                "Restrict it to SYSTEM and Administrators, or set restoreRoot to a folder that doesn't exist yet. " +
                'See Help: Restore details.') -Level Error
            return 'Failed'
        }
    }

    Write-Log "Restoring $($restore.Spec) to $($restore.Target)"
    $code = Invoke-Restic $restore.Arguments
    if ($code -ne 0) {
        Write-Log "Restore failed (exit code $code)." -Level Error
        return 'Failed'
    }

    Write-Log "Restore completed: $($restore.Target)" -Level Success
    return 'Success'
}

# Interactive: gathers the inputs, then calls Invoke-RestoreSnapshot.
function Invoke-Restore {
    $config = $script:Config

    $snapshots = @(Get-SnapshotList)

    if ($snapshots.Count -eq 0) {
        Write-Log 'The repository has no snapshots.' -Level Warning
        return 'Warning'
    }

    Write-Host ''
    Write-Host ('{0,4}  {1,-16}  {2,-8}  {3,-12}  {4}' -f '#', 'Time', 'ID', 'Job', 'Paths')
    for ($i = 0; $i -lt $snapshots.Count; $i++) {
        $s = $snapshots[$i]
        Write-Host ('{0,4}  {1:yyyy-MM-dd HH:mm}  {2}  {3,-12}  {4}' -f ($i + 1), $s.Time, $s.ShortId, $s.Job, $s.Paths)
    }
    Write-Host ''

    $selection = Read-Host 'Snapshot number (Enter to cancel)'
    if (-not $selection) {
        Write-Log 'Restore cancelled.'
        return 'Success'
    }

    $index = 0
    if (-not [int]::TryParse($selection, [ref]$index) -or $index -lt 1 -or $index -gt $snapshots.Count) {
        throw "Invalid selection: $selection"
    }
    $snapshot = $snapshots[$index - 1]

    Write-Host "Snapshot $($snapshot.ShortId) contains: $($snapshot.Paths)"
    $source = (Read-Host 'Folder or file to restore, e.g. C:\Users\name\Documents (Enter = entire snapshot)').Trim().Trim('"')

    $sourceType = ''
    if ($source) {
        $path = ConvertTo-SnapshotPath $source
        $leaf = Get-SnapshotLeaf $path
        $node = @(Get-SnapshotChildren $snapshot.Id (Get-SnapshotParentPath $path)) |
            Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
        if (-not $node) { throw "$source is not in snapshot $($snapshot.ShortId)." }
        if ($node.Type -eq 'dir') { $sourceType = 'dir' } else { $sourceType = 'file' }
    }

    Write-Host "[1] Restore to a new folder under $($config.RestoreRoot)"
    Write-Host '[2] Restore in place (overwrites existing files)'
    $choice = Read-Host 'Select'

    switch ($choice) {
        '1' { $inPlace = $false }
        '2' {
            $inPlace = $true
            $target = (Get-RestoreArguments $snapshot.Id $source $sourceType $true $config.RestoreRoot (Get-Date)).Target
            $when = '{0:yyyy-MM-dd HH:mm}' -f $snapshot.Time
            if ($sourceType -eq 'file') {
                Write-Host "$source will be overwritten with the version from snapshot $($snapshot.ShortId) ($when)." -ForegroundColor Yellow
            }
            else {
                Write-Host "Files in $target will be overwritten with the versions from snapshot $($snapshot.ShortId) ($when)." -ForegroundColor Yellow
                Write-Host 'Files that are not in the snapshot are left alone.' -ForegroundColor Yellow
            }
            if ((Read-Host 'Type YES to continue') -cne 'YES') {
                Write-Log 'Restore cancelled.'
                return 'Success'
            }
        }
        default { throw "Invalid choice: $choice" }
    }

    return Invoke-RestoreSnapshot -SnapshotId $snapshot.Id -Source $source -SourceType $sourceType -InPlace $inPlace
}

# Task Scheduler through its COM API (Schedule.Service) rather than the ScheduledTasks cmdlets: their CIM
# provider can fail for elevated callers ("The parameter is incorrect" on every call, seen on a Windows 11
# Insider build) while the COM API, which they wrap, keeps working.

function Get-TaskService {
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    return $service
}

# Path: a task path as in Select-BackupTasks ('\' or '\Folder\').
function Get-TaskFolder {
    param($Service, [string]$Path)

    $folder = $Path.TrimEnd('\')
    if (-not $folder) { $folder = '\' }
    return $Service.GetFolder($folder)
}

# Every task, hidden ones included, shaped for Select-BackupTasks: TaskName, TaskPath ('\Folder\'), State,
# Actions (Arguments of each exec action), Task (the COM object). A folder that can't be read is skipped.
function Get-ScheduledTaskList {
    param($Service = (Get-TaskService))

    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($Service.GetFolder('\'))
    $tasks = @()
    while ($pending.Count -gt 0) {
        $folder = $pending.Dequeue()
        try {
            foreach ($sub in @($folder.GetFolders(0))) { $pending.Enqueue($sub) }
            $path = $folder.Path.TrimEnd('\') + '\'
            foreach ($task in @($folder.GetTasks(1))) { $tasks += ConvertFrom-ComTask $task $path }
        }
        catch { }
    }
    return $tasks
}

# One task (COM object) in the shape of Get-ScheduledTaskList; Path is its folder ('\Folder\').
function ConvertFrom-ComTask {
    param($Task, [string]$Path = '\')

    $states = @{ 1 = 'Disabled'; 2 = 'Queued'; 3 = 'Ready'; 4 = 'Running' }
    $state = 'Unknown'
    if ($states.ContainsKey([int]$Task.State)) { $state = $states[[int]$Task.State] }
    elseif ($Task.Definition.Settings.Enabled -eq $false) { $state = 'Disabled' }
    $actions = @(foreach ($action in @($Task.Definition.Actions)) {
        if ($action.Type -eq 0) { [pscustomobject]@{ Arguments = [string]$action.Arguments } }
    })
    return [pscustomobject]@{ TaskName = $Task.Name; TaskPath = $Path; State = $state; Actions = $actions; Task = $Task }
}

# Setup registers the task under this name in Task Scheduler's root folder: a '\' would create folders.
function Assert-TaskName {
    param([string]$Name)

    if ($Name.Length -gt 200 -or $Name -notmatch '^\w[\w .()-]*(?<! )$') {
        throw "Task name '$Name' is invalid. Use letters, digits, spaces, '.', '_', '-', '(' or ')'."
    }
}

# Task Scheduler reports 1899-12-30 (or 1999-11-30) for "never" or "not scheduled".
function ConvertFrom-TaskTime {
    param($Time)

    if ($Time -is [datetime] -and $Time.Year -ge 2000) { return $Time }
    return $null
}

# The definition Setup registers: daily at At, run as SYSTEM with highest privileges. The settings are
# the ones New-ScheduledTaskSettingsSet produced before the switch to COM.
function New-BackupTaskDefinition {
    param($Service, [datetime]$At, [int]$MaxHours, [bool]$Disabled)

    $definition = $Service.NewTask(0)
    $definition.RegistrationInfo.Description = 'Restic backup and maintenance'
    $definition.Principal.UserId = 'SYSTEM'
    $definition.Principal.LogonType = 5            # TASK_LOGON_SERVICE_ACCOUNT
    $definition.Principal.RunLevel = 1             # TASK_RUNLEVEL_HIGHEST

    $settings = $definition.Settings
    $settings.Compatibility = 3                    # TASK_COMPATIBILITY_V2_1, what the cmdlets registered
    $settings.StartWhenAvailable = $true
    $settings.RunOnlyIfNetworkAvailable = $true
    $settings.MultipleInstances = 2                # TASK_INSTANCES_IGNORE_NEW
    $settings.ExecutionTimeLimit = "PT$($MaxHours)H"
    $settings.Enabled = -not $Disabled

    # Local time without an offset, so it stays at dailyAt across DST changes (the cmdlets stored an offset).
    $trigger = $definition.Triggers.Create(2)      # TASK_TRIGGER_DAILY
    $trigger.StartBoundary = $At.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $trigger.DaysInterval = 1

    $action = $definition.Actions.Create(0)        # TASK_ACTION_EXEC
    # Full path: a bare name depends on the search order.
    $action.Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Backup' -f $script:ScriptPath
    $action.WorkingDirectory = Split-Path $script:ScriptPath
    return $definition
}

# Replaces: leftover tasks (from Get-TaskStatus) to remove once the configured one is registered.
# A disabled task stays disabled; a new one takes the state of a disabled task it replaces.
function Register-BackupTask {
    param([object[]]$Replaces = @())

    $schedule = $script:Config.Schedule
    $taskName = [string](Get-Setting $schedule 'taskName' 'Restic Backup')
    $dailyAt = [string](Get-Setting $schedule 'dailyAt' '02:00')
    $maxHours = [int](Get-Setting $schedule 'maxRuntimeHours' 12)
    $at = [datetime]::ParseExact($dailyAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $Replaces = @($Replaces | Where-Object { $_ })

    Assert-TaskName $taskName

    $service = Get-TaskService
    $root = $service.GetFolder('\')
    $existing = $null
    try { $existing = $root.GetTask($taskName) } catch { }
    # Create or update would replace another program's task of that name.
    if ($existing -and -not (Test-BackupTask (ConvertFrom-ComTask $existing) (Split-Path -Leaf $script:ScriptPath))) {
        throw "A scheduled task named '$taskName' already exists and doesn't run this tool. Change the task name in Settings (schedule.taskName)."
    }
    # From the definition: the runtime Enabled/State can come back empty when Task Scheduler hasn't loaded the task.
    if ($existing) { $disabled = $existing.Definition.Settings.Enabled -eq $false }
    else { $disabled = @($Replaces | Where-Object { $_.State -eq 'Disabled' }).Count -gt 0 }

    $definition = New-BackupTaskDefinition $service $at $maxHours $disabled
    # Create or update replaces a task of the same name; Task Scheduler can't rename, so a renamed one is a new task.
    $root.RegisterTaskDefinition($taskName, $definition, 6, 'SYSTEM', $null, 5) | Out-Null   # TASK_CREATE_OR_UPDATE, service account

    Write-Log "Scheduled task '$taskName' registered: daily at $dailyAt as SYSTEM." -Level Success
    if ($disabled) { Write-Log "The task is kept disabled. Enable it to resume scheduled backups." -Level Warning }

    $status = 'Success'
    foreach ($old in $Replaces) {
        try {
            (Get-TaskFolder $service $old.Path).DeleteTask($old.Name, 0)
            Write-Log "Old scheduled task '$($old.Display)' removed." -Level Success
        }
        catch {
            Write-Log "Old scheduled task '$($old.Display)' could not be removed: $($_.Exception.Message) Remove it in Task Scheduler." -Level Error
            $status = 'Warning'
        }
    }
    return $status
}

# True when a task runs this script's Backup mode, from any folder (it may have moved since).
function Test-BackupTask {
    param($Task, [string]$ScriptName)

    foreach ($action in @($Task.Actions)) {
        $arguments = [string]$action.Arguments
        if ($arguments.IndexOf("\$ScriptName", [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $arguments -match '-Mode\s+"?Backup\b') { return $true }
    }
    return $false
}

# Splits the scheduled tasks into the configured one (in the root folder) and leftovers: other tasks
# of this script, e.g. under a name used before a rename. Returns Task ($null = not registered), Leftovers.
function Select-BackupTasks {
    param($Tasks, [string]$TaskName, [string]$ScriptName)

    $configured = $null
    $leftovers = @()
    foreach ($task in @($Tasks)) {
        if ($task.TaskPath -eq '\' -and $task.TaskName -eq $TaskName) { $configured = $task; continue }
        if (Test-BackupTask $task $ScriptName) {
            $leftovers += [pscustomobject]@{
                Name = $task.TaskName; Path = $task.TaskPath; State = [string]$task.State
                Display = $task.TaskPath.TrimStart('\') + $task.TaskName
            }
        }
    }
    return [pscustomobject]@{ Task = $configured; Leftovers = $leftovers }
}

function Format-TaskLeftovers {
    param($Leftovers)
    return (@($Leftovers) | ForEach-Object { "'$($_.Display)' ($($_.State))" }) -join ', '
}

# State: Ready, Disabled, Running, Queued (Task Scheduler's names). Leftovers: see Select-BackupTasks.
# Foreign: a task of that name exists but doesn't run this tool; it counts as not registered, and Setup refuses it.
function Get-TaskStatus {
    $taskName = [string](Get-Setting $script:Config.Schedule 'taskName' 'Restic Backup')
    $status = [pscustomobject]@{
        Name = $taskName; Registered = $false; Foreign = $false; State = $null; LocationMatches = $false; NextRun = $null
        LastRun = $null; LastResult = $null; Leftovers = @()
    }

    $scriptName = Split-Path -Leaf $script:ScriptPath
    $found = Select-BackupTasks @(Get-ScheduledTaskList) $taskName $scriptName
    $status.Leftovers = @($found.Leftovers)
    $task = $found.Task
    if (-not $task) { return $status }
    if (-not (Test-BackupTask $task $scriptName)) {
        $status.Foreign = $true
        return $status
    }
    $status.Registered = $true
    $status.State = [string]$task.State

    # The task stores an absolute path, which no longer matches once the folder has moved. Tasks of older
    # versions pass -ConfigFile, which no longer exists: they fail until Setup updates them.
    $arguments = [string](@($task.Actions) | Select-Object -First 1).Arguments
    $status.LocationMatches = $arguments.IndexOf($script:ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $arguments.IndexOf('-ConfigFile', [StringComparison]::OrdinalIgnoreCase) -lt 0

    try {
        $status.NextRun = ConvertFrom-TaskTime $task.Task.NextRunTime
        $status.LastRun = ConvertFrom-TaskTime $task.Task.LastRunTime
        if ($status.LastRun) { $status.LastResult = [int]$task.Task.LastTaskResult }
    }
    catch { }
    return $status
}

# Warns when the task is missing or the folder has moved since Setup registered it.
function Test-TaskLocation {
    $task = Get-TaskStatus
    if ($task.Foreign) {
        Write-Log "A scheduled task named '$($task.Name)' exists but isn't this tool's. Change schedule.taskName, then run Setup." -Level Warning
    }
    elseif (-not $task.Registered) {
        Write-Log "Scheduled task '$($task.Name)' is not registered. Run Setup to create it." -Level Warning
    }
    elseif (-not $task.LocationMatches) {
        Write-Log "Scheduled task '$($task.Name)' points to a different location. Run Setup to update it. See Help: Moving the folder." -Level Warning
    }
    if ($task.State -eq 'Disabled') {
        Write-Log "Scheduled task '$($task.Name)' is disabled: no scheduled backups run. Enable it from the menu." -Level Warning
    }
    if ($task.Leftovers.Count -gt 0) {
        Write-Log "Other scheduled tasks also run this backup: $(Format-TaskLeftovers $task.Leftovers). Run Setup to remove them. See Help: Scheduled task." -Level Warning
    }
}

# Menu header line, e.g. "'Restic Backup' Ready, next 2026-10-26 02:00".
function Format-TaskSummary {
    param($Task)

    if ($Task.Foreign) { return "'$($Task.Name)' is another program's task: change schedule.taskName" }
    if (-not $Task.Registered) { return "'$($Task.Name)' not registered" }
    $text = "'$($Task.Name)' $($Task.State)"
    if ($Task.State -eq 'Disabled') { $text += ' (no scheduled backups)' }
    elseif ($Task.NextRun) { $text += ', next {0:yyyy-MM-dd HH:mm}' -f $Task.NextRun }
    if ($Task.Leftovers.Count -gt 0) { $text += "; also found: $(Format-TaskLeftovers $Task.Leftovers)" }
    return $text
}

# Enables or disables the configured task in Task Scheduler (not a config setting; Setup keeps the state).
function Set-BackupTaskEnabled {
    param([bool]$Enabled)

    $task = Get-TaskStatus
    if ($task.Foreign) {
        Write-Log "The scheduled task '$($task.Name)' isn't this tool's: not changed." -Level Error
        return 'Failed'
    }
    if (-not $task.Registered) {
        Write-Log "Scheduled task '$($task.Name)' is not registered. Run Setup to create it." -Level Error
        return 'Failed'
    }

    (Get-TaskService).GetFolder('\').GetTask($task.Name).Enabled = $Enabled
    if ($Enabled) {
        Write-Log "Scheduled task '$($task.Name)' enabled." -Level Success
    }
    else {
        Write-Log "Scheduled task '$($task.Name)' disabled: no scheduled backups run until it is enabled again." -Level Warning
        if ($task.State -eq 'Running') { Write-Log 'The run in progress continues.' }
    }
    return 'Success'
}

# Interactive: gathers the inputs, then calls Invoke-SetupCore.
function Invoke-Setup {
    $config = $script:Config

    Write-Log "Setup for $($config.Hostname)"
    Write-Log "Repository: $($config.Repository)"

    # restic first, so nothing is asked for in vain; Invoke-SetupCore then finds it installed.
    try { Install-Restic }
    catch {
        Write-Log $_.Exception.Message -Level Error
        $zip = (Read-Host "Path to a local copy of $((Get-ResticTarget).ZipName) (Enter = cancel Setup)").Trim().Trim('"')
        if (-not $zip) { throw 'Setup cancelled: restic is not installed.' }
        Install-Restic -ZipPath $zip
    }

    $secrets = $null
    $writeSecrets = $true
    if (Test-Path -LiteralPath $config.SecretsFile -PathType Leaf) {
        $writeSecrets = (Read-Host 'Secrets are already stored. Replace them? [y/N]') -match '^(y|yes)$'
    }

    if ($writeSecrets) {
        $accessKey = (Read-Host 'AWS access key ID').Trim()
        $secretKey = Read-PlainSecret 'AWS secret access key'
        $password = Read-PlainSecret 'Restic repository password'
        if ($password -cne (Read-PlainSecret 'Confirm restic repository password')) {
            throw 'Passwords do not match.'
        }
        if (-not $accessKey -or -not $secretKey -or -not $password) {
            throw 'All three secrets are required.'
        }
        $secrets = @{ awsAccessKeyId = $accessKey; awsSecretAccessKey = $secretKey; resticPassword = $password }
    }

    $initialize = (Read-Host 'Initialize the repository if it does not exist? [Y/n]') -notmatch '^(n|no)$'

    $copyFrom = ''
    $copyScope = 'None'
    $previous = Get-RepositoryChange
    if ($previous) {
        Write-Log "This switches the repository from $previous to $($config.Repository)." -Level Warning
        Write-Log ('The snapshots in the old repository stay there, but this machine no longer backs up to it or restores ' +
            'from it (point the configuration back to restore from it). Setup can copy them into the new repository, ' +
            'using the AWS keys being set up; it fails if they cannot read the old one.') -Level Warning
        while ($copyScope -eq 'None') {
            $answer = (Read-Host 'Copy snapshots from the old repository? [N]othing, the [L]atest of each job, [A]ll (Enter = nothing)').Trim()
            if ($answer -match '^(n|nothing)?$') { break }
            elseif ($answer -match '^(l|latest)$') { $copyScope = 'Latest' }
            elseif ($answer -match '^(a|all)$') { $copyScope = 'All' }
            else { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
        }
        if ($copyScope -ne 'None') { $copyFrom = $previous }
    }

    $registerTask = (Read-Host 'Create or update the scheduled backup task? [Y/n]') -notmatch '^(n|no)$'

    $removeTasks = @()
    if ($registerTask) {
        $task = Get-TaskStatus
        if ($task.Leftovers.Count -gt 0) {
            Write-Log "Other scheduled tasks also run this backup: $(Format-TaskLeftovers $task.Leftovers)." -Level Warning
            if ((Read-Host "Remove them after registering '$($task.Name)'? [Y/n]") -notmatch '^(n|no)$') { $removeTasks = @($task.Leftovers) }
        }
    }

    return Invoke-SetupCore -Secrets $secrets -InitializeRepository $initialize -RegisterTask $registerTask -RemoveTasks $removeTasks `
        -CopyFrom $copyFrom -CopyScope $copyScope
}

# Secrets: hashtable with awsAccessKeyId, awsSecretAccessKey, resticPassword, or $null to keep the stored ones.
# RemoveTasks: leftover tasks (Get-TaskStatus) to remove after registering the task.
# ResticZip: a local copy of the restic release zip, for machines that can't download it (see Install-Restic).
# CopyFrom: the previous repository, to copy snapshots from (CopyScope Latest or All, see Copy-RepositorySnapshots)
# with the password stored before this Setup. When it can't be read, Setup fails before the task.
function Invoke-SetupCore {
    param(
        [hashtable]$Secrets = $null, [bool]$InitializeRepository = $true, [bool]$RegisterTask = $true, [object[]]$RemoveTasks = @(),
        [string]$ResticZip = '', [string]$CopyFrom = '', [string]$CopyScope = 'None'
    )

    $config = $script:Config
    if ($CopyScope -eq 'None') { $CopyFrom = '' }

    # Before anything changes: Register-BackupTask refuses these too, but only at the end.
    if ($RegisterTask) {
        Assert-TaskName ([string](Get-Setting $config.Schedule 'taskName' 'Restic Backup'))
        $task = Get-TaskStatus
        if ($task.Foreign) {
            throw "A scheduled task named '$($task.Name)' already exists and doesn't run this tool. Change the task name in Settings (schedule.taskName)."
        }
    }

    # 1. restic; a failure ends Setup before anything else changes.
    Initialize-DataDirectory
    Install-Restic -ZipPath $ResticZip

    # Read before step 2 may replace it.
    $fromPassword = $null
    if ($CopyFrom) {
        try { $fromPassword = (Read-Secrets).resticPassword }
        catch { throw "The old repository's password can't be read, so its snapshots can't be copied: $($_.Exception.Message)" }
    }

    # 2. Secrets
    if ($null -ne $Secrets) {
        foreach ($key in @('awsAccessKeyId', 'awsSecretAccessKey', 'resticPassword')) {
            if (-not $Secrets[$key]) { throw 'All three secrets are required.' }
        }
        Save-Secrets $Secrets
        $script:ResticReady = $false
        Write-Log "Secrets saved to $($config.SecretsFile)" -Level Success
    }

    # 3. Repository
    Initialize-Restic
    $code = Get-RepositoryStatus
    if ($code -eq 0) {
        Write-Log 'Repository exists and is accessible.' -Level Success
    }
    elseif ($code -eq 10) {
        if (-not $InitializeRepository) {
            Write-Log 'Repository does not exist and was not initialized.' -Level Warning
            return 'Warning'
        }
        # Copying keeps deduplicating only when both repositories chunk files the same way.
        $arguments = @('init')
        if ($CopyFrom) { $arguments += @('--from-repo', $CopyFrom, '--copy-chunker-params') }
        $env:RESTIC_FROM_PASSWORD = $fromPassword
        try { $code = Invoke-Restic $arguments }
        finally { Remove-Item Env:RESTIC_FROM_PASSWORD -ErrorAction SilentlyContinue }
        if ($code -ne 0) {
            Write-Log "Repository initialization failed (exit code $code)." -Level Error
            return 'Failed'
        }
        Write-Log 'Repository initialized.' -Level Success
    }
    else {
        Write-Log "Cannot access the repository (restic exit code $code). Check the credentials and password." -Level Error
        return 'Failed'
    }

    $statuses = @()
    if ($CopyFrom) {
        $statuses += Copy-RepositorySnapshots -From $CopyFrom -FromPassword $fromPassword -Scope $CopyScope
        if ($statuses -contains 'Failed') { return $statuses }
    }

    # Runs refuse to start when the configuration points elsewhere (Assert-RepositoryUnchanged).
    Save-StateValue 'repository' $config.Repository

    # 4. Scheduled task
    if ($RegisterTask) { $statuses += Register-BackupTask -Replaces $RemoveTasks }

    if ($statuses.Count -eq 0) { return 'Success' }
    return $statuses
}

# Parameters are passed to the worker (see the parameter names of Invoke-Backup, Invoke-RestoreSnapshot, Invoke-SetupCore).
# Restore and Setup without parameters ask for their inputs interactively.
function Invoke-Operation {
    param([string]$Name, [hashtable]$Parameters = @{})

    if ($Name -notin @('Setup', 'EnableTask', 'DisableTask')) {
        Assert-RepositoryUnchanged
        Initialize-Restic
        Assert-Repository
        # Servers set up before Setup recorded the repository adopt the current one.
        if (-not (Get-Setting (Read-State) 'repository')) { Save-StateValue 'repository' $script:Config.Repository }
    }

    switch ($Name) {
        'Setup' {
            if ($Parameters.Count -eq 0) { return Invoke-Setup }
            return Invoke-SetupCore @Parameters
        }
        'EnableTask'    { return Set-BackupTaskEnabled $true }
        'DisableTask'   { return Set-BackupTaskEnabled $false }
        'Backup' {
            # Scheduled entry point: back up, then run whatever maintenance is due.
            $statuses = @(Invoke-Backup)
            if ($statuses -contains 'Failed') {
                Write-Log 'Skipping maintenance because a backup job failed.' -Level Warning
                return $statuses
            }
            return $statuses + @(Invoke-DueMaintenance)
        }
        'BackupOnly'    { return Invoke-Backup @Parameters }
        'Maintenance'   { return Invoke-DueMaintenance }
        'Forget'        { return Invoke-Forget }
        'ForgetPreview' { return Invoke-Forget -DryRun }
        'ForgetSnapshots' {
            # Internal: forgets chosen snapshots by ID (see Invoke-SnapshotForget); with no parameters, the menu asks.
            if ($Parameters.Count -eq 0) { return Invoke-ForgetMenu }
            return Invoke-SnapshotForget @Parameters
        }
        'Prune'         { return Invoke-Prune }
        'Check'         { return Invoke-Check }
        'List'          { $code = Invoke-Restic @('snapshots'); if ($code -ne 0) { return 'Failed' }; return 'Success' }
        'Restore' {
            if ($Parameters.Count -eq 0) { return Invoke-Restore }
            return Invoke-RestoreSnapshot @Parameters
        }
        'Cleanup' {
            # Internal: snapshots outside retention (see Get-CleanupPlan).
            if ($Parameters.Count -eq 0) { return Invoke-Cleanup }
            return Invoke-SnapshotCleanup @Parameters
        }
        'Unlock' {
            # Internal, after a cancelled action: removes stale locks only.
            $code = Invoke-Restic @('unlock')
            if ($code -ne 0) { Write-Log "Unlock failed (exit code $code)." -Level Error; return 'Failed' }
            return 'Success'
        }
        default         { throw "Unknown operation: $Name" }
    }
}

# Text is the menu input: empty = all enabled jobs, or numbers like "1,3".
# Returns an object whose Names are the picked jobs (empty = all enabled), or $null for invalid input.
function ConvertTo-JobSelection {
    param([string]$Text, $Jobs)

    $Jobs = @($Jobs)
    if (-not $Text.Trim()) { return [pscustomobject]@{ Names = @() } }

    $picked = @{}
    foreach ($part in ($Text -split '[,\s]+' | Where-Object { $_ })) {
        $number = 0
        if (-not [int]::TryParse($part, [ref]$number) -or $number -lt 1 -or $number -gt $Jobs.Count) { return $null }
        $picked[$number - 1] = $true
    }

    $names = @(for ($i = 0; $i -lt $Jobs.Count; $i++) { if ($picked.ContainsKey($i)) { $Jobs[$i].Name } })
    return [pscustomobject]@{ Names = $names }
}

function Read-JobSelection {
    $jobs = @($script:Config.Jobs)

    Write-Host ''
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $label = $jobs[$i].Name
        if (-not $jobs[$i].Enabled) { $label += ' (disabled)' }
        Write-Host ('{0,4}. {1}' -f ($i + 1), $label)
    }
    return ConvertTo-JobSelection (Read-Host 'Jobs (Enter = all enabled, or numbers like 1,3)') $jobs
}

function Show-Menu {
    $levels = @{ 0 = 'Success'; 1 = 'Error'; 3 = 'Warning' }
    # For the snapshots outside retention; read from S3, so only at the start and after actions that change them.
    $snapshots = $null
    $reload = $true

    while ($true) {
        $state = Read-State
        $previous = Get-RepositoryChange $state
        if ($reload) {
            $snapshots = $null
            if (-not $previous) {
                try { Initialize-Restic; $snapshots = @(Get-SnapshotList) } catch { }
            }
            $reload = $false
        }
        $restic = "restic $((Get-ResticPin).Version)"
        $resticColor = 'Gray'
        try { $null = Find-ResticExe }
        catch { $restic = "$($_.Exception.Message) (8. Setup)"; $resticColor = 'Red' }
        $task = $null
        try { $task = Get-TaskStatus } catch { }
        $taskColor = 'Gray'
        if (-not $task) { $taskSummary = 'unknown (the task could not be read)' }
        else {
            $taskSummary = Format-TaskSummary $task
            if ($task.Foreign) { $taskSummary += ' (H: Scheduled task)' }
            elseif (-not $task.Registered) { $taskSummary += ' (H: Setup)' }
            elseif (-not $task.LocationMatches) { $taskSummary += '; points to a different location (H: Moving the folder)' }
            elseif ($task.Leftovers.Count -gt 0) { $taskSummary += ' (H: Scheduled task)' }
            if (-not $task.Registered -or -not $task.LocationMatches -or $task.Leftovers.Count -gt 0) { $taskColor = 'Red' }
            elseif ($task.State -eq 'Disabled') { $taskColor = 'Yellow' }
        }

        Write-Host ''
        Write-Host '========================================'
        Write-Host " Restic - $($script:Config.Hostname)"
        Write-Host " $($script:Config.Repository)"
        if ($previous) {
            Write-Host " Repository changed from $previous; run Setup (8) to switch, or change the configuration back (H: Switching repositories)" -ForegroundColor Red
        }
        Write-Host (' Last forget: {0}  prune: {1}  check: {2}' -f
            (Format-StateTimestamp $state 'lastForget'),
            (Format-StateTimestamp $state 'lastPrune'),
            (Format-StateTimestamp $state 'lastCheck'))
        Write-Host " Task: $taskSummary" -ForegroundColor $taskColor
        Write-Host " $restic" -ForegroundColor $resticColor
        $groups = @()
        if ($null -ne $snapshots) { $groups = @(Get-UnmanagedSnapshotGroups $script:Config.Jobs $snapshots) }
        if ($groups.Count -gt 0) {
            Write-Host " Outside retention: $(@($groups | ForEach-Object { "$($_.Label) ($($_.Count))" }) -join ', ') (10. Clean up)" -ForegroundColor DarkGray
        }
        Write-Host '========================================'
        Write-Host ' 1. Back up now'
        Write-Host ' 2. List snapshots'
        Write-Host ' 3. Restore'
        Write-Host ' 4. Forget snapshots (retention policy, a job, picked ones, everything)'
        Write-Host ' 5. Prune'
        Write-Host ' 6. Check integrity'
        Write-Host ' 7. Run due maintenance'
        Write-Host ' 8. Setup (restic, secrets, repository, scheduled task)'
        $enableTask = $task -and $task.State -eq 'Disabled'
        if ($enableTask) { Write-Host ' 9. Enable the scheduled task' }
        else { Write-Host ' 9. Disable the scheduled task' }
        Write-Host '10. Clean up snapshots outside retention (removed or renamed jobs)'
        Write-Host ' H. Help'
        Write-Host ' Q. Quit'

        $choice = (Read-Host 'Select').Trim()
        if ($choice -match '^(q|quit|exit)$') { return }
        if ($choice -match '^(h|help)$') {
            Show-HelpMenu
            continue
        }

        $statuses = @()
        $known = $true
        if ($choice -in @('1', '4', '7', '8', '10')) { $reload = $true }
        try {
            switch ($choice) {
                '1' {
                    $selection = Read-JobSelection
                    if ($selection) { $statuses = Invoke-Operation 'BackupOnly' @{ JobNames = $selection.Names } }
                    else {
                        Write-Host 'Unknown job selection.' -ForegroundColor Yellow
                        $known = $false
                    }
                }
                '2' { $statuses = Invoke-Operation 'List' }
                '3' { $statuses = Invoke-Operation 'Restore' }
                '4' { $statuses = Invoke-Operation 'ForgetSnapshots' }
                '5' { $statuses = Invoke-Operation 'Prune' }
                '6' { $statuses = Invoke-Operation 'Check' }
                '7' { $statuses = Invoke-Operation 'Maintenance' }
                '8' { $statuses = Invoke-Operation 'Setup' }
                '9' {
                    if ($enableTask) { $statuses = Invoke-Operation 'EnableTask' }
                    elseif ((Read-Host 'Disable the scheduled task? Scheduled backups stop until it is enabled again. [y/N]') -match '^(y|yes)$') {
                        $statuses = Invoke-Operation 'DisableTask'
                    }
                    else { $known = $false }
                }
                '10' { $statuses = Invoke-Operation 'Cleanup' }
                default {
                    Write-Host 'Unknown option.' -ForegroundColor Yellow
                    $known = $false
                }
            }

            if ($known) {
                $code = Get-ExitCode @($statuses)
                Write-Log "Done (exit code $code)." -Level $levels[$code]
            }
        }
        catch {
            Write-Log $_.Exception.Message -Level Error
        }
    }
}

#endregion

#region Configuration editor

function Format-JsonString {
    param([string]$Text)

    $escaped = $Text.Replace('\', '\\').Replace('"', '\"')
    $escaped = [regex]::Replace($escaped, '[\x00-\x1f]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    return '"' + $escaped + '"'
}

function Test-JsonScalar {
    param($Value)

    return ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType])
}

# Keeps the hand-written layout: two-space indent, short scalar arrays on one line, and blank
# lines around top-level objects and arrays. ConvertTo-Json in 5.1 does none of this.
function ConvertTo-PrettyJson {
    param($Value, [int]$Depth = 0)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    if ($Value -is [string]) { return Format-JsonString $Value }
    if ($Value -is [datetime]) { return Format-JsonString $Value.ToString('o') }
    if ($Value -is [ValueType]) { return ([IFormattable]$Value).ToString($null, [Globalization.CultureInfo]::InvariantCulture) }

    $indent = '  ' * ($Depth + 1)
    $closing = '  ' * $Depth

    if ($Value -is [System.Collections.IList]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }

        $parts = @(foreach ($item in $items) { ConvertTo-PrettyJson $item ($Depth + 1) })
        $inline = '[' + ($parts -join ', ') + ']'
        if ($inline.Length -le 60 -and -not @($items | Where-Object { -not (Test-JsonScalar $_) })) { return $inline }
        return "[`n$indent" + ($parts -join ",`n$indent") + "`n$closing]"
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $properties = @(foreach ($key in $Value.Keys) { [pscustomobject]@{ Name = [string]$key; Value = $Value[$key] } })
    }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        $properties = @($Value.PSObject.Properties)
    }
    else {
        return Format-JsonString ([string]$Value)
    }

    if ($properties.Count -eq 0) { return '{}' }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('{')
    for ($i = 0; $i -lt $properties.Count; $i++) {
        $property = $properties[$i]
        if ($i -gt 0) {
            [void]$builder.Append(',')
            if ($Depth -eq 0 -and -not ((Test-JsonScalar $property.Value) -and (Test-JsonScalar $properties[$i - 1].Value))) {
                [void]$builder.Append("`n")
            }
        }
        [void]$builder.Append("`n$indent" + (Format-JsonString $property.Name) + ': ' + (ConvertTo-PrettyJson $property.Value ($Depth + 1)))
    }
    [void]$builder.Append("`n$closing}")
    return $builder.ToString()
}

# Leaves a missing setting out when it would only restate the default, so saving doesn't add keys.
function Set-Setting {
    param($Object, [string]$Name, $Value, $Default = $null)

    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Value }
    elseif ([string]$Value -cne [string]$Default) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Split-Lines {
    param([string]$Text)

    return @($Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Show-EditorMessage {
    param([string]$Text, [string]$Icon = 'Error', [string]$Buttons = 'OK')

    Add-Type -AssemblyName System.Windows.Forms
    return [string][System.Windows.Forms.MessageBox]::Show($script:Editor.Ui.Form, $Text, 'Restic settings', $Buttons, $Icon)
}

# Checks that ConvertTo-Config leaves to Setup or the maintenance run, caught here before saving.
function Assert-EditorValues {
    param($Document)

    Assert-TaskName ([string](Get-Setting (Get-Setting $Document 'schedule') 'taskName' 'Restic Backup'))
    $dailyAt = [string](Get-Setting (Get-Setting $Document 'schedule') 'dailyAt' '02:00')
    $time = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($dailyAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$time)) {
        throw "Daily at '$dailyAt' is not a valid time. Use HH:mm, e.g. 02:00."
    }

    $retention = Get-Setting $Document 'retention'
    $within = [string](Get-Setting $retention 'keepWithin' '')
    if ($within -and $within -cnotmatch '^(\d+[ymdh])+$') {
        throw "Keep within '$within' is not a restic duration such as 30d or 1y6m."
    }

    $forgetDays = [double](Get-Setting (Get-Setting $Document 'maintenance') 'forgetEveryDays' 0)
    if ($forgetDays -gt 0) {
        try { $null = Get-RetentionArguments $retention }
        catch { throw 'Forget is scheduled but no retention rule is set. Set at least one keep value, or set Forget every to 0.' }
    }
}

function Get-ControlValue {
    param($Control)

    if ($Control -is [System.Windows.Forms.CheckBox]) { return $Control.Checked }
    if ($Control -is [System.Windows.Forms.NumericUpDown]) { return [int]$Control.Value }
    return $Control.Text.Trim()
}

function Set-ControlValue {
    param($Control, $Value)

    if ($Control -is [System.Windows.Forms.CheckBox]) { $Control.Checked = [bool]$Value }
    elseif ($Control -is [System.Windows.Forms.NumericUpDown]) {
        $number = 0.0
        [void][double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
        $Control.Value = [decimal][Math]::Min([Math]::Max($number, [double]$Control.Minimum), [double]$Control.Maximum)
    }
    else { $Control.Text = [string]$Value }
}

function Register-EditorChange {
    param($Control, [scriptblock]$Action)

    if ($Control -is [System.Windows.Forms.CheckBox]) { $Control.add_CheckedChanged($Action) }
    elseif ($Control -is [System.Windows.Forms.NumericUpDown]) { $Control.add_ValueChanged($Action) }
    else { $Control.add_TextChanged($Action) }
}

# -Hint: grey text shown while the box is empty (single-line boxes only).
function New-EditorTextBox {
    param([switch]$Multiline, [string]$Hint)

    $box = New-Object System.Windows.Forms.TextBox
    if ($Hint) { Set-CueBanner $box $Hint }
    if ($Multiline) {
        $box.Multiline = $true
        $box.AcceptsReturn = $true
        $box.WordWrap = $false
        $box.ScrollBars = 'Both'
        $box.Height = 110
    }
    return $box
}

# EM_SETCUEBANNER, shown even while the box has focus. It belongs to the window handle, which WinForms
# creates late and may recreate, so it is sent on every HandleCreated; the box carries its hint in Tag.
function Set-CueBanner {
    param($Box, [string]$Text)

    if (-not ('ResticGui.CueBanner' -as [type])) {
        Add-Type -Namespace ResticGui -Name CueBanner -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
'@
    }
    $Box.Tag = $Text
    $Box.add_HandleCreated({
        param($source)
        [void][ResticGui.CueBanner]::SendMessage($source.Handle, 0x1501, [IntPtr]1, [string]$source.Tag)
    })
}

function New-EditorNumber {
    return New-Object System.Windows.Forms.NumericUpDown -Property @{ Maximum = 100000; Width = 90 }
}

function New-EditorTable {
    $table = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
        Dock = 'Fill'; AutoScroll = $true; ColumnCount = 3; Padding = [System.Windows.Forms.Padding]::new(8)
    }
    [void]$table.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$table.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$table.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    return $table
}

function New-EditorTab {
    param($Tabs, [string]$Title)

    $page = New-Object System.Windows.Forms.TabPage $Title
    $table = New-EditorTable
    $page.Controls.Add($table)
    $Tabs.TabPages.Add($page)
    return $table
}

function Add-EditorHeading {
    param($Table, [string]$Text)

    $row = $Table.RowCount
    $Table.RowCount = $row + 1
    [void]$Table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))

    $label = New-Object System.Windows.Forms.Label -Property @{
        Text = $Text; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(3, 12, 3, 3)
        Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }
    $Table.Controls.Add($label, 0, $row)
    $Table.SetColumnSpan($label, 3)
}

# Label | control | note (text, or a control such as a button). Warning notes are shown in red.
# Tip: shown on hovering the label or the control.
function Add-EditorRow {
    param($Table, [string]$Label, $Control, $Note, [switch]$Warning, [string]$Tip)

    $row = $Table.RowCount
    $Table.RowCount = $row + 1
    [void]$Table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))

    if ($Label) {
        $caption = New-Object System.Windows.Forms.Label -Property @{
            Text = $Label; AutoSize = $true; Anchor = 'Top, Left'; Margin = [System.Windows.Forms.Padding]::new(3, 7, 9, 3)
        }
        $Table.Controls.Add($caption, 0, $row)
        if ($Tip) { $script:Editor.Ui.Tip.SetToolTip($caption, $Tip) }
    }
    if ($Tip) { $script:Editor.Ui.Tip.SetToolTip($Control, $Tip) }

    # Top-anchored: the last row takes up the table's spare height and would otherwise center its control.
    if ($Control -is [System.Windows.Forms.TextBox]) { $Control.Anchor = 'Top, Left, Right' }
    else { $Control.Anchor = 'Top, Left' }
    $Table.Controls.Add($Control, 1, $row)

    if ($Note -is [System.Windows.Forms.Control]) {
        $Table.Controls.Add($Note, 2, $row)
    }
    elseif ($Note) {
        $color = [System.Drawing.SystemColors]::GrayText
        if ($Warning) { $color = [System.Drawing.Color]::Firebrick }
        $Table.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
            Text = $Note; AutoSize = $true; ForeColor = $color; Anchor = 'Top, Left'
            MaximumSize = [System.Drawing.Size]::new(260, 0); Margin = [System.Windows.Forms.Padding]::new(3, 7, 3, 3)
        }), 2, $row)
    }
}

# A control bound to <section>.<key> of the document ('' = top level). RequiresSetup fields
# take effect only after Setup runs again; they are flagged in red and reported after saving.
function Add-EditorField {
    param($Table, [string]$Label, $Control, [string]$Section, [string]$Key, $Default, [string]$Note, [switch]$RequiresSetup, [string]$Tip)

    Add-EditorRow $Table $Label $Control $Note -Warning:$RequiresSetup -Tip $Tip
    Register-EditorChange $Control { Set-EditorDirty }
    [void]$script:Editor.Fields.Add(@{
        Label = $Label; Control = $Control; Section = $Section; Key = $Key; Default = $Default
        RequiresSetup = [bool]$RequiresSetup; Original = ''
    })
}

function Set-EditorDirty {
    if ($script:Editor.Loading) { return }
    $script:Editor.Dirty = $true
    Update-EditorTitle
}

function Update-EditorTitle {
    $title = "Restic settings - $($script:Editor.Path)"
    if ($script:Editor.Dirty) { $title += ' *' }
    $script:Editor.Ui.Form.Text = $title
}

function Update-RepositoryUrl {
    $ui = $script:Editor.Ui
    $ui.RepositoryUrl.Text = Get-RepositoryUrl $ui.Region.Text.Trim() $ui.Bucket.Text.Trim()
    Update-SetupCopy
}

# Setup offers to copy the snapshots of the previous repository only while the URL differs from it.
function Update-SetupCopy {
    $editor = $script:Editor
    $ui = $editor.Ui
    if (-not $ui.CopyScope) { return }

    $previous = $editor.PreviousRepository
    $switching = [bool]$previous -and $previous -ne $ui.RepositoryUrl.Text
    $ui.CopyScope.Enabled = $switching
    if ($switching) {
        $ui.CopyNote.Text = "From $previous, the repository this machine used until now. Uses its stored password and the AWS keys being set up."
    }
    else {
        $ui.CopyScope.SelectedIndex = 0
        $ui.CopyNote.Text = 'Only when the repository changes.'
    }
}

function Update-SetupSchedule {
    $ui = $script:Editor.Ui
    $ui.SetupSchedule.Text = "'$($ui.TaskName.Text.Trim())', daily at $($ui.DailyAt.Text.Trim()) (change it on the Schedule tab)"
}

function Update-SetupSecrets {
    $ui = $script:Editor.Ui
    foreach ($box in @($ui.AccessKey, $ui.SecretKey, $ui.Password, $ui.Confirm)) { $box.Enabled = $ui.SetupReplace.Checked }
}

# Without stored secrets, they must be entered.
function Set-SetupSecretsStored {
    param([bool]$Stored)

    $ui = $script:Editor.Ui
    $ui.SetupReplace.Enabled = $Stored
    if ($Stored) { $ui.SetupReplace.Text = 'Replace the stored secrets' }
    else {
        $ui.SetupReplace.Checked = $true
        $ui.SetupReplace.Text = 'Store the secrets (none are stored yet)'
    }
    Update-SetupSecrets
}

function Test-SetupSecretsTyped {
    $ui = $script:Editor.Ui
    if (-not $ui.SetupReplace.Checked) { return $false }
    return [bool](@($ui.AccessKey, $ui.SecretKey, $ui.Password, $ui.Confirm) | Where-Object { $_.Text })
}

# The menu's rules (passwords match, all three present). Returns the secrets, or $null to keep the stored ones.
function Get-SetupSecrets {
    $ui = $script:Editor.Ui
    if (-not $ui.SetupReplace.Checked) { return $null }

    $accessKey = $ui.AccessKey.Text.Trim()
    if ($ui.Password.Text -cne $ui.Confirm.Text) { throw 'Passwords do not match.' }
    if (-not $accessKey -or -not $ui.SecretKey.Text -or -not $ui.Password.Text) { throw 'All three secrets are required.' }
    return @{ awsAccessKeyId = $accessKey; awsSecretAccessKey = $ui.SecretKey.Text; resticPassword = $ui.Password.Text }
}

function Import-EditorFields {
    $document = $script:Editor.Document
    foreach ($field in $script:Editor.Fields) {
        $section = $document
        if ($field.Section) { $section = Get-Setting $document $field.Section }
        Set-ControlValue $field.Control (Get-Setting $section $field.Key $field.Default)
        $field.Original = [string](Get-ControlValue $field.Control)
    }

    $script:Editor.Ui.GlobalExcludes.Text = @(Get-StringList $document 'globalExcludes') -join "`r`n"

    $script:Editor.Jobs.Clear()
    foreach ($job in @(Get-Setting $document 'jobs' @())) { [void]$script:Editor.Jobs.Add($job) }
    $script:Editor.SavedJobNames = @($script:Editor.Jobs | ForEach-Object { [string](Get-Setting $_ 'name') })
    $script:Editor.Origins = @(Get-EditorOrigins)
}

# Each job with the name it was saved under, so that a save can tell a rename from a removal.
function Get-EditorOrigins {
    return @(foreach ($job in $script:Editor.Jobs) { @{ Job = $job; Name = [string](Get-Setting $job 'name') } })
}

function Export-EditorFields {
    $document = $script:Editor.Document
    foreach ($field in $script:Editor.Fields) {
        $section = $document
        if ($field.Section) {
            $section = Get-Setting $document $field.Section
            if ($null -eq $section) {
                $section = [pscustomobject]@{}
                $document | Add-Member -NotePropertyName $field.Section -NotePropertyValue $section
            }
        }
        Set-Setting $section $field.Key (Get-ControlValue $field.Control) $field.Default
    }

    Set-Setting $document 'globalExcludes' ([object[]]@(Split-Lines $script:Editor.Ui.GlobalExcludes.Text))
    Set-Setting $document 'jobs' ([object[]]$script:Editor.Jobs.ToArray())
}

# Appends the suggested patterns that aren't in the box yet (compared case-insensitively, like --iexclude).
function Add-SuggestedExcludes {
    $box = $script:Editor.Ui.GlobalExcludes
    $current = @(Split-Lines $box.Text)
    $missing = @(Get-SuggestedExcludes | Where-Object { $current -notcontains $_ })
    if ($missing.Count -eq 0) { return }

    $text = $box.Text.TrimEnd()
    if ($text) { $text += "`r`n" }
    $box.Text = $text + ($missing -join "`r`n")
}

function Get-JobLabel {
    param($Job)

    $label = [string](Get-Setting $Job 'name' '')
    if (-not $label) { $label = '(unnamed)' }
    if (-not [bool](Get-Setting $Job 'enabled' $true)) { $label += ' (disabled)' }
    return $label
}

function Get-EditorJobPaths {
    return @(Split-Lines $script:Editor.Ui.JobPaths.Text | ForEach-Object { $_.Trim('"') } | Where-Object { $_ })
}

function Update-MissingPaths {
    $missing = @(Get-EditorJobPaths | Where-Object {
        $path = $_
        -not $(try { Test-Path -LiteralPath $path } catch { $false })
    })

    $text = ''
    if ($missing.Count -gt 0) { $text = 'Not found on this machine: ' + ($missing -join ', ') }
    $script:Editor.Ui.MissingPaths.Text = $text
    # Hidden, the auto-sized row collapses instead of leaving a gap under the paths box.
    $script:Editor.Ui.MissingPaths.Visible = [bool]$text
}

function Update-JobList {
    param([int]$Select)

    $ui = $script:Editor.Ui
    $script:Editor.Loading = $true
    try {
        $ui.JobList.BeginUpdate()
        $ui.JobList.Items.Clear()
        foreach ($job in $script:Editor.Jobs) { [void]$ui.JobList.Items.Add((Get-JobLabel $job)) }
        $ui.JobList.EndUpdate()

        if ($Select -ge $ui.JobList.Items.Count) { $Select = $ui.JobList.Items.Count - 1 }
        $ui.JobList.SelectedIndex = $Select
    }
    finally { $script:Editor.Loading = $false }

    Show-EditorJob
}

function Show-EditorJob {
    $ui = $script:Editor.Ui
    $index = $ui.JobList.SelectedIndex

    $script:Editor.Loading = $true
    try {
        $ui.JobDetails.Enabled = $index -ge 0
        if ($index -ge 0) {
            $job = $script:Editor.Jobs[$index]
            $ui.JobName.Text = [string](Get-Setting $job 'name' '')
            $ui.JobEnabled.Checked = [bool](Get-Setting $job 'enabled' $true)
            $ui.JobPaths.Text = @(Get-StringList $job 'paths') -join "`r`n"
            $ui.JobTags.Text = @(Get-StringList $job 'tags') -join ' '
            $ui.JobExcludes.Text = @(Get-StringList $job 'excludes') -join "`r`n"
        }
        else {
            foreach ($box in @($ui.JobName, $ui.JobPaths, $ui.JobTags, $ui.JobExcludes)) { $box.Text = '' }
            $ui.JobEnabled.Checked = $false
        }
        Update-MissingPaths
    }
    finally { $script:Editor.Loading = $false }
}

# Writes the detail controls back into the selected job as the user types.
function Update-EditorJob {
    if ($script:Editor.Loading) { return }

    $ui = $script:Editor.Ui
    $index = $ui.JobList.SelectedIndex
    if ($index -lt 0) { return }

    $job = $script:Editor.Jobs[$index]
    Set-Setting $job 'name' $ui.JobName.Text.Trim()
    Set-Setting $job 'enabled' $ui.JobEnabled.Checked $true
    Set-Setting $job 'paths' ([object[]]@(Get-EditorJobPaths))
    Set-Setting $job 'tags' ([object[]]@($ui.JobTags.Text -split '[,\s]+' | Where-Object { $_ }))
    Set-Setting $job 'excludes' ([object[]]@(Split-Lines $ui.JobExcludes.Text))

    $script:Editor.Loading = $true
    try {
        $ui.JobList.Items[$index] = Get-JobLabel $job
        $ui.JobList.SelectedIndex = $index
    }
    finally { $script:Editor.Loading = $false }

    Update-MissingPaths
    Set-EditorDirty
}

function Add-EditorJob {
    $names = @($script:Editor.Jobs | ForEach-Object { [string](Get-Setting $_ 'name') })
    $name = 'new-job'
    $number = 2
    while ($names -contains $name) { $name = "new-job-$number"; $number++ }

    [void]$script:Editor.Jobs.Add([pscustomobject]@{ name = $name; enabled = $true; paths = @(); tags = @(); excludes = @() })
    Update-JobList ($script:Editor.Jobs.Count - 1)
    Set-EditorDirty

    $script:Editor.Ui.JobName.Focus() | Out-Null
    $script:Editor.Ui.JobName.SelectAll()
}

function Remove-EditorJob {
    $index = $script:Editor.Ui.JobList.SelectedIndex
    if ($index -lt 0) { return }

    $name = [string](Get-Setting $script:Editor.Jobs[$index] 'name')
    $message = "Remove job '$name'?`n`nIts existing snapshots keep the tag job:$name and no longer get retention. " +
        "When you save, you choose what happens to them.`n`nTo stop backing it up but keep applying retention, disable the job instead."
    if ((Show-EditorMessage $message 'Warning' 'YesNo') -ne 'Yes') { return }

    $script:Editor.Jobs.RemoveAt($index)
    Update-JobList $index
    Set-EditorDirty
}

function Move-EditorJob {
    param([int]$Offset)

    $jobs = $script:Editor.Jobs
    $index = $script:Editor.Ui.JobList.SelectedIndex
    $target = $index + $Offset
    if ($index -lt 0 -or $target -lt 0 -or $target -ge $jobs.Count) { return }

    $job = $jobs[$index]
    $jobs.RemoveAt($index)
    $jobs.Insert($target, $job)
    Update-JobList $target
    Set-EditorDirty
}

function Save-EditorConfig {
    $editor = $script:Editor
    $document = $editor.Document

    Export-EditorFields
    $null = ConvertTo-Config $document
    Assert-EditorValues $document

    # Tags are case-sensitive in restic, so a case-only rename also leaves the old snapshots outside retention.
    $names = @($editor.Jobs | ForEach-Object { [string](Get-Setting $_ 'name') })
    $dropped = @($editor.SavedJobNames | Where-Object { $names -cnotcontains $_ })
    $switched = @($editor.Fields | Where-Object { $_.Section -eq 'repository' -and [string](Get-ControlValue $_.Control) -cne $_.Original })
    if ($dropped.Count -gt 0 -and $switched.Count -gt 0) {
        throw "Jobs were removed or renamed ($($dropped -join ', ')) and the repository changed. Save these changes separately: " +
            'the snapshots of those jobs are in the old repository.'
    }
    $cleanup = @()
    if ($dropped.Count -gt 0) {
        $cleanup = Request-EditorCleanup $dropped $names
        if ($null -eq $cleanup) { return $false }
    }

    $setup = @($editor.Fields | Where-Object { $_.RequiresSetup -and [string](Get-ControlValue $_.Control) -cne $_.Original } |
        ForEach-Object { $_.Label })

    if (Test-Path -LiteralPath $editor.Path -PathType Leaf) {
        Copy-Item -LiteralPath $editor.Path -Destination "$($editor.Path).bak" -Force
    }
    [System.IO.File]::WriteAllText($editor.Path, (ConvertTo-PrettyJson $document) + "`n", (New-Object System.Text.UTF8Encoding $false))

    foreach ($action in @($cleanup)) { [void]$editor.Cleanup.Add($action) }
    $editor.Origins = @(Get-EditorOrigins)
    $editor.SavedJobNames = $names
    foreach ($field in $editor.Fields) { $field.Original = [string](Get-ControlValue $field.Control) }
    $editor.Dirty = $false
    $editor.SetupFields = $setup
    Update-EditorTitle
    return $true
}

# At a save that removes or renames jobs: what happens to their snapshots, which no job gives retention any more.
# Counts come from the main window's snapshot list when it has one; jobs without snapshots aren't asked about.
# A renamed job suggests moving its snapshots to the new name. Returns the Cleanup actions, which run after the
# dialog closes (Show-ConfigEditor returns them), or $null to not save.
function Request-EditorCleanup {
    param([string[]]$Dropped, [string[]]$Names)

    $editor = $script:Editor
    $snapshots = $null
    if ($script:Gui -and $script:Gui.SnapshotsLoaded) { $snapshots = @($script:Gui.Snapshots) }

    $suggest = @{}
    foreach ($origin in $editor.Origins) {
        if ($Dropped -cnotcontains $origin.Name) { continue }
        foreach ($job in $editor.Jobs) {
            if ([object]::ReferenceEquals($job, $origin.Job)) { $suggest[$origin.Name] = [string](Get-Setting $job 'name') }
        }
    }

    $groups = @(foreach ($name in $Dropped) {
        $count = $null
        $newest = $null
        if ($null -ne $snapshots) {
            $own = @($snapshots | Where-Object { $_.Job -ceq $name })
            if ($own.Count -eq 0) { continue }
            $count = $own.Count
            $newest = ($own | Sort-Object Time -Descending | Select-Object -First 1).Time
        }
        [pscustomobject]@{ Job = $name; Label = $name; Count = $count; Newest = $newest }
    })
    if ($groups.Count -eq 0) { return , @() }

    $intro = 'These jobs are no longer in the configuration (removed or renamed). No job applies retention to their ' +
        'snapshots any more, so they are kept forever unless you choose otherwise. Your choices run after the settings close.'
    if ($null -eq $snapshots) { $intro += " The snapshot counts are unknown: the main window hasn't read the repository." }
    $actions = Show-CleanupDialog $groups $Names $editor.Ui.Form $intro $suggest
    if ($null -eq $actions) { return $null }
    return , $actions
}

function Invoke-EditorSave {
    try { return Save-EditorConfig }
    catch {
        Show-EditorMessage "Not saved: $($_.Exception.Message)" | Out-Null
        return $false
    }
}

# After a save that changed fields only Setup applies: offers to run Setup. Returns $true to stay open
# (Setup couldn't start; the General tab shows Run Setup). When Setup starts, $script:Editor.SetupResult is set.
function Request-EditorSetup {
    $editor = $script:Editor
    if ($editor.SetupFields.Count -eq 0) { return $false }

    # Switching repositories: the copy is chosen on the General tab before Run Setup.
    if ($editor.Ui.CopyScope.Enabled) {
        $message = "Saved. This machine switches from $($editor.PreviousRepository) to $($editor.Ui.RepositoryUrl.Text) " +
            "when Setup runs; until then, its backups fail.`n`nThe snapshots in the old repository stay there, but this " +
            "machine no longer backs up to it or restores from it (to restore from it, point the configuration back). " +
            "Setup can copy them into the new repository: choose what to copy under Setup, then click Run Setup."
        $editor.SetupFields = @()
        Show-EditorMessage $message 'Warning' | Out-Null
        Show-EditorGeneral $editor.Ui.CopyScope
        return $true
    }

    $message = "Saved. These changes take effect when Setup runs: $($editor.SetupFields -join ', ').`n`nRun Setup now?"
    $editor.SetupFields = @()
    if ((Show-EditorMessage $message 'Question' 'YesNo') -ne 'Yes') { return $false }
    if (Invoke-EditorSetup) { return $false }
    Show-EditorGeneral $editor.Ui.RunSetup
    return $true
}

# Scrolls the General tab (which holds the secrets and Run Setup) to a control.
function Show-EditorGeneral {
    param($Control)

    $ui = $script:Editor.Ui
    $ui.Tabs.SelectedTab = $ui.GeneralPage
    $ui.GeneralTable.ScrollControlIntoView($Control)
}

# Save and Ctrl+S.
function Invoke-EditorSaveAndClose {
    if (-not (Invoke-EditorSave)) { return }
    if (Request-EditorSetup) { return }
    $script:Editor.Ui.Form.Close()
}

# Run Setup: saves, checks what Setup needs, and sets SetupResult; the caller closes the dialog and the main
# window runs it (Show-ConfigEditor returns the parameters).
function Start-EditorSetup {
    $editor = $script:Editor
    $ui = $editor.Ui
    $secrets = Get-SetupSecrets

    if ($editor.Dirty) {
        if ((Show-EditorMessage 'Save your changes and run Setup?' 'Question' 'OKCancel') -ne 'OK') { return }
        if (-not (Invoke-EditorSave)) { return }
        $editor.SetupFields = @()
    }

    # Setup runs with the saved file. The main window re-reads it after closing.
    $script:Config = Read-Config $editor.Path
    # Setup installs restic; only an unsupported machine stops it here.
    $null = Get-ResticTarget
    $stored = Test-Path -LiteralPath $script:Config.SecretsFile -PathType Leaf
    if ($null -eq $secrets -and -not $stored) {
        Set-SetupSecretsStored $false
        throw "No secrets are stored in $($script:Config.DataDirectory). Enter them."
    }

    $copyScope = @('None', 'Latest', 'All')[[Math]::Max(0, $ui.CopyScope.SelectedIndex)]
    $copyFrom = ''
    if ($ui.CopyScope.Enabled -and $copyScope -ne 'None') {
        if (-not $stored) { throw "Copying needs the old repository's password, but no secrets are stored in $($script:Config.DataDirectory)." }
        $copyFrom = $editor.PreviousRepository
    }

    # Asked here: the Setup worker can't show a dialog.
    $removeTasks = @()
    if ($ui.SetupRegisterTask.Checked) {
        $task = Get-TaskStatus
        if ($task.Leftovers.Count -gt 0) {
            $message = "Other scheduled tasks also run this backup: $(Format-TaskLeftovers $task.Leftovers).`n`n" +
                "Remove them after registering '$($task.Name)'? Otherwise they keep running too."
            $answer = Show-EditorMessage $message 'Question' 'YesNoCancel'
            if ($answer -eq 'Cancel') { return }
            if ($answer -eq 'Yes') { $removeTasks = @($task.Leftovers) }
        }
    }

    $editor.SetupResult = @{
        Secrets = $secrets; InitializeRepository = $ui.SetupInitialize.Checked; RegisterTask = $ui.SetupRegisterTask.Checked
        RemoveTasks = $removeTasks; CopyFrom = $copyFrom; CopyScope = $copyScope
    }
}

# Returns $true when Setup is ready to run (SetupResult set).
function Invoke-EditorSetup {
    try { Start-EditorSetup | Out-Null }
    catch { Show-EditorMessage "Setup can't run: $($_.Exception.Message)" | Out-Null }
    return [bool]$script:Editor.SetupResult
}

# First run: the defaults plus a starting retention policy, with no repository and no jobs.
# Written out in full, so the created file can be hand-edited like the shipped one.
function New-ConfigDocument {
    return [pscustomobject][ordered]@{
        repository       = [pscustomobject][ordered]@{ region = ''; bucket = '' }
        dataDirectory    = Get-DefaultDataDirectory
        logRetentionDays = 30
        useVss           = $true
        restoreRoot      = 'C:\Restore'
        schedule         = [pscustomobject][ordered]@{ taskName = 'Restic Backup'; dailyAt = '02:00'; maxRuntimeHours = 12 }
        retention        = [pscustomobject][ordered]@{
            keepLast = 0; keepDaily = 7; keepWeekly = 4; keepMonthly = 12; keepYearly = 0; keepWithin = ''
        }
        maintenance      = [pscustomobject][ordered]@{
            forgetEveryDays = 1; pruneEveryDays = 7; checkEveryDays = 30; checkReadDataSubset = '2.5%'
        }
        globalExcludes   = @(Get-SuggestedExcludes)
        jobs             = @()
    }
}

# The Settings dialog of the main window: the configuration file, plus running Setup.
# Works on the raw JSON document rather than Read-Config's result, so unknown keys survive a save
# and an invalid file can still be opened and fixed. A missing file opens New-ConfigDocument; Save creates it.
# -Owner: the main window, which makes this a modal dialog over it.
# Returns Setup (the parameters of the Setup operation when Run Setup closed it, otherwise $null) and Cleanup
# (the Cleanup actions saves queued for the snapshots of removed or renamed jobs; see Request-EditorCleanup).
function Show-ConfigEditor {
    param([string]$Path, $Owner)

    $isNew = -not (Test-Path -LiteralPath $Path -PathType Leaf)
    if ($isNew) { $document = New-ConfigDocument }
    else { $document = Read-ConfigDocument $Path }
    $script:Editor = @{
        Path          = [System.IO.Path]::GetFullPath($Path)
        Document      = $document
        Jobs          = [System.Collections.ArrayList]::new()
        SavedJobNames = @()
        # Get-EditorOrigins; Cleanup: the actions saves queued for the snapshots of removed or renamed jobs.
        Origins       = @()
        Cleanup       = [System.Collections.ArrayList]::new()
        # The repository this machine used until now (see Update-SetupCopy).
        PreviousRepository = $null
        Fields        = [System.Collections.ArrayList]::new()
        Ui            = @{}
        Dirty         = $false
        Loading       = $true
        # Labels of the RequiresSetup fields the last save changed.
        SetupFields   = @()
        SetupResult   = $null
    }
    $ui = $script:Editor.Ui

    $form = New-Object System.Windows.Forms.Form -Property @{
        Size = [System.Drawing.Size]::new(900, 660); MinimumSize = [System.Drawing.Size]::new(720, 500)
        StartPosition = 'CenterParent'; Font = [System.Drawing.Font]::new('Segoe UI', 9); KeyPreview = $true; ShowInTaskbar = $false
    }
    $ui.Form = $form
    # The fields' tooltips (Add-EditorRow -Tip); the help has the details.
    $ui.Tip = New-Object System.Windows.Forms.ToolTip -Property @{ AutoPopDelay = 20000 }
    $tabs = New-Object System.Windows.Forms.TabControl -Property @{ Dock = 'Fill' }
    $ui.Tabs = $tabs

    # General: everything Setup applies, and Run Setup itself. The secrets and checkboxes are never saved
    # to the file; Run Setup hands them to the main window.
    $table = New-EditorTab $tabs 'General'
    $ui.GeneralPage = $tabs.TabPages[0]
    $ui.GeneralTable = $table
    Add-EditorHeading $table 'Repository'
    $ui.Region = New-EditorTextBox -Hint 'eu-central-1'
    Add-EditorField $table 'AWS region' $ui.Region 'repository' 'region' '' -RequiresSetup -Note "The bucket's region." `
        -Tip "The AWS region the bucket is in, e.g. eu-central-1.`nChanging it switches the repository: run Setup."
    $ui.Bucket = New-EditorTextBox -Hint 'my-backup-bucket'
    Add-EditorField $table 'Bucket' $ui.Bucket 'repository' 'bucket' '' -RequiresSetup -Note 'Must already exist.' `
        -Tip "Shared by all servers. Each one writes to <bucket>/<computer name>.`nChanging it switches the repository: run Setup."
    $ui.RepositoryUrl = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(3, 7, 3, 7) }
    Add-EditorRow $table 'Repository URL' $ui.RepositoryUrl 'Each server uses its own folder in the bucket.'
    $ui.Region.add_TextChanged({ Update-RepositoryUrl })
    $ui.Bucket.add_TextChanged({ Update-RepositoryUrl })

    Add-EditorHeading $table 'Secrets'
    $ui.SetupReplace = New-Object System.Windows.Forms.CheckBox -Property @{ AutoSize = $true }
    $ui.SetupReplace.add_CheckedChanged({ Update-SetupSecrets })
    Add-EditorRow $table '' $ui.SetupReplace -Note 'Stored encrypted in the data directory, never in the configuration file.' `
        -Tip "secrets.dat, encrypted for this machine (DPAPI). Anyone who can read the file can decrypt it. Setup restricts it to SYSTEM and Administrators."
    $keysTip = "Keys of this server's IAM user, limited to <bucket>/<computer name>.`nPolicy: Help > First-time setup."
    foreach ($spec in @(
            @('AccessKey', 'AWS access key ID', 'AKIAIOSFODNN7EXAMPLE', $false, $keysTip),
            @('SecretKey', 'AWS secret access key', 'The secret of that access key', $true, $keysTip),
            @('Password', 'Restic repository password', 'Encrypts the repository; keep a copy safe', $true,
                "Encrypts this server's repository. Lost password = unreadable backups.`nKeep a copy outside this server."),
            @('Confirm', 'Confirm password', 'The same password again', $true, ''))) {
        $box = New-EditorTextBox -Hint $spec[2]
        $box.UseSystemPasswordChar = $spec[3]
        $ui[$spec[0]] = $box
        Add-EditorRow $table $spec[1] $box -Tip $spec[4]
    }

    Add-EditorHeading $table 'This machine'
    Add-EditorField $table 'Data directory' (New-EditorTextBox -Hint (Get-DefaultDataDirectory)) '' 'dataDirectory' (Get-DefaultDataDirectory) -RequiresSetup `
        -Note 'Holds restic, the secrets, state and logs.' `
        -Tip ("Restricted to SYSTEM and Administrators.`nChanging it: run Setup (installs restic there, asks for the secrets).`n" +
            "A new or empty folder, not a system folder. See Help: Moving the folder.")
    Add-EditorField $table 'Restore root' (New-EditorTextBox -Hint 'C:\Restore') '' 'restoreRoot' 'C:\Restore' -Note 'Restores to a new folder go under here.' `
        -Tip "A restore goes to <restore root>\<snapshot id>-<time>\<folder>.`nCreated for SYSTEM and Administrators only. See Help: Restore details."
    Add-EditorField $table 'Keep logs (days)' (New-EditorNumber) '' 'logRetentionDays' 30 -Note '0 = keep forever.' `
        -Tip 'Older log files are deleted at the start of each run.'
    Add-EditorField $table 'VSS' (New-Object System.Windows.Forms.CheckBox -Property @{
        Text = 'Back up from a volume shadow copy (--use-fs-snapshot)'; AutoSize = $true }) '' 'useVss' $true `
        -Tip 'Open and locked files are backed up in a consistent state.'

    Add-EditorHeading $table 'Setup (installs restic and applies the red fields: secrets, repository, scheduled task)'
    $ui.SetupRestic = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(420, 0); Margin = [System.Windows.Forms.Padding]::new(3, 7, 3, 7)
    }
    Add-EditorRow $table 'restic' $ui.SetupRestic
    $ui.SetupInitialize = New-Object System.Windows.Forms.CheckBox -Property @{
        Text = 'Initialize the repository if it does not exist'; AutoSize = $true; Checked = $true
    }
    Add-EditorRow $table '' $ui.SetupInitialize
    $ui.CopyScope = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Width = 260 }
    [void]$ui.CopyScope.Items.AddRange([object[]]@('Nothing', 'The newest snapshot of each job', 'All snapshots'))
    $ui.CopyScope.SelectedIndex = 0
    $ui.CopyNote = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText; Anchor = 'Top, Left'
        MaximumSize = [System.Drawing.Size]::new(260, 0); Margin = [System.Windows.Forms.Padding]::new(3, 7, 3, 3)
    }
    Add-EditorRow $table 'Copy snapshots' $ui.CopyScope $ui.CopyNote
    $ui.SetupRegisterTask = New-Object System.Windows.Forms.CheckBox -Property @{
        Text = 'Create or update the scheduled backup task'; AutoSize = $true; Checked = $true
    }
    $ui.SetupSchedule = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText; Anchor = 'Top, Left'
        MaximumSize = [System.Drawing.Size]::new(260, 0); Margin = [System.Windows.Forms.Padding]::new(3, 7, 3, 3)
    }
    Add-EditorRow $table '' $ui.SetupRegisterTask $ui.SetupSchedule
    $ui.RunSetup = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Run Setup'; Width = 110; Margin = [System.Windows.Forms.Padding]::new(3, 14, 3, 3)
    }
    $ui.RunSetup.add_Click({ if (Invoke-EditorSetup) { $script:Editor.Ui.Form.Close() } })
    Add-EditorRow $table '' $ui.RunSetup -Note 'Saves, closes this window and runs Setup in the main window.'

    # Schedule
    $table = New-EditorTab $tabs 'Schedule'
    $ui.TaskName = New-EditorTextBox
    Add-EditorField $table 'Task name' $ui.TaskName 'schedule' 'taskName' 'Restic Backup' -RequiresSetup `
        -Note 'Run Setup to apply. A task under the old name is not removed.' `
        -Tip 'In the Task Scheduler root folder. After a rename, Setup offers to remove the old task.'
    $ui.DailyAt = New-EditorTextBox
    Add-EditorField $table 'Daily at (HH:mm)' $ui.DailyAt 'schedule' 'dailyAt' '02:00' -RequiresSetup -Note 'Run Setup to apply.' `
        -Tip "Local time, 24-hour. A missed run starts when the machine is back."
    $ui.TaskName.add_TextChanged({ Update-SetupSchedule })
    $ui.DailyAt.add_TextChanged({ Update-SetupSchedule })
    Add-EditorField $table 'Max runtime (hours)' (New-EditorNumber) 'schedule' 'maxRuntimeHours' 12 -RequiresSetup -Note 'Run Setup to apply.' `
        -Tip 'Task Scheduler stops a run that takes longer.'

    # Retention and maintenance
    $table = New-EditorTab $tabs 'Retention & maintenance'
    Add-EditorHeading $table 'Retention (applied separately to each job)'
    Add-EditorField $table 'Keep last' (New-EditorNumber) 'retention' 'keepLast' 0 -Note '0 = rule off.' -Tip 'The newest N snapshots.'
    foreach ($spec in @(@('hourly', 'hour'), @('daily', 'day'), @('weekly', 'week'), @('monthly', 'month'), @('yearly', 'year'))) {
        $name = $spec[0].Substring(0, 1).ToUpper() + $spec[0].Substring(1)
        Add-EditorField $table "Keep $($spec[0])" (New-EditorNumber) 'retention' "keep$name" 0 `
            -Tip "The newest snapshot of each of the last N $($spec[1])s that have snapshots."
    }
    Add-EditorField $table 'Keep within' (New-EditorTextBox -Hint '30d') 'retention' 'keepWithin' '' -Note 'A duration such as 30d or 1y6m (y, m, d, h). Empty = off.' `
        -Tip "Every snapshot within this time of the job's newest snapshot."

    Add-EditorHeading $table 'Maintenance (run after the scheduled backup when due)'
    Add-EditorField $table 'Forget every (days)' (New-EditorNumber) 'maintenance' 'forgetEveryDays' 0 -Note '0 = never.' `
        -Tip 'Applies the retention policy. Skipped when a backup job failed.'
    Add-EditorField $table 'Prune every (days)' (New-EditorNumber) 'maintenance' 'pruneEveryDays' 0 -Note '0 = never.' `
        -Tip 'Deletes data no snapshot uses; frees S3 space. Slow.'
    Add-EditorField $table 'Check every (days)' (New-EditorNumber) 'maintenance' 'checkEveryDays' 0 -Note '0 = never.' `
        -Tip "Verifies the repository's integrity."
    Add-EditorField $table 'Check data subset' (New-EditorTextBox -Hint '2.5%') 'maintenance' 'checkReadDataSubset' '' `
        -Note 'e.g. 2.5%, 1/10 or 500M. Empty = check the metadata only.' -Tip 'Downloaded and verified on each check. Costs S3 egress.'

    # Global excludes
    $page = New-Object System.Windows.Forms.TabPage 'Global excludes'
    $page.Padding = [System.Windows.Forms.Padding]::new(8)
    $ui.GlobalExcludes = New-EditorTextBox -Multiline
    $ui.GlobalExcludes.Dock = 'Fill'
    $page.Controls.Add($ui.GlobalExcludes)
    $page.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = 'One pattern per line, matched case-insensitively (--iexclude). Applied to every job.'
        Dock = 'Top'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(0, 0, 0, 6)
    }))
    $suggest = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
    }
    $button = New-Object System.Windows.Forms.Button -Property @{ Text = 'Add suggested'; AutoSize = $true }
    $button.add_Click({ Add-SuggestedExcludes })
    $suggest.Controls.Add($button)
    $suggest.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = 'Adds common Windows temp, cache and system files that are missing; keeps yours.'; AutoSize = $true
        ForeColor = [System.Drawing.SystemColors]::GrayText; Margin = [System.Windows.Forms.Padding]::new(6, 8, 3, 3)
    }))
    $page.Controls.Add($suggest)
    $ui.GlobalExcludes.BringToFront()
    Register-EditorChange $ui.GlobalExcludes { Set-EditorDirty }
    $tabs.TabPages.Add($page)

    # Jobs: list on the left, the selected job on the right
    $page = New-Object System.Windows.Forms.TabPage 'Jobs'
    $layout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 1 }
    [void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 250))
    [void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $left = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(8, 8, 0, 8) }
    $ui.JobList = New-Object System.Windows.Forms.ListBox -Property @{ Dock = 'Fill'; IntegralHeight = $false }
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Bottom'; AutoSize = $true }
    foreach ($spec in @(
            @{ Text = 'Add'; Action = { Add-EditorJob } },
            @{ Text = 'Remove'; Action = { Remove-EditorJob } },
            @{ Text = 'Up'; Action = { Move-EditorJob -1 } },
            @{ Text = 'Down'; Action = { Move-EditorJob 1 } })) {
        $button = New-Object System.Windows.Forms.Button -Property @{
            Text = $spec.Text; AutoSize = $true; MinimumSize = [System.Drawing.Size]::new(40, 0); Margin = [System.Windows.Forms.Padding]::new(0, 3, 4, 0)
        }
        $button.add_Click($spec.Action)
        $buttons.Controls.Add($button)
    }
    $left.Controls.Add($ui.JobList)
    $left.Controls.Add($buttons)
    $ui.JobList.BringToFront()
    $ui.JobList.add_SelectedIndexChanged({ if (-not $script:Editor.Loading) { Show-EditorJob } })

    $ui.JobDetails = New-EditorTable
    $table = $ui.JobDetails
    $ui.JobName = New-EditorTextBox -Hint 'documents'
    Add-EditorRow $table 'Name' $ui.JobName -Warning `
        -Note "Letters, digits, '.', '_' or '-'. Renaming: when you save, you can move the old name's snapshots to the new one." `
        -Tip 'Each snapshot is tagged job:<name>; retention works per job tag (case-sensitive).'
    $ui.JobEnabled = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Back up this job'; AutoSize = $true }
    Add-EditorRow $table 'Enabled' $ui.JobEnabled -Note 'Disabled jobs still get retention.' `
        -Tip 'The scheduled backup skips disabled jobs. Back up now can still run them.'
    $ui.JobPaths = New-EditorTextBox -Multiline
    $browse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Add folder...'; AutoSize = $true; Anchor = 'Top, Left' }
    $browse.add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Folder to back up' }
        if ($dialog.ShowDialog() -eq 'OK') {
            $text = $script:Editor.Ui.JobPaths.Text.TrimEnd()
            if ($text) { $text += "`r`n" }
            $script:Editor.Ui.JobPaths.Text = $text + $dialog.SelectedPath
        }
        $dialog.Dispose()
    })
    Add-EditorRow $table 'Paths' $ui.JobPaths $browse -Tip 'Folders or files, one per line. A missing path is skipped with a warning.'
    $ui.MissingPaths = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; ForeColor = [System.Drawing.Color]::Firebrick; MaximumSize = [System.Drawing.Size]::new(420, 0)
    }
    Add-EditorRow $table '' $ui.MissingPaths
    $ui.JobTags = New-EditorTextBox -Hint 'users documents'
    Add-EditorRow $table 'Tags' $ui.JobTags -Note 'Separated by spaces. job:<name> is added automatically.'
    $ui.JobExcludes = New-EditorTextBox -Multiline
    Add-EditorRow $table 'Excludes' $ui.JobExcludes -Note 'One pattern per line, on top of the global excludes.' `
        -Tip 'Case-insensitive restic patterns, e.g. *.iso, .git, C:\Data\Cache.'
    foreach ($control in @($ui.JobName, $ui.JobEnabled, $ui.JobPaths, $ui.JobTags, $ui.JobExcludes)) {
        Register-EditorChange $control { Update-EditorJob }
    }

    $layout.Controls.Add($left, 0, 0)
    $layout.Controls.Add($ui.JobDetails, 1, 0)
    $page.Controls.Add($layout)
    $tabs.TabPages.Add($page)

    # Save / Cancel
    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; FlowDirection = 'RightToLeft'; Padding = [System.Windows.Forms.Padding]::new(6)
    }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90 }
    $cancel.add_Click({ $script:Editor.Ui.Form.Close() })
    $save = New-Object System.Windows.Forms.Button -Property @{ Text = 'Save'; Width = 90 }
    $save.add_Click({ Invoke-EditorSaveAndClose })
    $bottom.Controls.Add($cancel)
    $bottom.Controls.Add($save)
    $helpButton = New-Object System.Windows.Forms.Button -Property @{ Text = 'Help (F1)'; Width = 90 }
    $helpButton.add_Click({ Show-HelpWindow 'Settings' })
    $bottom.Controls.Add($helpButton)

    $form.Controls.Add($tabs)
    $form.Controls.Add($bottom)
    $tabs.BringToFront()

    $form.add_KeyDown({
        param($source, $key)
        if ($key.Control -and $key.KeyCode -eq 'S') {
            $key.SuppressKeyPress = $true
            Invoke-EditorSaveAndClose
        }
        elseif ($key.KeyCode -eq 'F1') {
            $key.SuppressKeyPress = $true
            Show-HelpWindow 'Settings'
        }
    })
    # Opening this dialog disables a Help window that is already open.
    $form.add_Shown({ Enable-HelpWindow })
    $form.add_FormClosing({
        param($source, $closing)
        $editor = $script:Editor
        if ($editor.SetupResult) { return }
        if ($editor.Dirty) {
            $answer = Show-EditorMessage 'Save changes before closing?' 'Question' 'YesNoCancel'
            if ($answer -eq 'Cancel') { $closing.Cancel = $true; return }
            if ($answer -eq 'Yes' -and (-not (Invoke-EditorSave) -or (Request-EditorSetup))) { $closing.Cancel = $true; return }
            # Setup uses the typed secrets.
            if ($editor.SetupResult) { return }
        }
        if ((Test-SetupSecretsTyped) -and
            (Show-EditorMessage "The secrets you entered haven't been stored. Close anyway?" 'Warning' 'YesNo') -ne 'Yes') {
            Show-EditorGeneral $editor.Ui.AccessKey
            $closing.Cancel = $true
        }
    })

    # The repository Setup last set up (recorded in the state file), else the one the file pointed to when opened.
    $dataDirectory = Get-PathSetting $document 'dataDirectory' (Get-DefaultDataDirectory)
    $stateFile = Join-Path $dataDirectory 'state.json'
    try {
        if ([System.IO.File]::Exists($stateFile)) {
            $script:Editor.PreviousRepository = [string](Get-Setting (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json) 'repository' '')
        }
    }
    catch { }
    $repository = Get-Setting $document 'repository'
    if (-not $script:Editor.PreviousRepository -and -not $isNew -and (Get-Setting $repository 'region') -and (Get-Setting $repository 'bucket')) {
        $script:Editor.PreviousRepository = Get-RepositoryUrl (Get-Setting $repository 'region') (Get-Setting $repository 'bucket')
    }

    Import-EditorFields
    $script:Editor.Loading = $false
    Update-RepositoryUrl
    Update-SetupSchedule
    Update-JobList 0
    # A new configuration isn't on disk until saved.
    $script:Editor.Dirty = $isNew
    Update-EditorTitle

    # From the document, so this also works for a new or invalid configuration.
    $stored =[System.IO.File]::Exists((Join-Path $dataDirectory 'secrets.dat'))
    Set-SetupSecretsStored $stored
    try {
        $target = Get-ResticTarget $dataDirectory
        if (-not [System.IO.File]::Exists($target.Path)) {
            $ui.SetupRestic.Text = "$($target.Version), not installed. Setup downloads it, or uses $($target.ZipName) from the script's folder."
        }
        elseif (Test-FileHash $target.Path $target.ExeHash) { $ui.SetupRestic.Text = "$($target.Version), installed." }
        else { $ui.SetupRestic.Text = "$($target.Version), damaged or modified. Setup reinstalls it." }
    }
    catch {
        $ui.SetupRestic.Text = $_.Exception.Message
        $ui.SetupRestic.ForeColor = [System.Drawing.Color]::Firebrick
    }
    if (-not $ui.Region.Text) { $form.ActiveControl = $ui.Region }
    elseif (-not $stored) { $form.ActiveControl = $ui.AccessKey }

    [void]$form.ShowDialog($Owner)

    $result = [pscustomobject]@{ Setup = $script:Editor.SetupResult; Cleanup = @($script:Editor.Cleanup) }
    foreach ($box in @($ui.AccessKey, $ui.SecretKey, $ui.Password, $ui.Confirm)) { $box.Clear() }
    $form.Dispose()
    return $result
}

#endregion

#region GUI runner

# Background work for the main window. The worker only enqueues into $script:Gui.Queue; the UI thread
# polls it with a Forms.Timer (Update-GuiTask). Never call Control.Invoke from the worker: in 5.1 the
# scriptblock would run in the wrong runspace.
# $script:Gui needs: Queue (ConcurrentQueue[object]), Current (the running task or $null), Ui.Output (RichTextBox).
# The runner also maintains OutputLines (lines in the pane) and LastLogFile (log of the last action).

# Every function of this script plus the base variables, copied into a fresh runspace. The functions
# live in the worker's global scope, so their $script: variables resolve to the globals set here.
function New-GuiRunspace {
    param([hashtable]$Variables)

    $state = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    Get-Command -CommandType Function | Where-Object { $_.ScriptBlock.File -eq $script:ScriptPath } | ForEach-Object {
        $state.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $_.Name, $_.Definition))
    }

    $all = @{
        Config                = $script:Config
        ConfigPath            = $script:ConfigPath
        ScriptPath            = $script:ScriptPath
        LogSink               = $script:Gui.Queue
        ResticReady           = $false
        RepositoryChecked     = $false
        ActionData            = $null
        ErrorActionPreference = 'Stop'
    }
    foreach ($key in $Variables.Keys) { $all[$key] = $Variables[$key] }
    foreach ($key in $all.Keys) {
        $state.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $key, $all[$key], $null))
    }

    $runspace = [runspacefactory]::CreateRunspace($state)
    $runspace.Open()
    return $runspace
}

# Runs $Script in a new runspace. OnComplete runs on the UI thread as param($Result, $ErrorMessage):
# $Result is the last object the worker wrote (a worker returning a list returns it as one object: ,@(...)).
# -Action marks an operation: it can be cancelled and is followed by an unlock then (see Stop-GuiTask).
# Returns $false if a task is already running.
function Start-GuiTask {
    param(
        [string]$Name,
        [scriptblock]$Script,
        [hashtable]$Variables = @{},
        [scriptblock]$OnComplete,
        [switch]$Action
    )

    if ($script:Gui.Current) { return $false }

    $runspace = New-GuiRunspace $Variables
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($Script.ToString())

    $script:Gui.Current = @{
        Name                = $Name
        Action              = [bool]$Action
        PowerShell          = $ps
        Runspace            = $runspace
        Async               = $ps.BeginInvoke()
        OnComplete          = $OnComplete
        Started             = Get-Date
        Cancelled           = $false
        # Set on the unlock that follows a cancelled action: the cancelled action's OnComplete.
        CancelledOnComplete = $null
    }
    return $true
}

# An Invoke-Operation run with its own log file, like a scheduled run.
# $Result is [pscustomobject]@{ Statuses; LogFile; Data ($script:ActionData, e.g. the forget preview) }.
function Start-GuiAction {
    param([string]$Operation, [hashtable]$Parameters = @{}, [scriptblock]$OnComplete)

    $worker = {
        try {
            Start-Log -Directory $Config.LogDirectory -RetentionDays $Config.LogRetentionDays -Name $Operation.ToLower()
            Write-Log "Mode:       Gui/$Operation"
            Write-Log "Hostname:   $($Config.Hostname)"
            Write-Log "Repository: $($Config.Repository)"
            Write-Log "Log file:   $LogFile" -Level Detail

            $statuses = @(Invoke-Operation $Operation $Parameters)
            Write-Log "Finished with exit code $(Get-ExitCode $statuses)."
        }
        catch {
            Write-Log $_.Exception.Message -Level Error
            $statuses = @('Failed')
        }
        [pscustomobject]@{ Statuses = $statuses; LogFile = $LogFile; Data = $ActionData }
    }

    return Start-GuiTask -Name $Operation -Script $worker -Action -OnComplete $OnComplete `
        -Variables @{ Operation = $Operation; Parameters = $Parameters }
}

# Stops the running task. The worker can't start a new command once stopping, and killing restic
# unblocks the one it is waiting on (Stop alone would wait for restic to exit).
function Stop-GuiTask {
    param([switch]$Quiet)

    $task = $script:Gui.Current
    if (-not $task -or $task.Cancelled) { return }

    $task.Cancelled = $true
    [void]$task.PowerShell.BeginStop($null, $null)
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID AND Name LIKE 'restic-%.exe'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $Quiet) { $script:Gui.Queue.Enqueue([pscustomobject]@{ Level = 'Warning'; Message = 'Cancelled by user.' }) }
}

# Ends a running query (not an action) without a message, so that an action can start right away.
# Waits up to 10 s; its OnComplete gets 'Cancelled by user.'.
function Stop-GuiQuery {
    $task = $script:Gui.Current
    if (-not $task -or $task.Action) { return }

    Stop-GuiTask -Quiet
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $task.Async.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Update-GuiTask
}

# Moves queued lines into the output pane. A tick stops after $Max lines or ~50 ms, whichever comes
# first ($Max 0 = everything); each change of colour costs a few ms, so the budget matters.
function Receive-GuiOutput {
    param([int]$Max = 500)

    $box = $script:Gui.Ui.Output
    $colors = @{
        Info    = [System.Drawing.SystemColors]::WindowText
        Success = [System.Drawing.Color]::Green
        Warning = [System.Drawing.Color]::DarkOrange
        Error   = [System.Drawing.Color]::Red
        Detail  = [System.Drawing.Color]::Gray
    }

    # Consecutive lines of the same level are appended in one go.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $item = $null
    $level = $null
    $text = New-Object System.Text.StringBuilder
    $count = 0
    while (($Max -le 0 -or ($count -lt $Max -and $watch.ElapsedMilliseconds -lt 50)) -and
           $script:Gui.Queue.TryDequeue([ref]$item)) {
        $count++
        if ($level -and $item.Level -ne $level) {
            Add-GuiOutputText $box $text.ToString() $colors[$level]
            [void]$text.Clear()
        }
        $level = $item.Level
        [void]$text.Append([string]$item.Message).Append("`n")
    }
    if (-not $level -or -not $box) { return }

    Add-GuiOutputText $box $text.ToString() $colors[$level]
    $script:Gui.OutputLines += $count
    Limit-GuiOutput $box
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Add-GuiOutputText {
    param($Box, [string]$Text, $Color)

    if (-not $Box) { return }
    $Box.SelectionStart = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionColor = $Color
    $Box.AppendText($Text)
}

# Keeps at most ~20,000 lines, trimming from the top in steps of 1000 so it doesn't run every tick.
# Counts logical lines itself: the box's own line numbers include word-wrapped lines.
function Limit-GuiOutput {
    param($Box)

    $maxLines = 20000
    $excess = $script:Gui.OutputLines - $maxLines
    if ($excess -lt 1000) { return }

    $content = $Box.Text
    $index = -1
    for ($i = 0; $i -lt $excess; $i++) {
        $index = $content.IndexOf("`n", $index + 1)
        if ($index -lt 0) { break }
    }
    if ($index -lt 0) { return }

    $Box.ReadOnly = $false
    $Box.Select(0, $index + 1)
    $Box.SelectedText = ''
    $Box.ReadOnly = $true
    $script:Gui.OutputLines -= $excess
}

# Timer tick: show queued output; when the task has finished, clean it up and call its OnComplete.
function Update-GuiTask {
    Receive-GuiOutput

    $task = $script:Gui.Current
    if (-not $task -or -not $task.Async.IsCompleted) { return }

    $result = $null
    $errorMessage = $null
    try {
        $output = $task.PowerShell.EndInvoke($task.Async)
        if ($output.Count -gt 0) { $result = $output[$output.Count - 1] }
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($_.Exception.InnerException) { $errorMessage = $_.Exception.InnerException.Message }
    }
    if (-not $errorMessage -and $task.PowerShell.Streams.Error.Count -gt 0) {
        $errorMessage = $task.PowerShell.Streams.Error[0].Exception.Message
    }
    $task.PowerShell.Dispose()
    $task.Runspace.Dispose()
    $script:Gui.Current = $null

    # Last lines first, then the follow-up.
    Receive-GuiOutput -Max 0
    if ($task.Action -and $result -and $result.LogFile) { $script:Gui.LastLogFile = $result.LogFile }

    $onComplete = $task.OnComplete
    if ($task.CancelledOnComplete) {
        $onComplete = $task.CancelledOnComplete
        $result = $null
        $errorMessage = 'Cancelled by user.'
    }
    if ($task.Cancelled) {
        $result = $null
        $errorMessage = 'Cancelled by user.'
        # restic leaves its lock behind when killed. Locks of dead processes on this host are stale,
        # so 'unlock' can't remove another machine's lock. The cancelled action completes after it.
        if ($task.Action -and $task.Name -notin @('Setup', 'Unlock')) {
            if (Start-GuiAction -Operation 'Unlock') {
                $script:Gui.Current.CancelledOnComplete = $onComplete
                return
            }
        }
    }
    if ($onComplete) { & $onComplete $result $errorMessage }
}

# The 100 ms timer that drives Update-GuiTask; start it with the main window.
function New-GuiTimer {
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        try { Update-GuiTask }
        catch { $script:Gui.Queue.Enqueue([pscustomobject]@{ Level = 'Error'; Message = $_.Exception.Message }) }
    })
    return $timer
}

#endregion

#region Main window

function Test-WinForms {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        return $true
    }
    catch { return $false }
}

# The launcher starts PowerShell with a visible console (so the menu fallback works); the window hides it.
function Set-ConsoleWindowVisible {
    param([bool]$Visible)

    try {
        if (-not ('ResticGui.ConsoleWindow' -as [type])) {
            Add-Type -Namespace ResticGui -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        }
        $handle = [ResticGui.ConsoleWindow]::GetConsoleWindow()
        if ($handle -eq [IntPtr]::Zero) { return }
        $command = 0
        if ($Visible) { $command = 5 }
        [void][ResticGui.ConsoleWindow]::ShowWindow($handle, $command)
    }
    catch { }
}

function Show-GuiMessage {
    param([string]$Text, [string]$Icon = 'Error', [string]$Buttons = 'OK', [string]$DefaultButton = 'Button1')

    return [string][System.Windows.Forms.MessageBox]::Show($script:Gui.Ui.Form, $Text, 'Restic', $Buttons, $Icon, $DefaultButton)
}

# Into the output pane, in order with the worker's lines.
function Write-GuiLine {
    param([string]$Message, [string]$Level = 'Info')

    $script:Gui.Queue.Enqueue([pscustomobject]@{ Level = $Level; Message = $Message })
}

function Get-GuiTaskLabel {
    param([string]$Name)

    $labels = @{
        BackupOnly = 'Back up now'; ForgetPreview = 'Forget (dry run)'; Maintenance = 'Run due maintenance'
        Repository = 'Checking the repository'; Browse = 'Reading the snapshot'
        EnableTask = 'Enable the scheduled task'; DisableTask = 'Disable the scheduled task'
        Cleanup = 'Clean up snapshots outside retention'; ForgetSnapshots = 'Forget snapshots'
    }
    if ($labels.ContainsKey($Name)) { return $labels[$Name] }
    return $Name
}

function Update-GuiConfig {
    $gui = $script:Gui
    try {
        $gui.Config = Read-Config $gui.ConfigPath
        $gui.ConfigError = $null
    }
    catch {
        $gui.Config = $null
        $gui.ConfigError = $_.Exception.Message
        if (-not (Test-Path -LiteralPath $gui.ConfigPath -PathType Leaf)) {
            $gui.ConfigError = "There is no configuration yet ($($gui.ConfigPath)). Create it in Settings."
        }
    }
    # Get-TaskStatus, Read-State etc. read these; the workers get copies of them.
    $script:Config = $gui.Config
    $script:ConfigPath = $gui.ConfigPath
}

# Local and fast checks, on the UI thread. The repository is checked by Update-GuiRepository.
function Update-GuiHealth {
    # RepositoryChange: the repository Setup last set up, when the configuration points elsewhere (Get-RepositoryChange).
    $health = @{ ResticError = $null; SecretsError = $null; Task = $null; State = $null; RepositoryChange = $null }
    $script:Gui.Health = $health
    if (-not $script:Gui.Config) { return }

    try { $null = Find-ResticExe }
    catch { $health.ResticError = $_.Exception.Message }

    if (-not (Test-Path -LiteralPath $script:Config.SecretsFile -PathType Leaf)) {
        $health.SecretsError = "No secrets are stored in $($script:Config.DataDirectory). Run Setup in Settings."
    }
    else {
        try { $null = Read-Secrets }
        catch { $health.SecretsError = $_.Exception.Message }
    }

    try { $health.Task = Get-TaskStatus } catch { }
    try {
        $health.State = Read-State
        $health.RepositoryChange = Get-RepositoryChange $health.State
    }
    catch { }
}

# Whether the repository check can't run: the same conditions under which restic actions can't.
function Test-GuiRepositoryBlocked {
    $gui = $script:Gui
    return (-not $gui.Config -or $gui.Health.ResticError -or $gui.Health.SecretsError -or $gui.Health.RepositoryChange)
}

# Background query: can the repository be reached, and its snapshot list (kept for the snapshot views).
function Update-GuiRepository {
    $gui = $script:Gui
    if ($gui.ClosePending) { return }
    if (Test-GuiRepositoryBlocked) {
        $gui.Repository = @{ Status = 'Unknown'; Message = $null }
        $gui.Snapshots = @()
        $gui.SnapshotsLoaded = $false
        Update-GuiSnapshots
        return
    }

    $probe = {
        $code = $null
        $message = $null
        $snapshots = $null
        try {
            Initialize-Restic
            $code = Get-RepositoryStatus
            if ($code -eq 0) { $snapshots = @(Get-SnapshotList) }
        }
        catch { $message = $_.Exception.Message }

        # Its own sink: restic's messages explain a failure, but don't belong in the output pane.
        $lines = New-Object System.Collections.ArrayList
        $item = $null
        while ($LogSink.TryDequeue([ref]$item)) {
            if ($item.Level -ne 'Detail' -and $item.Message) { [void]$lines.Add([string]$item.Message) }
        }
        [pscustomobject]@{ Code = $code; Message = $message; Output = @($lines); Snapshots = $snapshots }
    }

    $started = Start-GuiTask -Name 'Repository' -Script $probe `
        -Variables @{ LogSink = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') } `
        -OnComplete { param($Result, $ErrorMessage) Complete-GuiRepository $Result $ErrorMessage }
    # Not started = another task is running; its completion refreshes again.
    if ($started) { $gui.Repository = @{ Status = 'Checking'; Message = $null } }
}

function Complete-GuiRepository {
    param($Result, $ErrorMessage)

    $repository = @{ Status = 'Error'; Message = $ErrorMessage }
    if (-not $ErrorMessage) {
        if ($Result.Message) { $repository.Message = $Result.Message }
        elseif ($Result.Code -eq 0) {
            $repository.Status = 'OK'
            $script:Gui.Snapshots = @($Result.Snapshots)
        }
        elseif ($Result.Code -eq 10) {
            $repository.Status = 'NotInitialized'
            $repository.Message = 'The repository is not initialized. Run Setup in Settings.'
        }
        else {
            $repository.Status = 'NoAccess'
            $repository.Message = "The repository can't be accessed (restic exit code $($Result.Code))."
            if ($Result.Output.Count -gt 0) { $repository.Message += ' ' + $Result.Output[-1] }
        }
    }
    $script:Gui.Repository = $repository
    if ($repository.Status -ne 'OK') {
        # An old list would pass for the current one.
        $script:Gui.Snapshots = @()
        $script:Gui.SnapshotsLoaded = $false
        # Cancelled = ended by Stop-GuiQuery so an action can start; the action refreshes afterwards.
        if (-not $script:Gui.ClosePending -and $ErrorMessage -ne 'Cancelled by user.') { Write-GuiLine "Repository check: $($repository.Message)" 'Error' }
    }
    else { $script:Gui.SnapshotsLoaded = $true }
    Update-GuiSnapshots
    Update-GuiStatus
    Update-GuiButtons
}

# Everything local first (fast), then the repository check in the background.
function Update-GuiAll {
    Update-GuiConfig
    Update-GuiHealth
    Update-GuiRepository
    Update-GuiStatus
    Update-GuiButtons
}

# Like Update-GuiAll, but keeps the last repository check and snapshot list (after actions that don't
# change them). Update-GuiRepository still runs when the check can't run any more: it only resets then.
function Update-GuiLocal {
    Update-GuiConfig
    Update-GuiHealth
    if (Test-GuiRepositoryBlocked) { Update-GuiRepository }
    Update-GuiStatus
    Update-GuiButtons
}

# Operations after which the snapshot list is reloaded (Maintenance may run forget).
function Test-GuiChangesSnapshots {
    param([string]$Operation)
    return $Operation -in @('BackupOnly', 'Forget', 'ForgetSnapshots', 'Maintenance', 'Cleanup')
}

# Replaces the labels of a status line. Segments: @(text, color) pairs; $null color = normal text. An optional
# third item, a scriptblock, makes the segment a link that runs it.
function Set-GuiSegments {
    param($Flow, [object[]]$Segments)

    $Flow.SuspendLayout()
    while ($Flow.Controls.Count -gt 0) { $Flow.Controls[0].Dispose() }
    foreach ($segment in $Segments) {
        $label = New-Object System.Windows.Forms.Label -Property @{
            Text = $segment[0]; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 0, 14, 0)
        }
        if ($segment[1]) { $label.ForeColor = $segment[1] }
        if ($segment.Count -gt 2 -and $segment[2]) {
            $label.Font = [System.Drawing.Font]::new($label.Font, [System.Drawing.FontStyle]::Underline)
            $label.Cursor = [System.Windows.Forms.Cursors]::Hand
            $label.Tag = $segment[2]
            $label.add_Click({ param($source) Invoke-GuiHandler $source.Tag })
        }
        $Flow.Controls.Add($label)
    }
    $Flow.ResumeLayout()
}

function Format-GuiTaskResult {
    param($Code)

    switch ($Code) {
        0 { return 'OK' }
        3 { return 'warnings' }
        267009 { return 'running' }   # 0x41301
    }
    return "failed (exit code $Code)"
}

# Newest snapshot per configured job. Stale = enabled and no snapshot in the last 48 hours (or none at
# all); disabled jobs are never stale. Returns Name, Enabled, Newest ($null = never), Stale.
function Get-JobSnapshotSummary {
    param($Jobs, $Snapshots, [datetime]$Now = (Get-Date))

    $staleHours = 48
    return @(foreach ($job in @($Jobs)) {
        $newest = $null
        foreach ($snapshot in @($Snapshots)) {
            # Tags are case-sensitive in restic.
            if ($snapshot.Job -ceq $job.Name -and (-not $newest -or $snapshot.Time -gt $newest)) { $newest = $snapshot.Time }
        }
        $stale = [bool]$job.Enabled -and (-not $newest -or ($Now - $newest).TotalHours -gt $staleHours)
        [pscustomobject]@{ Name = $job.Name; Enabled = [bool]$job.Enabled; Newest = $newest; Stale = $stale }
    })
}

function Update-GuiStatus {
    $gui = $script:Gui
    $ui = $gui.Ui
    $config = $gui.Config
    $health = $gui.Health
    $red = [System.Drawing.Color]::Firebrick
    $gray = [System.Drawing.SystemColors]::GrayText
    $ok = ' ' + [char]0x2713
    $bad = ' ' + [char]0x2717

    $hostname = $env:COMPUTERNAME
    if ($config) { $hostname = $config.Hostname }
    $ui.Form.Text = "Restic - $hostname"
    $ui.Host.Text = $hostname
    if ($config) { $ui.Repository.Text = $config.Repository }
    else { $ui.Repository.Text = "Configuration: $($gui.ConfigPath)" }

    # Health, plus the first problem's message underneath
    $segments = @()
    $problem = $null
    # The help section about the problem.
    $topic = $null
    if (-not $config) {
        $segments += , @("Config$bad", $red)
        $problem = $gui.ConfigError
        $topic = 'Settings'
        if (-not (Test-Path -LiteralPath $gui.ConfigPath -PathType Leaf)) { $topic = 'First-time setup' }
    }
    else {
        $segments += , @("Config$ok", $null)
        $restic = "restic $((Get-ResticPin).Version)"
        if ($health.ResticError) { $segments += , @("$restic$bad", $red); $problem = $health.ResticError; $topic = 'Setup' }
        else { $segments += , @("$restic$ok", $null) }

        if ($health.SecretsError) {
            $segments += , @("Secrets$bad", $red)
            if (-not $problem) { $problem = $health.SecretsError; $topic = 'Setup' }
        }
        elseif (-not $health.ResticError) { $segments += , @("Secrets$ok", $null) }

        if ($health.RepositoryChange) {
            $segments += , @("Repository$bad", $red)
            if (-not $problem) {
                $problem = "The repository changed from $($health.RepositoryChange) (the region, bucket or computer name changed), " +
                    'so backups fail until Setup runs. Run Setup in Settings (it can copy the snapshots), or change the configuration back.'
                $topic = 'Switching repositories'
            }
        }

        switch ($gui.Repository.Status) {
            'OK'       { $segments += , @("Repository$ok", $null) }
            'Checking' { $segments += , @("Repository (checking$([char]0x2026))", $gray) }
            'Unknown'  { }
            default {
                $segments += , @("Repository$bad", $red)
                if (-not $problem) {
                    $problem = $gui.Repository.Message
                    $topic = 'Troubleshooting'
                    if ($gui.Repository.Status -eq 'NotInitialized') { $topic = 'Setup' }
                }
            }
        }
    }
    Set-GuiSegments $ui.Health $segments
    $ui.Problem.Text = [string]$problem
    $ui.ProblemRow.Visible = [bool]$problem
    $gui.ProblemHelp = $topic

    # Scheduled task
    $task = $health.Task
    $topic = $null
    if (-not $config) { $segments = @(, @('unknown (the configuration is invalid)', $gray)) }
    elseif (-not $task) { $segments = @(, @('unknown (the task could not be read)', $gray)) }
    elseif ($task.Foreign) {
        $segments = @(, @("'$($task.Name)' is another program's task; change the task name in Settings", $red))
        $topic = 'Scheduled task'
    }
    elseif (-not $task.Registered) {
        $segments = @(, @("'$($task.Name)' is not registered; run Setup in Settings", $red))
        $topic = 'Setup'
    }
    else {
        $segments = @()
        if (-not $task.LocationMatches) {
            $segments += , @("'$($task.Name)' points to a different location; run Setup in Settings", $red)
            $topic = 'Moving the folder'
        }
        else { $segments += , @("'$($task.Name)' daily", $null) }
        if ($task.State -eq 'Disabled') { $segments += , @('Disabled (no scheduled backups)', [System.Drawing.Color]::DarkOrange) }
        else { $segments += , @($task.State, $null) }
        if ($task.NextRun -and $task.State -ne 'Disabled') { $segments += , @(('next {0:yyyy-MM-dd HH:mm}' -f $task.NextRun), $null) }
        if ($task.LastRun) {
            $color = $null
            if ($task.LastResult -eq 3) { $color = [System.Drawing.Color]::DarkOrange }
            elseif ($task.LastResult -notin @(0, 267009)) { $color = $red }
            $segments += , @(('last {0} ({1:yyyy-MM-dd HH:mm})' -f (Format-GuiTaskResult $task.LastResult), $task.LastRun), $color)
        }
        else { $segments += , @('not run yet', $gray) }
    }
    if ($config -and $task -and $task.Leftovers.Count -gt 0) {
        $segments += , @("also found: $(Format-TaskLeftovers $task.Leftovers); run Setup in Settings to remove them", $red)
        if (-not $topic) { $topic = 'Scheduled task' }
    }
    if ($topic) { $segments += , @('Help', $null, [scriptblock]::Create("Show-HelpWindow '$topic'")) }
    Set-GuiSegments $ui.Task $segments

    # Maintenance
    if ($config -and $health.State) {
        $state = $health.State
        $ui.Maintenance.Text = 'forget {0}    prune {1}    check {2}' -f (Format-StateTimestamp $state 'lastForget'),
            (Format-StateTimestamp $state 'lastPrune'), (Format-StateTimestamp $state 'lastCheck')
    }
    else { $ui.Maintenance.Text = 'unknown' }

    # Newest snapshot per job
    if (-not $config) { $segments = @(, @('unknown', $gray)) }
    elseif ($config.Jobs.Count -eq 0) { $segments = @(, @('no jobs configured', $gray)) }
    elseif (-not $gui.SnapshotsLoaded) {
        if ($gui.Repository.Status -eq 'Checking') { $segments = @(, @("checking$([char]0x2026)", $gray)) }
        else { $segments = @(, @('unknown (the snapshots could not be read)', $gray)) }
    }
    else {
        $segments = @(foreach ($job in Get-JobSnapshotSummary $config.Jobs $gui.Snapshots) {
            $text = "$($job.Name) never"
            if ($job.Newest) { $text = '{0} {1:yyyy-MM-dd HH:mm}' -f $job.Name, $job.Newest }
            if (-not $job.Enabled) { , @("$text (disabled)", $gray) }
            elseif (-not $job.Stale) { , @($text, $null) }
            elseif ($job.Newest) { , @("$text (stale, > 48h)", $red) }
            else { , @($text, $red) }
        })
        # Grey, not red: keeping them is a valid choice.
        $groups = @(Get-UnmanagedSnapshotGroups $config.Jobs $gui.Snapshots)
        if ($groups.Count -gt 0) {
            $text = 'outside retention: ' + (@($groups | ForEach-Object { "$($_.Label) ($($_.Count))" }) -join ', ')
            $segments += , @($text, $gray, { Invoke-GuiCleanup })
        }
    }
    Set-GuiSegments $ui.Jobs $segments
}

# Enables the buttons that make sense in the current state; a disabled button shows why on hover.
function Update-GuiButtons {
    $gui = $script:Gui
    $health = $gui.Health
    $running = $gui.Current

    $actions = $null   # reason the repository actions are unavailable
    $settings = $null
    if ($running -and $running.Action) {
        $actions = 'An action is running.'
        $settings = $actions
    }
    elseif (-not $gui.Config) {
        $actions = 'The configuration is invalid. Fix it in Settings.'
        if (-not (Test-Path -LiteralPath $gui.ConfigPath -PathType Leaf)) { $actions = 'There is no configuration yet. Create it in Settings.' }
    }
    elseif ($health.ResticError) { $actions = "restic $((Get-ResticPin).Version) is not installed or doesn't match its hash. Run Setup in Settings." }
    elseif ($health.SecretsError) { $actions = 'No usable secrets are stored. Run Setup in Settings.' }
    elseif ($health.RepositoryChange) { $actions = 'The repository changed. Run Setup in Settings, or change the configuration back.' }
    elseif ($gui.Repository.Status -eq 'NotInitialized') { $actions = 'The repository is not initialized. Run Setup in Settings.' }
    elseif ($gui.Repository.Status -ne 'OK' -and $gui.Repository.Status -ne 'Checking') {
        $actions = "The repository can't be accessed. See the status at the top."
    }
    elseif ($running -or $gui.Repository.Status -eq 'Checking') { $actions = 'Waiting for the repository check.' }

    $reasons = @{}
    foreach ($name in @('BackupNow', 'List', 'Restore', 'Forget', 'Prune', 'Check', 'Maintenance', 'Cleanup')) { $reasons[$name] = $actions }
    $reasons.Settings = $settings
    if (-not $reasons.Cleanup -and $gui.Config -and @(Get-UnmanagedSnapshotGroups $gui.Config.Jobs $gui.Snapshots).Count -eq 0) {
        $reasons.Cleanup = 'Every snapshot belongs to a configured job.'
    }
    $reasons.ForgetSelected = $actions
    if (-not $actions -and $gui.Ui.SnapshotGrid -and $gui.Ui.SnapshotGrid.Tag.Grid.SelectedRows.Count -eq 0) {
        $reasons.ForgetSelected = 'Select the snapshots to forget first.'
    }

    # Acts on Task Scheduler only, so it doesn't wait for restic, the secrets or the repository.
    $task = $health.Task
    $reasons.Task = $settings
    if (-not $reasons.Task) {
        if (-not $gui.Config) { $reasons.Task = 'The configuration is invalid. Fix it in Settings.' }
        elseif (-not $task) { $reasons.Task = 'The scheduled task could not be read.' }
        elseif ($task.Foreign) { $reasons.Task = "The scheduled task '$($task.Name)' is another program's task. Change the task name in Settings." }
        elseif (-not $task.Registered) { $reasons.Task = "The scheduled task '$($task.Name)' is not registered. Run Setup in Settings." }
    }
    $taskText = 'Disable task'
    if ($task -and $task.State -eq 'Disabled') { $taskText = 'Enable task' }
    $gui.Ui.Buttons.Task.Text = $taskText

    foreach ($name in $gui.Unbuilt) {
        if (-not $reasons[$name]) { $reasons[$name] = 'Not in the window yet. Use the console menu (-Mode Menu).' }
    }

    foreach ($name in $reasons.Keys) {
        $gui.Ui.Buttons[$name].Enabled = -not $reasons[$name]
    }
    $gui.Reasons = $reasons

    $ui = $gui.Ui
    $ui.Refresh.Enabled = -not $running
    $ui.Cancel.Enabled = [bool]($running -and $running.Action -and -not $running.Cancelled)
    $ui.OpenLog.Enabled = [bool]($gui.LastLogFile -and (Test-Path -LiteralPath $gui.LastLogFile -PathType Leaf))
}

function Update-GuiStatusBar {
    $task = $script:Gui.Current
    $text = 'Ready'
    if ($task -and $task.Action) {
        $verb = 'Running'
        if ($task.Cancelled) { $verb = 'Cancelling' }
        $text = '{0}: {1}   {2:hh\:mm\:ss}' -f $verb, (Get-GuiTaskLabel $task.Name), ((Get-Date) - $task.Started)
    }
    elseif ($task) { $text = "$(Get-GuiTaskLabel $task.Name)$([char]0x2026)" }

    if ($script:Gui.Ui.StatusText.Text -ne $text) { $script:Gui.Ui.StatusText.Text = $text }
}

# Starts an operation as an action. Default OnComplete: report it, then refresh (the repository check
# only when the operation can change the snapshot list).
function Start-GuiOperation {
    param(
        [string]$Operation,
        [hashtable]$Parameters = @{},
        [scriptblock]$OnComplete
    )

    if (-not $OnComplete) {
        if (Test-GuiChangesSnapshots $Operation) {
            $OnComplete = { param($Result, $ErrorMessage) Complete-GuiOperation $Result $ErrorMessage | Out-Null; Update-GuiAll }
        }
        else { $OnComplete = { param($Result, $ErrorMessage) Complete-GuiOperation $Result $ErrorMessage | Out-Null; Update-GuiLocal } }
    }
    if ($script:Gui.ClosePending) { return }
    if ($script:Gui.Current) {
        Show-GuiMessage 'Another task is still running. Try again when it has finished.' 'Warning' | Out-Null
        return
    }

    $script:Gui.Ui.Tabs.SelectedTab = $script:Gui.Ui.OutputPage
    # Instead of clearing the pane between actions.
    $rule = [string][char]0x2500 * 4
    Write-GuiLine ('{0} {1:yyyy-MM-dd HH:mm:ss}  {2} {0}' -f $rule, (Get-Date), (Get-GuiTaskLabel $Operation)) 'Detail'
    [void](Start-GuiAction -Operation $Operation -Parameters $Parameters -OnComplete $OnComplete)
    Update-GuiButtons
    Update-GuiStatusBar
}

# Writes the "Done" line like the menu does. Returns the exit code, or $null when cancelled.
function Complete-GuiOperation {
    param($Result, $ErrorMessage)

    if ($ErrorMessage -eq 'Cancelled by user.') {
        Write-GuiLine 'Done (cancelled).' 'Warning'
        return $null
    }

    $code = 1
    if ($ErrorMessage) { Write-GuiLine $ErrorMessage 'Error' }
    elseif ($Result) { $code = Get-ExitCode @($Result.Statuses) }
    $levels = @{ 0 = 'Success'; 1 = 'Error'; 3 = 'Warning' }
    Write-GuiLine "Done (exit code $code)." $levels[$code]
    return $code
}

# Runs a button's action; an error goes to a message box instead of the WinForms crash dialog.
function Invoke-GuiHandler {
    param([scriptblock]$Action)

    try { & $Action }
    catch { Show-GuiMessage $_.Exception.Message | Out-Null }
}

# Jobs to back up now: enabled ones ticked, disabled ones can be ticked. Returns the names in config
# order, or $null when cancelled.
function Show-BackupDialog {
    $jobs = @($script:Config.Jobs)

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Back up now'; ClientSize = [System.Drawing.Size]::new(380, 300); MinimumSize = [System.Drawing.Size]::new(300, 220)
        StartPosition = 'CenterParent'; Font = [System.Drawing.Font]::new('Segoe UI', 9)
        MinimizeBox = $false; MaximizeBox = $false; ShowInTaskbar = $false; Padding = [System.Windows.Forms.Padding]::new(10)
    }
    $label = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Jobs to back up now. No maintenance runs afterwards.'; Dock = 'Top'; AutoSize = $true
        Padding = [System.Windows.Forms.Padding]::new(0, 0, 0, 6)
    }
    $list = New-Object System.Windows.Forms.CheckedListBox -Property @{ Dock = 'Fill'; CheckOnClick = $true; IntegralHeight = $false }
    foreach ($job in $jobs) {
        $text = $job.Name
        if (-not $job.Enabled) { $text += ' (disabled)' }
        [void]$list.Items.Add($text, $job.Enabled)
    }

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; FlowDirection = 'RightToLeft'; Padding = [System.Windows.Forms.Padding]::new(0, 8, 0, 0)
    }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90; DialogResult = 'Cancel' }
    $ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'Back up'; Width = 90; DialogResult = 'OK' }
    $ok.Enabled = $list.CheckedItems.Count -gt 0
    $bottom.Controls.Add($cancel)
    $bottom.Controls.Add($ok)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    # ItemCheck fires before the change.
    $list.add_ItemCheck({
        param($source, $change)
        $count = $source.CheckedItems.Count
        if ($change.NewValue -eq 'Checked') { $count++ } else { $count-- }
        $source.FindForm().AcceptButton.Enabled = $count -gt 0
    })

    $form.Controls.Add($list)
    $form.Controls.Add($label)
    $form.Controls.Add($bottom)
    $list.BringToFront()

    $result = $form.ShowDialog($script:Gui.Ui.Form)
    $names = @()
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        if ($list.GetItemChecked($i)) { $names += $jobs[$i].Name }
    }
    $form.Dispose()

    if ($result -ne 'OK') { return $null }
    return , $names
}

# What to do with groups of snapshots outside retention (Get-UnmanagedSnapshotGroups objects; Count $null = unknown).
# JobNames: the jobs they can be assigned to. Suggest: @{ <group job> = <job> } preselects that assignment (a rename).
# Asks before forgetting anything. Returns the Cleanup actions (keeping isn't one, so it can be empty), or $null
# when cancelled. Also used by the Settings dialog, hence -Owner.
function Show-CleanupDialog {
    param($Groups, [string[]]$JobNames, $Owner, [string]$Intro, [hashtable]$Suggest = @{})

    $Groups = @($Groups)
    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Snapshots outside retention'; StartPosition = 'CenterParent'; Font = [System.Drawing.Font]::new('Segoe UI', 9)
        FormBorderStyle = 'FixedDialog'; MinimizeBox = $false; MaximizeBox = $false; ShowInTaskbar = $false
        AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = [System.Windows.Forms.Padding]::new(10)
    }
    # Auto-sized to its content, so it isn't cut off at higher display scaling.
    $layout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ AutoSize = $true; ColumnCount = 2; Location = [System.Drawing.Point]::new(10, 10) }
    $row = 0
    $intro = New-Object System.Windows.Forms.Label -Property @{
        Text = $Intro; AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(560, 0); Margin = [System.Windows.Forms.Padding]::new(3, 0, 3, 10)
    }
    $layout.Controls.Add($intro, 0, $row)
    $layout.SetColumnSpan($intro, 2)

    $combos = @()
    foreach ($group in $Groups) {
        $row++
        $text = $group.Label
        if ($null -ne $group.Count) { $text += ' ({0} snapshots, newest {1:yyyy-MM-dd HH:mm})' -f $group.Count, $group.Newest }
        $layout.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
            Text = $text; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(3, 7, 12, 3)
        }), 0, $row)

        $choices = @(
            @{ Text = 'Keep them (no retention)'; Action = $null },
            @{ Text = 'Forget them all'; Action = @{ Job = $group.Job; Action = 'Delete' } },
            @{ Text = 'Keep only the newest'; Action = @{ Job = $group.Job; Action = 'KeepNewest' } }
        )
        foreach ($name in @($JobNames)) {
            $choices += @{ Text = "Assign them to job '$name'"; Action = @{ Job = $group.Job; Action = 'Retag'; Target = $name } }
        }
        $combo = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Width = 280 }
        foreach ($choice in $choices) { [void]$combo.Items.Add($choice.Text) }
        $combo.Tag = $choices
        $combo.SelectedIndex = 0
        if ($group.Job -and $Suggest.ContainsKey($group.Job)) {
            $index = [array]::IndexOf([string[]]@($JobNames), [string]$Suggest[$group.Job])
            if ($index -ge 0) { $combo.SelectedIndex = 3 + $index }
        }
        $layout.Controls.Add($combo, 1, $row)
        $combos += $combo
    }

    $row++
    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        AutoSize = $true; FlowDirection = 'RightToLeft'; Anchor = 'Right'; Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0)
    }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90; DialogResult = 'Cancel' }
    $ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'OK'; Width = 90; DialogResult = 'OK' }
    $bottom.Controls.Add($cancel)
    $bottom.Controls.Add($ok)
    $layout.Controls.Add($bottom, 0, $row)
    $layout.SetColumnSpan($bottom, 2)
    $form.Controls.Add($layout)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    # Handlers can't see this function's variables.
    $form.Tag = $combos

    $form.add_FormClosing({
        param($source, $closing)
        if ($source.DialogResult -ne 'OK') { return }
        $forgotten = @(foreach ($combo in $source.Tag) {
            $action = $combo.Tag[$combo.SelectedIndex].Action
            if ($action -and $action.Action -ne 'Retag') { Format-SnapshotGroupLabel $action.Job }
        })
        if ($forgotten.Count -eq 0) { return }
        $message = "Forget the snapshots of $($forgotten -join ', ') (all, or all but the newest)?`n`nForgotten snapshots can't be restored."
        if ([System.Windows.Forms.MessageBox]::Show($source, $message, 'Restic', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { $closing.Cancel = $true }
    })

    $result = $form.ShowDialog($Owner)
    $actions = @(foreach ($combo in $combos) {
        $action = $combo.Tag[$combo.SelectedIndex].Action
        if ($action) { $action }
    })
    $form.Dispose()

    if ($result -ne 'OK') { return $null }
    return , $actions
}

# The Clean up button: the snapshots no configured job gives retention.
function Invoke-GuiCleanup {
    $gui = $script:Gui
    if (-not $gui.Ui.Buttons.Cleanup.Enabled) { return }
    $groups = @(Get-UnmanagedSnapshotGroups $gui.Config.Jobs $gui.Snapshots)
    if ($groups.Count -eq 0) { return }

    $intro = 'No configured job applies retention to these snapshots: they belong to removed or renamed jobs, or have no ' +
        'job tag (e.g. from before jobs existed). They are kept forever unless you choose otherwise.'
    $actions = Show-CleanupDialog $groups @($gui.Config.Jobs | ForEach-Object { $_.Name }) $gui.Ui.Form $intro
    Update-GuiButtons
    if ($null -eq $actions -or $actions.Count -eq 0) { return }
    Start-GuiCleanup $actions
}

# Afterwards offers to prune when snapshots were forgotten.
function Start-GuiCleanup {
    param([object[]]$Actions)

    $script:Gui.CleanupRemoves = Test-CleanupRemoves $Actions
    Start-GuiOperation 'Cleanup' @{ Actions = $Actions } -OnComplete {
        param($Result, $ErrorMessage)
        $code = Complete-GuiOperation $Result $ErrorMessage
        if ($code -eq 0 -and $script:Gui.CleanupRemoves -and -not $script:Gui.ClosePending -and
            (Show-GuiMessage "Prune now to free the space?`n`nOtherwise the next scheduled prune does." 'Question' 'YesNo' 'Button2') -eq 'Yes') {
            Start-GuiOperation 'Prune' -OnComplete { param($Result, $ErrorMessage) Complete-GuiOperation $Result $ErrorMessage | Out-Null; Update-GuiAll }
            return
        }
        Update-GuiAll
    }
}

# The Forget button, and Forget selected in the Snapshots tab (Ids: the selected snapshots). A retention dry run
# first (an action with its log, which also reads a fresh snapshot list), then the Forget dialog on its result.
function Invoke-GuiForget {
    param([string[]]$Ids = @())

    $script:Gui.ForgetIds = @($Ids)
    Start-GuiOperation 'ForgetPreview' -OnComplete {
        param($Result, $ErrorMessage)
        $code = Complete-GuiOperation $Result $ErrorMessage
        $data = $null
        if ($Result) { $data = $Result.Data }
        # 3 = no retention policy: the other choices still work.
        if ($code -in @(0, 3) -and $data -and -not $script:Gui.ClosePending) {
            Update-GuiButtons
            $choice = Show-ForgetDialog $data $script:Gui.ForgetIds
            if ($choice -and -not $script:Gui.ClosePending) {
                Start-GuiForget $choice
                return
            }
        }
        Update-GuiLocal
    }
}

function Invoke-GuiForgetSelected {
    $gui = $script:Gui
    if (-not $gui.Ui.Buttons.ForgetSelected.Enabled) { return }
    $ids = Get-SnapshotGridSelectedIds $gui.Ui.SnapshotGrid
    if ($ids.Count -gt 0) { Invoke-GuiForget $ids }
}

# Forgets the Forget dialog's choice; afterwards offers to prune (default Yes after a whole job or everything).
function Start-GuiForget {
    param($Choice)

    $script:Gui.ForgetPruneButton = 'Button2'
    if ($Choice.PruneByDefault) { $script:Gui.ForgetPruneButton = 'Button1' }
    Start-GuiOperation 'ForgetSnapshots' @{ Ids = [string[]]@($Choice.Ids); Retention = [bool]$Choice.Retention } -OnComplete {
        param($Result, $ErrorMessage)
        $code = Complete-GuiOperation $Result $ErrorMessage
        if ($code -eq 0 -and -not $script:Gui.ClosePending -and
            (Show-GuiMessage "Prune now to free the space?`n`nOtherwise the next scheduled prune does." 'Question' 'YesNo' $script:Gui.ForgetPruneButton) -eq 'Yes') {
            Start-GuiOperation 'Prune' -OnComplete { param($Result, $ErrorMessage) Complete-GuiOperation $Result $ErrorMessage | Out-Null; Update-GuiAll }
            return
        }
        Update-GuiAll
    }
}

# What to forget, with the snapshots it removes (or keeps) in a grid, so it can be checked before confirming.
# Data: the ForgetPreview action's (Preview, NoPolicy, Snapshots); Ids: snapshots selected in the main window.
# Returns @{ Ids; Retention; PruneByDefault }, or $null when cancelled. State lives in $script:Gui.Forget.
function Show-ForgetDialog {
    param($Data, [string[]]$Ids = @())

    $gui = $script:Gui
    $snapshots = @($Data.Snapshots | Where-Object { $_ })
    $groups = @(Get-SnapshotJobGroups $script:Config.Jobs $snapshots)
    $bold = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Forget snapshots'; ClientSize = [System.Drawing.Size]::new(960, 620); MinimumSize = [System.Drawing.Size]::new(720, 480)
        StartPosition = 'CenterParent'; Font = [System.Drawing.Font]::new('Segoe UI', 9)
        MinimizeBox = $false; ShowInTaskbar = $false; Padding = [System.Windows.Forms.Padding]::new(10)
    }
    $forget = @{
        Form = $form; Snapshots = $snapshots; Preview = @($Data.Preview); NoPolicy = [bool]$Data.NoPolicy; Ids = @($Ids)
        Groups = $groups; Plan = $null; Mode = $null; Job = ''; Expected = $null; Result = $null; Ui = @{}
    }
    $gui.Forget = $forget
    $ui = $forget.Ui

    # What to forget
    $options = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Top'; AutoSize = $true; ColumnCount = 2 }
    $text = 'Apply the retention policy'
    if ($forget.NoPolicy) { $text += ' (none is configured)' }
    $ui.Retention = New-Object System.Windows.Forms.RadioButton -Property @{ Text = $text; AutoSize = $true; Enabled = -not $forget.NoPolicy }
    $ui.Job = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'All snapshots of job:'; AutoSize = $true; Enabled = $groups.Count -gt 0 }
    $ui.JobList = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Width = 440; Enabled = $groups.Count -gt 0 }
    foreach ($group in $groups) {
        $item = '{0} ({1} snapshots, newest {2:yyyy-MM-dd HH:mm})' -f $group.Label, $group.Count, $group.Newest
        if (-not $group.Configured) { $item += ', outside retention' }
        [void]$ui.JobList.Items.Add($item)
    }
    if ($groups.Count -gt 0) { $ui.JobList.SelectedIndex = 0 }
    $ui.Selected = New-Object System.Windows.Forms.RadioButton -Property @{
        Text = "The $($forget.Ids.Count) snapshots selected in the Snapshots tab"; AutoSize = $true; Enabled = $forget.Ids.Count -gt 0
    }
    if ($forget.Ids.Count -eq 1) { $ui.Selected.Text = 'The snapshot selected in the Snapshots tab' }
    elseif ($forget.Ids.Count -eq 0) { $ui.Selected.Text = 'The snapshots selected in the Snapshots tab (none selected)' }
    $ui.Everything = New-Object System.Windows.Forms.RadioButton -Property @{
        Text = "Everything in this repository ($($snapshots.Count) snapshots)"; AutoSize = $true; Enabled = $snapshots.Count -gt 0
    }
    $options.Controls.Add($ui.Retention, 0, 0)
    $options.SetColumnSpan($ui.Retention, 2)
    $options.Controls.Add($ui.Job, 0, 1)
    $options.Controls.Add($ui.JobList, 1, 1)
    $options.Controls.Add($ui.Selected, 0, 2)
    $options.SetColumnSpan($ui.Selected, 2)
    $options.Controls.Add($ui.Everything, 0, 3)
    $options.SetColumnSpan($ui.Everything, 2)
    foreach ($radio in @($ui.Retention, $ui.Job, $ui.Selected, $ui.Everything)) {
        $radio.add_CheckedChanged({ param($source) if ($source.Checked) { Invoke-GuiHandler { Update-ForgetDialog } } })
    }
    $ui.JobList.add_SelectedIndexChanged({
        Invoke-GuiHandler {
            $ui = $script:Gui.Forget.Ui
            if ($ui.Job.Checked) { Update-ForgetDialog } else { $ui.Job.Checked = $true }
        }
    })

    # Summary, warnings, the kept toggle
    $info = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Top'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false; Padding = [System.Windows.Forms.Padding]::new(0, 8, 0, 4)
    }
    $ui.Summary = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(920, 0); Font = $bold }
    $ui.Warnings = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(920, 0); ForeColor = [System.Drawing.Color]::Firebrick
    }
    $ui.ShowKept = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Show the snapshots that are kept too'; AutoSize = $true }
    $ui.ShowKept.add_CheckedChanged({ Invoke-GuiHandler { Update-ForgetFilter } })
    foreach ($control in @($ui.Summary, $ui.Warnings, $ui.ShowKept)) { $info.Controls.Add($control) }

    # Grid
    $table = New-Object System.Data.DataTable
    $table.CaseSensitive = $true
    foreach ($column in @(@('Id', [string]), @('Time', [datetime]), @('ShortId', [string]), @('Job', [string]), @('Host', [string]),
                          @('Action', [string]), @('Reason', [string]), @('Warning', [string]), @('Paths', [string]))) {
        [void]$table.Columns.Add($column[0], $column[1])
    }
    $view = [System.Data.DataView]::new($table)
    $view.Sort = 'Time DESC'
    $grid = New-Object System.Windows.Forms.DataGridView -Property @{
        Dock = 'Fill'; ReadOnly = $true; AutoGenerateColumns = $false; SelectionMode = 'FullRowSelect'; MultiSelect = $true
        AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; AllowUserToResizeRows = $false; RowHeadersVisible = $false
        BackgroundColor = [System.Drawing.SystemColors]::Window
    }
    # Width 0 = takes the remaining space.
    foreach ($column in @(@('Time', 'Time', 115), @('ShortId', 'ID', 75), @('Job', 'Job', 110), @('Host', 'Host', 100),
                          @('Action', 'Action', 60), @('Reason', 'Kept by retention as', 170), @('Warning', 'Warning', 250), @('Paths', 'Paths', 0))) {
        $gridColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{
            Name = $column[0]; DataPropertyName = $column[0]; HeaderText = $column[1]; SortMode = 'Automatic'
        }
        if ($column[2] -gt 0) { $gridColumn.Width = $column[2] }
        else { $gridColumn.AutoSizeMode = 'Fill'; $gridColumn.MinimumWidth = 80 }
        [void]$grid.Columns.Add($gridColumn)
    }
    $grid.Columns['Time'].DefaultCellStyle.Format = 'yyyy-MM-dd HH:mm'
    $grid.Columns['Warning'].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick
    $grid.DataSource = $view
    # A selected row would hide the colours; the grid is for reading.
    $grid.add_DataBindingComplete({ param($source) $source.ClearSelection() })
    $grid.add_CellFormatting({
        param($source, $format)
        if ($format.RowIndex -lt 0 -or $source.Columns[$format.ColumnIndex].Name -eq 'Warning') { return }
        $row = $source.Rows[$format.RowIndex].DataBoundItem
        if ($row -and $row['Action'] -eq 'Keep') { $format.CellStyle.ForeColor = [System.Drawing.SystemColors]::GrayText }
    })
    $forget.Table = $table
    $forget.View = $view

    # Confirmation and buttons
    $bottom = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; ColumnCount = 3; Padding = [System.Windows.Forms.Padding]::new(0, 8, 0, 0)
    }
    [void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $ui.ConfirmLabel = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; Anchor = 'Left'; ForeColor = [System.Drawing.Color]::Firebrick }
    $ui.Confirm = New-Object System.Windows.Forms.TextBox -Property @{ Width = 200; Anchor = 'Left' }
    $ui.Confirm.add_TextChanged({ Invoke-GuiHandler { Update-ForgetConfirm } })
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; FlowDirection = 'RightToLeft'; WrapContents = $false; Anchor = 'Right' }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90; DialogResult = 'Cancel' }
    # No DialogResult: Confirm-ForgetDialog closes the form only when everything is confirmed.
    $ui.Ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'Forget'; Width = 90; Enabled = $false }
    $ui.Ok.add_Click({ Invoke-GuiHandler { Confirm-ForgetDialog } })
    $buttons.Controls.Add($cancel)
    $buttons.Controls.Add($ui.Ok)
    $bottom.Controls.Add($ui.ConfirmLabel, 0, 0)
    $bottom.Controls.Add($ui.Confirm, 1, 0)
    $bottom.Controls.Add($buttons, 2, 0)
    $form.CancelButton = $cancel

    $form.Controls.Add($grid)
    $form.Controls.Add($info)
    $form.Controls.Add($options)
    $form.Controls.Add($bottom)
    $grid.BringToFront()

    # The selection if there is one, else retention, else the first job.
    if ($forget.Ids.Count -gt 0) { $ui.Selected.Checked = $true }
    elseif (-not $forget.NoPolicy) { $ui.Retention.Checked = $true }
    elseif ($groups.Count -gt 0) { $ui.Job.Checked = $true }
    Update-ForgetDialog

    [void]$form.ShowDialog($gui.Ui.Form)
    $result = $null
    if ($form.DialogResult -eq 'OK') { $result = $forget.Result }
    $gui.Forget = $null
    $form.Dispose()
    return $result
}

# The plan for the chosen option, into the grid, summary and warnings.
function Update-ForgetDialog {
    $forget = $script:Gui.Forget
    if (-not $forget) { return }
    $ui = $forget.Ui

    $mode = $null
    if ($ui.Retention.Checked) { $mode = 'Retention' }
    elseif ($ui.Job.Checked) { $mode = 'Job' }
    elseif ($ui.Selected.Checked) { $mode = 'Selected' }
    elseif ($ui.Everything.Checked) { $mode = 'Everything' }
    $job = ''
    if ($mode -eq 'Job' -and $ui.JobList.SelectedIndex -ge 0) { $job = $forget.Groups[$ui.JobList.SelectedIndex].Job }
    $forget.Mode = $mode
    $forget.Job = $job

    $plan = $null
    if ($mode) { $plan = Get-ForgetPlan $mode $forget.Snapshots $forget.Preview $job $forget.Ids $script:Config.Jobs $forget.NoPolicy }
    $forget.Plan = $plan

    $table = $forget.Table
    $table.BeginLoadData()
    $table.Rows.Clear()
    foreach ($row in @($plan.Rows | Where-Object { $_ })) {
        $action = 'Keep'
        if ($row.Action -eq 'Remove') { $action = 'Forget' }
        [void]$table.Rows.Add($row.Id, $row.Time, $row.ShortId, (Format-SnapshotGroupLabel $row.Job), $row.Host, $action,
            $row.Reason, $row.Warning, $row.Paths)
    }
    $table.EndLoadData()
    Update-ForgetFilter

    $count = 0
    if ($plan) { $count = $plan.RemoveIds.Count }
    if (-not $plan) { $ui.Summary.Text = 'Choose what to forget.' }
    elseif ($count -eq 0) { $ui.Summary.Text = 'Nothing to forget.' }
    else {
        $parts = @(Get-ForgetTotals $plan.Rows | Where-Object { $_.Remove -gt 0 } | ForEach-Object { '{0}: {1} of {2}' -f $_.Label, $_.Remove, ($_.Remove + $_.Keep) })
        $ui.Summary.Text = "Forgets $count of $($forget.Snapshots.Count) snapshots ($($parts -join ', ')). Forgotten snapshots can't be restored."
    }
    $warnings = @()
    if ($plan) { $warnings = @($plan.Warnings) }
    $ui.Warnings.Text = ($warnings | ForEach-Object { [string][char]0x26A0 + " $_" }) -join "`n"
    $ui.Warnings.Visible = $warnings.Count -gt 0

    $forget.Expected = Get-ForgetConfirmation $mode $job $script:Config.Hostname
    $ui.Confirm.Text = ''
    $ui.ConfirmLabel.Visible = [bool]$forget.Expected
    $ui.Confirm.Visible = [bool]$forget.Expected
    if ($forget.Expected) { $ui.ConfirmLabel.Text = "Type $($forget.Expected) to confirm:" }
    Update-ForgetConfirm
}

function Update-ForgetFilter {
    $forget = $script:Gui.Forget
    if (-not $forget) { return }
    if ($forget.Ui.ShowKept.Checked) { $forget.View.RowFilter = '' }
    else { $forget.View.RowFilter = "Action = 'Forget'" }
}

function Update-ForgetConfirm {
    $forget = $script:Gui.Forget
    if (-not $forget) { return }
    $ready = $forget.Plan -and $forget.Plan.RemoveIds.Count -gt 0
    if ($ready -and $forget.Expected) { $ready = $forget.Ui.Confirm.Text.Trim() -eq $forget.Expected }
    $forget.Ui.Ok.Enabled = [bool]$ready
}

# Forget: a typed name confirms the bulk choices; the others are asked here.
function Confirm-ForgetDialog {
    $forget = $script:Gui.Forget
    Update-ForgetConfirm
    if (-not $forget.Ui.Ok.Enabled) { return }

    $plan = $forget.Plan
    if (-not $forget.Expected) {
        $message = "Forget these $($plan.RemoveIds.Count) snapshots?`n`nForgotten snapshots can't be restored."
        if ($plan.Warnings.Count -gt 0) { $message += "`n`n" + (@($plan.Warnings) -join "`n") }
        if ([System.Windows.Forms.MessageBox]::Show($forget.Form, $message, 'Restic', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
    }
    $forget.Result = @{
        Ids = [string[]]@($plan.RemoveIds); Retention = $forget.Mode -eq 'Retention'; PruneByDefault = $forget.Mode -in @('Job', 'Everything')
    }
    $forget.Form.DialogResult = 'OK'
}

# Run Setup in Settings closes it and starts the Setup action here, with the configuration it just saved.
# The cleanup that saves queued for removed or renamed jobs runs then too, after Setup.
function Invoke-GuiSettings {
    $gui = $script:Gui

    # Saving rewrites the file; only then is the repository checked again. (1601 when there's no file.)
    $written = [System.IO.File]::GetLastWriteTimeUtc($gui.ConfigPath)
    $result = $null
    try { $result = Show-ConfigEditor $gui.ConfigPath -Owner $gui.Ui.Form }
    catch { Show-GuiMessage "The settings can't be opened: $($_.Exception.Message)" | Out-Null }
    $cleanup = @()
    if ($result) { $cleanup = @($result.Cleanup) }
    if (-not ($result -and $result.Setup) -and $cleanup.Count -eq 0) {
        if ([System.IO.File]::GetLastWriteTimeUtc($gui.ConfigPath) -ne $written) { Update-GuiAll } else { Update-GuiLocal }
        return
    }

    Update-GuiConfig
    Update-GuiHealth
    # Settings is enabled while the repository check runs; end it so the action can start.
    Stop-GuiQuery
    if ($result.Setup) {
        $gui.PendingCleanup = $cleanup
        Start-GuiSetup $result.Setup
    }
    else { Start-GuiCleanup $cleanup }
}

# Kept in $script:Gui until Setup ends: a retry with a local restic zip needs them (with the secrets) again.
function Start-GuiSetup {
    param([hashtable]$Parameters)

    $script:Gui.SetupParameters = $Parameters
    Start-GuiOperation 'Setup' $Parameters -OnComplete { param($Result, $ErrorMessage) Complete-GuiSetup $Result $ErrorMessage }
}

# When Setup failed because restic couldn't be installed (usually no download), offers a local release zip.
function Complete-GuiSetup {
    param($Result, $ErrorMessage)

    $gui = $script:Gui
    $parameters = $gui.SetupParameters
    $gui.SetupParameters = $null
    $code = Complete-GuiOperation $Result $ErrorMessage

    # Not on an unsupported machine (Get-ResticTarget throws): a zip wouldn't help there.
    $missing = $false
    if ($code -eq 1 -and -not $gui.ClosePending) {
        try {
            $target = Get-ResticTarget
            try { $null = Find-ResticExe } catch { $missing = $true }
        }
        catch { }
    }
    if ($missing) {
        $message = "restic $($target.Version) couldn't be installed, so Setup stopped (see the output).`n`n" +
            "Select a local copy of the official release zip ($($target.ZipName))?"
        if ((Show-GuiMessage $message 'Question' 'YesNo') -eq 'Yes') {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog -Property @{
                Title = "Select $($target.ZipName)"; FileName = $target.ZipName; Filter = "restic release ($($target.ZipName))|$($target.ZipName)|Zip files (*.zip)|*.zip"
            }
            $picked = $dialog.ShowDialog($gui.Ui.Form) -eq 'OK'
            $zip = $dialog.FileName
            $dialog.Dispose()
            if ($picked) {
                $parameters.ResticZip = $zip
                Start-GuiSetup $parameters
                return
            }
        }
    }

    # Queued by Settings; needs the restic and repository that Setup provides.
    $cleanup = @($gui.PendingCleanup)
    $gui.PendingCleanup = @()
    if ($cleanup.Count -gt 0 -and -not $gui.ClosePending) {
        # $null = cancelled.
        if ($null -ne $code -and $code -ne 1) {
            Update-GuiConfig
            Start-GuiCleanup $cleanup
            return
        }
        Write-GuiLine "The snapshots of the removed or renamed jobs were left alone because Setup didn't finish. Use Clean up later." 'Warning'
    }
    Update-GuiAll
}

# Enables or disables the scheduled task; disabling asks first.
function Invoke-GuiTaskToggle {
    $task = $script:Gui.Health.Task
    $operation = 'DisableTask'
    if ($task.State -eq 'Disabled') { $operation = 'EnableTask' }
    elseif ((Show-GuiMessage "Disable the scheduled task '$($task.Name)'?`n`nScheduled backups stop until it is enabled again." `
            'Question' 'YesNo' 'Button2') -ne 'Yes') { return }

    # Enabled while the repository check runs; end it so the action can start.
    Stop-GuiQuery
    Start-GuiOperation $operation
}

# A query, not an action: the repository check reloads the list (no log file, errors go to the pane).
function Invoke-GuiList {
    $ui = $script:Gui.Ui
    $ui.Tabs.SelectedTab = $ui.SnapshotsPage
    Update-GuiRepository
    Update-GuiStatus
    Update-GuiButtons
}

function Update-GuiSnapshots {
    $gui = $script:Gui
    if (-not $gui.Ui.SnapshotGrid) { return }
    $names = @()
    if ($gui.Config) { $names = @($gui.Config.Jobs | ForEach-Object { $_.Name }) }
    Set-SnapshotGridData $gui.Ui.SnapshotGrid @($gui.Snapshots) $names $gui.SnapshotsLoaded
}

# A job filter above a read-only, sortable snapshot grid (also used by the restore dialog). Returns the
# panel; fill it with Set-SnapshotGridData. The panel's Tag holds @{ Table; View; Grid; Filter; Count; Loaded }.
# Filter choices 'All jobs' and '(no job tag)' can't clash with job names (no spaces or parentheses).
# -MultiSelect: several rows can be selected (Get-SnapshotGridSelectedIds).
function New-SnapshotGrid {
    param([switch]$MultiSelect)

    $table = New-Object System.Data.DataTable
    $table.CaseSensitive = $true   # job tags are case-sensitive
    foreach ($column in @(@('Id', [string]), @('Time', [datetime]), @('ShortId', [string]), @('Job', [string]),
                          @('Host', [string]), @('Paths', [string]), @('Tags', [string]))) {
        [void]$table.Columns.Add($column[0], $column[1])
    }
    $view = [System.Data.DataView]::new($table)
    $view.Sort = 'Time DESC'

    $grid = New-Object System.Windows.Forms.DataGridView -Property @{
        Dock = 'Fill'; ReadOnly = $true; AutoGenerateColumns = $false; SelectionMode = 'FullRowSelect'; MultiSelect = [bool]$MultiSelect
        AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; AllowUserToResizeRows = $false; RowHeadersVisible = $false
        BackgroundColor = [System.Drawing.SystemColors]::Window; BorderStyle = 'None'
    }
    # Width 0 = takes the remaining space.
    foreach ($column in @(@('Time', 'Time', 115), @('ShortId', 'ID', 75), @('Job', 'Job', 110), @('Host', 'Host', 100),
                          @('Paths', 'Paths', 0), @('Tags', 'Tags', 160))) {
        $gridColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{
            Name = $column[0]; DataPropertyName = $column[0]; HeaderText = $column[1]; SortMode = 'Automatic'
        }
        if ($column[2] -gt 0) { $gridColumn.Width = $column[2] }
        else { $gridColumn.AutoSizeMode = 'Fill'; $gridColumn.MinimumWidth = 80 }
        [void]$grid.Columns.Add($gridColumn)
    }
    $grid.Columns['Time'].DefaultCellStyle.Format = 'yyyy-MM-dd HH:mm'
    $grid.DataSource = $view

    $top = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Top'; AutoSize = $true; WrapContents = $false; Padding = [System.Windows.Forms.Padding]::new(4, 4, 4, 4)
    }
    $top.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = 'Job:'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 6, 4, 0)
    }))
    $filter = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Width = 200 }
    $top.Controls.Add($filter)
    $count = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText; Margin = [System.Windows.Forms.Padding]::new(12, 6, 0, 0)
    }
    $top.Controls.Add($count)

    $panel = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Fill' }
    $panel.Controls.Add($grid)
    $panel.Controls.Add($top)
    $grid.BringToFront()

    $state = @{ Table = $table; View = $view; Grid = $grid; Filter = $filter; Count = $count; Loaded = $false }
    $panel.Tag = $state
    # Handlers run without access to this function's variables.
    $filter.Tag = $state
    $filter.add_SelectedIndexChanged({ param($source) Update-SnapshotGridFilter $source.Tag })
    [void]$filter.Items.Add('All jobs')
    $filter.SelectedIndex = 0
    return $panel
}

# Filter choices: all jobs, the config's jobs (in order), other jobs found in the snapshots, no job tag.
# Keeps the chosen filter and the selected snapshot when they still exist.
function Set-SnapshotGridData {
    param($Panel, [object[]]$Snapshots, [string[]]$JobNames, [bool]$Loaded = $true)

    $state = $Panel.Tag
    $selected = Get-SnapshotGridSelection $Panel
    $state.Loaded = $Loaded

    $table = $state.Table
    $table.BeginLoadData()
    $table.Rows.Clear()
    foreach ($snapshot in @($Snapshots)) {
        [void]$table.Rows.Add($snapshot.Id, $snapshot.Time, $snapshot.ShortId, $snapshot.Job, $snapshot.Host,
            $snapshot.Paths, (@($snapshot.Tags) -join ', '))
    }
    $table.EndLoadData()

    $choices = New-Object System.Collections.Generic.List[string]
    $choices.Add('All jobs')
    foreach ($name in @($JobNames)) { if ($name -and -not $choices.Contains($name)) { $choices.Add($name) } }
    foreach ($name in @($Snapshots | ForEach-Object { $_.Job } | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)) {
        if (-not $choices.Contains($name)) { $choices.Add($name) }
    }
    $choices.Add('(no job tag)')

    $filter = $state.Filter
    $previous = [string]$filter.SelectedItem
    $filter.BeginUpdate()
    $filter.Items.Clear()
    $filter.Items.AddRange([object[]]$choices.ToArray())
    $filter.EndUpdate()
    $filter.SelectedIndex = [Math]::Max(0, $choices.IndexOf($previous))
    Update-SnapshotGridFilter $state

    if ($selected) {
        foreach ($row in $state.Grid.Rows) {
            if ($row.DataBoundItem['Id'] -eq $selected) {
                $state.Grid.CurrentCell = $row.Cells[0]
                break
            }
        }
    }
}

function Update-SnapshotGridFilter {
    param([hashtable]$State)

    $choice = [string]$State.Filter.SelectedItem
    $rowFilter = ''
    if ($choice -eq '(no job tag)') { $rowFilter = "Job = ''" }
    elseif ($choice -and $choice -ne 'All jobs') { $rowFilter = "Job = '{0}'" -f ($choice -replace "'", "''") }
    $State.View.RowFilter = $rowFilter

    $shown = $State.View.Count
    $total = $State.Table.Rows.Count
    if (-not $State.Loaded) { $State.Count.Text = 'Not loaded.' }
    elseif ($rowFilter) { $State.Count.Text = "$shown of $total snapshots" }
    else { $State.Count.Text = "$total snapshots" }
}

# The full ID of the selected snapshot (of several selected, the focused one), or $null.
function Get-SnapshotGridSelection {
    param($Panel)

    $grid = $Panel.Tag.Grid
    if ($grid.SelectedRows.Count -eq 0) { return $null }
    if ($grid.CurrentRow -and $grid.CurrentRow.Selected) { return [string]$grid.CurrentRow.DataBoundItem['Id'] }
    return [string]$grid.SelectedRows[0].DataBoundItem['Id']
}

# The full IDs of every selected snapshot.
function Get-SnapshotGridSelectedIds {
    param($Panel)

    return , [string[]]@(foreach ($row in $Panel.Tag.Grid.SelectedRows) { [string]$row.DataBoundItem['Id'] })
}

function Format-ByteSize {
    param([long]$Bytes)

    if ($Bytes -lt 1024) { return "$Bytes B" }
    $value = [double]$Bytes
    foreach ($unit in @('KB', 'MB', 'GB', 'TB')) {
        $value /= 1024
        if ($value -lt 1024 -or $unit -eq 'TB') { return '{0:0.#} {1}' -f $value, $unit }
    }
}

# Restore dialog. Its state lives in $script:Gui.Restore while it is open (handlers and query
# callbacks run without access to Show-RestoreDialog's variables); $null once it has closed.
# Tree nodes: Tag = an entry from Get-SnapshotChildren, or a string for the extra nodes
# ('Loading', 'Error', 'Empty'), which can't be restored.

function New-RestoreInfoNode {
    param([string]$Text, [string]$Kind)

    $node = New-Object System.Windows.Forms.TreeNode $Text
    $node.Tag = $Kind
    if ($Kind -eq 'Error') { $node.ForeColor = [System.Drawing.Color]::Firebrick }
    else { $node.ForeColor = [System.Drawing.SystemColors]::GrayText }
    return $node
}

# Folders get a 'Loading…' child, so they can be expanded; Expand-RestoreNode replaces it.
function New-RestoreTreeNode {
    param($Entry)

    $text = $Entry.Name
    if ($Entry.Path -match '^/[A-Za-z]$') { $text = "$($Entry.Name):" }
    elseif ($Entry.Type -eq 'file') { $text += "   $(Format-ByteSize $Entry.Size)" }
    elseif ($Entry.Type -ne 'dir') { $text += "   ($($Entry.Type))" }

    $node = New-Object System.Windows.Forms.TreeNode $text
    $node.Tag = $Entry
    if ($Entry.Type -eq 'dir') { [void]$node.Nodes.Add((New-RestoreInfoNode "Loading$([char]0x2026)" 'Loading')) }
    return $node
}

# Folders first, then files, case-insensitive.
function Add-RestoreTreeChildren {
    param($Nodes, [object[]]$Entries)

    $sorted = @($Entries | Sort-Object @{ Expression = { $_.Type -ne 'dir' } }, Name)
    if ($sorted.Count -eq 0) {
        [void]$Nodes.Add((New-RestoreInfoNode '(empty)' 'Empty'))
        return
    }
    $Nodes.AddRange([System.Windows.Forms.TreeNode[]]@(foreach ($entry in $sorted) { New-RestoreTreeNode $entry }))
}

# Queues a listing of one folder ($Node $null = the snapshot's top level). One query runs at a time;
# a request made for an earlier snapshot (older Generation) is dropped.
function Request-RestoreChildren {
    param($Node)

    $restore = $script:Gui.Restore
    [void]$restore.Pending.Add(@{ Node = $Node; SnapshotId = $restore.SnapshotId; Generation = $restore.Generation })
    Start-RestoreQuery
}

function Start-RestoreQuery {
    $restore = $script:Gui.Restore
    if (-not $restore -or $restore.Request) { return }

    while ($restore.Pending.Count -gt 0) {
        $request = $restore.Pending[0]
        $restore.Pending.RemoveAt(0)
        if ($request.Generation -ne $restore.Generation) { continue }

        $path = '/'
        if ($request.Node) { $path = $request.Node.Tag.Path }
        $started = Start-GuiTask -Name 'Browse' -Script { Initialize-Restic; , @(Get-SnapshotChildren $SnapshotId $Path) } `
            -Variables @{ SnapshotId = $request.SnapshotId; Path = $path } `
            -OnComplete { param($Result, $ErrorMessage) Complete-RestoreQuery $Result $ErrorMessage }
        if ($started) { $restore.Request = $request }
        else { $restore.Pending.Insert(0, $request) }
        return
    }
}

function Complete-RestoreQuery {
    param($Result, $ErrorMessage)

    $restore = $script:Gui.Restore
    if (-not $restore) { return }   # the dialog has closed
    $request = $restore.Request
    $restore.Request = $null

    if ($request.Generation -eq $restore.Generation) {
        $tree = $restore.Tree
        $nodes = $tree.Nodes
        if ($request.Node) { $nodes = $request.Node.Nodes }
        $tree.BeginUpdate()
        $nodes.Clear()
        if ($ErrorMessage) { [void]$nodes.Add((New-RestoreInfoNode "Can't read this folder: $ErrorMessage" 'Error')) }
        else { Add-RestoreTreeChildren $nodes @($Result) }
        # Clearing the children collapses the node.
        if ($request.Node) { $request.Node.Expand() }
        $tree.EndUpdate()
    }
    Start-RestoreQuery
}

function Expand-RestoreNode {
    param($Node)

    if ($Node.Nodes.Count -ne 1) { return }
    $placeholder = $Node.Nodes[0]
    # Name marks a placeholder that has already been requested.
    if ($placeholder.Tag -ne 'Loading' -or $placeholder.Name) { return }
    $placeholder.Name = 'Requested'
    Request-RestoreChildren $Node
}

# Loads the tree of the snapshot selected in the grid.
function Select-RestoreSnapshot {
    $restore = $script:Gui.Restore
    if (-not $restore.Ready) { return }

    $id = Get-SnapshotGridSelection $restore.Grid
    if ($id -eq $restore.SnapshotId) { return }
    $restore.SnapshotId = $id
    $restore.Generation++
    $restore.Tree.Nodes.Clear()
    if ($id) {
        [void]$restore.Tree.Nodes.Add((New-RestoreInfoNode "Loading$([char]0x2026)" 'Loading'))
        Request-RestoreChildren $null
    }
    Update-RestoreTarget
}

# The entry chosen in the tree, or $null (= the whole snapshot).
function Get-RestoreSelection {
    $node = $script:Gui.Restore.Tree.SelectedNode
    if (-not $node -or $node.Tag -is [string]) { return $null }
    return $node.Tag
}

# Recomputes source, target and OK from the current choices into $script:Gui.Restore.Choice.
function Update-RestoreTarget {
    $restore = $script:Gui.Restore
    $ui = $restore.Ui
    $entry = Get-RestoreSelection

    $source = ''
    $sourceType = ''
    $problem = $null
    $target = $null
    if ($entry) {
        try { $source = ConvertFrom-SnapshotPath $entry.Path }
        catch { $problem = $_.Exception.Message }
        $sourceType = 'file'
        if ($entry.Type -eq 'dir') { $sourceType = 'dir' }
    }

    # In place needs a folder or file.
    $ui.InPlace.Enabled = [bool]($entry -and -not $problem)
    if (-not $ui.InPlace.Enabled -and $ui.InPlace.Checked) { $ui.NewFolder.Checked = $true }
    $inPlace = $ui.InPlace.Checked

    if (-not $entry) { $ui.Source.Text = 'Source:  the whole snapshot' }
    elseif ($problem) { $ui.Source.Text = "Source:  $($entry.Path)" }
    else {
        $kind = 'file'
        if ($sourceType -eq 'dir') { $kind = 'folder' }
        $ui.Source.Text = "Source:  $source ($kind)"
    }

    if ($restore.SnapshotId -and -not $problem) {
        try {
            $stamp = Get-Date
            $target = (Get-RestoreArguments $restore.SnapshotId $source $sourceType $inPlace $restore.RestoreRoot $stamp).Target
            $shortId = $restore.SnapshotId.Substring(0, 8)
            $target = $target.Replace(('{0}-{1:yyyyMMdd-HHmmss}' -f $shortId, $stamp), "$shortId-<yyyyMMdd-HHmmss>")
        }
        catch { $problem = $_.Exception.Message }
    }

    $ui.Target.ForeColor = [System.Drawing.SystemColors]::ControlText
    if ($problem) {
        $ui.Target.Text = $problem
        $ui.Target.ForeColor = [System.Drawing.Color]::Firebrick
    }
    elseif ($target) { $ui.Target.Text = "Restores into:  $target" }
    else {
        $ui.Target.Text = 'Select a snapshot.'
        $ui.Target.ForeColor = [System.Drawing.SystemColors]::GrayText
    }

    $ui.Ok.Enabled = [bool]($target -and -not $problem)
    $restore.Choice = @{ SnapshotId = $restore.SnapshotId; Source = $source; SourceType = $sourceType; InPlace = $inPlace; Target = $target }
}

# OK: an in-place restore must be confirmed first; Cancel there returns to the restore dialog.
function Confirm-RestoreDialog {
    $restore = $script:Gui.Restore
    Update-RestoreTarget
    if (-not $restore.Ui.Ok.Enabled) { return }

    $choice = $restore.Choice
    if ($choice.InPlace) {
        $snapshot = @($restore.Snapshots | Where-Object { $_.Id -eq $choice.SnapshotId })[0]
        if (-not (Show-RestoreConfirmDialog $restore.Form $choice.Target $choice.Source $choice.SourceType $snapshot)) { return }
    }
    $restore.Result = @{
        SnapshotId = $choice.SnapshotId; Source = $choice.Source; SourceType = $choice.SourceType; InPlace = $choice.InPlace
    }
    $restore.Form.DialogResult = 'OK'
}

# The in-place warning, with the menu's texts. OK is enabled only once YES (case-sensitive) is typed.
function Show-RestoreConfirmDialog {
    param($Owner, [string]$Target, [string]$Source, [string]$SourceType, $Snapshot)

    $when = '{0:yyyy-MM-dd HH:mm}' -f $Snapshot.Time
    if ($SourceType -eq 'file') {
        $message = "$Source will be overwritten with the version from snapshot $($Snapshot.ShortId) ($when)."
    }
    else {
        $message = "Files in $Target will be overwritten with the versions from snapshot $($Snapshot.ShortId) ($when).`n`n" +
            'Files that are not in the snapshot are left alone.'
    }

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Restore in place'; ClientSize = [System.Drawing.Size]::new(480, 230); FormBorderStyle = 'FixedDialog'
        StartPosition = 'CenterParent'; Font = [System.Drawing.Font]::new('Segoe UI', 9)
        MinimizeBox = $false; MaximizeBox = $false; ShowInTaskbar = $false; Padding = [System.Windows.Forms.Padding]::new(10)
    }
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Fill'; FlowDirection = 'TopDown'; WrapContents = $false }
    $width = [System.Drawing.Size]::new(455, 0)
    $flow.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = "Target:  $Target"; AutoSize = $true; MaximumSize = $width
        Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }))
    $flow.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = $message; AutoSize = $true; MaximumSize = $width; ForeColor = [System.Drawing.Color]::Firebrick
        Margin = [System.Windows.Forms.Padding]::new(3, 8, 3, 8)
    }))
    $flow.Controls.Add((New-Object System.Windows.Forms.Label -Property @{ Text = 'Type YES to continue:'; AutoSize = $true }))
    $box = New-Object System.Windows.Forms.TextBox -Property @{ Width = 120 }
    $flow.Controls.Add($box)

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; FlowDirection = 'RightToLeft'; Padding = [System.Windows.Forms.Padding]::new(0, 8, 0, 0)
    }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90; DialogResult = 'Cancel' }
    $ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'Restore'; Width = 90; DialogResult = 'OK'; Enabled = $false }
    $bottom.Controls.Add($cancel)
    $bottom.Controls.Add($ok)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $box.add_TextChanged({ param($source) $source.FindForm().AcceptButton.Enabled = $source.Text -ceq 'YES' })

    $form.Controls.Add($flow)
    $form.Controls.Add($bottom)
    $form.ActiveControl = $box

    $result = $form.ShowDialog($Owner)
    $confirmed = $result -eq 'OK' -and $box.Text -ceq 'YES'
    $form.Dispose()
    return $confirmed
}

# Returns the parameters of the Restore operation, or $null when cancelled. Runs 'ls' queries while
# it is open (no action can run then: the main window is blocked).
function Show-RestoreDialog {
    $gui = $script:Gui
    $snapshots = @($gui.Snapshots)
    $names = @($script:Config.Jobs | ForEach-Object { $_.Name })

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Restore'; ClientSize = [System.Drawing.Size]::new(900, 640); MinimumSize = [System.Drawing.Size]::new(700, 520)
        StartPosition = 'CenterParent'; Font = [System.Drawing.Font]::new('Segoe UI', 9)
        MinimizeBox = $false; ShowInTaskbar = $false; Padding = [System.Windows.Forms.Padding]::new(10)
    }
    $restore = @{
        Form = $form; Snapshots = $snapshots; RestoreRoot = $script:Config.RestoreRoot
        SnapshotId = $null; Generation = 0; Pending = New-Object System.Collections.ArrayList; Request = $null
        Ready = $false; Choice = $null; Result = $null; Ui = @{}
        Preselect = Get-SnapshotGridSelection $gui.Ui.SnapshotGrid
    }
    $gui.Restore = $restore
    $ui = $restore.Ui

    $split = New-Object System.Windows.Forms.SplitContainer -Property @{ Dock = 'Fill'; Orientation = 'Horizontal' }
    $restore.Split = $split

    # Snapshot
    $restore.Grid = New-SnapshotGrid
    $split.Panel1.Controls.Add($restore.Grid)
    $split.Panel1.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = '1. Snapshot'; Dock = 'Top'; AutoSize = $true; Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }))
    $restore.Grid.BringToFront()
    Set-SnapshotGridData $restore.Grid $snapshots $names $true
    $restore.Grid.Tag.Grid.add_SelectionChanged({ Invoke-GuiHandler { Select-RestoreSnapshot } })

    # Folder or file
    $treeTop = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Top'; AutoSize = $true; WrapContents = $false; Padding = [System.Windows.Forms.Padding]::new(0, 6, 0, 2)
    }
    $treeTop.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = '2. Folder or file (nothing selected = the whole snapshot)'; AutoSize = $true
        Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold); Margin = [System.Windows.Forms.Padding]::new(0, 6, 10, 0)
    }))
    $whole = New-Object System.Windows.Forms.Button -Property @{ Text = 'Whole snapshot'; AutoSize = $true }
    $whole.add_Click({ Invoke-GuiHandler { $script:Gui.Restore.Tree.SelectedNode = $null; Update-RestoreTarget } })
    $treeTop.Controls.Add($whole)
    $restore.Tree = New-Object System.Windows.Forms.TreeView -Property @{ Dock = 'Fill'; HideSelection = $false }
    $restore.Tree.add_BeforeExpand({ param($source, $expand) Invoke-GuiHandler { Expand-RestoreNode $expand.Node } })
    $restore.Tree.add_AfterSelect({
        param($source, $select)
        Invoke-GuiHandler {
            # 'Loading…' and error nodes can't be chosen.
            if ($select.Node -and $select.Node.Tag -is [string]) { $source.SelectedNode = $null }
            Update-RestoreTarget
        }
    })
    $split.Panel2.Controls.Add($restore.Tree)
    $split.Panel2.Controls.Add($treeTop)
    $restore.Tree.BringToFront()

    # Target
    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false; Padding = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
    }
    $bottom.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = '3. Target'; AutoSize = $true; Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }))
    $ui.Source = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(860, 0) }
    $ui.NewFolder = New-Object System.Windows.Forms.RadioButton -Property @{
        Text = "New folder under $($script:Config.RestoreRoot)"; AutoSize = $true; Checked = $true
    }
    $ui.InPlace = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'In place (overwrites existing files)'; AutoSize = $true }
    $ui.Target = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(860, 0) }
    foreach ($radio in @($ui.NewFolder, $ui.InPlace)) {
        $radio.add_CheckedChanged({ param($source) if ($source.Checked) { Invoke-GuiHandler { Update-RestoreTarget } } })
    }
    foreach ($control in @($ui.Source, $ui.NewFolder, $ui.InPlace, $ui.Target)) { $bottom.Controls.Add($control) }

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; FlowDirection = 'RightToLeft'; Padding = [System.Windows.Forms.Padding]::new(0, 8, 0, 0)
    }
    $cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90; DialogResult = 'Cancel' }
    # No DialogResult: Confirm-RestoreDialog closes the form only when everything is confirmed.
    $ui.Ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'Restore'; Width = 90; Enabled = $false }
    $ui.Ok.add_Click({ Invoke-GuiHandler { Confirm-RestoreDialog } })
    $buttons.Controls.Add($cancel)
    $buttons.Controls.Add($ui.Ok)
    $form.CancelButton = $cancel

    $form.Controls.Add($split)
    $form.Controls.Add($bottom)
    $form.Controls.Add($buttons)
    $split.BringToFront()

    $form.add_Shown({
        Invoke-GuiHandler {
            $restore = $script:Gui.Restore
            $restore.Split.SplitterDistance = [int]($restore.Split.Height * 0.4)
            # The snapshot selected in the main window's grid, if any; otherwise the newest.
            $grid = $restore.Grid.Tag.Grid
            if ($restore.Preselect) {
                foreach ($row in $grid.Rows) {
                    if ($row.DataBoundItem['Id'] -eq $restore.Preselect) { $grid.CurrentCell = $row.Cells[0]; break }
                }
            }
            $restore.Ready = $true
            Select-RestoreSnapshot
            Update-RestoreTarget
        }
    })

    Update-RestoreTarget
    [void]$form.ShowDialog($gui.Ui.Form)

    $result = $null
    if ($form.DialogResult -eq 'OK') { $result = $restore.Result }
    # Callbacks of a query still running see $null and do nothing.
    $gui.Restore = $null
    $form.Dispose()
    Stop-GuiQuery
    return $result
}

function Invoke-GuiRestore {
    if (@($script:Gui.Snapshots).Count -eq 0) {
        Show-GuiMessage 'The repository has no snapshots.' 'Information' | Out-Null
        return
    }
    $parameters = Show-RestoreDialog
    Update-GuiButtons
    if ($parameters) { Start-GuiOperation 'Restore' $parameters }
}

function New-GuiButton {
    param($Panel, [string]$Name, [string]$Text, [scriptblock]$Action)

    $button = New-Object System.Windows.Forms.Button -Property @{
        Name = $Name; Text = $Text; Size = [System.Drawing.Size]::new(150, 30); TextAlign = 'MiddleLeft'
        Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 6); Padding = [System.Windows.Forms.Padding]::new(6, 0, 0, 0)
    }
    # Handlers run without access to this function's variables; the button carries its action.
    $button.Tag = $Action
    $button.add_Click({ param($source) Invoke-GuiHandler $source.Tag })
    $Panel.Controls.Add($button)
    $script:Gui.Ui.Buttons[$Name] = $button
}

# Status-area row: caption | content, the content spanning the rest of the row.
function Add-GuiStatusRow {
    param($Table, [string]$Caption, $Control)

    $row = $Table.RowCount
    $Table.RowCount = $row + 1
    [void]$Table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    if ($Caption) {
        $Table.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
            Text = $Caption; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 2, 10, 2)
            ForeColor = [System.Drawing.SystemColors]::GrayText
        }), 0, $row)
    }
    $Control.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 2)
    $Table.Controls.Add($Control, 1, $row)
}

function New-GuiFlow {
    return New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; WrapContents = $true; Dock = 'Fill' }
}

function Show-MainWindow {
    param([string]$Path)

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:Gui = @{
        ConfigPath   = [System.IO.Path]::GetFullPath($Path)
        Config       = $null
        ConfigError  = $null
        Current      = $null
        Queue        = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Ui           = @{ Buttons = @{} }
        Health       = @{}
        Repository   = @{ Status = 'Unknown'; Message = $null }
        Snapshots    = @()
        # False until a repository check has read the list (and again after a failed one).
        SnapshotsLoaded = $false
        Reasons      = @{}
        # Buttons whose dialogs are not built yet.
        Unbuilt      = @()
        Restore      = $null
        # The Forget dialog's state; the grid selection it was opened for; the default button of the prune question.
        Forget       = $null
        ForgetIds    = @()
        ForgetPruneButton = 'Button2'
        LastLogFile  = $null
        OutputLines  = 0
        ClosePending = $false
        TipShown     = $null
        # The help section about the problem shown under Health.
        ProblemHelp  = $null
        SetupParameters = $null
        # Cleanup actions Settings queued behind Setup; whether the running cleanup forgets snapshots.
        PendingCleanup = @()
        CleanupRemoves = $false
    }
    $ui = $script:Gui.Ui
    $font = [System.Drawing.Font]::new('Segoe UI', 9)

    $form = New-Object System.Windows.Forms.Form -Property @{
        Size = [System.Drawing.Size]::new(1000, 720); MinimumSize = [System.Drawing.Size]::new(760, 500)
        StartPosition = 'CenterScreen'; Font = $font; KeyPreview = $true
    }
    $ui.Form = $form
    $ui.Tip = New-Object System.Windows.Forms.ToolTip
    $form.add_KeyDown({
        param($source, $key)
        if ($key.KeyCode -eq 'F1') {
            $key.SuppressKeyPress = $true
            Invoke-GuiHandler { Show-HelpWindow }
        }
    })

    $root = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 3 }
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))

    # Status area
    $status = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
        Dock = 'Fill'; AutoSize = $true; ColumnCount = 3; Padding = [System.Windows.Forms.Padding]::new(10, 8, 10, 6)
    }
    [void]$status.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$status.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$status.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))

    $status.RowCount = 2
    [void]$status.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$status.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $ui.Host = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; Font = [System.Drawing.Font]::new('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    }
    $status.Controls.Add($ui.Host, 0, 0)
    $status.SetColumnSpan($ui.Host, 2)
    $ui.Repository = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText; Margin = [System.Windows.Forms.Padding]::new(3, 0, 3, 6)
    }
    $status.Controls.Add($ui.Repository, 0, 1)
    $status.SetColumnSpan($ui.Repository, 2)
    $ui.Refresh = New-Object System.Windows.Forms.Button -Property @{ Text = 'Refresh'; Width = 90; Anchor = 'Top, Right' }
    $ui.Refresh.add_Click({ Invoke-GuiHandler { Update-GuiAll } })
    $status.Controls.Add($ui.Refresh, 2, 0)
    $status.SetRowSpan($ui.Refresh, 2)

    $ui.Health = New-GuiFlow
    Add-GuiStatusRow $status 'Health:' $ui.Health
    # The first problem, and a link to its help section ($script:Gui.ProblemHelp).
    $ui.ProblemRow = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; WrapContents = $false }
    $ui.Problem = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; ForeColor = [System.Drawing.Color]::Firebrick; MaximumSize = [System.Drawing.Size]::new(760, 0)
        Margin = [System.Windows.Forms.Padding]::new(0)
    }
    $ui.ProblemHelp = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Help'; AutoSize = $true; Cursor = [System.Windows.Forms.Cursors]::Hand; Margin = [System.Windows.Forms.Padding]::new(10, 0, 0, 0)
    }
    $ui.ProblemHelp.Font = [System.Drawing.Font]::new($font, [System.Drawing.FontStyle]::Underline)
    $ui.ProblemHelp.add_Click({ Invoke-GuiHandler { Show-HelpWindow $script:Gui.ProblemHelp } })
    $ui.ProblemRow.Controls.Add($ui.Problem)
    $ui.ProblemRow.Controls.Add($ui.ProblemHelp)
    Add-GuiStatusRow $status '' $ui.ProblemRow
    $ui.Task = New-GuiFlow
    Add-GuiStatusRow $status 'Task:' $ui.Task
    $ui.Maintenance = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true }
    Add-GuiStatusRow $status 'Maintenance:' $ui.Maintenance
    $ui.Jobs = New-GuiFlow
    Add-GuiStatusRow $status 'Jobs:' $ui.Jobs

    # Buttons | output
    $middle = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 1 }
    [void]$middle.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$middle.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$middle.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Fill'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false
        Padding = [System.Windows.Forms.Padding]::new(10, 4, 6, 6)
    }
    $ui.ButtonPanel = $buttons
    New-GuiButton $buttons 'BackupNow' "Back up now$([char]0x2026)" {
        $names = Show-BackupDialog
        if ($null -ne $names) { Start-GuiOperation 'BackupOnly' @{ JobNames = @($names) } }
    }
    New-GuiButton $buttons 'List' 'List snapshots' { Invoke-GuiList }
    New-GuiButton $buttons 'Restore' "Restore$([char]0x2026)" { Invoke-GuiRestore }
    New-GuiButton $buttons 'Forget' "Forget$([char]0x2026)" { Invoke-GuiForget }
    New-GuiButton $buttons 'Prune' 'Prune' { Start-GuiOperation 'Prune' }
    New-GuiButton $buttons 'Check' 'Check' { Start-GuiOperation 'Check' }
    New-GuiButton $buttons 'Maintenance' 'Run due maintenance' { Start-GuiOperation 'Maintenance' }
    New-GuiButton $buttons 'Cleanup' "Clean up$([char]0x2026)" { Invoke-GuiCleanup }
    $buttons.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $false; Size = [System.Drawing.Size]::new(150, 2); BorderStyle = 'Fixed3D'
        Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 10)
    }))
    New-GuiButton $buttons 'Task' 'Disable task' { Invoke-GuiTaskToggle }
    New-GuiButton $buttons 'Settings' "Settings$([char]0x2026)" { Invoke-GuiSettings }
    # Always enabled: Update-GuiButtons doesn't know it.
    New-GuiButton $buttons 'Help' 'Help (F1)' { Show-HelpWindow }

    # Disabled controls get no mouse events, so their tooltips are shown from the panel underneath.
    $tipMove = {
        param($source, $mouse)
        $gui = $script:Gui
        $control = $source.GetChildAtPoint($mouse.Location)
        $text = $null
        if ($control -and -not $control.Enabled -and $control.Name) { $text = $gui.Reasons[$control.Name] }
        if ($text -eq $gui.TipShown) { return }
        if ($text) { $gui.Ui.Tip.Show($text, $source, $mouse.X + 12, $mouse.Y + 18) }
        else { $gui.Ui.Tip.Hide($source) }
        $gui.TipShown = $text
    }
    $tipLeave = {
        param($source)
        $script:Gui.Ui.Tip.Hide($source)
        $script:Gui.TipShown = $null
    }
    $buttons.add_MouseMove($tipMove)
    $buttons.add_MouseLeave($tipLeave)

    $tabs = New-Object System.Windows.Forms.TabControl -Property @{ Dock = 'Fill'; Margin = [System.Windows.Forms.Padding]::new(0, 4, 10, 0) }
    $page = New-Object System.Windows.Forms.TabPage 'Output'
    $ui.Output = New-Object System.Windows.Forms.RichTextBox -Property @{
        Dock = 'Fill'; ReadOnly = $true; BackColor = [System.Drawing.SystemColors]::Window; WordWrap = $false
        ScrollBars = 'Both'; DetectUrls = $false; HideSelection = $false; BorderStyle = 'None'
        Font = [System.Drawing.Font]::new('Consolas', 9)
    }
    $page.Controls.Add($ui.Output)
    $tabs.TabPages.Add($page)
    $ui.OutputPage = $page
    $page = New-Object System.Windows.Forms.TabPage 'Snapshots'
    $ui.SnapshotGrid = New-SnapshotGrid -MultiSelect
    $page.Controls.Add($ui.SnapshotGrid)
    $snapshotBar = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; AutoSize = $true; WrapContents = $false; Padding = [System.Windows.Forms.Padding]::new(4, 4, 4, 2)
    }
    New-GuiButton $snapshotBar 'ForgetSelected' "Forget selected$([char]0x2026)" { Invoke-GuiForgetSelected }
    $ui.Buttons.ForgetSelected.Margin = [System.Windows.Forms.Padding]::new(0)
    $snapshotBar.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = 'Ctrl+click or Shift+click to select several.'; AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText
        Margin = [System.Windows.Forms.Padding]::new(10, 8, 0, 0)
    }))
    $snapshotBar.add_MouseMove($tipMove)
    $snapshotBar.add_MouseLeave($tipLeave)
    $page.Controls.Add($snapshotBar)
    $ui.SnapshotGrid.BringToFront()
    $grid = $ui.SnapshotGrid.Tag.Grid
    # Not before the window is complete (binding the grid selects a row).
    $grid.add_SelectionChanged({ if ($script:Gui.Ui.OpenLog) { Invoke-GuiHandler { Update-GuiButtons } } })
    # Right-click selects the row under the mouse unless it is part of the selection already.
    $grid.add_CellMouseDown({
        param($source, $mouse)
        if ($mouse.Button -ne 'Right' -or $mouse.RowIndex -lt 0) { return }
        $row = $source.Rows[$mouse.RowIndex]
        if (-not $row.Selected) {
            $source.ClearSelection()
            $source.CurrentCell = $row.Cells[[Math]::Max(0, $mouse.ColumnIndex)]
            $row.Selected = $true
        }
    })
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $item = $menu.Items.Add("Forget selected$([char]0x2026)")
    $item.add_Click({ Invoke-GuiHandler { Invoke-GuiForgetSelected } })
    $item = $menu.Items.Add("Restore$([char]0x2026)")
    $item.add_Click({ Invoke-GuiHandler { if ($script:Gui.Ui.Buttons.Restore.Enabled) { Invoke-GuiRestore } } })
    $menu.add_Opening({
        param($source)
        $buttons = $script:Gui.Ui.Buttons
        $source.Items[0].Enabled = $buttons.ForgetSelected.Enabled
        $source.Items[1].Enabled = $buttons.Restore.Enabled -and $script:Gui.Ui.SnapshotGrid.Tag.Grid.SelectedRows.Count -eq 1
    })
    $grid.ContextMenuStrip = $menu
    $tabs.TabPages.Add($page)
    $ui.SnapshotsPage = $page
    $ui.Tabs = $tabs

    $middle.Controls.Add($buttons, 0, 0)
    $middle.Controls.Add($tabs, 1, 0)

    # Status bar
    $bar = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
        Dock = 'Fill'; AutoSize = $true; ColumnCount = 3; RowCount = 1; Padding = [System.Windows.Forms.Padding]::new(10, 4, 10, 8)
    }
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$bar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $ui.StatusText = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; Anchor = 'Left'; Text = 'Ready' }
    $ui.Cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90; Enabled = $false }
    $ui.Cancel.add_Click({ Invoke-GuiHandler { Stop-GuiTask; Update-GuiButtons } })
    $ui.OpenLog = New-Object System.Windows.Forms.Button -Property @{ Text = 'Open last log'; AutoSize = $true; Enabled = $false }
    $ui.OpenLog.add_Click({ Invoke-GuiHandler { Start-Process -FilePath $script:Gui.LastLogFile } })
    $bar.Controls.Add($ui.StatusText, 0, 0)
    $bar.Controls.Add($ui.Cancel, 1, 0)
    $bar.Controls.Add($ui.OpenLog, 2, 0)

    $root.Controls.Add($status, 0, 0)
    $root.Controls.Add($middle, 0, 1)
    $root.Controls.Add($bar, 0, 2)
    $form.Controls.Add($root)

    $timer = New-GuiTimer
    $timer.add_Tick({
        Update-GuiStatusBar
        # Closing waits for the cancelled task (and its unlock) to end.
        if ($script:Gui.ClosePending -and -not $script:Gui.Current) { $script:Gui.Ui.Form.Close() }
    })

    $form.add_Shown({
        Set-ConsoleWindowVisible $false
        $script:Gui.Ui.Timer.Start()
        Invoke-GuiHandler { Update-GuiRepository; Update-GuiStatus; Update-GuiButtons }
        # First run: nothing works without a configuration.
        if (-not (Test-Path -LiteralPath $script:Gui.ConfigPath -PathType Leaf)) { Invoke-GuiHandler { Invoke-GuiSettings } }
    })
    $form.add_FormClosing({
        param($source, $closing)
        $gui = $script:Gui
        if (-not $gui.Current) { return }
        $closing.Cancel = $true
        if ($gui.ClosePending) { return }
        if ($gui.Current.Action -and
            (Show-GuiMessage 'An action is running. Cancel it and close?' 'Question' 'YesNo' 'Button2') -ne 'Yes') { return }
        $gui.ClosePending = $true
        Stop-GuiTask
        Update-GuiButtons
    })
    $ui.Timer = $timer

    # Local state before the window shows; the repository check starts once it's up.
    Update-GuiConfig
    Update-GuiHealth
    Update-GuiSnapshots
    Update-GuiStatus
    Update-GuiButtons

    [void]$form.ShowDialog()
    $timer.Stop()
    $timer.Dispose()
    if ($script:Help -and -not $script:Help.Form.IsDisposed) { $script:Help.Form.Dispose() }
    $form.Dispose()
}

#endregion

#region Help

# HELP.md next to the script is the user guide behind Help in the main window, Settings and the menu.
# Pointers into it name a heading (Show-HelpWindow 'Setup'); a renamed heading opens the help at the top.

function Get-HelpPath {
    return Join-Path (Split-Path -Parent $script:ScriptPath) 'HELP.md'
}

# Splits the help at its '#' and '##' headings (not inside ``` blocks). Returns Title, Level (1 = part,
# 2 = section) and Lines (the text up to the next heading) per heading. Pure.
function ConvertTo-HelpSections {
    param([string[]]$Lines)

    $sections = @()
    $code = $false
    foreach ($line in @($Lines)) {
        if ($line -match '^```') { $code = -not $code }
        elseif (-not $code -and $line -match '^(#{1,2})\s+(.+?)\s*$') {
            $sections += [pscustomobject]@{ Title = $Matches[2]; Level = $Matches[1].Length; Lines = New-Object System.Collections.ArrayList }
            continue
        }
        if ($sections.Count -gt 0) { [void]$sections[-1].Lines.Add($line) }
    }
    return $sections
}

function Read-HelpSections {
    $path = Get-HelpPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The help file is missing: $path" }
    return @(ConvertTo-HelpSections @(Get-Content -LiteralPath $path -Encoding UTF8))
}

# Index of the section titled Title (case-insensitive), or -1.
function Find-HelpSection {
    param($Sections, [string]$Title)

    $Sections = @($Sections)
    for ($i = 0; $i -lt $Sections.Count; $i++) {
        if ($Title -and $Sections[$i].Title -eq $Title) { return $i }
    }
    return -1
}

# Inline **bold** and `code` of a line as runs: Text, Style (Plain, Bold, Code). Pure.
function ConvertTo-HelpRuns {
    param([string]$Text)

    return @([regex]::Split($Text, '(\*\*[^*]+\*\*|`[^`]+`)') | Where-Object { $_ } | ForEach-Object {
        if ($_ -match '^\*\*(.+)\*\*$') { [pscustomobject]@{ Text = $Matches[1]; Style = 'Bold' } }
        elseif ($_ -match '^`(.+)`$') { [pscustomobject]@{ Text = $Matches[1]; Style = 'Code' } }
        else { [pscustomobject]@{ Text = $_; Style = 'Plain' } }
    })
}

function ConvertTo-HelpPlain {
    param([string]$Text)
    return (@(ConvertTo-HelpRuns $Text) | ForEach-Object { $_.Text }) -join ''
}

# Markdown table rows as aligned text lines; the |---| row becomes a rule. Pure.
function Format-HelpTable {
    param([string[]]$Rows)

    $cells = @(foreach ($row in @($Rows)) { , @($row.Trim().Trim('|').Split('|') | ForEach-Object { ConvertTo-HelpPlain $_.Trim() }) })
    $widths = @{}
    foreach ($row in $cells) {
        for ($i = 0; $i -lt $row.Count; $i++) {
            if ($row[$i] -match '^:?-+:?$') { continue }
            $widths[$i] = [Math]::Max([int]$widths[$i], $row[$i].Length)
        }
    }
    return @(foreach ($row in $cells) {
        $rule = @($row | Where-Object { $_ -notmatch '^:?-+:?$' }).Count -eq 0
        $parts = @(for ($i = 0; $i -lt $row.Count; $i++) {
            if ($rule) { '-' * [int]$widths[$i] } else { $row[$i].PadRight([int]$widths[$i]) }
        })
        ($parts -join '  ').TrimEnd()
    })
}

# A section's lines as display blocks. Text (consecutive lines joined into one paragraph), Bullet (Text, Marker
# '-' or '1.', Indent 0 or 1), Code (Lines as written; tables become aligned Code), Blank. Pure.
function ConvertTo-HelpBlocks {
    param([string[]]$Lines)

    $blocks = New-Object System.Collections.ArrayList
    # The paragraph or bullet the next line continues.
    $current = $null
    $code = $null
    $table = $null
    foreach ($line in @($Lines) + @($null)) {
        if ($null -ne $code) {
            if ($null -eq $line -or $line -match '^```') {
                [void]$blocks.Add([pscustomobject]@{ Type = 'Code'; Lines = @($code) })
                $code = $null
            }
            else { $code += $line }
            continue
        }
        if ($null -ne $line -and $line -match '^\s*\|') {
            if ($null -eq $table) { $table = @() }
            $table += $line
            $current = $null
            continue
        }
        if ($null -ne $table) {
            [void]$blocks.Add([pscustomobject]@{ Type = 'Code'; Lines = @(Format-HelpTable $table) })
            $table = $null
        }
        if ($null -eq $line) { break }

        if ($line -match '^```') { $code = @(); $current = $null }
        elseif (-not $line.Trim()) {
            [void]$blocks.Add([pscustomobject]@{ Type = 'Blank' })
            $current = $null
        }
        elseif ($line -match '^(\s*)(-|\d+\.)\s+(.*)$') {
            $current = [pscustomobject]@{ Type = 'Bullet'; Text = $Matches[3]; Marker = $Matches[2]; Indent = [Math]::Min(1, [int][Math]::Floor($Matches[1].Length / 2)) }
            [void]$blocks.Add($current)
        }
        elseif ($current) { $current.Text += ' ' + $line.Trim() }
        else {
            $current = [pscustomobject]@{ Type = 'Text'; Text = $line.Trim() }
            [void]$blocks.Add($current)
        }
    }
    return $blocks
}

# Word-wraps Text to Width columns; First starts the first line, Indent the others.
function Split-HelpText {
    param([string]$Text, [int]$Width, [string]$First = '', [string]$Indent = '')

    $lines = @()
    $line = $First
    $empty = $true
    foreach ($word in @($Text -split '\s+' | Where-Object { $_ })) {
        if (-not $empty -and $line.Length + 1 + $word.Length -gt $Width) {
            $lines += $line
            $line = $Indent
            $empty = $true
        }
        if ($empty) { $line += $word } else { $line += ' ' + $word }
        $empty = $false
    }
    return $lines + $line
}

# A section as console lines, wrapped to Width.
function Format-HelpText {
    param($Section, [int]$Width = 100)

    $lines = @('', $Section.Title, ('=' * $Section.Title.Length))
    foreach ($block in @(ConvertTo-HelpBlocks $Section.Lines)) {
        switch ($block.Type) {
            'Blank' { $lines += '' }
            'Code'  { $lines += @($block.Lines | ForEach-Object { "    $_" }) }
            'Bullet' {
                $pad = '  ' * ($block.Indent + 1)
                $marker = "$($block.Marker) "
                $lines += Split-HelpText (ConvertTo-HelpPlain $block.Text) $Width "$pad$marker" ($pad + (' ' * $marker.Length))
            }
            default { $lines += Split-HelpText (ConvertTo-HelpPlain $block.Text) $Width }
        }
    }
    return $lines
}

# The menu's Help: the sections by number, then the chosen one, paged.
function Show-HelpMenu {
    try { $sections = @(Read-HelpSections) }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        return
    }
    $width = 100
    try { $width = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) } catch { }

    while ($true) {
        Write-Host ''
        $numbers = @()
        for ($i = 0; $i -lt $sections.Count; $i++) {
            if ($sections[$i].Level -eq 1) { Write-Host " $($sections[$i].Title)" -ForegroundColor Cyan }
            else {
                $numbers += $i
                Write-Host ('{0,4}. {1}' -f $numbers.Count, $sections[$i].Title)
            }
        }
        $answer = (Read-Host 'Section number (Enter = back to the menu)').Trim()
        if (-not $answer) { return }
        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $numbers.Count) {
            Write-Host 'Unknown section.' -ForegroundColor Yellow
            continue
        }

        $lines = @(Format-HelpText $sections[$numbers[$number - 1]] $width)
        # Hosts without paging (e.g. the ISE) print it all.
        try { $lines | Out-Host -Paging }
        catch { foreach ($line in $lines) { Write-Host $line } }
        [void](Read-Host 'Enter = back to the sections')
    }
}

# A modal dialog opened after the Help window (such as Settings) disables it; this keeps it usable beside the dialog.
function Enable-HelpWindow {
    $help = $script:Help
    if (-not $help -or $help.Form.IsDisposed -or -not $help.Form.IsHandleCreated) { return }
    if (-not ('ResticGui.HelpWindow' -as [type])) {
        Add-Type -Namespace ResticGui -Name HelpWindow -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnableWindow(IntPtr hWnd, bool enable);
'@
    }
    [void][ResticGui.HelpWindow]::EnableWindow($help.Form.Handle, $true)
}

function Add-HelpRun {
    param($Box, [string]$Text, $Font, $BackColor = [System.Drawing.SystemColors]::Window)

    $Box.SelectionStart = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionFont = $Font
    $Box.SelectionBackColor = $BackColor
    $Box.SelectedText = $Text
}

# Writes the sections into the RichTextBox; returns where each one starts.
function Write-HelpDocument {
    param($Box, $Sections)

    $fonts = @{
        Plain   = [System.Drawing.Font]::new('Segoe UI', 9.75)
        Bold    = [System.Drawing.Font]::new('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
        Code    = [System.Drawing.Font]::new('Consolas', 9.5)
        Part    = [System.Drawing.Font]::new('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
        Section = [System.Drawing.Font]::new('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    }
    $shade = [System.Drawing.Color]::FromArgb(240, 240, 240)
    $window = [System.Drawing.SystemColors]::Window

    $starts = @()
    foreach ($section in @($Sections)) {
        $Box.SelectionIndent = 0
        $Box.SelectionHangingIndent = 0
        if ($Box.TextLength -gt 0) { Add-HelpRun $Box "`n" $fonts.Plain }
        $starts += $Box.TextLength
        $font = $fonts.Section
        if ($section.Level -eq 1) { $font = $fonts.Part }
        Add-HelpRun $Box "$($section.Title)`n" $font

        # The blank line under a heading is spacing enough.
        $blank = $true
        foreach ($block in @(ConvertTo-HelpBlocks $section.Lines)) {
            if ($block.Type -eq 'Blank') {
                if (-not $blank) { Add-HelpRun $Box "`n" $fonts.Plain }
                $blank = $true
                continue
            }
            $blank = $false
            if ($block.Type -eq 'Code') {
                $Box.SelectionIndent = 12
                $Box.SelectionHangingIndent = 0
                foreach ($line in @($block.Lines)) { Add-HelpRun $Box " $line `n" $fonts.Code $shade }
                continue
            }

            $text = $block.Text
            if ($block.Type -eq 'Bullet') {
                $Box.SelectionIndent = 10 + 18 * $block.Indent
                $Box.SelectionHangingIndent = 14
                $marker = $block.Marker
                if ($marker -eq '-') { $marker = [string][char]0x2022 }
                Add-HelpRun $Box "$marker  " $fonts.Plain
            }
            else {
                $Box.SelectionIndent = 0
                $Box.SelectionHangingIndent = 0
            }
            foreach ($run in @(ConvertTo-HelpRuns $text)) {
                switch ($run.Style) {
                    'Bold'  { Add-HelpRun $Box $run.Text $fonts.Bold }
                    'Code'  { Add-HelpRun $Box $run.Text $fonts.Code $shade }
                    default { Add-HelpRun $Box $run.Text $fonts.Plain }
                }
            }
            Add-HelpRun $Box "`n" $fonts.Plain $window
        }
    }
    return $starts
}

# Scrolls the section to the top of the text.
function Show-HelpSection {
    param([int]$Index)

    $help = $script:Help
    $box = $help.Ui.Text
    if ($Index -lt 0 -or $Index -ge $help.Starts.Count) { return }
    $box.Select($box.TextLength, 0)
    $box.ScrollToCaret()
    $box.Select($help.Starts[$Index], 0)
    $box.ScrollToCaret()
}

# Next match of the Find box after the selection, wrapping around (case-insensitive).
function Find-HelpText {
    $ui = $script:Help.Ui
    $text = $ui.Find.Text
    if (-not $text) { return }
    $box = $ui.Text
    $start = $box.SelectionStart + $box.SelectionLength
    $index = -1
    if ($start -lt $box.TextLength) { $index = $box.Find($text, $start, [System.Windows.Forms.RichTextBoxFinds]::None) }
    if ($index -lt 0) { $index = $box.Find($text, 0, [System.Windows.Forms.RichTextBoxFinds]::None) }
    if ($index -lt 0) {
        $ui.FindStatus.Text = 'Not found.'
        return
    }
    $ui.FindStatus.Text = ''
    $box.ScrollToCaret()
}

function New-HelpWindow {
    param($Sections)

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Restic help'; Size = [System.Drawing.Size]::new(860, 600); MinimumSize = [System.Drawing.Size]::new(640, 420)
        StartPosition = 'Manual'; Font = [System.Drawing.Font]::new('Segoe UI', 9); KeyPreview = $true
    }
    $help = @{ Form = $form; Sections = @($Sections); Starts = @(); Ui = @{} }
    $ui = $help.Ui

    $layout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 2 }
    [void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 240))
    [void]$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Fill'; AutoSize = $true; WrapContents = $false; Padding = [System.Windows.Forms.Padding]::new(4, 6, 4, 2)
    }
    $bar.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = 'Find:'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(3, 7, 3, 3)
    }))
    $ui.Find = New-Object System.Windows.Forms.TextBox -Property @{ Width = 240 }
    $ui.Find.add_KeyDown({
        param($source, $key)
        if ($key.KeyCode -eq 'Enter') {
            $key.SuppressKeyPress = $true
            Invoke-GuiHandler { Find-HelpText }
        }
    })
    $bar.Controls.Add($ui.Find)
    $next = New-Object System.Windows.Forms.Button -Property @{ Text = 'Find next'; AutoSize = $true }
    $next.add_Click({ Invoke-GuiHandler { Find-HelpText } })
    $bar.Controls.Add($next)
    $ui.FindStatus = New-Object System.Windows.Forms.Label -Property @{
        AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText; Margin = [System.Windows.Forms.Padding]::new(8, 7, 3, 3)
    }
    $bar.Controls.Add($ui.FindStatus)
    $bar.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
        Text = "File: $(Get-HelpPath)"; AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText
        Margin = [System.Windows.Forms.Padding]::new(16, 7, 3, 3)
    }))
    $layout.Controls.Add($bar, 0, 0)
    $layout.SetColumnSpan($bar, 2)

    $ui.List = New-Object System.Windows.Forms.ListBox -Property @{
        Dock = 'Fill'; IntegralHeight = $false; Margin = [System.Windows.Forms.Padding]::new(8, 4, 4, 8)
    }
    foreach ($section in $help.Sections) {
        if ($section.Level -eq 1) { [void]$ui.List.Items.Add($section.Title) }
        else { [void]$ui.List.Items.Add("    $($section.Title)") }
    }
    $ui.List.add_SelectedIndexChanged({ param($source) Invoke-GuiHandler { Show-HelpSection $source.SelectedIndex } })
    $layout.Controls.Add($ui.List, 0, 1)

    # The panel gives the text a margin; RichTextBox has no padding of its own.
    $page = New-Object System.Windows.Forms.Panel -Property @{
        Dock = 'Fill'; BackColor = [System.Drawing.SystemColors]::Window; BorderStyle = 'FixedSingle'
        Padding = [System.Windows.Forms.Padding]::new(12, 8, 4, 8); Margin = [System.Windows.Forms.Padding]::new(4, 4, 8, 8)
    }
    $ui.Text = New-Object System.Windows.Forms.RichTextBox -Property @{
        Dock = 'Fill'; BorderStyle = 'None'; BackColor = [System.Drawing.SystemColors]::Window; DetectUrls = $false
        HideSelection = $false; ScrollBars = 'Vertical'
    }
    $page.Controls.Add($ui.Text)
    $layout.Controls.Add($page, 1, 1)
    $form.Controls.Add($layout)

    $help.Starts = @(Write-HelpDocument $ui.Text $help.Sections)
    $ui.Text.ReadOnly = $true
    $ui.Text.Select(0, 0)

    $form.add_KeyDown({
        param($source, $key)
        $ui = $script:Help.Ui
        if ($key.Control -and $key.KeyCode -eq 'F') {
            $key.SuppressKeyPress = $true
            $ui.Find.Focus()
            $ui.Find.SelectAll()
        }
        elseif ($key.KeyCode -eq 'F3') {
            $key.SuppressKeyPress = $true
            Invoke-GuiHandler { Find-HelpText }
        }
        elseif ($key.KeyCode -eq 'Escape') { $script:Help.Form.Close() }
    })
    $form.add_FormClosed({ $script:Help = $null })
    return $help
}

# Down and right of the window that opens it (Settings or the main window), so it doesn't hide it; kept on its screen.
function Set-HelpWindowLocation {
    param($Form)

    $owner = [System.Windows.Forms.Form]::ActiveForm
    if (-not $owner -and $script:Gui) { $owner = $script:Gui.Ui.Form }
    if ($owner) {
        $screen = [System.Windows.Forms.Screen]::FromControl($owner).WorkingArea
        $x = $owner.Left + 120
        $y = $owner.Top + 90
    }
    else {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = $screen.Left + ($screen.Width - $Form.Width) / 2
        $y = $screen.Top + ($screen.Height - $Form.Height) / 2
    }
    $x = [Math]::Max($screen.Left, [Math]::Min($x, $screen.Right - $Form.Width))
    $y = [Math]::Max($screen.Top, [Math]::Min($y, $screen.Bottom - $Form.Height))
    $Form.Location = [System.Drawing.Point]::new([int]$x, [int]$y)
}

# The Help window: modeless and single, so it stays open beside the main window and Settings.
# Section: the heading to show; '' keeps the current position (the top when the window is new).
function Show-HelpWindow {
    param([string]$Section = '')

    $help = $script:Help
    if (-not $help -or $help.Form.IsDisposed) {
        try { $sections = @(Read-HelpSections) }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Restic help', 'OK', 'Warning') | Out-Null
            return
        }
        $help = New-HelpWindow $sections
        $script:Help = $help
        Set-HelpWindowLocation $help.Form
        $help.Form.Show()
    }

    if ($help.Form.WindowState -eq 'Minimized') { $help.Form.WindowState = 'Normal' }
    Enable-HelpWindow
    $help.Form.Activate()
    $index = Find-HelpSection $help.Sections $Section
    if ($index -ge 0) {
        if ($help.Ui.List.SelectedIndex -eq $index) { Show-HelpSection $index }
        else { $help.Ui.List.SelectedIndex = $index }
    }
}

#endregion

#region Main

$exitCode = 1
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'Run this script as Administrator (needed for VSS and to read the secrets file).'
    }

    if ($Mode -eq 'Gui') {
        # Also before Read-Config: the window opens in any state and shows what is wrong.
        if (Test-WinForms) {
            Show-MainWindow $script:ConfigPath
            exit 0
        }
        Write-Host 'Windows Forms is not available on this machine; opening the console menu.' -ForegroundColor Yellow
        $Mode = 'Menu'
    }

    $script:Config = Read-Config $script:ConfigPath

    Start-Log -Directory $script:Config.LogDirectory -RetentionDays $script:Config.LogRetentionDays -Name $Mode.ToLower()
    Write-Log "Mode:       $Mode"
    Write-Log "Hostname:   $($script:Config.Hostname)"
    Write-Log "Repository: $($script:Config.Repository)"
    Write-Log "Log file:   $script:LogFile" -Level Detail

    if ($Mode -eq 'Menu') {
        Test-TaskLocation
        Show-Menu
        $exitCode = 0
    }
    else {
        $exitCode = Get-ExitCode @(Invoke-Operation $Mode)
        Write-Log "Finished with exit code $exitCode."
    }
}
catch {
    # The main window hides the console; the launcher's pause would otherwise wait in an invisible window.
    if ($Mode -eq 'Gui') { Set-ConsoleWindowVisible $true }
    Write-Log $_.Exception.Message -Level Error
    $exitCode = 1
}

exit $exitCode

#endregion
