[CmdletBinding()]
param(
    [string]$DataRoot = '',
    [string]$CodexHome = '',
    [string]$TestRoot = '',
    [ValidateSet('None','CopyError','CorruptCopy','AfterRename','AfterJunction','SourceChanged','Reopen','AfterReconcile')]
    [string]$TestFailure = 'None',
    [switch]$RecoverOnly,
    [ValidateRange(-1,1800)]
    [int]$RenameRetrySeconds = -1
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testing = -not [string]::IsNullOrWhiteSpace($TestRoot)
$profileRoot = [Environment]::GetFolderPath('UserProfile')
if ($testing) {
    $root = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $fixtureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'tests-guarded')).TrimEnd('\')
    if (-not $root.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath (Join-Path $root '.fixture') -PathType Leaf)) {
        throw "Test mode requires a marked fixture below $fixtureRoot."
    }
    $source = Join-Path $root 'source'
    $destination = Join-Path $root 'destination'
} elseif ($TestFailure -ne 'None') {
    throw 'Fault injection is allowed only in marked test fixtures.'
} else {
    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        throw 'Pass -DataRoot to choose a destination directory.'
    }
    $root = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $source = if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        Join-Path $profileRoot '.codex'
    } else {
        [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
    }
    $destination = Join-Path $root '.codex'
}
$destinationQualifier = Split-Path -Path $root -Qualifier
$destinationDriveName = if ($destinationQualifier -match '^(?<drive>[A-Za-z]):\\?$') {
    $Matches.drive
} else {
    ''
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backup = "$source.before-migration.$stamp"
$logPath = Join-Path $root "codex-migration-$stamp.log"
$copyLog = Join-Path $root "robocopy-$stamp.log"
$statePath = Join-Path $root 'migration-state.json'
$mutex = New-Object Threading.Mutex($false, ('Local\CodexHomeMigration-' + $(if ($testing) {Split-Path $root -Leaf} else {'Production'})))
$ownsMutex = $false
$renamed = $false
$state = $null
$exitCode = 1
$reuseDestination = $false
$sandboxServiceName = 'CodexSandboxService.OpenAI.Codex'
$servicePaused = $false
$restoreSandboxService = $false
$renameRetryLimit = if ($RenameRetrySeconds -ge 0) { $RenameRetrySeconds } elseif ($testing) { 10 } else { 300 }
$consoleModeSaved = $false
$consoleInputHandle = [IntPtr]::Zero
[uint32]$consoleOriginalMode = 0

function Disable-ConsoleQuickEdit {
    if (-not ('CodexMigrationConsole8' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexMigrationConsole8 {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(int standardHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetConsoleMode(IntPtr handle, uint mode);
}
'@
    }
    $script:consoleInputHandle = [CodexMigrationConsole8]::GetStdHandle(-10)
    [uint32]$mode = 0
    if (-not [CodexMigrationConsole8]::GetConsoleMode($consoleInputHandle, [ref]$mode)) {
        return '[CONSOLE] No console input handle; if the title shows Select, press Esc to resume.'
    }
    $script:consoleOriginalMode = $mode
    # ENABLE_EXTENDED_FLAGS is required to disable ENABLE_QUICK_EDIT_MODE.
    [uint32]$migrationMode = ($mode -bor 0x80) -band (-bnot 0x40)
    if (-not [CodexMigrationConsole8]::SetConsoleMode($consoleInputHandle, $migrationMode)) {
        throw "Cannot disable console QuickEdit (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())). No migration started."
    }
    $script:consoleModeSaved = $true
    return '[CONSOLE] Mouse QuickEdit pause disabled for this run; console settings will be restored on exit.'
}
function Restore-ConsoleQuickEdit {
    if ($consoleModeSaved) {
        if (-not [CodexMigrationConsole8]::SetConsoleMode($consoleInputHandle, $consoleOriginalMode)) {
            Write-Host "Console setting restore failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())); data recovery is unaffected."
        }
        $script:consoleModeSaved = $false
    }
}

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
}
function Save-State([string]$Phase) {
    $script:state.Phase = $Phase
    $script:state.Updated = (Get-Date).ToString('o')
    $tempState = "$statePath.new"
    $script:state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempState -Encoding UTF8
    if ([IO.File]::Exists($statePath)) {
        [IO.File]::Replace($tempState, $statePath, "$statePath.previous")
    } else { [IO.File]::Move($tempState, $statePath) }
}
function Get-CodexProcesses {
    @(Get-Process -Name @('codex','codex-code-mode-host','codex-computer-use-swift') -ErrorAction SilentlyContinue)
}
function Assert-CodexClosed {
    if (-not $testing -and @(Get-CodexProcesses).Count -gt 0) {
        throw 'Codex reopened during migration. Path switch cancelled.'
    }
    if (-not $testing -and $servicePaused) {
        $service = Get-Service -Name $sandboxServiceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -ne 'Stopped') {
            throw 'Codex sandbox service restarted during migration; path switch cancelled.'
        }
    }
}
function Add-ServiceStateFields {
    foreach ($pair in @(@('SandboxServiceName',$sandboxServiceName),@('SandboxServiceRestorePending',$false))) {
        if ($null -eq $script:state.PSObject.Properties[$pair[0]]) {
            $script:state | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]
        }
    }
}
function Pause-SandboxService {
    if ($testing) { return }
    Assert-CodexClosed
    $service = Get-Service -Name $sandboxServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) { Write-Log '[2/5 SERVICE] Sandbox service is not installed.'; return }
    if ($service.Status -eq 'Stopped') { $script:servicePaused = $true; return }
    if ($service.Status -ne 'Running') { throw "Sandbox service is in a transitional state: $($service.Status)" }
    Add-ServiceStateFields
    # Persist restoration intent BEFORE stopping, so RecoverOnly also restores
    # a service after forced termination between Stop-Service and state save.
    $script:restoreSandboxService = $true
    $script:state.SandboxServiceRestorePending = $true
    Save-State $script:state.Phase
    Write-Log "[2/5 SERVICE] Temporarily stopping only $sandboxServiceName; it will be restored after success or failure."
    Stop-Service -Name $sandboxServiceName -ErrorAction Stop
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
    $script:servicePaused = $true
    Write-Log '[2/5 SERVICE] Sandbox service stopped; checking all source file locks next.'
}
function Restore-SandboxService {
    if ($testing -or -not $restoreSandboxService) { return }
    Write-Log "[SERVICE RESTORE] Restoring $sandboxServiceName to Running."
    $service = Get-Service -Name $sandboxServiceName -ErrorAction Stop
    if ($service.Status -eq 'StopPending') {
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
        $service.Refresh()
    }
    if ($service.Status -eq 'Stopped') { Start-Service -Name $sandboxServiceName -ErrorAction Stop }
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
    $script:servicePaused = $false
    $script:restoreSandboxService = $false
    $script:state.SandboxServiceRestorePending = $false
    Save-State $script:state.Phase
    Write-Log '[SERVICE RESTORE] Sandbox service is Running again.'
}
function Test-SamePath([string]$Left, [string]$Right) {
    [string]::Equals([IO.Path]::GetFullPath($Left).TrimEnd('\'), [IO.Path]::GetFullPath($Right).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}
function Get-ItemIfPresent([string]$Path) {
    Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}
function Move-DirectoryWithRetry([string]$From, [string]$To, [string]$Purpose) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    while ($true) {
        try {
            [IO.Directory]::Move($From, $To)
            return
        } catch {
            $exception = $_.Exception
            while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
            $hresult = [int]$exception.HResult
            $win32 = $hresult -band 0xFFFF
            $retryable = $win32 -in @(5,32,33)
            if (-not $retryable -or $watch.Elapsed.TotalSeconds -ge $renameRetryLimit) { throw }
            $attempt++
            $remaining = [Math]::Max(0, [int][Math]::Ceiling($renameRetryLimit - $watch.Elapsed.TotalSeconds))
            Write-Log ("[2/5 RENAME WAIT] {0} denied (Win32 0x{1:X2}, HRESULT 0x{2:X8}); retry {3}, about {4}s remaining. Source/backup paths are preserved." -f $Purpose,$win32,$hresult,$attempt,$remaining)
            Start-Sleep -Seconds 5
        }
    }
}
function Assert-SourceRenameAccess([string]$Path) {
    Assert-CodexClosed
    if ($null -ne (Get-ItemIfPresent $backup)) {
        throw "Rename preflight backup path is already occupied: $backup"
    }
    $priorPhase = $script:state.Phase
    Save-State 'RenameProbePending'
    try {
        Move-DirectoryWithRetry $Path $backup 'source rename probe'
        $script:renamed = $true
        Save-State 'BackupRenamed'
        Assert-CodexClosed
        if ($null -ne (Get-ItemIfPresent $Path)) {
            throw "Source path was recreated during rename preflight; original is retained at $backup."
        }
        Move-DirectoryWithRetry $backup $Path 'source probe restore'
        $script:renamed = $false
        Save-State $priorPhase
        Write-Log "[2/5 RENAME CHECK] Exact directory rename probe passed; original restored at: $Path"
    } catch {
        $primaryText = ''
        $primary = $_.Exception
        while ($null -ne $primary) {
            $part = ('{0}: {1} (HRESULT 0x{2:X8})' -f $primary.GetType().FullName,$primary.Message,$primary.HResult)
            if ($primaryText) { $primaryText += ' --> ' }
            $primaryText += $part
            $primary = $primary.InnerException
        }
        if ($script:renamed -and $null -eq (Get-ItemIfPresent $Path) -and (Test-Path -LiteralPath $backup -PathType Container)) {
            try {
                Move-DirectoryWithRetry $backup $Path 'source probe recovery'
                $script:renamed = $false
                Save-State $priorPhase
                Write-Log '[2/5 RENAME CHECK] Probe failed; original directory was restored.'
            } catch {
                $recovery = $_.Exception
                throw "Rename preflight failed: $primaryText. Original remains at '$backup'; restoration failed: $($recovery.Message)"
            }
        }
        if ($script:renamed) {
            throw "Rename preflight failed: $primaryText. Original is retained at '$backup'; source path is occupied and was not overwritten."
        }
        throw "Source rename preflight failed before copy; original path restored: $primaryText"
    }
}
function New-PreservedJunction([string]$Path, [string]$Target) {
    $existing = Get-ItemIfPresent $Path
    if ($null -ne $existing) {
        if ($existing.LinkType -eq 'Junction' -and @($existing.Target).Count -eq 1 -and
            (Test-SamePath ([string]@($existing.Target)[0]) $Target)) { return }
        throw "Junction path is occupied by an unexpected item: $Path"
    }
    if (Test-Path -LiteralPath $Target -PathType Container) {
        New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    } else {
        # Windows PowerShell 5.1 refuses dangling junctions; mklink preserves them.
        # Reject command-shell metacharacters instead of interpolating unsafe paths.
        if ($Path -match '[\r\n"%!\^&|<>]' -or $Target -match '[\r\n"%!\^&|<>]') {
            throw 'Unsupported characters in dangling junction path; source untouched.'
        }
        & "$env:SystemRoot\System32\cmd.exe" /d /c "mklink /J `"$Path`" `"$Target`"" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not preserve dangling junction: $Path" }
    }
    $created = Get-Item -LiteralPath $Path -Force
    if ($created.LinkType -ne 'Junction' -or @($created.Target).Count -ne 1 -or
        -not (Test-SamePath ([string]@($created.Target)[0]) $Target)) {
        throw "Created junction target mismatch: $Path"
    }
}
function Get-Manifest([string]$Base) {
    $files = @{}; $dirs = @{}; $links = @{}
    [long]$bytes = 0
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($Base)
    while ($stack.Count -gt 0) {
        $folder = New-Object IO.DirectoryInfo($stack.Pop())
        foreach ($entry in $folder.EnumerateFileSystemInfos()) {
            $relative = $entry.FullName.Substring($Base.Length + 1)
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $link = Get-Item -LiteralPath $entry.FullName -Force
                if ($link.LinkType -ne 'Junction' -or @($link.Target).Count -ne 1) {
                    throw "Unsupported reparse point; source untouched: $relative"
                }
                $links[$relative] = [string]@($link.Target)[0]
            } elseif (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $dirs[$relative] = $true
                $stack.Push($entry.FullName)
            } else {
                $files[$relative] = [pscustomobject]@{
                    Length = [long]$entry.Length
                    Ticks = $entry.LastWriteTimeUtc.Ticks
                    Attributes = [int]$entry.Attributes
                }
                $bytes += $entry.Length
            }
        }
    }
    [pscustomobject]@{ Files=$files; Directories=$dirs; Links=$links; Bytes=$bytes }
}
function Open-MigrationReadStream([string]$Path, [string]$Relative) {
    # Guards must have no remaining holder: merely allowing shared reads still
    # leaves their parent directory unable to rename on this workstation.
    $isGuard = $Relative -cmatch '^\.codex-provisioning-[0-9a-f]{16}\.guard$'
    $share = [IO.FileShare]::Read
    if ($isGuard) { $share = [IO.FileShare]::None }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    if ($isGuard -and $stream.Length -ne 0) {
        $stream.Dispose()
        throw "Provisioning guard is no longer empty; source untouched: $Relative"
    }
    return $stream
}
function Get-MigrationHash([string]$Path, [string]$Relative) {
    $stream = $null; $sha = $null
    try {
        $stream = Open-MigrationReadStream $Path $Relative
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
        if ($Relative -cmatch '^\.codex-provisioning-[0-9a-f]{16}\.guard$' -and $stream.Length -ne 0) {
            throw "Provisioning guard changed during verification: $Relative"
        }
        return $hash
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}
function Assert-SourceReadable($Manifest) {
    Write-Log '[2/5 READ CHECK] Checking all source files before copying; provisioning guards remain SHA-256 verified.'
    # Output can have been paused for minutes; reject a reopened app before
    # reading paths from the old inventory, including transient .tmp files.
    Assert-CodexClosed
    $done = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    foreach ($relative in $Manifest.Files.Keys) {
        $stream = $null
        try {
            $stream = Open-MigrationReadStream (Join-Path $source $relative) $relative
            if ($stream.Length -ne $Manifest.Files[$relative].Length) { throw "Source file length changed: $relative" }
        } finally { if ($null -ne $stream) { $stream.Dispose() } }
        $done++
        if ($timer.Elapsed.TotalSeconds -ge 3 -or $done -eq $Manifest.Files.Count) {
            Write-Log ("[2/5 READ CHECK] {0}/{1} files readable." -f $done, $Manifest.Files.Count)
            Assert-CodexClosed
            $timer.Restart()
        }
    }
}
function Assert-Manifests($Expected, $Actual, [switch]$CheckTimes) {
    if ($Expected.Files.Count -ne $Actual.Files.Count -or
        $Expected.Directories.Count -ne $Actual.Directories.Count -or
        $Expected.Links.Count -ne $Actual.Links.Count -or $Expected.Bytes -ne $Actual.Bytes) {
        throw 'File/directory/link counts or byte totals differ.'
    }
    foreach ($name in $Expected.Files.Keys) {
        if (-not $Actual.Files.ContainsKey($name) -or $Expected.Files[$name].Length -ne $Actual.Files[$name].Length) {
            throw "File inventory mismatch: $name"
        }
        if ($CheckTimes -and ($Expected.Files[$name].Ticks -ne $Actual.Files[$name].Ticks -or
            $Expected.Files[$name].Attributes -ne $Actual.Files[$name].Attributes)) {
            throw "Source changed after shutdown: $name"
        }
    }
    foreach ($name in $Expected.Directories.Keys) {
        if (-not $Actual.Directories.ContainsKey($name)) { throw "Directory missing: $name" }
    }
    foreach ($name in $Expected.Links.Keys) {
        if (-not $Actual.Links.ContainsKey($name) -or
            -not (Test-SamePath $Expected.Links[$name] $Actual.Links[$name])) {
            throw "Junction target mismatch: $name"
        }
    }
}
function Set-RootAccess {
    $sections = [Security.AccessControl.AccessControlSections]::Access
    $acl = Get-Acl -LiteralPath $source
    $newAcl = New-Object Security.AccessControl.DirectorySecurity
    $newAcl.SetSecurityDescriptorSddlForm($acl.GetSecurityDescriptorSddlForm($sections), $sections)
    # Retain source effective access; do not inherit broader E: permissions.
    $newAcl.SetAccessRuleProtection($true, $true)
    $directoryInfo = New-Object IO.DirectoryInfo($destination)
    $directoryInfo.SetAccessControl($newAcl)
}
function Get-AccessSignature([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}' -f $_.IdentityReference.Value, $_.AccessControlType,
            [int]$_.FileSystemRights, [int]$_.InheritanceFlags, [int]$_.PropagationFlags
    } | Sort-Object -Unique)
    $rules -join ';'
}
function Set-DirectoryAccess([string]$From, [string]$To, [switch]$Protect) {
    $sections = [Security.AccessControl.AccessControlSections]::Access
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm((Get-Acl -LiteralPath $From).GetSecurityDescriptorSddlForm($sections), $sections)
    if ($Protect) { $acl.SetAccessRuleProtection($true, $true) }
    (New-Object IO.DirectoryInfo($To)).SetAccessControl($acl)
    if ((Get-AccessSignature $From) -ne (Get-AccessSignature $To)) {
        throw "Could not preserve directory access permissions: $To"
    }
}
function Assert-ChildPath([string]$Path, [string]$Base) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $Path"
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    while (-not (Test-SamePath $parent $Base)) {
        $item = Get-ItemIfPresent $parent
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to traverse a reparse-point ancestor: $parent"
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}
function Prepare-PartialDestination($Expected) {
    $actual = Get-Manifest $destination
    $candidates = @{}
    foreach ($relative in $actual.Files.Keys) {
        if (-not $Expected.Files.ContainsKey($relative)) { $candidates[$relative] = $true }
    }
    foreach ($relative in $actual.Directories.Keys) {
        if (-not $Expected.Directories.ContainsKey($relative)) { $candidates[$relative] = $true }
    }
    foreach ($relative in $actual.Links.Keys) {
        if (-not $Expected.Links.ContainsKey($relative) -or
            -not (Test-SamePath $actual.Links[$relative] $Expected.Links[$relative])) {
            $candidates[$relative] = $true
        }
    }
    if ($candidates.Count -eq 0) { Write-Log '[2/5 RESUME] Existing partial copy has no obsolete or conflicting items.'; return }
    $quarantine = "$destination.retry-extras.$stamp"
    if ($null -ne (Get-ItemIfPresent $quarantine)) { throw 'Retry quarantine path already exists.' }
    $script:state.Quarantine = $quarantine
    Save-State 'Reconciling'
    [IO.Directory]::CreateDirectory($quarantine) | Out-Null
    Set-DirectoryAccess $source $quarantine -Protect
    $moved = New-Object 'Collections.Generic.List[string]'
    foreach ($relative in @($candidates.Keys | Sort-Object Length)) {
        $covered = $false
        foreach ($ancestor in $moved) {
            if ($relative.StartsWith(($ancestor + '\'), [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break }
        }
        if ($covered) { continue }
        Assert-CodexClosed
        $from = Join-Path $destination $relative
        $to = Join-Path $quarantine $relative
        Assert-ChildPath $from $destination
        Assert-ChildPath $to $quarantine
        $item = Get-Item -LiteralPath $from -Force
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to)) | Out-Null
        if ($item.PSIsContainer) { [IO.Directory]::Move($from, $to) }
        else { [IO.File]::Move($from, $to) }
        $moved.Add($relative)
        Write-Log "[2/5 RESUME] Preserved obsolete/conflicting target item: $relative"
    }
    Write-Log "[2/5 RESUME] $($moved.Count) items retained at: $quarantine"
    Save-State 'Prepared'
}
function Copy-SandboxBin {
    $from = Join-Path $source '.sandbox-bin'
    $to = Join-Path $destination '.sandbox-bin'
    # These executables inherit the sandbox directory DACL. Robocopy /COPY:S
    # fails on this actual DACL even though inherited target permissions match.
    # Fail closed if a future sandbox layout no longer has these properties.
    foreach ($item in (New-Object IO.DirectoryInfo($from)).EnumerateFileSystemInfos()) {
        if (($item.Attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) {
            throw 'Sandbox-bin layout changed; expected regular files only.'
        }
        $acl = Get-Acl -LiteralPath $item.FullName
        if ($acl.AreAccessRulesProtected -or @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])).Count -ne 0) {
            throw "Sandbox file has explicit permissions; source untouched: $($item.Name)"
        }
    }
    [IO.Directory]::CreateDirectory($to) | Out-Null
    Set-DirectoryAccess $from $to
    Write-Log '[3/5 SANDBOX] Copying sandbox executables with their original inherited permissions.'
    & "$env:SystemRoot\System32\robocopy.exe" $from $to /E /COPY:DAT /DCOPY:DAT /XJ /Z /R:2 /W:2 /TEE "/UNILOG+:$copyLog"
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "Sandbox copy failed with exit code $code; original untouched." }
}
function Restore-Original([string]$BackupPath) {
    if (-not (Test-SamePath (Split-Path $BackupPath -Parent) (Split-Path $source -Parent)) -or
        -not (Split-Path $BackupPath -Leaf).StartsWith(((Split-Path $source -Leaf) + '.before-migration.'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected backup path; recovery refused.'
    }
    $original = Get-ItemIfPresent $BackupPath
    if ($null -eq $original -or -not $original.PSIsContainer -or
        ($original.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Original backup is missing or is a reparse point.'
    }
    Assert-CodexClosed
    $current = Get-ItemIfPresent $source
    if ($null -ne $current) {
        if ($current.LinkType -ne 'Junction' -or @($current.Target).Count -ne 1 -or
            -not (Test-SamePath ([string]@($current.Target)[0]) $destination)) {
            throw 'Source is occupied by a real directory or unexpected link; neither copy was deleted.'
        }
        # Delete the verified junction itself only; never recurse into its target.
        [IO.Directory]::Delete($source, $false)
    }
    Move-DirectoryWithRetry $BackupPath $source 'original restore'
    Write-Log 'ROLLBACK OK: original directory restored; destination retained.'
}
try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another migration helper is running.' }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $consoleMessage = Disable-ConsoleQuickEdit
    Write-Log ("Migration helper v8 started. Console pause protection, sandbox-service pause/restore and rename retry ({0}s)." -f $renameRetryLimit)
    Write-Log $consoleMessage
    Write-Log "Source: $source"
    Write-Log "Destination: $destination"
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $prior = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if (-not (Test-SamePath $prior.Source $source) -or -not (Test-SamePath $prior.Destination $destination)) {
            throw 'Previous state belongs to other paths; refusing to continue.'
        }
        $pending = $prior.PSObject.Properties['SandboxServiceRestorePending']
        if ($null -ne $pending -and [bool]$pending.Value) {
            if ($prior.SandboxServiceName -ne $sandboxServiceName) { throw 'Unexpected sandbox service in saved state; recovery refused.' }
            $script:restoreSandboxService = $true
            $script:state = $prior
        }
        $current = Get-ItemIfPresent $source
        if ($prior.Phase -eq 'Completed' -and $null -ne $current -and $current.LinkType -eq 'Junction' -and
            (Test-SamePath ([string]@($current.Target)[0]) $destination) -and -not $RecoverOnly) {
            Write-Log 'Migration already completed. Original backup is retained.'
            $exitCode = 0
        } elseif (Test-Path -LiteralPath $prior.Backup -PathType Container) {
            $script:state = $prior
            Add-ServiceStateFields
            Pause-SandboxService
            Restore-Original $prior.Backup
            $script:state = $prior
            Save-State 'RolledBack'
            Write-Log 'Previous switch restored. Run again to attempt a fresh migration.'
            $exitCode = 0
        } elseif ($RecoverOnly) {
            if ($null -ne $current -and ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                Write-Log 'Original directory is already in place; no rollback needed.'
                $exitCode = 0
            } else { throw 'No recoverable original backup was found.' }
        }
    } elseif ($RecoverOnly) { throw 'No saved migration state; original data was not changed by this version.' }

    if ($exitCode -ne 0) {
        $sourceItem = Get-Item -LiteralPath $source -Force
        if (-not $sourceItem.PSIsContainer -or
            ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Source must be the original real directory.'
        }
        $destItem = Get-ItemIfPresent $destination
        if ($null -ne $destItem) {
            if (-not $destItem.PSIsContainer -or ($destItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Destination is not a real directory.'
            }
            if (@(Get-ChildItem -LiteralPath $destination -Force).Count -gt 0) {
                if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
                    throw 'Nonempty destination has no matching journal; preserved for inspection.'
                }
                $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                if ($saved.Phase -notin @('Prepared','Reconciling','Copying','Verified','RenameProbePending','RenamePending','RolledBack','FailedOriginalUnchanged')) {
                    throw 'Previous migration state does not permit safe reuse; both copies preserved.'
                }
                $reuseDestination = $true
                Write-Log 'Recognized partial destination; will reconcile and reuse it after Codex closes.'
            } else { Write-Log 'Reusing verified empty destination from the previous failed copy.' }
        }
        $script:state = [pscustomobject]@{
            Version=8; Source=$source; Destination=$destination; Backup=$backup
            Phase='Prepared'; Updated=''; Log=$logPath; CopyLog=$copyLog
            ReusedDestination=$reuseDestination; Quarantine=''
            SandboxServiceName=$sandboxServiceName; SandboxServiceRestorePending=$restoreSandboxService
        }
        Save-State 'Prepared'
        if (-not $testing) {
            while (@(Get-CodexProcesses).Count -gt 0) {
                $processes = @(Get-CodexProcesses)
                Write-Log ("[1/5 WAIT] Close Codex; keep this terminal open. PIDs: " + (($processes | ForEach-Object {$_.Id}) -join ', '))
                Start-Sleep -Seconds 3
            }
            Start-Sleep -Seconds 3
            Assert-CodexClosed
        }
        Pause-SandboxService
        Assert-SourceRenameAccess $source
        Write-Log '[2/5 INVENTORY] Capturing stopped source, including all SQLite/WAL/SHM files.'
        $baseline = Get-Manifest $source
        Write-Log ("Source: {0} files, {1} directories, {2} junctions, {3:N0} bytes." -f $baseline.Files.Count,$baseline.Directories.Count,$baseline.Links.Count,$baseline.Bytes)
        Assert-SourceReadable $baseline
        if (-not $destinationDriveName) { throw 'Destination must be on a local drive with a drive letter.' }
        $destinationDrive = Get-PSDrive -Name $destinationDriveName -ErrorAction Stop
        if ($destinationDrive.Free -lt ($baseline.Bytes + 2GB)) { throw "Insufficient free space on $destinationQualifier." }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Set-RootAccess
        if ($reuseDestination) { Prepare-PartialDestination $baseline }
        if ($testing -and $TestFailure -eq 'AfterReconcile') { throw 'TEST: interrupted after target reconciliation.' }
        Save-State 'Copying'
        if ($testing -and $TestFailure -eq 'CopyError') { throw 'TEST: simulated copy failure.' }
        Write-Log '[3/5 COPY] Copying data, attributes, timestamps and access permissions.'
        Write-Log "Detailed copy log: $copyLog"
        $copyArgs = @($source,$destination,'/E','/COPY:DATS','/DCOPY:DAT','/XJ','/Z','/R:2','/W:2','/TEE',"/UNILOG:$copyLog")
        $hasSandboxBin = $baseline.Directories.ContainsKey('.sandbox-bin')
        if ($hasSandboxBin) { $copyArgs += @('/XD',(Join-Path $source '.sandbox-bin'),(Join-Path $destination '.sandbox-bin')) }
        & "$env:SystemRoot\System32\robocopy.exe" @copyArgs
        $copyExit = $LASTEXITCODE
        if ($copyExit -ge 8) { throw "Robocopy failed with exit code $copyExit; original untouched." }
        if ($hasSandboxBin) { Copy-SandboxBin }
        Write-Log "Copy completed, code $copyExit. Recreating original junctions without copying their targets."
        foreach ($relative in $baseline.Links.Keys) {
            New-PreservedJunction (Join-Path $destination $relative) $baseline.Links[$relative]
        }
        Set-RootAccess
        if ($testing -and $TestFailure -eq 'CorruptCopy') {
            [IO.File]::WriteAllText((Join-Path $destination 'payload.txt'), 'bad!!')
        }
        Assert-CodexClosed
        $copied = Get-Manifest $destination
        Assert-Manifests $baseline $copied
        Write-Log '[4/5 VERIFY] Verifying every file SHA-256 and access permissions. Large files may take time.'
        $done = 0
        [long]$verifiedBytes = 0
        $timer = [Diagnostics.Stopwatch]::StartNew()
        foreach ($relative in $baseline.Files.Keys) {
            $left = Join-Path $source $relative
            $right = Join-Path $destination $relative
            if ((Get-MigrationHash $left $relative) -ne (Get-MigrationHash $right $relative)) {
                throw "SHA-256 mismatch: $relative"
            }
            if ((Get-AccessSignature $left) -ne (Get-AccessSignature $right)) { throw "Access permissions mismatch: $relative" }
            $done++
            $verifiedBytes += $baseline.Files[$relative].Length
            if ($timer.Elapsed.TotalSeconds -ge 3 -or $done -eq $baseline.Files.Count) {
                Write-Log ("[4/5 VERIFY] {0}/{1} files; {2:N2}/{3:N2} GiB verified." -f $done,$baseline.Files.Count,($verifiedBytes/1GB),($baseline.Bytes/1GB))
                Assert-CodexClosed
                $timer.Restart()
            }
        }
        foreach ($relative in @('') + @($baseline.Directories.Keys)) {
            $left = if ($relative) {Join-Path $source $relative} else {$source}
            $right = if ($relative) {Join-Path $destination $relative} else {$destination}
            if ((Get-AccessSignature $left) -ne (Get-AccessSignature $right)) { throw "Directory access permissions mismatch: $relative" }
        }
        if ($testing -and $TestFailure -eq 'SourceChanged') {
            [IO.File]::WriteAllText((Join-Path $source 'unexpected.txt'), 'simulated writer')
        }
        Assert-Manifests $baseline (Get-Manifest $source) -CheckTimes
        Assert-CodexClosed
        if ($testing -and $TestFailure -eq 'Reopen') { throw 'TEST: simulated Codex reopening; switch cancelled.' }
        Save-State 'Verified'
        Write-Log '[5/5 SWITCH] Checks passed; retaining original as backup, then creating root junction.'
        Assert-SourceRenameAccess $source
        Save-State 'RenamePending'
        Move-DirectoryWithRetry $source $backup 'final source rename'
        $renamed = $true
        Save-State 'BackupRenamed'
        if ($testing -and $TestFailure -eq 'AfterRename') { throw 'TEST: failure after source rename.' }
        New-Item -ItemType Junction -Path $source -Target $destination | Out-Null
        Save-State 'JunctionCreated'
        if ($testing -and $TestFailure -eq 'AfterJunction') { throw 'TEST: failure after junction creation.' }
        $link = Get-Item -LiteralPath $source -Force
        if ($link.LinkType -ne 'Junction' -or -not (Test-SamePath ([string]@($link.Target)[0]) $destination)) {
            throw 'Root junction target verification failed.'
        }
        Assert-Manifests $baseline (Get-Manifest $source)
        Save-State 'Completed'
        Write-Log 'Switch verified; restoring original sandbox service state before reporting success.'
        Write-Log "Original retained at: $backup"
        Write-Log 'C: space is NOT freed yet. Verify Codex before removing the original backup separately.'
        $exitCode = 0
    }
} catch {
    $exception = $_.Exception
    $failure = ('{0}: {1} (HRESULT 0x{2:X8})' -f $exception.GetType().FullName,$exception.Message,$exception.HResult)
    if ($null -ne $exception.InnerException) {
        $failure += (' Inner: {0}: {1} (HRESULT 0x{2:X8})' -f $exception.InnerException.GetType().FullName,$exception.InnerException.Message,$exception.InnerException.HResult)
    }
    try { Write-Log "FAILED: $failure"; Write-Log $_.ScriptStackTrace } catch { Write-Host "FAILED: $failure" }
    if ($renamed) {
        try {
            Restore-Original $backup
            if ($null -ne $state) { Save-State 'RolledBack' }
        } catch {
            Write-Host "RECOVERY REQUIRED: $($_.Exception.Message)"
            Write-Host "Original retained at: $backup"
            try { Save-State 'RecoveryRequired' } catch {}
        }
    } elseif ($null -ne $state -and $state.Phase -notin @('Completed','RolledBack')) {
        try { Save-State 'FailedOriginalUnchanged' } catch {}
    }
    $exitCode = 1
} finally {
    try { Restore-SandboxService }
    catch {
        $restoreError = $_.Exception.Message
        $exitCode = 1
        if ($renamed) {
            Write-Host "Service restoration failed after switch: $restoreError"
            Write-Host 'Attempting to restore the original directory, then its sandbox service.'
            try {
                # A failed start can leave the service running or transitioning.
                # Stop that exact service before moving the original back.
                $script:servicePaused = $false
                Pause-SandboxService
                Restore-Original $backup
                $renamed = $false
                Save-State 'RolledBack'
                $script:restoreSandboxService = $true
                $script:state.SandboxServiceRestorePending = $true
                Save-State 'RolledBack'
                Restore-SandboxService
                Write-Host 'ROLLBACK OK: original directory and sandbox service restored after startup failure.'
            } catch {
                Write-Host "RECOVERY REQUIRED: $($_.Exception.Message)"
                if ($renamed) { try { Save-State 'RecoveryRequired' } catch {} }
                Write-Host 'Run this helper with -RecoverOnly from the external terminal while Codex is closed.'
            }
        } else {
            Write-Host "SERVICE RECOVERY REQUIRED: $restoreError"
            Write-Host 'Run this helper with -RecoverOnly from the external terminal while Codex is closed.'
        }
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Restore-ConsoleQuickEdit
}
if ($exitCode -eq 0 -and $null -ne $state -and $state.Phase -eq 'Completed') {
    Write-Log 'SUCCESS: migration completed and sandbox service restored. Codex may now be opened.'
}
Write-Host "Log: $logPath"
exit $exitCode
