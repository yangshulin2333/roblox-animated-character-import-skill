[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [string]$BlenderPath,

    [string]$OutputDir,

    [string]$ReportPath,

    [switch]$RequireStudio
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-BlenderExecutable {
    param([string]$ExplicitPath)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ExplicitPath) { $candidates.Add($ExplicitPath) }
    if ($env:BLENDER_EXE) { $candidates.Add($env:BLENDER_EXE) }

    $command = Get-Command blender -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }

    $roots = @(
        'C:\Program Files\Blender Foundation',
        (Join-Path $env:LOCALAPPDATA 'Programs\Blender Foundation')
    )
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Filter blender.exe -File -Recurse -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Find-RobloxStudio {
    $command = Get-Command RobloxStudioBeta -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $versions = Join-Path $env:LOCALAPPDATA 'Roblox\Versions'
    if (Test-Path -LiteralPath $versions) {
        $match = Get-ChildItem -LiteralPath $versions -Filter RobloxStudioBeta.exe -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    return $null
}

$resolvedSource = $null
$sourceType = 'missing'
$sourceCandidates = @()
$candidateDetails = @()
$nativeDccFiles = @()
$textureCandidates = @()
$detectedProjects = @()
$blockers = @()
$warnings = @()

$blenderReadableExtensions = @('.blend', '.fbx', '.glb', '.gltf', '.obj')
$nativeDccExtensions = @('.max', '.ma', '.mb', '.c4d', '.uasset', '.uproject')
$textureExtensions = @('.png', '.jpg', '.jpeg', '.tga', '.bmp', '.dds', '.exr', '.tif', '.tiff')
$derivedPathPattern = '(?i)(^|[\\/])(RobloxExport|Roblox_Ready|_RobloxIntake|_extracted)([\\/]|$)|_Roblox\.(fbx|blend|glb|gltf)$'

function Get-CandidatePriority {
    param([string]$Extension)
    switch ($Extension.ToLowerInvariant()) {
        '.blend' { return 100 }
        '.fbx' { return 80 }
        '.glb' { return 70 }
        '.gltf' { return 65 }
        '.obj' { return 20 }
        default { return 0 }
    }
}

function Get-Inventory {
    param([string]$Root)

    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue)
    $sourceFiles = @($files | Where-Object { $_.FullName -notmatch $derivedPathPattern })
    $script:sourceCandidates = @(
        $sourceFiles |
            Where-Object { $_.Extension.ToLowerInvariant() -in $blenderReadableExtensions } |
            Sort-Object @{ Expression = { Get-CandidatePriority $_.Extension }; Descending = $true }, FullName |
            Select-Object -ExpandProperty FullName
    )
    $script:candidateDetails = @(
        $sourceFiles |
            Where-Object { $_.Extension.ToLowerInvariant() -in $blenderReadableExtensions } |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path = $_.FullName
                    extension = $_.Extension.ToLowerInvariant()
                    priority_hint = Get-CandidatePriority $_.Extension
                    size_bytes = [int64]$_.Length
                    last_write_utc = $_.LastWriteTimeUtc.ToString('o')
                }
            } |
            Sort-Object @{ Expression = 'priority_hint'; Descending = $true }, path
    )
    $script:nativeDccFiles = @(
        $sourceFiles |
            Where-Object { $_.Extension.ToLowerInvariant() -in $nativeDccExtensions } |
            Select-Object -ExpandProperty FullName
    )
    $script:textureCandidates = @(
        $sourceFiles |
            Where-Object { $_.Extension.ToLowerInvariant() -in $textureExtensions } |
            Select-Object -ExpandProperty FullName
    )

    if ((Test-Path -LiteralPath (Join-Path $Root 'ProjectSettings') -PathType Container) -or
        @($sourceFiles | Where-Object { $_.Extension.ToLowerInvariant() -in @('.unity', '.anim', '.controller', '.prefab') }).Count -gt 0) {
        $script:detectedProjects += 'Unity'
    }
    if (@($sourceFiles | Where-Object { $_.Extension.ToLowerInvariant() -eq '.uproject' }).Count -gt 0 -or
        @($sourceFiles | Where-Object { $_.Extension.ToLowerInvariant() -eq '.uasset' }).Count -gt 0) {
        $script:detectedProjects += 'Unreal'
    }
    if (@($sourceFiles | Where-Object { $_.Extension.ToLowerInvariant() -eq '.max' }).Count -gt 0) {
        $script:detectedProjects += '3dsMax'
    }
    if (@($sourceFiles | Where-Object { $_.Extension.ToLowerInvariant() -eq '.blend' }).Count -gt 0) {
        $script:detectedProjects += 'Blender'
    }
    $script:detectedProjects = @($script:detectedProjects | Select-Object -Unique)
}

