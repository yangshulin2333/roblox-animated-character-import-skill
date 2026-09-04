[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [string]$BlenderPath,

    [string]$Armature,

    [string[]]$Actions = @(),

    [switch]$AllActions,

    [switch]$FixMaxInfluences,

    [switch]$AllInOne,

    [switch]$AllowUntextured,

    [string]$BaseColorTexture,

    [string]$MaterialName = 'Roblox_BaseColor',

    [ValidateRange(256, 4096)]
    [int]$MaxTextureDimension = 4096,

    [switch]$NoTextureToolInstall,

    [ValidateSet('linked', 'separate', 'embed', 'none')]
    [string]$TextureMode = 'separate'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($AllActions -and $Actions.Count -gt 0) {
    throw 'Use either -AllActions or -Actions, not both.'
}
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw 'run_pipeline.ps1 requires one exact source model file. Run preflight on a directory/ZIP first.'
}
if ($BaseColorTexture -and -not (Test-Path -LiteralPath $BaseColorTexture -PathType Leaf)) {
    throw "Base-color texture does not exist: $BaseColorTexture"
}

$resolvedSource = (Resolve-Path -LiteralPath $Source).Path
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDir)
if (Test-Path -LiteralPath $resolvedOutput) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0) {
        throw "Output directory is not empty; refusing to overwrite: $resolvedOutput"
    }
} else {
    New-Item -ItemType Directory -Path $resolvedOutput | Out-Null
}

$preflightScript = Join-Path $PSScriptRoot 'preflight.ps1'
$inspectScript = Join-Path $PSScriptRoot 'inspect_in_blender.py'
$exportScript = Join-Path $PSScriptRoot 'export_fbx_bundle.py'
$readbackScript = Join-Path $PSScriptRoot 'readback_bundle.py'
$validateScript = Join-Path $PSScriptRoot 'validate_bundle.py'
$normalizeTexturesScript = Join-Path $PSScriptRoot 'normalize_roblox_textures.ps1'
$preflightReport = Join-Path $resolvedOutput 'preflight_report.json'
$inspectionReport = Join-Path $resolvedOutput 'inspection_report.json'
$readbackReport = Join-Path $resolvedOutput 'readback_report.json'
$bundleValidation = Join-Path $resolvedOutput 'bundle_validation.json'
$textureNormalizationReport = Join-Path $resolvedOutput 'texture_normalization.json'

& $preflightScript -Source $resolvedSource -BlenderPath $BlenderPath -OutputDir $resolvedOutput -ReportPath $preflightReport | Out-Null
$preflight = Get-Content -Raw -Encoding UTF8 -LiteralPath $preflightReport | ConvertFrom-Json
if ($preflight.status -ne 'PREFLIGHT_PASS') { throw "Preflight failed. See $preflightReport" }
$blender = [string]$preflight.blender.path
if (-not $blender) { throw 'Preflight returned no Blender executable.' }

& $blender --background --factory-startup --disable-autoexec --python $inspectScript -- --source $resolvedSource --report $inspectionReport
if ($LASTEXITCODE -ne 0) { throw "Blender inspection failed. See $inspectionReport" }
$inspection = Get-Content -Raw -Encoding UTF8 -LiteralPath $inspectionReport | ConvertFrom-Json

$unresolvedBlockers = @()
foreach ($blocker in @($inspection.blockers)) {
    if ($blocker.code -eq 'MAX_INFLUENCES_EXCEEDED' -and $FixMaxInfluences) { continue }
    $unresolvedBlockers += $blocker
}
if ($unresolvedBlockers.Count -gt 0) {
    $codes = ($unresolvedBlockers | ForEach-Object { $_.code }) -join ', '
    throw "Source has unresolved compatibility blockers: $codes. See $inspectionReport"
}
if ($AllActions -and [int]$inspection.summary.action_count -eq 0) {
    throw "-AllActions was requested but the source contains no Blender Actions. See $inspectionReport"
}
if (-not $AllowUntextured) {
    $missingUv = @($inspection.meshes | Where-Object { @($_.uv_layers).Count -eq 0 })
    $missingMaterial = @($inspection.meshes | Where-Object { @($_.material_slots).Count -eq 0 })
    $materialImageCount = if ($null -ne $inspection.summary.material_image_count) {
        [int]$inspection.summary.material_image_count
    } else {
        [int]$inspection.summary.image_count
    }
    if ($missingUv.Count -gt 0) {
        throw "SOURCE_APPEARANCE_BLOCKED: at least one visible mesh has no UV layer. See $inspectionReport"
    }
    if (-not $BaseColorTexture -and ($missingMaterial.Count -gt 0 -or $materialImageCount -eq 0)) {
        throw "SOURCE_APPEARANCE_BLOCKED: the selected source does not preserve complete UV/material/image mapping. Inspect sibling DCC files before export, or pass -AllowUntextured only when a white model is intentional. See $inspectionReport"
    }
}

