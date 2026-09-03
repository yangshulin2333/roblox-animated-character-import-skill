[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [string]$WorkDir,

    [string]$ReportPath,

    [string]$ArchiveToolPath,

    [switch]$Extract,

    [switch]$HashSources
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Issue {
    param(
        [string]$Code,
        [string]$MessageZh,
        [string]$MessageEn = '',
        $Details = $null
    )
    [pscustomobject][ordered]@{
        code = $Code
        message_zh = $MessageZh
        message_en = $MessageEn
        details = $Details
    }
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $absolute = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $absolute
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($absolute, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    return $json
}

function Get-FilePrefix {
    param([string]$Path, [int]$Count = 512)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $Count
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -eq $buffer.Length) { return $buffer }
        if ($read -eq 0) { return [byte[]]@() }
        return [byte[]]$buffer[0..($read - 1)]
    } finally {
        $stream.Dispose()
    }
}

function Get-GzipPayloadInfo {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $gzip = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Decompress)
    try {
        $buffer = New-Object byte[] 512
        $read = $gzip.Read($buffer, 0, $buffer.Length)
        $entryName = if ($read -gt 0) {
            [System.Text.Encoding]::ASCII.GetString($buffer, 0, [Math]::Min(100, $read)).Trim([char]0)
        } else { '' }
        $tarMagic = if ($read -ge 263) { [System.Text.Encoding]::ASCII.GetString($buffer, 257, 6).Trim([char]0) } else { '' }
        [pscustomobject][ordered]@{
            is_tar = $tarMagic -eq 'ustar'
            first_entry = $entryName
            looks_like_unitypackage = ($tarMagic -eq 'ustar' -and $entryName -match '^[0-9a-fA-F]{32}(/|$)')
        }
    } finally {
        $gzip.Dispose()
        $stream.Dispose()
    }
}

function Get-ContainerType {
    param([System.IO.FileInfo]$File)
    $prefix = Get-FilePrefix -Path $File.FullName
    $extension = $File.Extension.ToLowerInvariant()
    $hex = (($prefix | Select-Object -First 16 | ForEach-Object { $_.ToString('X2') }) -join ' ')
    $ascii = if ($prefix.Count -gt 0) { [System.Text.Encoding]::ASCII.GetString($prefix) } else { '' }

    $type = 'unknown'
    $details = [ordered]@{}
    if ($prefix.Count -ge 8 -and $prefix[0] -eq 0x52 -and $prefix[1] -eq 0x61 -and $prefix[2] -eq 0x72 -and $prefix[3] -eq 0x21 -and $prefix[6] -eq 0x01) {
        $type = 'rar5'
    } elseif ($prefix.Count -ge 7 -and $prefix[0] -eq 0x52 -and $prefix[1] -eq 0x61 -and $prefix[2] -eq 0x72 -and $prefix[3] -eq 0x21) {
        $type = 'rar'
    } elseif ($prefix.Count -ge 6 -and $prefix[0] -eq 0x37 -and $prefix[1] -eq 0x7A -and $prefix[2] -eq 0xBC -and $prefix[3] -eq 0xAF -and $prefix[4] -eq 0x27 -and $prefix[5] -eq 0x1C) {
        $type = '7z'
    } elseif ($prefix.Count -ge 4 -and $prefix[0] -eq 0x50 -and $prefix[1] -eq 0x4B -and $prefix[2] -in @(0x03, 0x05, 0x07) -and $prefix[3] -in @(0x04, 0x06, 0x08)) {
        $type = 'zip'
    } elseif ($prefix.Count -ge 2 -and $prefix[0] -eq 0x1F -and $prefix[1] -eq 0x8B) {
        try {
            $gzipInfo = Get-GzipPayloadInfo -Path $File.FullName
            $details.gzip_payload = $gzipInfo
            if ($gzipInfo.looks_like_unitypackage -or $extension -eq '.unitypackage') {
                $type = 'unitypackage'
            } elseif ($gzipInfo.is_tar) {
                $type = 'tar-gzip'
            } else {
                $type = 'gzip'
            }
        } catch {
            $type = 'gzip-corrupt'
            $details.gzip_error = $_.Exception.Message
        }
    } elseif ($prefix.Count -ge 263 -and [System.Text.Encoding]::ASCII.GetString($prefix, 257, 5) -eq 'ustar') {
        $type = 'tar'
    } elseif ($ascii.StartsWith('Kaydara FBX Binary')) {
        $type = 'fbx'
    } elseif ($prefix.Count -ge 4 -and [System.Text.Encoding]::ASCII.GetString($prefix, 0, 4) -eq 'glTF') {
        $type = 'glb'
    } elseif ($extension -in @('.fbx', '.blend', '.glb', '.gltf', '.obj', '.max', '.ma', '.mb', '.c4d', '.uasset', '.uproject')) {
        $type = $extension.TrimStart('.')
    }

    [pscustomobject][ordered]@{
        type = $type
        signature_hex = $hex
        extension = $extension
        details = $details
    }
}