if (Test-Path -LiteralPath $Source) {
    $resolvedSource = (Resolve-Path -LiteralPath $Source).Path
    $item = Get-Item -LiteralPath $resolvedSource
    if ($item.PSIsContainer) {
        $sourceType = 'directory'
        Get-Inventory -Root $resolvedSource
        if ($sourceCandidates.Count -eq 0) {
            if ($nativeDccFiles.Count -gt 0) {
                $blockers += [pscustomobject][ordered]@{ code = 'NATIVE_DCC_EXPORT_REQUIRED'; message = '只找到原生 DCC/引擎资源，需要先从对应软件导出 FBX 或 glTF。' }
            } else {
                $blockers += [pscustomobject][ordered]@{ code = 'NO_MODEL_FILE'; message = '目录中没有找到 Blender 可读取的模型文件。' }
            }
        } else {
            $warnings += [pscustomobject][ordered]@{ code = 'INSPECT_ALL_CANDIDATES'; message = '不能只按扩展名选择；需要逐个检测，并优先保留骨架、动作、UV、材质和贴图关系最完整的文件。' }
        }
    } else {
        $extension = $item.Extension.ToLowerInvariant()
        if ($extension -eq '.zip') {
            $sourceType = 'zip'
            $warnings += [pscustomobject][ordered]@{ code = 'EXTRACT_REQUIRED'; message = '需要先清点并安全解压 ZIP，再进入 Blender 转换。' }
        } elseif ($extension -in $blenderReadableExtensions) {
            $sourceType = $extension.TrimStart('.')
            $sourceCandidates = @($resolvedSource)
            $candidateDetails = @([pscustomobject][ordered]@{
                path = $resolvedSource
                extension = $extension
                priority_hint = Get-CandidatePriority $extension
                size_bytes = [int64]$item.Length
                last_write_utc = $item.LastWriteTimeUtc.ToString('o')
            })
            $parent = Split-Path -Parent $resolvedSource
            if ($parent) {
                $textureCandidates = @(
                    Get-ChildItem -LiteralPath $parent -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension.ToLowerInvariant() -in $textureExtensions } |
                        Select-Object -ExpandProperty FullName
                )
            }
        } elseif ($extension -in $nativeDccExtensions) {
            $sourceType = $extension.TrimStart('.')
            $nativeDccFiles = @($resolvedSource)
            $blockers += [pscustomobject][ordered]@{ code = 'NATIVE_DCC_EXPORT_REQUIRED'; message = "原生源文件 $extension 必须先通过对应 DCC/编辑器导出为 FBX 或 glTF。" }
        } else {
            $sourceType = $extension.TrimStart('.')
            $blockers += [pscustomobject][ordered]@{ code = 'UNSUPPORTED_SOURCE'; message = "暂不支持该源文件扩展名：$extension" }
        }
    }
} else {
    $blockers += [pscustomobject][ordered]@{ code = 'SOURCE_NOT_FOUND'; message = "找不到原始资源：$Source" }
}

$resolvedBlender = Resolve-BlenderExecutable -ExplicitPath $BlenderPath
if (-not $resolvedBlender) {
    $blockers += [pscustomobject][ordered]@{ code = 'BLENDER_NOT_FOUND'; message = '找不到 Blender。请传入 -BlenderPath、设置 BLENDER_EXE，或安装 Blender。' }
}

$studioPath = Find-RobloxStudio
if ($RequireStudio -and -not $studioPath) {
    $blockers += [pscustomobject][ordered]@{ code = 'ROBLOX_STUDIO_NOT_FOUND'; message = '这台电脑上没有找到 Roblox Studio。' }
}

$resolvedOutput = $null
$freeBytes = $null
if ($OutputDir) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputDir)
    $probe = $resolvedOutput
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
    if ($probe -and (Test-Path -LiteralPath $probe)) {
        try {
            $root = [System.IO.Path]::GetPathRoot($probe).TrimEnd('\').TrimEnd(':')
            $drive = Get-PSDrive -Name $root -ErrorAction Stop
            $freeBytes = [int64]$drive.Free
            if ($freeBytes -lt 1073741824) {
                $warnings += [pscustomobject][ordered]@{ code = 'LOW_DISK_SPACE'; message = '输出磁盘剩余空间不足 1 GiB。' }
            }
        } catch {
            $warnings += [pscustomobject][ordered]@{ code = 'FREE_SPACE_UNKNOWN'; message = '无法确定输出磁盘的剩余空间。' }
        }
    }
}

$preflightStatus = if ($blockers.Count -eq 0) { 'PREFLIGHT_PASS' } else { 'PREFLIGHT_BLOCKED' }
$result = [ordered]@{
    schema_version = '1.0'
    status = $preflightStatus
    computer = [ordered]@{
        name = $env:COMPUTERNAME
        os = [System.Environment]::OSVersion.VersionString
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    source = [ordered]@{
        requested_path = $Source
        resolved_path = $resolvedSource
        type = $sourceType
        candidates = $sourceCandidates
        candidate_details = $candidateDetails
        native_dcc_files = $nativeDccFiles
        texture_candidates = $textureCandidates
        detected_projects = $detectedProjects
    }
    blender = [ordered]@{
        path = $resolvedBlender
    }
    roblox_studio = [ordered]@{
        path = $studioPath
        required = [bool]$RequireStudio
        mcp_connection = 'not_tested_by_preflight'
    }
    output = [ordered]@{
        path = $resolvedOutput
        free_bytes = $freeBytes
    }
    blockers = @($blockers)
    warnings = @($warnings)
}

$json = $result | ConvertTo-Json -Depth 8
if ($ReportPath) {
    $absoluteReport = [System.IO.Path]::GetFullPath($ReportPath)
    $parent = Split-Path -Parent $absoluteReport
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($absoluteReport, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}
$json
if ($blockers.Count -gt 0) { exit 2 }
