[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$PrefabDirectory,

    [Parameter(Mandatory = $true)]
    [string]$MaterialDirectory,

    [Parameter(Mandatory = $true)]
    [string]$TextureDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($path in @($SourceRoot, $PrefabDirectory, $MaterialDirectory, $TextureDirectory)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Required Unity directory does not exist: $path"
    }
}

$resolvedRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputDir)
$appearanceDir = Join-Path $resolvedOutput 'appearances'
$manifestPath = Join-Path $resolvedOutput 'appearance_manifest.json'
if ((Test-Path -LiteralPath $manifestPath) -and -not $Resume) {
    throw "Appearance manifest already exists; refusing to overwrite: $manifestPath"
}
if (Test-Path -LiteralPath $appearanceDir) {
    $existing = @(Get-ChildItem -LiteralPath $appearanceDir -Force)
    if ($existing.Count -gt 0 -and -not $Resume) {
        throw "Appearance directory is not empty; refusing to overwrite: $appearanceDir"
    }
} else {
    New-Item -ItemType Directory -Path $appearanceDir | Out-Null
}

$allFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File)
$guidToAsset = @{}
$assetToGuid = @{}
foreach ($meta in @($allFiles | Where-Object Extension -eq '.meta')) {
    $match = Select-String -LiteralPath $meta.FullName -Pattern '^guid:\s*([0-9a-f]{32})' | Select-Object -First 1
    if ($match) {
        $guid = $match.Matches[0].Groups[1].Value
        $asset = $meta.FullName.Substring(0, $meta.FullName.Length - 5)
        $guidToAsset[$guid] = $asset
        $assetToGuid[$asset] = $guid
    }
}

$entries = [Collections.Generic.List[object]]::new()
$errors = [Collections.Generic.List[object]]::new()
$materialCatalog = [Collections.Generic.List[object]]::new()
$materialByPath = @{}
$catalogTextures = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$prefabMaterials = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$resolvedMaterialDirectory = (Resolve-Path -LiteralPath $MaterialDirectory).Path
$resolvedTextureDirectory = (Resolve-Path -LiteralPath $TextureDirectory).Path

foreach ($material in @(Get-ChildItem -LiteralPath $MaterialDirectory -File -Filter '*.mat' | Sort-Object Name)) {
    $materialText = Get-Content -LiteralPath $material.FullName -Raw -Encoding UTF8
    $mainTex = [regex]::Match($materialText, '(?ms)-\s+_MainTex:.*?m_Texture:\s*\{fileID:\s*\d+,\s*guid:\s*([0-9a-f]{32})')
    if (-not $mainTex.Success -or -not $guidToAsset.ContainsKey($mainTex.Groups[1].Value)) {
        $errors.Add([ordered]@{ material = $material.Name; code = 'MAINTEX_UNRESOLVED' })
        continue
    }
    $texturePath = [string]$guidToAsset[$mainTex.Groups[1].Value]
    if (-not $texturePath.StartsWith($resolvedTextureDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        $errors.Add([ordered]@{ material = $material.Name; code = 'MAINTEX_OUTSIDE_TEXTURE_DIR'; texture = $texturePath })
        continue
    }

    $destination = Join-Path $appearanceDir ([IO.Path]::GetFileName($texturePath))
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $texturePath -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            throw "Existing appearance texture differs from the audited source: $destination"
        }
    } else {
        Copy-Item -LiteralPath $texturePath -Destination $destination
    }
    [void]$catalogTextures.Add($texturePath)
    $record = [pscustomobject][ordered]@{
        material = $material.FullName.Substring($resolvedRoot.Length + 1).Replace('\', '/')
        texture = "appearances/$([IO.Path]::GetFileName($texturePath))"
        texture_sha256 = (Get-FileHash -LiteralPath $texturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $materialCatalog.Add($record)
    $materialByPath[$material.FullName] = $record
}

$prefabs = @(Get-ChildItem -LiteralPath $PrefabDirectory -File -Filter '*.prefab' | Sort-Object Name)
foreach ($prefab in $prefabs) {
    $prefabText = Get-Content -LiteralPath $prefab.FullName -Raw -Encoding UTF8
    $materialPaths = [Collections.Generic.List[string]]::new()
    foreach ($guidMatch in [regex]::Matches($prefabText, 'guid:\s*([0-9a-f]{32})')) {
        $guid = $guidMatch.Groups[1].Value
        if ($guidToAsset.ContainsKey($guid)) {
            $resolved = [string]$guidToAsset[$guid]
            if ([IO.Path]::GetExtension($resolved) -eq '.mat' -and $resolved.StartsWith($resolvedMaterialDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not $materialPaths.Contains($resolved)) { $materialPaths.Add($resolved) }
            }
        }
    }
    if ($materialPaths.Count -eq 0) {
        $errors.Add([ordered]@{
            prefab = $prefab.Name
            code = 'MATERIAL_LINK_MISSING'
        })
        continue
    }
    $resolvedMaterials = [Collections.Generic.List[object]]::new()
    foreach ($materialPath in $materialPaths) {
        [void]$prefabMaterials.Add($materialPath)
        if (-not $materialByPath.ContainsKey($materialPath)) {
            $errors.Add([ordered]@{ prefab = $prefab.Name; code = 'MATERIAL_NOT_IN_CATALOG'; material = $materialPath })
            continue
        }
        $resolvedMaterials.Add($materialByPath[$materialPath])
    }
    $entries.Add([ordered]@{
        appearance = [IO.Path]::GetFileNameWithoutExtension($prefab.Name)
        prefab = $prefab.FullName.Substring($resolvedRoot.Length + 1).Replace('\', '/')
        mode = if ($resolvedMaterials.Count -eq 1) { 'single_material' } else { 'composite_materials' }
        materials = $resolvedMaterials
    })
}

$unlinked = @(
    Get-ChildItem -LiteralPath $TextureDirectory -File -Filter '*.png' |
        Where-Object { -not $catalogTextures.Contains($_.FullName) } |
        Sort-Object Name |
        ForEach-Object Name
)
$unreferencedMaterials = @(
    Get-ChildItem -LiteralPath $MaterialDirectory -File -Filter '*.mat' |
        Where-Object { -not $prefabMaterials.Contains($_.FullName) } |
        Sort-Object Name |
        ForEach-Object Name
)

$manifest = [ordered]@{
    schema_version = '1.0'
    status = if ($errors.Count -eq 0) { 'APPEARANCE_BUNDLE_PASS' } else { 'APPEARANCE_BUNDLE_BLOCKED' }
    source_root = $resolvedRoot
    appearance_count = $entries.Count
    appearances = $entries
    material_count = $materialCatalog.Count
    material_catalog = $materialCatalog
    prefab_unreferenced_materials = $unreferencedMaterials
    unlinked_texture_files = $unlinked
    errors = $errors
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
if ($errors.Count -gt 0) {
    throw "Unity appearance collection failed. See $manifestPath"
}
$manifest | ConvertTo-Json -Depth 4
