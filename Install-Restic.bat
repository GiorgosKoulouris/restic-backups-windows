<# :
@echo off
setlocal

rem Installs or updates the Restic backup manager from S3. Download and run this file on its own.
rem Batch part: elevate, run the PowerShell part below (the rest of this file), pause.
rem PowerShell reads this batch part as a block comment: never write its closing marker in it.
rem Full paths: cmd looks in the current folder first, which may be writable by anyone.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%SystemRoot%\System32\net.exe" session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    "%PS%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "INSTALLER=%~f0"
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:INSTALLER))"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXIT_CODE%
#>

# PowerShell part. Windows PowerShell 5.1 compatible.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Set by dev\Publish-Bundle.ps1 when it stages this file: the S3 folder holding manifest.txt
# (a file:/// folder for a dev install, dev\Install-Local.bat).
$BaseUrl = '__BASE_URL__'
$DefaultRoot = Join-Path $env:ProgramFiles 'Restic'
$ScriptName = 'Restic-ManageSnapshots.ps1'
$ToolsName = 'ResticTools'

# Trust rules: the script has its own copy (Test-TrustedPath, Lock-TrustedPath) because this file is standalone.
# Keep the trusted SIDs, the change rights and the locked DACL identical in both.
# SYSTEM, Administrators, CREATOR OWNER, TrustedInstaller.
$TrustedSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
# Rights that change a folder or file: WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles,
# WriteAttributes, Delete, ChangePermissions, TakeOwnership, GenericAll, GenericWrite.
$ChangeRights = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
# Rights that rename or delete a folder or what's in it, or change who may: DeleteSubdirectoriesAndFiles, Delete,
# ChangePermissions, TakeOwnership, GenericAll. Creating files is not among them.
$MoveRights = 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000

# manifest.txt: "version <x>", then one "<root|tools> <file name>" line per file (tools = ResticTools). # starts a comment.
function Get-Manifest {
    $url = $BaseUrl + 'manifest.txt'
    try { $data = (New-Object Net.WebClient).DownloadData($url) }
    catch { throw "Can't download $url. $($_.Exception.Message)" }
    $text = [Text.Encoding]::UTF8.GetString($data).TrimStart([char]0xFEFF)

    $version = $null
    $files = @()
    foreach ($line in $text -split "`r?`n") {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^version\s+(\S+)$') { $version = $Matches[1]; continue }
        if ($line -match '^(root|tools)\s+([A-Za-z0-9_-][A-Za-z0-9._-]*)$') {
            $files += [pscustomobject]@{ Dest = $Matches[1]; Name = $Matches[2] }
            continue
        }
        throw "manifest.txt: invalid line '$line'."
    }
    if (-not $version) { throw 'manifest.txt has no version line.' }
    if (-not ($files | Where-Object { $_.Dest -eq 'tools' -and $_.Name -eq $ScriptName })) { throw "manifest.txt doesn't list tools $ScriptName." }
    return [pscustomobject]@{ Version = $version; Files = $files }
}

# Untrusted accounts that own $Path or hold any of $Rights on it. Inherit-only entries apply to what's inside, not to $Path.
# The scheduled task runs the script as SYSTEM: any of them could run code as SYSTEM.
function Get-UntrustedHolders([string]$Path, [int]$Rights) {
    $sidType = [Security.Principal.SecurityIdentifier]
    $acl = Get-Acl -LiteralPath $Path

    $found = @()
    $owner = $acl.GetOwner($sidType)
    if ($TrustedSids -notcontains $owner.Value) { $found += $owner }
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if (([int]$rule.FileSystemRights -band $Rights) -eq 0) { continue }
        if ($TrustedSids -contains $rule.IdentityReference.Value) { continue }
        $found += $rule.IdentityReference
    }

    $names = @()
    foreach ($sid in $found) {
        try { $name = $sid.Translate([Security.Principal.NTAccount]).Value } catch { $name = $sid.Value }
        if ($names -notcontains $name) { $names += $name }
    }
    return $names
}

# Links (reparse points) inside $Path, at any depth; folder links are not followed. icacls /T would follow them.
function Get-Links([string]$Path) {
    $found = @()
    $folders = New-Object System.Collections.Stack
    $folders.Push($Path)
    while ($folders.Count -gt 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $folders.Pop() -Force)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { $found += $child.FullName }
            elseif ($child.PSIsContainer) { $folders.Push($child.FullName) }
        }
    }
    return $found
}

