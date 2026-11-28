[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\QLHarness'),
    [switch]$NoShortcut,
    [switch]$NonInteractive,
    [switch]$NoRegistration
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repository = 'TeamOasis7/QL_harness'
$root = [IO.Path]::GetFullPath($InstallRoot)
$pins = [Collections.Generic.List[IDisposable]]::new()
if (-not ('QLBootstrapPin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class QLBootstrapPin {
    [StructLayout(LayoutKind.Sequential)] struct Info { public uint attr,c0,c1,a0,a1,w0,w1,volume,highSize,lowSize,links,high,low; }
    [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32")] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info info);
    [DllImport("kernel32",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int type,ref int data,uint size);
    [DllImport("kernel32",CharSet=CharSet.Unicode)] static extern bool CreateDirectoryW(string path,IntPtr security);
    public static SafeFileHandle Pin(string path,bool directory) {
        var h=CreateFileW(path,directory?0x80u:0x80000000u,directory?3u:1u,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        Info i;
        if(h.IsInvalid || !GetFileInformationByHandle(h,out i) || (i.attr&0x400)!=0 || ((i.attr&0x10)!=0)!=directory || (!directory && i.links!=1)) {
            h.Dispose(); throw new InvalidOperationException("Unsafe install path");
        }
        return h;
    }
    public static SafeFileHandle PinForDelete(string path) {
        var h=CreateFileW(path,0x80010000u,1u,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        Info i;
        if(h.IsInvalid||!GetFileInformationByHandle(h,out i)||(i.attr&0x410)!=0||i.links!=1){h.Dispose();throw new InvalidOperationException("Unsafe legacy shortcut");}
        return h;
    }
    public static void DeletePinned(SafeFileHandle handle,string identity,string hash) {
        if(Identity(handle)!=identity||HashPinned(handle)!=hash) throw new InvalidOperationException("Legacy shortcut changed; preserving it");
        int remove=1;
        if(!SetFileInformationByHandle(handle,4,ref remove,4)) throw new InvalidOperationException("Cannot remove legacy shortcut");
    }
    public static string Identity(SafeFileHandle handle) {
        Info i;
        if(!GetFileInformationByHandle(handle,out i)) throw new InvalidOperationException("Cannot identify legacy shortcut");
        return i.volume+":"+i.high+":"+i.low+":"+i.c0+":"+i.c1;
    }
    public static string HashPinned(SafeFileHandle handle) {
        using(var borrowed=new SafeFileHandle(handle.DangerousGetHandle(),false))
        using(var stream=new System.IO.FileStream(borrowed,System.IO.FileAccess.Read))
        using(var sha=System.Security.Cryptography.SHA256.Create()) {
            if(stream.Length>1048576) throw new InvalidOperationException("Legacy shortcut exceeds size limit");
            stream.Position=0;
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","");
        }
    }
    public static void NewDirectory(string path) {
        if(!CreateDirectoryW(path,IntPtr.Zero)) throw new InvalidOperationException("Cannot create install directory");
    }
    public static void Replace(string source,string destination) {
        System.IO.File.Replace(source,destination,null);
    }
}
'@
}
function Ensure-PinnedDirectory([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { [QLBootstrapPin]::NewDirectory($path) }
    $pins.Add([QLBootstrapPin]::Pin($path,$true))
}
function File-Hash([string]$path) {
    $handle = [QLBootstrapPin]::Pin($path,$false)
    $stream = [IO.FileStream]::new($handle,[IO.FileAccess]::Read)
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
        finally { $hash.Dispose() }
    } finally { $stream.Dispose() }
}
function Bytes-Hash([byte[]]$bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Atomic-Bytes([string]$path,[byte[]]$bytes) {
    $temp = $path + '.new-' + [Guid]::NewGuid().ToString('N')
    $file = [IO.File]::Open($temp,'CreateNew','Write','None')
    try { $file.Write($bytes,0,$bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    if (Test-Path -LiteralPath $path) { [QLBootstrapPin]::Replace($temp,$path) }
    else { [IO.File]::Move($temp,$path) }
}
function Gh-Json([string[]]$arguments) {
    $raw = & $gh @arguments
    if ($LASTEXITCODE -ne 0) { throw 'GitHub request failed. Check account access to the private repository.' }
    $text = $raw -join "`n"
    if ($text.Length -gt 2097152) { throw 'GitHub response exceeds limit' }
    return ($text | ConvertFrom-Json)
}
function Ensure-NodrShortcut([string]$desktop,[string]$installation,$shell) {
    $shortcutPath=Join-Path $desktop 'NODR.lnk'
    if(Test-Path -LiteralPath $shortcutPath){
        $pins.Add([QLBootstrapPin]::Pin($shortcutPath,$false))
        if($shell.CreateShortcut($shortcutPath).TargetPath -ine (Join-Path $installation 'Harness.cmd')){throw 'Existing desktop shortcut points elsewhere; preserving it'}
        return
    }
    $stage=Join-Path $desktop ('.ql-harness-'+[Guid]::NewGuid().ToString('N')+'.lnk')
    if(Test-Path -LiteralPath $stage){throw 'Shortcut staging collision'}
    $shortcut=$shell.CreateShortcut($stage)
    $shortcut.TargetPath=Join-Path $installation 'Harness.cmd'
    $shortcut.WorkingDirectory=$installation
    $shortcut.Description='NODR'
    $shortcut.IconLocation=Join-Path $installation 'assets/nodr.ico'
    $shortcut.Save()
    $stagePin=[QLBootstrapPin]::Pin($stage,$false)
    $stagePin.Dispose()
    [IO.File]::Move($stage,$shortcutPath)
}
function Remove-LegacyShortcut([string]$path,[string]$target,$shell,[string]$installation) {
    # WScript cannot load a link while a DELETE-access handle is open. Bind identity
    # under a read lock, then reacquire DELETE access and require the same object.
    $readHandle=[QLBootstrapPin]::Pin($path,$false)
    try {
        $identity=[QLBootstrapPin]::Identity($readHandle)
        $hash=[QLBootstrapPin]::HashPinned($readHandle)
        $same=$shell.CreateShortcut($path).TargetPath -ieq $target
    } finally {$readHandle.Dispose()}
    if(-not $same){return}
    if($installation){Ensure-NodrShortcut (Split-Path -Parent $path) $installation $shell}
    $handle=[QLBootstrapPin]::PinForDelete($path)
    try {
        [QLBootstrapPin]::DeletePinned($handle,$identity,$hash)
    } finally {$handle.Dispose()}
}
try {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'NODR requires 64-bit Windows' }
    if ($root -eq [IO.Path]::GetPathRoot($root)) { throw 'Choose an application installation directory' }
    $chain = [Collections.Generic.List[string]]::new()
    $ancestor = [IO.DirectoryInfo]::new($root)
    while ($ancestor) { $chain.Insert(0,$ancestor.FullName); $ancestor=$ancestor.Parent }
    $rootExisted = Test-Path -LiteralPath $root
    foreach ($directory in $chain) { Ensure-PinnedDirectory $directory }
    $marker = Join-Path $root '.ql-harness-install.json'
    $oldFiles = @{}
    $portableTool = $null
    if ($rootExisted) {
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Existing directory is not a NODR installation; choose another InstallRoot' }
        $markerPin = [QLBootstrapPin]::Pin($marker,$false)
        $markerPin.Dispose()
        if ((Get-Item -LiteralPath $marker).Length -gt 16384) { throw 'Invalid install marker size' }
        $old = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($old.schema -cne 'ql-harness-user-install/v1' -or $old.repository -cne $repository) { throw 'Invalid installation marker' }
        foreach ($entry in $old.files.PSObject.Properties) { $oldFiles[$entry.Name] = $entry.Value }
        $portableTool = $old.tool
    } else {
        $initial = @{schema='ql-harness-user-install/v1';repository=$repository;files=@{}}
        Atomic-Bytes $marker ([Text.Encoding]::UTF8.GetBytes(($initial | ConvertTo-Json -Compress)))
    }
    Ensure-PinnedDirectory (Join-Path $root 'scripts')
    Ensure-PinnedDirectory (Join-Path $root 'assets')
    $ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ghCommand) { $gh = $ghCommand.Source }
    elseif ($portableTool) {
        if ($portableTool.path -isnot [string] -or $portableTool.sha256 -isnot [string] -or
            $portableTool.path -cnotmatch '^\.tools/gh-[a-f0-9]{32}/gh\.exe$' -or $portableTool.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid cached GitHub CLI binding' }
        $gh = Join-Path $root $portableTool.path
        $pins.Add([QLBootstrapPin]::Pin((Join-Path $root '.tools'),$true))
        $pins.Add([QLBootstrapPin]::Pin((Split-Path -Parent $gh),$true))
        if ((File-Hash $gh) -cne $portableTool.sha256) { throw 'Cached GitHub CLI was changed; preserving it' }
    }
    else {
        Ensure-PinnedDirectory (Join-Path $root '.tools')
        $toolStage = Join-Path $root ('.tools\gh-' + [Guid]::NewGuid().ToString('N'))
        Ensure-PinnedDirectory $toolStage
        Write-Host 'Downloading the official portable GitHub CLI...'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Headers @{'User-Agent'='QL-Harness-Installer'} -TimeoutSec 60
        if ($release.tag_name -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Unexpected GitHub CLI version' }
        $version = $release.tag_name.Substring(1)
        $architecture = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
        $archiveName = 'gh_' + $version + '_windows_' + $architecture + '.zip'
        $checksumsName = 'gh_' + $version + '_checksums.txt'
        $downloadBase = 'https://github.com/cli/cli/releases/download/' + $release.tag_name + '/'
        foreach ($name in @($archiveName,$checksumsName)) {
            $asset = @($release.assets | Where-Object { $_.name -ceq $name })
            if ($asset.Count -ne 1 -or $asset[0].browser_download_url -cne ($downloadBase+$name)) { throw 'Unexpected official GitHub CLI asset' }
            if ($asset[0].size -gt 67108864) { throw 'GitHub CLI asset too large' }
            Invoke-WebRequest -UseBasicParsing -Uri ($downloadBase+$name) -OutFile (Join-Path $toolStage $name) -TimeoutSec 120
        }
        $checksumLines = @(Get-Content -LiteralPath (Join-Path $toolStage $checksumsName) | Where-Object { $_ -cmatch ('^[a-f0-9]{64}\s+'+[regex]::Escape($archiveName)+'$') })
        if ($checksumLines.Count -ne 1 -or (File-Hash (Join-Path $toolStage $archiveName)) -cne $checksumLines[0].Substring(0,64)) { throw 'GitHub CLI archive checksum mismatch' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $toolStage $archiveName))
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)' -or $entry.Length -gt 134217728) { throw 'Unsafe GitHub CLI archive entry' }
            }
            $binaries = @($zip.Entries | Where-Object { $_.FullName -ceq ('gh_'+$version+'_windows_'+$architecture+'/bin/gh.exe') -or $_.FullName -ceq 'bin/gh.exe' })
            if ($binaries.Count -ne 1) { throw 'GitHub CLI executable missing from archive' }
            $gh = Join-Path $toolStage 'gh.exe'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($binaries[0],$gh,$false)
        } finally { $zip.Dispose() }
        $portableTool = @{path=('.tools/'+[IO.Path]::GetFileName($toolStage)+'/gh.exe');sha256=(File-Hash $gh)}
    }
    $ghPin = [QLBootstrapPin]::Pin($gh,$false)
    $pins.Add($ghPin)
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $gh auth status --hostname github.com *> $null
        $authExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrorPreference }
    if ($authExit -ne 0) {
        if ($NonInteractive) { throw 'GitHub authentication is required; rerun interactively to sign in' }
        Write-Host 'Sign in with a GitHub account that can access your private NODR repository.'
        & $gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication was not completed' }
    }
    $commit = Gh-Json @('api','--hostname','github.com',('repos/'+$repository+'/commits/main'))
    if ($commit.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid private repository commit' }
    $sourcePaths = [ordered]@{
        'latest-verified-release.json'='latest-verified-release.json'
        'Install.cmd'='Install.cmd'
        'Harness.cmd'='Harness.cmd'
        'scripts/install-verified-release.ps1'='scripts/install-verified-release.ps1'
        'scripts/open-verified-release.ps1'='scripts/open-verified-release.ps1'
        'scripts/uninstall-user-install.ps1'='scripts/uninstall-user-install.ps1'
        'assets/nodr.ico'='apps/harness-desktop/assets/nodr.ico'
    }
    $names = @($sourcePaths.Keys)
    $prepared = @{}
    foreach ($name in $names) {
        $sourcePath = $sourcePaths[$name]
        $entry = Gh-Json @('api','--hostname','github.com',('repos/'+$repository+'/contents/'+$sourcePath+'?ref='+$commit.sha))
        if ($entry.type -cne 'file' -or $entry.path -cne $sourcePath -or $entry.encoding -cne 'base64' -or $entry.size -gt 262144) { throw 'Invalid private installation file' }
        $bytes = [Convert]::FromBase64String($entry.content)
        $sha1 = [Security.Cryptography.SHA1]::Create()
        try {
            $header = [Text.Encoding]::ASCII.GetBytes('blob '+$bytes.Length+[char]0)
            $blob = New-Object byte[] ($header.Length+$bytes.Length)
            [Array]::Copy($header,0,$blob,0,$header.Length); [Array]::Copy($bytes,0,$blob,$header.Length,$bytes.Length)
            $gitHash = [BitConverter]::ToString($sha1.ComputeHash($blob)).Replace('-','').ToLowerInvariant()
        } finally { $sha1.Dispose() }
        if ($gitHash -cne $entry.sha -or $bytes.Length -ne $entry.size) { throw 'Private installation file Git hash mismatch' }
        $target = Join-Path $root $name
        $newHash = Bytes-Hash $bytes
        if (Test-Path -LiteralPath $target) {
            $observed = File-Hash $target
            if ($observed -cne $newHash -and (!$oldFiles.ContainsKey($name) -or $observed -cne $oldFiles[$name])) { throw ('Existing file was changed; preserving '+$name) }
        }
        $prepared[$name] = @{bytes=$bytes;hash=$newHash}
    }
    $newFiles = @{}
    foreach ($name in $names) {
        $target = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $target) -or (File-Hash $target) -cne $prepared[$name].hash) { Atomic-Bytes $target $prepared[$name].bytes }
        $newFiles[$name] = $prepared[$name].hash
    }
    $releasePointer=[Text.Encoding]::UTF8.GetString($prepared['latest-verified-release.json'].bytes)|ConvertFrom-Json
    $state = @{schema='ql-harness-user-install/v1';repository=$repository;commit=$commit.sha;files=$newFiles;tool=$portableTool;release=$releasePointer}
    Atomic-Bytes $marker ([Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 4 -Compress)))
    $savedPath = $env:PATH
    $savedGhHost = $env:GH_HOST
    try {
        $env:PATH = (Split-Path -Parent $gh) + ';' + $savedPath
        $env:GH_HOST = 'github.com'
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\install-verified-release.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'NODR executable installation failed' }
    } finally { $env:PATH = $savedPath; $env:GH_HOST = $savedGhHost }
    if (-not $NoShortcut) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $desktopChain = [Collections.Generic.List[string]]::new()
        $ancestor = [IO.DirectoryInfo]::new($desktop)
        while ($ancestor) { $desktopChain.Insert(0,$ancestor.FullName); $ancestor=$ancestor.Parent }
        foreach ($directory in $desktopChain) { $pins.Add([QLBootstrapPin]::Pin($directory,$true)) }
        $shell = New-Object -ComObject WScript.Shell
        Ensure-NodrShortcut $desktop $root $shell
        # Remove only former product links that still resolve to this installation.
        foreach($legacyDesktop in @($desktop,(Join-Path $env:USERPROFILE 'Desktop'))|Select-Object -Unique){
            if(-not(Test-Path -LiteralPath $legacyDesktop -PathType Container)){continue}
            $legacyChain=[Collections.Generic.List[string]]::new()
            $legacyAncestor=[IO.DirectoryInfo]::new($legacyDesktop)
            while($legacyAncestor){$legacyChain.Insert(0,$legacyAncestor.FullName);$legacyAncestor=$legacyAncestor.Parent}
            foreach($directory in $legacyChain){$pins.Add([QLBootstrapPin]::Pin($directory,$true))}
            $legacyLink=Join-Path $legacyDesktop 'QL Harness.lnk'
            if(Test-Path -LiteralPath $legacyLink){
                Remove-LegacyShortcut $legacyLink (Join-Path $root 'Harness.cmd') $shell $root
            }
        }
    }
    if(-not $NoRegistration){
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\uninstall-user-install.ps1') -Register -NonInteractive
        if($LASTEXITCODE -ne 0){throw 'NODR application registration failed'}
    }
    Write-Host ('NODR installed. Open '+(Join-Path $root 'Harness.cmd'))
} finally {
    foreach ($pin in $pins) { $pin.Dispose() }
}
