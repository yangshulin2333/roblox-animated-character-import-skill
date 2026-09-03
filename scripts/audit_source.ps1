[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [ValidateSet('custom-rig-npc', 'player-replacement', 'avatar-r15')]
    [string]$IntendedUse = 'custom-rig-npc',

    [string]$BlenderPath,

    [string]$ArchiveToolPath,

    [string]$IntakeWorkDir,

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
$intakeScript = Join-Path $PSScriptRoot 'intake_source.ps1'
$inspectScript = Join-Path $PSScriptRoot 'inspect_in_blender.py'
$preflightReport = Join-Path $resolvedReportDir 'preflight_report.json'
$intakeReport = Join-Path $resolvedReportDir 'source_intake.json'
if (-not $IntakeWorkDir) { $IntakeWorkDir = Join-Path $resolvedReportDir 'intake' }

& $intakeScript -Source $Source -WorkDir $IntakeWorkDir -ReportPath $intakeReport -ArchiveToolPath $ArchiveToolPath -Extract | Out-Null
$intakeExit = $LASTEXITCODE
$intake = Get-Content -Raw -LiteralPath $intakeReport | ConvertFrom-Json

if ($intakeExit -ne 0 -or [string]$intake.status -ne 'SOURCE_NORMALIZED') {
    $blockedStatus = if (@($intake.blockers).Count -gt 0) { [string]$intake.blockers[0].code } else { 'SOURCE_INTAKE_BLOCKED' }
    $blockedReport = [ordered]@{
        schema_version = '2.0'
        status = $blockedStatus
        status_zh = [string]$intake.status_zh
        intended_use = $IntendedUse
        requested_source = $Source
        normalized_source = $null
        selected_source = $null
        candidates = @()
        intake = [ordered]@{
            status = [string]$intake.status
            container_type = if ($null -ne $intake.container) { [string]$intake.container.type } else { $null }
            resource_groups = @($intake.resource_groups)
            blockers = @($intake.blockers)
            warnings = @($intake.warnings)
            report = $intakeReport
        }
        next_action_zh = [string]$intake.next_action_zh
        next_action = [string]$intake.next_action_zh
        note_zh = '尚未进入 Blender 内容检测，也没有生成 Roblox 导出文件。'
        note = '尚未进入 Blender 内容检测，也没有生成 Roblox 导出文件。'
    }
    $parent = Split-Path -Parent $resolvedReportPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $blockedJson = $blockedReport | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($resolvedReportPath, $blockedJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $blockedJson
    exit 2
}

$normalizedSource = [string]$intake.normalized_source
& $preflightScript -Source $normalizedSource -BlenderPath $BlenderPath -ReportPath $preflightReport | Out-Null
$preflight = Get-Content -Raw -LiteralPath $preflightReport | ConvertFrom-Json

$candidateResults = @()
$candidates = @($preflight.source.candidates)
$blender = [string]$preflight.blender.path

function Get-ReasonZh {
    param([string]$Code)
    switch ($Code) {
        'NO_MESH' { '没有可渲染网格' }
        'MESH_TRIANGLE_LIMIT' { '至少一个独立网格超过 Roblox 三角面上限' }
        'ARMATURE_MISSING' { '缺少骨架' }
        'ACTIONS_MISSING' { '缺少骨骼动画' }
        'MAX_INFLUENCES_EXCEEDED' { '存在超过四根骨骼影响的顶点' }
        'UV_MISSING' { '至少一个可见网格缺少 UV' }
        'MATERIAL_MAPPING_MISSING' { '至少一个可见网格缺少材质槽或材质映射' }
        'IMAGE_REFERENCE_MISSING' { '材质没有实际引用可用贴图' }
        'FORMAT_CONVERSION_REQUIRED' { '源格式需要转换为 Roblox 兼容 FBX' }
        'R15_SCHEMA_REVIEW_REQUIRED' { '需要单独进行 R15/Avatar 结构审查' }
        'BLENDER_INSPECTION_FAILED' { 'Blender 无法完成内容检测' }
        default { "需要检查：$Code" }
    }
}

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
        $reasonArray = $reasonCodes.ToArray()

        $candidateResults += [pscustomobject][ordered]@{
            path = $candidate
            extension = $extension
            inspection = [string]$inspection.status
            direct_import_candidate = $directReady
            conversion_candidate = $conversionCandidate
            appearance_mapping_ready = $appearanceReady
            score = $score
            reason_codes = $reasonArray
            reasons_zh = @($reasonArray | ForEach-Object { Get-ReasonZh -Code $_ })
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
                source_bounds = $inspection.scene.bounds
                source_units = $inspection.scene.units
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
$statusZh = '原始资源中没有找到可继续处理的动画角色源'
$nextAction = '请提供可读取的模型、骨架、动画和贴图源文件。'
if ($selected) {
    if ($selected.direct_import_candidate) {
        $status = 'DIRECT_IMPORT_CANDIDATE'
        $statusZh = '找到可进入 Roblox Studio 导入验证的候选文件'
        $nextAction = '在目标 Studio 项目中导入该候选文件，并继续检查贴图、动作、权限和尺寸。'
    } else {
        $status = 'CONVERSION_REQUIRED'
        $statusZh = '找到可转换的角色源，但必须先修复或转换'
        $nextAction = '使用临时 Blender 场景处理选中的源文件，导出 FBX 后重新读取验证，再进入 Studio。'
    }
} elseif (@($preflight.source.native_dcc_files).Count -gt 0) {
    $status = 'NATIVE_DCC_EXPORT_REQUIRED'
    $statusZh = '只找到原生工程资源，需要从对应软件导出'
    $nextAction = '使用原生 Unity、Unreal、3ds Max、Maya 或 Blender 打开资源，导出包含模型、骨架、动画、UV 和贴图关系的 FBX/glTF。'
}

$report = [ordered]@{
    schema_version = '2.0'
    status = $status
    status_zh = $statusZh
    intended_use = $IntendedUse
    requested_source = $Source
    normalized_source = $normalizedSource
    selected_source = if ($selected) { $selected.path } else { $null }
    candidates = @($candidateResults)
    intake = [ordered]@{
        status = [string]$intake.status
        status_zh = [string]$intake.status_zh
        container_type = if ($null -ne $intake.container) { [string]$intake.container.type } else { $null }
        detected_ecosystems = if ($null -ne $intake.inventory) { @($intake.inventory.detected_ecosystems) } else { @() }
        asset_groups = if ($null -ne $intake.inventory) { @($intake.inventory.asset_groups) } else { @() }
        report = $intakeReport
    }
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
    next_action_zh = $nextAction
    next_action = $nextAction
    note_zh = 'DIRECT_IMPORT_CANDIDATE 只表示本地候选文件通过结构检测，不代表 Studio 已验收；贴图显示、动作播放、素材权限、尺寸和目标设备性能仍是独立门禁。'
    note = 'DIRECT_IMPORT_CANDIDATE 只表示本地候选文件通过结构检测，不代表 Studio 已验收；贴图显示、动作播放、素材权限、尺寸和目标设备性能仍是独立门禁。'
}

$parent = Split-Path -Parent $resolvedReportPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$json = $report | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($resolvedReportPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
$json

if ($status -in @('SOURCE_BLOCKED', 'NATIVE_DCC_EXPORT_REQUIRED')) { exit 2 }
