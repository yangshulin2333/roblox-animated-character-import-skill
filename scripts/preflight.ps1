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
$blockers = @()
$warnings = @()

if (Test-Path -LiteralPath $Source) {
    $resolvedSource = (Resolve-Path -LiteralPath $Source).Path
    $item = Get-Item -LiteralPath $resolvedSource
    if ($item.PSIsContainer) {
        $sourceType = 'directory'
        $sourceCandidates = @(
            Get-ChildItem -LiteralPath $resolvedSource -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension.ToLowerInvariant() -in @('.blend', '.fbx', '.glb', '.gltf', '.obj') } |
                Select-Object -ExpandProperty FullName
        )
        if ($sourceCandidates.Count -eq 0) {
            $blockers += [pscustomobject][ordered]@{ code = 'NO_MODEL_FILE'; message = 'The directory contains no supported model file.' }
        } else {
            $warnings += [pscustomobject][ordered]@{ code = 'SELECT_SOURCE_FILE'; message = 'Choose one exact source file before running conversion.' }
        }
    } else {
        $extension = $item.Extension.ToLowerInvariant()
        if ($extension -eq '.zip') {
            $sourceType = 'zip'
            $warnings += [pscustomobject][ordered]@{ code = 'EXTRACT_REQUIRED'; message = 'Inventory and safely extract the ZIP before Blender conversion.' }
        } elseif ($extension -in @('.blend', '.fbx', '.glb', '.gltf', '.obj')) {
            $sourceType = $extension.TrimStart('.')
            $sourceCandidates = @($resolvedSource)
        } else {
            $sourceType = $extension.TrimStart('.')
            $blockers += [pscustomobject][ordered]@{ code = 'UNSUPPORTED_SOURCE'; message = "Unsupported source extension: $extension" }
        }
    }
} else {
    $blockers += [pscustomobject][ordered]@{ code = 'SOURCE_NOT_FOUND'; message = "Source does not exist: $Source" }
}

$resolvedBlender = Resolve-BlenderExecutable -ExplicitPath $BlenderPath
if (-not $resolvedBlender) {
    $blockers += [pscustomobject][ordered]@{ code = 'BLENDER_NOT_FOUND'; message = 'Pass -BlenderPath, set BLENDER_EXE, or install Blender.' }
}

$studioPath = Find-RobloxStudio
if ($RequireStudio -and -not $studioPath) {
    $blockers += [pscustomobject][ordered]@{ code = 'ROBLOX_STUDIO_NOT_FOUND'; message = 'Roblox Studio was not found on this computer.' }
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
                $warnings += [pscustomobject][ordered]@{ code = 'LOW_DISK_SPACE'; message = 'Less than 1 GiB is free on the output drive.' }
            }
        } catch {
            $warnings += [pscustomobject][ordered]@{ code = 'FREE_SPACE_UNKNOWN'; message = 'Could not determine output drive free space.' }
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