function Test-SafeRelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.Replace('\', '/').Trim()
    if ($normalized.StartsWith('/') -or $normalized.StartsWith('\\') -or $normalized -match '^[A-Za-z]:') { return $false }
    foreach ($part in $normalized.Split('/')) {
        if ($part -eq '..') { return $false }
    }
    return $true
}

function Resolve-ChildPath {
    param([string]$Root, [string]$RelativePath)
    if (-not (Test-SafeRelativePath -Path $RelativePath)) { throw "检测到不安全的压缩包路径：$RelativePath" }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and $candidate -ne $rootFull) {
        throw "压缩包路径超出工作区：$RelativePath"
    }
    return $candidate
}

function Resolve-ArchiveTool {
    param([string]$ExplicitPath)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ExplicitPath) { $candidates.Add($ExplicitPath) }
    foreach ($known in @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe',
        'D:\Applications\7-Zip\7z.exe'
    )) { $candidates.Add($known) }
    foreach ($name in @('7zz.exe', '7z.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { $candidates.Add($command.Source) }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-FreeBytesForPath {
    param([string]$Path)
    $probe = [System.IO.Path]::GetFullPath($Path)
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
    if (-not $probe -or -not (Test-Path -LiteralPath $probe)) { return $null }
    try {
        $driveName = [System.IO.Path]::GetPathRoot($probe).TrimEnd('\').TrimEnd(':')
        return [int64](Get-PSDrive -Name $driveName -ErrorAction Stop).Free
    } catch {
        return $null
    }
}

function Get-MultipartGroup {
    param([System.IO.FileInfo]$File)
    $match = [regex]::Match($File.Name, '^(?<stem>.+)\.part(?<index>\d+)\.rar$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $stem = $match.Groups['stem'].Value
    $members = @(
        Get-ChildItem -LiteralPath $File.DirectoryName -File |
            Where-Object { $_.Name -match ('^' + [regex]::Escape($stem) + '\.part\d+\.rar$') } |
            ForEach-Object {
                $m = [regex]::Match($_.Name, '\.part(?<index>\d+)\.rar$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                [pscustomobject][ordered]@{ index = [int]$m.Groups['index'].Value; path = $_.FullName; size_bytes = [int64]$_.Length }
            } |
            Sort-Object index
    )
    $missing = New-Object System.Collections.Generic.List[int]
    if ($members.Count -gt 0) {
        foreach ($expected in 1..([int]$members[-1].index)) {
            if ($expected -notin @($members.index)) { $missing.Add($expected) }
        }
    }
    [pscustomobject][ordered]@{
        id = $stem
        type = 'rar-multipart'
        entry_path = if ($members.Count -gt 0) { [string]$members[0].path } else { $File.FullName }
        members = $members
        missing_parts = $missing.ToArray()
        total_size_bytes = [int64](($members | Measure-Object size_bytes -Sum).Sum)
    }
}

function Get-DirectoryArchiveGroups {
    param([string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue)
    $groups = New-Object System.Collections.Generic.List[object]
    $seenMultipart = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $multipart = Get-MultipartGroup -File $file
        if ($multipart) {
            if ($seenMultipart.Add([string]$multipart.id)) { $groups.Add($multipart) }
            continue
        }
        $kind = Get-ContainerType -File $file
        if ($kind.type -in @('zip', '7z', 'rar', 'rar5', 'unitypackage', 'tar-gzip', 'tar')) {
            $groups.Add([pscustomobject][ordered]@{
                id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                type = $kind.type
                entry_path = $file.FullName
                members = @([pscustomobject][ordered]@{ index = 1; path = $file.FullName; size_bytes = [int64]$file.Length })
                missing_parts = @()
                total_size_bytes = [int64]$file.Length
            })
        }
    }
    return $groups.ToArray()
}

function Get-TarEntries {
    param([string]$ArchivePath, [bool]$Gzip)
    $tar = (Get-Command tar.exe -ErrorAction SilentlyContinue).Source
    if (-not $tar) { throw '找不到 Windows tar.exe，无法读取 TAR/GZIP 资源包。' }
    $arguments = if ($Gzip) { @('-tzf', $ArchivePath) } else { @('-tf', $ArchivePath) }
    $output = @(& $tar @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw (($output | Select-Object -Last 8) -join [Environment]::NewLine) }
    return @($output | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function Expand-TarArchiveSafe {
    param([string]$ArchivePath, [string]$Destination, [bool]$Gzip)
    $entries = Get-TarEntries -ArchivePath $ArchivePath -Gzip $Gzip
    foreach ($entry in $entries) {
        if (-not (Test-SafeRelativePath -Path $entry)) { throw "压缩包包含不安全路径：$entry" }
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tar = (Get-Command tar.exe -ErrorAction Stop).Source
    $arguments = if ($Gzip) { @('-xzf', $ArchivePath, '-C', $Destination) } else { @('-xf', $ArchivePath, '-C', $Destination) }
    $output = @(& $tar @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($output | Select-Object -Last 8) -join [Environment]::NewLine) }
    return $entries
}

function Expand-ZipArchiveSafe {
    param([string]$ArchivePath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
        foreach ($entryName in $entryNames) {
            if (-not (Test-SafeRelativePath -Path $entryName)) { throw "ZIP 包含不安全路径：$entryName" }
        }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        foreach ($entry in $archive.Entries) {
            $target = Resolve-ChildPath -Root $Destination -RelativePath $entry.FullName
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            $parent = Split-Path -Parent $target
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
        return $entryNames
    } finally {
        $archive.Dispose()
    }
}

function Expand-SevenZipArchiveSafe {
    param([string]$ArchivePath, [string]$Destination, [string]$ToolPath)
    $listing = @(& $ToolPath l -slt -- $ArchivePath 2>&1)
    $listExit = $LASTEXITCODE
    if ($listExit -ne 0) { throw (($listing | Select-Object -Last 12) -join [Environment]::NewLine) }
    $entryNames = New-Object System.Collections.Generic.List[string]
    foreach ($line in $listing) {
        $text = [string]$line
        if ($text.StartsWith('Path = ')) {
            $path = $text.Substring(7)
            if ($path -and $path -ne $ArchivePath -and $path -ne [System.IO.Path]::GetFileName($ArchivePath)) {
                $entryNames.Add($path)
            }
        }
    }
    foreach ($entryName in $entryNames) {
        if (-not (Test-SafeRelativePath -Path $entryName)) { throw "压缩包包含不安全路径：$entryName" }
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $output = @(& $ToolPath x -y ("-o$Destination") -- $ArchivePath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($output | Select-Object -Last 12) -join [Environment]::NewLine) }
    return $entryNames.ToArray()
}

function Convert-UnityPackageLayout {
    param([string]$RawRoot, [string]$NormalizedRoot)
    New-Item -ItemType Directory -Force -Path $NormalizedRoot | Out-Null
    $records = New-Object System.Collections.Generic.List[object]
    $conflicts = New-Object System.Collections.Generic.List[string]
    foreach ($pathnameFile in Get-ChildItem -LiteralPath $RawRoot -Recurse -File -Filter 'pathname' -ErrorAction SilentlyContinue) {
        $logical = [System.IO.File]::ReadAllText($pathnameFile.FullName, [System.Text.Encoding]::UTF8)
        $logical = ($logical -replace '(\r?\n00)+\s*$', '').Trim([char]0, [char]13, [char]10, ' ')
        if (-not (Test-SafeRelativePath -Path $logical)) { throw "UnityPackage 包含不安全逻辑路径：$logical" }
        $asset = Join-Path $pathnameFile.DirectoryName 'asset'
        $assetMeta = Join-Path $pathnameFile.DirectoryName 'asset.meta'
        $destination = Resolve-ChildPath -Root $NormalizedRoot -RelativePath $logical
        $assetExists = Test-Path -LiteralPath $asset -PathType Leaf
        if ($assetExists) {
            $parent = Split-Path -Parent $destination
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $conflicts.Add($logical)
            } else {
                Copy-Item -LiteralPath $asset -Destination $destination
            }
            if (Test-Path -LiteralPath $assetMeta -PathType Leaf) {
                Copy-Item -LiteralPath $assetMeta -Destination ($destination + '.meta') -Force
            }
        } else {
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
        }
        $records.Add([pscustomobject][ordered]@{
            guid = $pathnameFile.Directory.Name
            logical_path = $logical
            asset_exists = [bool]$assetExists
            asset_size_bytes = if ($assetExists) { [int64](Get-Item -LiteralPath $asset).Length } else { 0 }
        })
    }
    [pscustomobject][ordered]@{
        record_count = $records.Count
        records = $records.ToArray()
        conflicts = $conflicts.ToArray()
    }
}

function Get-InventorySummary {
    param([string]$Root, [string]$ExactFile)
    $portableExtensions = @('.blend', '.fbx', '.glb', '.gltf', '.obj')
    $nativeExtensions = @('.max', '.ma', '.mb', '.c4d', '.uasset', '.uproject')
    $textureExtensions = @('.png', '.jpg', '.jpeg', '.tga', '.bmp', '.dds', '.exr', '.tif', '.tiff', '.psd')
    if ($ExactFile) {
        $files = @(Get-Item -LiteralPath $ExactFile)
    } else {
        $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)
    }
    $derivedPattern = '(?i)(^|[\\/])(RobloxExport|Roblox_Ready|_RobloxIntake|_extracted)([\\/]|$)|_Roblox\.(fbx|blend|glb|gltf)$'
    $portable = @($files | Where-Object { $_.Extension.ToLowerInvariant() -in $portableExtensions -and $_.FullName -notmatch $derivedPattern })
    $native = @($files | Where-Object { $_.Extension.ToLowerInvariant() -in $nativeExtensions })
    $textures = @($files | Where-Object { $_.Extension.ToLowerInvariant() -in $textureExtensions })
    $archives = @($files | Where-Object { $_.Extension.ToLowerInvariant() -in @('.zip', '.rar', '.7z', '.gz', '.tgz', '.unitypackage') })
    $extensionCounts = @(
        $files |
            Group-Object { $_.Extension.ToLowerInvariant() } |
            Sort-Object Count -Descending |
            ForEach-Object { [pscustomobject][ordered]@{ extension = $_.Name; count = $_.Count } }
    )
    $ecosystems = New-Object System.Collections.Generic.List[string]
    if ((Test-Path -LiteralPath (Join-Path $Root 'ProjectSettings') -PathType Container) -or @($files | Where-Object { $_.Extension.ToLowerInvariant() -in @('.unity', '.anim', '.controller', '.prefab') }).Count -gt 0) { $ecosystems.Add('Unity') }
    if (@($files | Where-Object { $_.Extension.ToLowerInvariant() -in @('.uproject', '.uasset') }).Count -gt 0) { $ecosystems.Add('Unreal') }
    if (@($files | Where-Object { $_.Extension.ToLowerInvariant() -eq '.max' }).Count -gt 0) { $ecosystems.Add('3dsMax') }
    if (@($files | Where-Object { $_.Extension.ToLowerInvariant() -eq '.blend' }).Count -gt 0) { $ecosystems.Add('Blender') }
    $groups = @(
        $portable |
            Sort-Object FullName |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    id = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                    candidate = $_.FullName
                    extension = $_.Extension.ToLowerInvariant()
                    size_bytes = [int64]$_.Length
                    status = 'PENDING_CONTENT_AUDIT'
                    status_zh = '等待模型、骨架、动画和贴图检测'
                }
            }
    )
    [pscustomobject][ordered]@{
        root = $Root
        file_count = $files.Count
        extension_counts = $extensionCounts
        detected_ecosystems = @($ecosystems.ToArray() | Select-Object -Unique)
        portable_candidates = @($portable | ForEach-Object { $_.FullName })
        native_files = @($native | ForEach-Object { $_.FullName })
        texture_candidates = @($textures | ForEach-Object { $_.FullName })
        nested_archives = @($archives | ForEach-Object { $_.FullName })
        asset_groups = $groups
    }
}

$blockers = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[object]
$resourceGroups = @()
$resolvedSource = $null
$container = $null
$normalizedSource = $null
$normalizedRoot = $null
$inventory = $null
$unityManifest = $null
$archiveEntries = @()
$archiveTool = Resolve-ArchiveTool -ExplicitPath $ArchiveToolPath
$freeBytes = $null
$minimumFreeBytes = $null

if (-not $WorkDir) {
    $WorkDir = Join-Path $env:TEMP ('roblox-source-intake-' + [guid]::NewGuid().ToString('N'))
}
$resolvedWorkDir = [System.IO.Path]::GetFullPath($WorkDir)
if (-not $ReportPath) { $ReportPath = Join-Path $resolvedWorkDir 'source_intake.json' }

if (-not (Test-Path -LiteralPath $Source)) {
    $blockers.Add((New-Issue 'SOURCE_NOT_FOUND' "找不到原始资源：$Source" 'Source does not exist.'))
} else {
    $resolvedSource = (Resolve-Path -LiteralPath $Source).Path
    $item = Get-Item -LiteralPath $resolvedSource
    if ($item.PSIsContainer) {
        $resourceGroups = @(Get-DirectoryArchiveGroups -Root $resolvedSource)
        $visibleModelFiles = @(Get-ChildItem -LiteralPath $resolvedSource -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLowerInvariant() -in @('.blend', '.fbx', '.glb', '.gltf', '.obj', '.max', '.uasset', '.uproject') -and $_.FullName -notmatch '(?i)_Roblox\.(fbx|blend|glb|gltf)$' })
        if ($resourceGroups.Count -eq 0) {
            $container = [pscustomobject][ordered]@{ type = 'directory'; signature_hex = ''; extension = ''; details = [ordered]@{} }
            $normalizedSource = $resolvedSource
            $normalizedRoot = $resolvedSource
        } elseif ($resourceGroups.Count -eq 1 -and $visibleModelFiles.Count -eq 0) {
            $group = $resourceGroups[0]
            if (@($group.missing_parts).Count -gt 0) {
                $blockers.Add((New-Issue 'ARCHIVE_MULTIPART_INCOMPLETE' ("分卷压缩包不完整，缺少：" + (@($group.missing_parts) -join ', ')) 'Multipart archive is incomplete.'))
            } else {
                $resolvedSource = [string]$group.entry_path
                $item = Get-Item -LiteralPath $resolvedSource
                $container = Get-ContainerType -File $item
                if ($group.type -eq 'rar-multipart') { $container.type = 'rar-multipart' }
            }
        } else {
            $blockers.Add((New-Issue 'SOURCE_SELECTION_REQUIRED' "目录中同时存在多个原始资源组或模型源，需要先选择一个资源组后再转换。" 'Select one source group before conversion.'))
        }
    } else {
        $container = Get-ContainerType -File $item
        $multipart = Get-MultipartGroup -File $item
        if ($multipart) {
            $resourceGroups = @($multipart)
            if (@($multipart.missing_parts).Count -gt 0) {
                $blockers.Add((New-Issue 'ARCHIVE_MULTIPART_INCOMPLETE' ("分卷压缩包不完整，缺少：" + (@($multipart.missing_parts) -join ', ')) 'Multipart archive is incomplete.'))
            } else {
                $resolvedSource = [string]$multipart.entry_path
                $item = Get-Item -LiteralPath $resolvedSource
                $container.type = 'rar-multipart'
            }
        }
    }
}

if ($blockers.Count -eq 0 -and $container -and -not $normalizedSource) {
    $portableKinds = @('fbx', 'blend', 'glb', 'gltf', 'obj', 'max', 'ma', 'mb', 'c4d', 'uasset', 'uproject')
    if ($container.type -in $portableKinds) {
        $normalizedSource = $resolvedSource
        $normalizedRoot = Split-Path -Parent $resolvedSource
    } elseif ($container.type -in @('unitypackage', 'tar-gzip', 'tar', 'zip', '7z', 'rar', 'rar5', 'rar-multipart')) {
        if (-not $Extract) {
            $warnings.Add((New-Issue 'EXTRACTION_NOT_REQUESTED' '已识别资源包，但尚未解包。使用 -Extract 才能继续内容审计。' 'Container identified; extraction was not requested.'))
        } else {
            $compressedBytes = if ($resourceGroups.Count -eq 1) { [int64]$resourceGroups[0].total_size_bytes } else { [int64](Get-Item -LiteralPath $resolvedSource).Length }
            $minimumFreeBytes = [int64][Math]::Max(1073741824, $compressedBytes * 2)
            $freeBytes = Get-FreeBytesForPath -Path $resolvedWorkDir
            if ($null -ne $freeBytes -and $freeBytes -lt $minimumFreeBytes) {
                $blockers.Add((New-Issue 'INSUFFICIENT_DISK_SPACE' "检测工作区空间不足。至少预留 $minimumFreeBytes 字节，当前约有 $freeBytes 字节。" 'Insufficient free space for safe extraction.'))
            } elseif ($null -eq $freeBytes) {
                $warnings.Add((New-Issue 'FREE_SPACE_UNKNOWN' '无法确认检测工作区剩余空间；大型压缩包可能在解包过程中失败。' 'Could not determine free space.'))
            }
            if ($blockers.Count -gt 0) {
                $normalizedSource = $null
            } else {
            $rawRoot = Join-Path $resolvedWorkDir 'raw'
            $normalizedRoot = Join-Path $resolvedWorkDir 'normalized'
            try {
                switch ($container.type) {
                    'unitypackage' {
                        $archiveEntries = @(Expand-TarArchiveSafe -ArchivePath $resolvedSource -Destination $rawRoot -Gzip $true)
                        $unityManifest = Convert-UnityPackageLayout -RawRoot $rawRoot -NormalizedRoot $normalizedRoot
                    }
                    'tar-gzip' {
                        $archiveEntries = @(Expand-TarArchiveSafe -ArchivePath $resolvedSource -Destination $normalizedRoot -Gzip $true)
                    }
                    'tar' {
                        $archiveEntries = @(Expand-TarArchiveSafe -ArchivePath $resolvedSource -Destination $normalizedRoot -Gzip $false)
                    }
                    'zip' {
                        $archiveEntries = @(Expand-ZipArchiveSafe -ArchivePath $resolvedSource -Destination $normalizedRoot)
                    }
                    default {
                        if (-not $archiveTool) {
                            throw '找不到支持 RAR/7z 的新版 7-Zip。请安装新版 7-Zip，或通过 -ArchiveToolPath 指定 7z.exe/7zz.exe。'
                        }
                        $archiveEntries = @(Expand-SevenZipArchiveSafe -ArchivePath $resolvedSource -Destination $normalizedRoot -ToolPath $archiveTool)
                    }
                }
                $normalizedSource = $normalizedRoot
            } catch {
                $rawError = $_.Exception.Message
                $code = if ($container.type -in @('rar', 'rar5', 'rar-multipart', '7z') -and $rawError -match 'Can not open|Unsupported|找不到支持') { 'EXTRACTOR_REQUIRED' } else { 'ARCHIVE_EXTRACTION_FAILED' }
                $messageZh = if ($code -eq 'EXTRACTOR_REQUIRED') {
                    '当前解包工具过旧、缺失或不支持该 RAR5/7z 格式。请安装新版 7-Zip，或通过 -ArchiveToolPath 指定新版 7z.exe/7zz.exe。'
                } else {
                    '原始资源包读取失败，请查看 details.raw_error。'
                }
                $blockers.Add((New-Issue $code $messageZh 'Archive extraction failed.' ([ordered]@{ raw_error = $rawError; archive_tool = $archiveTool })))
            }
            }
        }
    } elseif ($container.type -eq 'gzip') {
        $blockers.Add((New-Issue 'GZIP_PAYLOAD_UNSUPPORTED' '这是 GZIP 文件，但内部不是可识别的 TAR/UnityPackage，暂时不能作为模型资源处理。' 'GZIP payload is not a supported TAR resource.'))
    } elseif ($container.type -eq 'gzip-corrupt') {
        $blockers.Add((New-Issue 'ARCHIVE_CORRUPT' 'GZIP 文件损坏或无法读取。' 'GZIP is corrupt or unreadable.'))
    } else {
        $blockers.Add((New-Issue 'UNSUPPORTED_SOURCE_CONTAINER' ("无法识别原始资源类型：" + $container.type) 'Unsupported source container.'))
    }
}

if ($normalizedSource -and (Test-Path -LiteralPath $normalizedSource)) {
    $normalizedItem = Get-Item -LiteralPath $normalizedSource
    $inventoryRoot = if ($normalizedItem.PSIsContainer) { $normalizedSource } else { Split-Path -Parent $normalizedSource }
    $inventory = Get-InventorySummary -Root $inventoryRoot -ExactFile $(if ($normalizedItem.PSIsContainer) { $null } else { $normalizedSource })
    if (@($inventory.nested_archives).Count -gt 0) {
        $warnings.Add((New-Issue 'NESTED_ARCHIVES_FOUND' '标准化目录中还存在嵌套压缩包，本轮不会自动递归解包。' 'Nested archives were found and were not recursively extracted.'))
    }
}

$sourceFilesForHash = @()
if ($resourceGroups.Count -eq 1) {
    $sourceFilesForHash = @($resourceGroups[0].members | ForEach-Object { [string]$_.path })
} elseif ($resolvedSource -and (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
    $sourceFilesForHash = @($resolvedSource)
}
$sourceIdentity = @(
    foreach ($path in $sourceFilesForHash) {
        $file = Get-Item -LiteralPath $path
        [pscustomobject][ordered]@{
            path = $file.FullName
            size_bytes = [int64]$file.Length
            last_write_utc = $file.LastWriteTimeUtc.ToString('o')
            sha256 = if ($HashSources) { (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        }
    }
)

$status = 'SOURCE_INTAKE_BLOCKED'
$statusZh = '原始资源接收被阻止'
$nextActionZh = '根据阻止原因补齐文件、选择资源组或安装解包工具。'
if ($blockers.Count -eq 0 -and $normalizedSource) {
    $status = 'SOURCE_NORMALIZED'
    $statusZh = '原始资源已标准化，可以进入内容审计'
    $nextActionZh = '继续检测模型、三角面、骨架、动画、材质和贴图。'
} elseif ($blockers.Count -eq 0 -and $container) {
    $status = 'CONTAINER_IDENTIFIED'
    $statusZh = '已识别原始资源类型，尚未解包'
    $nextActionZh = '使用 -Extract 生成只用于检测的标准化工作目录。'
} elseif ($blockers.Count -gt 0) {
    switch ([string]$blockers[0].code) {
        'EXTRACTOR_REQUIRED' { $nextActionZh = '安装新版 7-Zip，或用 -ArchiveToolPath 指定支持 RAR5 的 7z.exe/7zz.exe，然后只重试原始资源接收阶段。' }
        'ARCHIVE_MULTIPART_INCOMPLETE' { $nextActionZh = '补齐缺失分卷，并确保所有分卷位于同一目录后重新检测。' }
        'SOURCE_SELECTION_REQUIRED' { $nextActionZh = '先从报告的 resource_groups 中选择一个资源组，再以该文件或目录重新运行。' }
        'SOURCE_NOT_FOUND' { $nextActionZh = '确认资源实际路径，并在接收方电脑使用本机绝对路径重新运行。' }
        'INSUFFICIENT_DISK_SPACE' { $nextActionZh = '把 -WorkDir 改到空间更充足的磁盘后重试；不要删除或修改原始资源。' }
    }
}

$archiveEntrySample = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $archiveEntries) {
    if ($archiveEntrySample.Count -ge 100) { break }
    $archiveEntrySample.Add([string]$entry)
}

$report = [ordered]@{
    schema_version = '1.0'
    status = $status
    status_zh = $statusZh
    requested_source = $Source
    resolved_source = $resolvedSource
    source_identity = $sourceIdentity
    container = $container
    resource_groups = $resourceGroups
    work_dir = $resolvedWorkDir
    extraction_requested = [bool]$Extract
    archive_tool = $archiveTool
    disk_space = [ordered]@{
        free_bytes_before_extraction = $freeBytes
        minimum_required_bytes = $minimumFreeBytes
        estimate_note_zh = '最低预留按压缩包总大小的两倍计算；高压缩率资源仍可能需要更多空间。'
    }
    archive_entry_count = @($archiveEntries).Count
    archive_entry_sample = $archiveEntrySample.ToArray()
    normalized_source = $normalizedSource
    normalized_root = $normalizedRoot
    unitypackage = $unityManifest
    inventory = $inventory
    blockers = $blockers.ToArray()
    warnings = $warnings.ToArray()
    next_action_zh = $nextActionZh
    note_zh = '标准化工作目录只是检测与转换中间区，不会修改原始资源，也不是 Roblox Studio 的另存副本。'
}

$json = Write-Utf8Json -Value $report -Path $ReportPath
$json
if ($blockers.Count -gt 0) { exit 2 }
