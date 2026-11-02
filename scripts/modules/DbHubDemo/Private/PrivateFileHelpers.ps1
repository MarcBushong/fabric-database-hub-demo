function Initialize-DemoPrivateDirectory {
    <#
    .SYNOPSIS
    Creates a new directory under the user's temporary folder that only the current user can open. Internal.

    .DESCRIPTION
    Request bodies that carry protected Run Command parameters (an access token, a product key) are written
    here and passed to the Azure CLI as --body @<file>, so the values never appear on a command line or in a
    log (ADR 0009). On Windows the directory is created with a protected ACL holding one entry: full control
    for the current user, without inherited entries. On Linux and macOS its mode is 700, as chmod 700 sets
    it. The caller deletes the directory in a finally block with Remove-DemoPrivateDirectory. In deploy.ps1's track
    processes the directory goes under DBHUB_PRIVATE_ROOT, inside the run's private handoff directory, so deploy.ps1
    deletes it even when a stop has to end the process before its finally block runs (Phase 28 live finding).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidatePattern('^[a-z0-9-]{1,20}$')]
        [string] $Prefix = 'dbhub'
    )

    $root = [System.IO.Path]::GetTempPath()
    $runRoot = [string]$env:DBHUB_PRIVATE_ROOT
    if ($runRoot -and [System.IO.Directory]::Exists($runRoot)) {
        $root = $runRoot
    }
    $path = Join-Path -Path $root -ChildPath ('{0}-{1}' -f $Prefix, [guid]::NewGuid().ToString('N'))
    if ($IsWindows) {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
        [System.IO.FileSystemAclExtensions]::Create([System.IO.DirectoryInfo]::new($path), $security)
    }
    else {
        $mode = [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute'
        [System.IO.Directory]::CreateDirectory($path, $mode) | Out-Null
        # The process umask can only remove bits; setting the mode again is the chmod 700 itself.
        [System.IO.File]::SetUnixFileMode($path, $mode)
    }
    return $path
}

function Write-DemoPrivateFile {
    <#
    .SYNOPSIS
    Writes UTF-8 text without a byte order mark into a directory from Initialize-DemoPrivateDirectory and
    returns the file's path. On Linux and macOS the file's mode is 600. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Directory,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    $path = Join-Path -Path $Directory -ChildPath $Name
    [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]'UserRead, UserWrite')
    }
    return $path
}

function Remove-DemoPrivateDirectory {
    <#
    .SYNOPSIS
    Deletes a directory from Initialize-DemoPrivateDirectory and everything in it. Never throws; returns
    $true when the directory is gone. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Path
    )

    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.Directory]::Exists($Path)) {
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete the private temporary directory')) {
        return $false
    }
    try {
        [System.IO.Directory]::Delete($Path, $true)
    }
    catch {
        Write-DemoLog -Level Warning -Message ('A private temporary directory could not be deleted: {0}' -f $_.Exception.Message)
    }
    return (-not [System.IO.Directory]::Exists($Path))
}