# Owner Administrators; full control for SYSTEM and Administrators, read and execute for Users; nothing inherited.
# -Contents: everything inside gets owner Administrators and only the permissions it inherits from $Path. Throws on
# a link inside (Read-InstallRoot refuses those up front).
function Lock-Path([string]$Path, [switch]$Contents) {
    $sections = [Security.AccessControl.AccessControlSections]'Owner, Access'
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm('O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)', $sections)
        [IO.Directory]::SetAccessControl($Path, $acl)
    }
    else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorSddlForm('O:BAD:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)', $sections)
        [IO.File]::SetAccessControl($Path, $acl)
    }
    if (-not $Contents) { return }
    # One item at a time, top down: icacls /T would follow links. Each folder is reset before its contents are listed,
    # so no other account can add a link meanwhile. icacls uses SIDs: servers may be localized.
    $folders = New-Object System.Collections.Stack
    $folders.Push($Path)
    while ($folders.Count -gt 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $folders.Pop() -Force)) {
            $item = $child.FullName
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$item is a link (reparse point). Remove it, then run the installer again." }
            & icacls.exe $item /setowner '*S-1-5-32-544' /Q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Can't set the owner of $item (icacls exit code $LASTEXITCODE)." }
            & icacls.exe $item /reset /Q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Can't reset the permissions of $item (icacls exit code $LASTEXITCODE)." }
            if ($child.PSIsContainer) { $folders.Push($item) }
        }
    }
}

function Read-Choice([string]$Prompt, [string[]]$Valid) {
    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if ($Valid -contains $answer) { return $answer }
    }
}

# Returns the install target, or $null to cancel. Loops until the folder is acceptable.
# The task runs ResticTools\<script> as SYSTEM. Users may create files in the root, but whoever can rename the root,
# ResticTools or a folder above them could put their own script at that path.
function Read-InstallRoot {
    while ($true) {
        Write-Host ''
        $answer = (Read-Host "Install folder (Enter = $DefaultRoot, Q = cancel)").Trim().Trim('"')
        if ($answer -eq 'q') { return $null }
        if (-not $answer) { $answer = $DefaultRoot }
        if ($answer -notmatch '^[A-Za-z]:\\.') {
            Write-Host 'Enter a full local path, e.g. C:\Program Files\Restic.'
            continue
        }
        $root = [IO.Path]::GetFullPath($answer).TrimEnd('\')
        $parent = [IO.Path]::GetDirectoryName($root)
        $tools = Join-Path $root $ToolsName

        if (Test-Path -LiteralPath $root -PathType Leaf) {
            Write-Host "$root is a file."
            continue
        }
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            Write-Host "$parent doesn't exist."
            continue
        }

        $current = Test-Path -LiteralPath (Join-Path $tools $ScriptName)
        if ($current) {
            $versionFile = Join-Path $tools 'version.txt'
            $installed = 'unknown'
            if (Test-Path -LiteralPath $versionFile) { $installed = (Get-Content -LiteralPath $versionFile -Encoding UTF8 -TotalCount 1).Trim() }
            Write-Host "Found an installation in $root. Installed: $installed. Available: $($script:Manifest.Version)."
            Write-Host '1. Update  2. Pick another folder  3. Cancel'
            $choice = Read-Choice 'Choice' @('1', '2', '3')
            if ($choice -eq '2') { continue }
            if ($choice -eq '3') { return $null }
        }

        $refused = $null
        for ($dir = $parent; $dir; $dir = [IO.Path]::GetDirectoryName($dir)) {
            $holders = @(Get-UntrustedHolders $dir $MoveRights)
            if ($holders.Count -gt 0) {
                $refused = "$($holders -join ', ') can rename $dir or what's in it, or change its permissions."
                break
            }
        }
        $toolsExists = Test-Path -LiteralPath $tools
        if (-not $refused -and $toolsExists) {
            # Never adopt a ResticTools someone else made: it could hold their configuration. The installer always locks its own.
            $item = Get-Item -LiteralPath $tools -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $refused = "$tools isn't a plain folder." }
            else {
                $holders = @(Get-UntrustedHolders $tools $ChangeRights)
                if ($holders.Count -gt 0) { $refused = "$($holders -join ', ') can change $tools. Fix its permissions or remove it." }
            }
            # Copying would write through a file link, and locking the contents refuses links.
            if (-not $refused) {
                $links = @(Get-Links $tools)
                if ($links.Count -gt 0) { $refused = "$tools contains links (reparse points): $($links -join ', '). Remove them." }
            }
        }
        if ($refused) {
            Write-Host "Refused: $refused" -ForegroundColor Red
            Write-Host "The scheduled task runs $ToolsName\$ScriptName as SYSTEM. Pick another folder, e.g. under C:\Program Files."
            continue
        }

        # A new root is always locked. An existing one only when it needs it, and the user agrees.
        $rootExists = Test-Path -LiteralPath $root
        $lockRoot = -not $rootExists
        if ($rootExists) {
            $holders = @(Get-UntrustedHolders $root $MoveRights)
            if ($holders.Count -gt 0) {
                Write-Host "$($holders -join ', ') can rename $root or what's in it, or change its permissions." -ForegroundColor Yellow
                Write-Host 'Locking it sets owner Administrators, full control for SYSTEM and Administrators, read for Users.'
                Write-Host 'Everything in it that inherits permissions gets the same.'
                if ((Read-Choice 'Lock it? (Y/N)' @('y', 'n')) -eq 'n') { continue }
                $lockRoot = $true
            }
        }
        return [pscustomobject]@{
            Root = $root; Tools = $tools; Current = $current
            RootExists = $rootExists; ToolsExists = $toolsExists; LockRoot = $lockRoot
        }
    }
}

