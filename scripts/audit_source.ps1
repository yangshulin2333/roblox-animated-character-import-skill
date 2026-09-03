[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [ValidateSet('custom-rig-npc', 'player-replacement', 'avatar-r15')]
    [string]$IntendedUse = 'custom-rig-npc',

    [string]$BlenderPath,

    [string]$ReportDir,

    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ReportDir) {
    $ReportDir = Join-Path $env:TEMP ('roblox-character-audit-' + [guid]::NewGuid().ToString('N'))
}
$resolvedReportDir = [System.IO.Path]::GetFullPath($ReportDir)
New-Item -ItemType Directory -Force -Path $resolvedReportDir | Out-Null

if (-not $ReportPath) {
    $ReportPath = Join-Path $resolvedReportDir 'source_audit.json'
}
$resolvedReportPath = [System.IO.Path]::GetFullPath($ReportPath)

$preflightScript = Join-Path $PSScriptRoot 'preflight.ps1'
$inspectScript = Join-Path $PSScriptRoot 'inspect_in_blender.py'
$preflightReport = Join-Path $resolvedReportDir 'preflight_report.json'

& $preflightScript -Source $Source -BlenderPath $BlenderPath -ReportPath $preflightReport | Out-Null
$preflight = Get-Content -Raw -LiteralPath $preflightReport | ConvertFrom-Json

$candidateResults = @()
$candidates = @($preflight.source.candidates)
$blender = [string]$preflight.blender.path

if ($candidates.Count -gt 0 -and $blender) {
    $index = 0
    foreach ($candidate in $candidates) {
        $index += 1
        $candidateReportPath = Join-Path $resolvedReportDir ('candidate_{0:d3}.json' -f $index)
        & $blender --background --factory-startup --disable-autoexec --python $inspectScript -- --source $candidate --report $candidateReportPath
        $inspectExit = $LASTEXITCODE
        if ($inspectExit -ne 0 -or -not (Test-Path -LiteralPath $candidateReportPath -PathType Leaf)) {
            $candidateResults += [pscustomobject][ordered]@{
                path = $candidate
                inspection = 'SOURCE_BLOCKED'
                direct_import_candidate = $false
                conversion_candidate = $false
                appearance_mapping_ready = $false
                score = -1000
                reason_codes = @('BLENDER_INSPECTION_FAILED')
                report = $candidateReportPath
            }
            continue
        }

        $inspection = Get-Content -Raw -LiteralPath $candidateReportPath | ConvertFrom-Json
        $meshes = @($inspection.meshes)
        $extension = [System.IO.Path]::GetExtension([string]$candidate).ToLowerInvariant()
        $directFormat = $extension -in @('.fbx', '.glb', '.gltf')
        $hasMesh = [int]$inspection.summary.mesh_count -gt 0
        $hasArmature = [int]$inspection.summary.armature_count -gt 0
        $hasActions = [int]$inspection.summary.action_count -gt 0
        $allTriangleLimitsPass = @($meshes | Where-Object { -not [bool]$_.triangle_limit_ok }).Count -eq 0
        $allMeshesHaveUv = $meshes.Count -gt 0 -and @($meshes | Where-Object { @($_.uv_layers).Count -eq 0 }).Count -eq 0
        $allMeshesHaveMaterial = $meshes.Count -gt 0 -and @($meshes | Where-Object { @($_.material_slots).Count -eq 0 }).Count -eq 0
        $materialImageCount = if ($null -ne $inspection.summary.material_image_count) {
            [int]$inspection.summary.material_image_count
        } else {
            [int]$inspection.summary.image_count
        }
        $hasImages = $materialImageCount -gt 0
        $appearanceReady = $allMeshesHaveUv -and $allMeshesHaveMaterial -and $hasImages
        $influencesPass = [int]$inspection.summary.vertices_over_four_influences -eq 0

        $hardBlockers = @($inspection.blockers | Where-Object { $_.code -ne 'MAX_INFLUENCES_EXCEEDED' })
        $requiresRig = $IntendedUse -in @('custom-rig-npc', 'player-replacement', 'avatar-r15')
        $structureReady = $hasMesh -and $allTriangleLimitsPass -and $hardBlockers.Count -eq 0
        if ($requiresRig) {
            $structureReady = $structureReady -and $hasArmature -and $hasActions
        }

        $reasonCodes = New-Object System.Collections.Generic.List[string]
        if (-not $hasMesh) { $reasonCodes.Add('NO_MESH') }
        if (-not $allTriangleLimitsPass) { $reasonCodes.Add('MESH_TRIANGLE_LIMIT') }
        if ($requiresRig -and -not $hasArmature) { $reasonCodes.Add('ARMATURE_MISSING') }
        if ($requiresRig -and -not $hasActions) { $reasonCodes.Add('ACTIONS_MISSING') }
        if (-not $influencesPass) { $reasonCodes.Add('MAX_INFLUENCES_EXCEEDED') }
        if (-not $allMeshesHaveUv) { $reasonCodes.Add('UV_MISSING') }
        if (-not $allMeshesHaveMaterial) { $reasonCodes.Add('MATERIAL_MAPPING_MISSING') }
        if (-not $hasImages) { $reasonCodes.Add('IMAGE_REFERENCE_MISSING') }
        if (-not $directFormat) { $reasonCodes.Add('FORMAT_CONVERSION_REQUIRED') }
        if ($IntendedUse -eq 'avatar-r15') { $reasonCodes.Add('R15_SCHEMA_REVIEW_REQUIRED') }
        foreach ($blocker in $hardBlockers) { $reasonCodes.Add([string]$blocker.code) }

        $directReady = $directFormat -and $structureReady -and $influencesPass -and $appearanceReady -and $IntendedUse -ne 'avatar-r15'
        $conversionCandidate = $structureReady
        $score = 0
        if ($extension -eq '.blend') { $score += 100 }
        elseif ($extension -eq '.fbx') { $score += 80 }
        elseif ($extension -in @('.glb', '.gltf')) { $score += 70 }
        elseif ($extension -eq '.obj') { $score += 20 }
        if ($hasArmature) { $score += 30 }
        if ($hasActions) { $score += 30 }
        if ($allMeshesHaveUv) { $score += 15 }
        if ($allMeshesHaveMaterial) { $score += 20 }
        if ($hasImages) { $score += 25 }
        if ($influencesPass) { $score += 15 } else { $score -= 20 }
        if (-not $allTriangleLimitsPass) { $score -= 200 }
        if ($hardBlockers.Count -gt 0) { $score -= 300 }

        $candidateResults += [pscustomobject][ordered]@{
            path = $candidate
            extension = $extension
            inspection = [string]$inspection.status
            direct_import_candidate = $directReady
            conversion_candidate = $conversionCandidate
            appearance_mapping_ready = $appearanceReady
            score = $score
            reason_codes = @($reasonCodes)
            facts = [ordered]@{
                meshes = [int]$inspection.summary.mesh_count
                vertices = [int]$inspection.summary.vertices
                triangles = [int]$inspection.summary.triangles
                armatures = [int]$inspection.summary.armature_count
                actions = [int]$inspection.summary.action_count
                images = [int]$inspection.summary.image_count
                material_images = $materialImageCount
                maximum_positive_bone_influences = [int]$inspection.summary.maximum_positive_bone_influences
                vertices_over_four_influences = [int]$inspection.summary.vertices_over_four_influences
            }
            report = $candidateReportPath
        }
    }
}