$exportArguments = @(
    '--background', '--factory-startup', '--disable-autoexec',
    '--python', $exportScript, '--',
    '--source', $resolvedSource,
    '--output-dir', $resolvedOutput,
    '--texture-mode', $TextureMode
)
if ($Armature) { $exportArguments += @('--armature', $Armature) }
if ($AllActions) { $exportArguments += '--all-actions' }
foreach ($action in $Actions) { $exportArguments += @('--action', $action) }
if ($FixMaxInfluences) { $exportArguments += '--fix-max-influences' }
if ($AllInOne) { $exportArguments += '--all-in-one' }
if ($BaseColorTexture) {
    $resolvedBaseColorTexture = (Resolve-Path -LiteralPath $BaseColorTexture).Path
    $exportArguments += @('--base-color-texture', $resolvedBaseColorTexture, '--material-name', $MaterialName)
}

& $blender @exportArguments
if ($LASTEXITCODE -ne 0) { throw "FBX export failed. Inspect the Blender output and $inspectionReport" }

$textureNormalizationStatus = 'TEXTURE_NORMALIZATION_NOT_APPLICABLE'
if ($TextureMode -eq 'separate') {
    $normalizationArguments = @{
        BundleDir = $resolvedOutput
        ReportPath = $textureNormalizationReport
        MaxDimension = $MaxTextureDimension
        BlenderPath = $blender
    }
    if ($NoTextureToolInstall) { $normalizationArguments.NoToolInstall = $true }
    & $normalizeTexturesScript @normalizationArguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "TEXTURE_COMPATIBILITY_BLOCKED: external texture normalization failed. See $textureNormalizationReport"
    }
    if (-not (Test-Path -LiteralPath $textureNormalizationReport -PathType Leaf)) {
        throw "TEXTURE_COMPATIBILITY_BLOCKED: texture normalization produced no report: $textureNormalizationReport"
    }
    $textureNormalization = Get-Content -Raw -Encoding UTF8 -LiteralPath $textureNormalizationReport | ConvertFrom-Json
    $textureNormalizationStatus = [string]$textureNormalization.status
    if ($textureNormalizationStatus -notin @('TEXTURE_NORMALIZATION_PASS', 'TEXTURE_NORMALIZATION_SKIPPED')) {
        throw "TEXTURE_COMPATIBILITY_BLOCKED: unexpected texture normalization status: $textureNormalizationStatus"
    }
}

& $blender --background --factory-startup --disable-autoexec --python $readbackScript -- --bundle $resolvedOutput --report $readbackReport
if ($LASTEXITCODE -ne 0) { throw "Fresh FBX read-back failed. See $readbackReport" }

& $blender --background --factory-startup --disable-autoexec --python $validateScript -- --bundle $resolvedOutput --report $bundleValidation
if ($LASTEXITCODE -ne 0) { throw "Bundle validation failed. See $bundleValidation" }

$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $resolvedOutput 'bundle_manifest.json') | ConvertFrom-Json
$result = [ordered]@{
    status = 'ROUNDTRIP_PASS'
    output_dir = $resolvedOutput
    model_fbx = (Join-Path $resolvedOutput 'model_bind.fbx')
    all_in_one_fbx = if ($AllInOne) { (Join-Path $resolvedOutput 'model_all_in_one.fbx') } else { $null }
    action_count = @($manifest.actions).Count
    skipped_actions = @($manifest.skipped_actions)
    texture_mode = $TextureMode
    texture_normalization_status = $textureNormalizationStatus
    texture_normalization_report = if ($TextureMode -eq 'separate') { $textureNormalizationReport } else { $null }
    max_texture_dimension = $MaxTextureDimension
    base_color_texture = if ($BaseColorTexture) { $resolvedBaseColorTexture } else { $null }
    formal_delivery = 'model_bind.fbx + animations/<one-action>.fbx + textures/ + manifests'
    preview_all_in_one = if ($AllInOne) { (Join-Path $resolvedOutput 'model_all_in_one.fbx') } else { $null }
    next_gate = 'Import model_bind.fbx into the exact Roblox Studio place, assign the declared external textures, validate one canary action, then import the remaining one-action FBXs. model_all_in_one.fbx is preview-only when present.'
}
$result | ConvertTo-Json -Depth 6