try {
    if ($BaseUrl -notmatch '^(https|file)://.+/$') { throw 'This copy has no download location. Use the Install-Restic.bat published to S3.' }
    Write-Host 'Restic backup manager installer'
    $script:Manifest = Get-Manifest
    Write-Host "Available version: $($Manifest.Version)"

    $target = Read-InstallRoot
    if (-not $target) {
        Write-Host 'Cancelled.'
        exit 0
    }

    # Download everything first, so a failed download leaves the installation untouched. Not in the admin's %TEMP%:
    # their non-elevated processes could swap the files, or rename the folder away and replace it. Created locked
    # (no window in which it inherits), in a folder whose entries only trusted accounts can rename.
    $temp = Join-Path $env:SystemRoot 'Temp'
    $holders = @(Get-UntrustedHolders $temp $MoveRights)
    if ($holders.Count -gt 0) { throw "$temp is not safe for staging the download: $($holders -join ', ') can rename what's in it." }
    $stage = Join-Path $temp ('restic-install-' + [guid]::NewGuid().ToString('N'))
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)', [Security.AccessControl.AccessControlSections]'Owner, Access')
    if (Test-Path -LiteralPath $stage) { throw "$stage already exists." }
    [void][IO.Directory]::CreateDirectory($stage, $acl)
    try {
        $client = New-Object Net.WebClient
        foreach ($file in $Manifest.Files) {
            Write-Host "Downloading $($file.Name)"
            $path = Join-Path $stage $file.Name
            try { $client.DownloadFile($BaseUrl + $file.Name, $path) }
            catch { throw "Can't download $($BaseUrl + $file.Name). $($_.Exception.Message)" }
            if ((Get-Item -LiteralPath $path).Length -eq 0) { throw "$($file.Name) is empty." }
        }

        # New-Item without -Force fails if someone created the folder since it was checked.
        if (-not $target.RootExists) { New-Item -ItemType Directory -Path $target.Root | Out-Null }
        if ($target.LockRoot) { Lock-Path $target.Root }
        if (-not $target.ToolsExists) { New-Item -ItemType Directory -Path $target.Tools | Out-Null }
        Lock-Path $target.Tools
        foreach ($file in $Manifest.Files) {
            if ($file.Dest -eq 'tools') {
                Copy-Item -LiteralPath (Join-Path $stage $file.Name) -Destination $target.Tools -Force
                continue
            }
            # The root may be writable by others: replace the file rather than write into one they may have made.
            $path = Join-Path $target.Root $file.Name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            Copy-Item -LiteralPath (Join-Path $stage $file.Name) -Destination $path
            Lock-Path $path
        }
        [IO.File]::WriteAllText((Join-Path $target.Tools 'version.txt'), $Manifest.Version + "`n")
        Lock-Path $target.Tools -Contents
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    $launcher = Join-Path $target.Root 'Restic-ManageSnapshots.bat'
    Write-Host ''
    Write-Host "Installed $($Manifest.Version) in $($target.Root)." -ForegroundColor Green
    if (-not $target.Current) {
        Write-Host "Next: run $launcher. Settings opens; fill it in and click Run Setup. See Help: First-time setup."
    }
    else {
        Write-Host 'If the main window or menu says to run Setup, run it.'
    }
    exit 0
}
catch {
    Write-Host ''
    Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