$selected = $candidateResults |
    Where-Object { $_.conversion_candidate } |
    Sort-Object @{ Expression = 'score'; Descending = $true }, path |
    Select-Object -First 1

$status = 'SOURCE_BLOCKED'
$nextAction = 'Provide a readable source model and its textures.'
if ($selected) {
    if ($selected.direct_import_candidate) {
        $status = 'DIRECT_IMPORT_CANDIDATE'
        $nextAction = 'Import this candidate in the exact Studio place and complete texture, playback, permission, and scale gates.'
    } else {
        $status = 'CONVERSION_REQUIRED'
        $nextAction = 'Use the selected candidate for a temporary Blender conversion, then read back the exported FBX before Studio import.'
    }
} elseif (@($preflight.source.native_dcc_files).Count -gt 0) {
    $status = 'NATIVE_DCC_EXPORT_REQUIRED'
    $nextAction = 'Open the native DCC/project and export FBX or glTF with mesh, rig, actions, UVs, and external textures.'
}

$report = [ordered]@{
    schema_version = '1.0'
    status = $status
    intended_use = $IntendedUse
    requested_source = $Source
    selected_source = if ($selected) { $selected.path } else { $null }
    candidates = @($candidateResults)
    preflight = [ordered]@{
        status = [string]$preflight.status
        detected_projects = @($preflight.source.detected_projects)
        native_dcc_files = @($preflight.source.native_dcc_files)
        texture_candidates = @($preflight.source.texture_candidates)
        report = $preflightReport
    }
    limits = [ordered]@{
        triangles_per_mesh = 20000
        maximum_positive_bone_influences_per_vertex = 4
    }
    next_action = $nextAction
    note = 'DIRECT_IMPORT_CANDIDATE is not Studio acceptance. Texture rendering, animation playback, permissions, scale, and target-device performance remain separate gates.'
}

$parent = Split-Path -Parent $resolvedReportPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$json = $report | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($resolvedReportPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
$json

if ($status -in @('SOURCE_BLOCKED', 'NATIVE_DCC_EXPORT_REQUIRED')) { exit 2 }
