[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StudioImportPlan,

    [Parameter(Mandatory = $true)]
    [string]$TargetRigPath,

    [string]$UniverseId,
    [string]$PlaceId,
    [string]$ExperienceOwner,
    [string]$AnimationUploader,

    [ValidatePattern('^\d+$')]
    [string]$CanaryPublishedAssetId,

    [ValidateSet('NOT_APPLICABLE_UNTIL_PUBLISHED', 'GRANT_REQUIRED', 'GRANTED', 'PERMISSION_BLOCKED', 'RUNTIME_FETCH_PASS', 'MODERATION_PENDING')]
    [string]$CanaryExperiencePermissionStatus
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8Json {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Path)
    $json = $Value | ConvertTo-Json -Depth 20
    $temporary = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-ExistingValue {
    param($Object, [string]$Name, $Fallback = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Fallback
}

$planPath = [System.IO.Path]::GetFullPath($StudioImportPlan)
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "找不到 studio_import_plan.json：$planPath"
}

$plan = [System.IO.File]::ReadAllText($planPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$oldImport = Read-ExistingValue -Object $plan -Name 'animation_import'
$oldActionsByFile = @{}
foreach ($oldAction in @(Read-ExistingValue -Object $oldImport -Name 'actions' -Fallback @())) {
    if ($oldAction.file) {
        $oldActionsByFile[[System.IO.Path]::GetFullPath([string]$oldAction.file).ToLowerInvariant()] = $oldAction
    }
}

$files = New-Object System.Collections.Generic.List[string]
if ($plan.canary_animation) { $files.Add([string]$plan.canary_animation) }
foreach ($file in @($plan.remaining_animations)) { $files.Add([string]$file) }
if ($files.Count -eq 0) { throw '导入计划里没有任何单动作 FBX。' }

$actions = New-Object System.Collections.Generic.List[object]
for ($index = 0; $index -lt $files.Count; $index++) {
    $file = [System.IO.Path]::GetFullPath($files[$index])
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "动画 FBX 不存在：$file" }
    $key = $file.ToLowerInvariant()
    $old = if ($oldActionsByFile.ContainsKey($key)) { $oldActionsByFile[$key] } else { $null }
    $actionName = Read-ExistingValue -Object $old -Name 'action'
    if (-not $actionName) { $actionName = [System.IO.Path]::GetFileNameWithoutExtension($file) }
    $localStatus = Read-ExistingValue -Object $old -Name 'local_import_status' -Fallback 'PENDING'
    $publishedAssetId = Read-ExistingValue -Object $old -Name 'published_asset_id'
    $permissionStatus = Read-ExistingValue -Object $old -Name 'experience_permission_status' -Fallback 'NOT_APPLICABLE_UNTIL_PUBLISHED'
    $runtimeStatus = Read-ExistingValue -Object $old -Name 'runtime_playback_status' -Fallback 'NOT_TESTED'
    if ($index -eq 0 -and $CanaryPublishedAssetId) {
        $localStatus = 'LOCAL_IMPORT_PASS'
        $publishedAssetId = $CanaryPublishedAssetId
        if ($CanaryExperiencePermissionStatus) { $permissionStatus = $CanaryExperiencePermissionStatus }
        if ($permissionStatus -eq 'PERMISSION_BLOCKED') { $runtimeStatus = 'PERMISSION_BLOCKED' }
    }
    $actions.Add([pscustomobject][ordered]@{
        order = $index + 1
        role = if ($index -eq 0) { 'CANARY' } else { 'REMAINING' }
        action = $actionName
        file = $file
        sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        local_import_status = $localStatus
        published_asset_id = $publishedAssetId
        experience_permission_status = $permissionStatus
        runtime_playback_status = $runtimeStatus
    })
}

$plan.schema_version = '1.2'
$animationImport = [pscustomobject][ordered]@{
    rig_type = 'CUSTOM'
    target_rig_path = $TargetRigPath
    rest_pose_source = 'IMPORTED_SKELETON'
    rest_pose_ui_zh = '导入的骨架（第二项）'
    applicability_zh = '仅用于同一绑定骨架导出的单动作 FBX；骨架层级或休息姿势不一致时必须停止并转为重定向检查。'
    local_import_policy = 'IMPORT_ALL_LOCALLY_THEN_PUBLISH_SELECTED'
    automation_mode = 'GUIDED_UI_LOOP'
    public_api_boundary_zh = 'Roblox 公开 Studio API 仍会逐个提示选择 FBX，不能把一组本地路径无交互地绑定到现有骨架；Codex 可按此队列自动执行并逐项验收。'
    experience = [pscustomobject][ordered]@{
        universe_id = if ($UniverseId) { $UniverseId } else { Read-ExistingValue -Object (Read-ExistingValue -Object $oldImport -Name 'experience') -Name 'universe_id' }
        place_id = if ($PlaceId) { $PlaceId } else { Read-ExistingValue -Object (Read-ExistingValue -Object $oldImport -Name 'experience') -Name 'place_id' }
        experience_owner = if ($ExperienceOwner) { $ExperienceOwner } else { Read-ExistingValue -Object (Read-ExistingValue -Object $oldImport -Name 'experience') -Name 'experience_owner' }
        animation_uploader = if ($AnimationUploader) { $AnimationUploader } else { Read-ExistingValue -Object (Read-ExistingValue -Object $oldImport -Name 'experience') -Name 'animation_uploader' }
    }
    actions = $actions.ToArray()
}

if ($null -ne $plan.PSObject.Properties['animation_import']) {
    $plan.animation_import = $animationImport
} else {
    $plan | Add-Member -NotePropertyName animation_import -NotePropertyValue $animationImport
}

$requiredOrder = @(
    '在准确的目标体验中导入 model_bind.fbx，并启用 Add to Workspace。',
    '只上传 texture_manifest.json 的 delivered_file 指向的 *_Roblox.png，并检查直接 rbxassetid 加载。',
    ('在动画编辑器选择 {0}；Rig 类型使用 Custom，休息姿势来源选择第二项“导入的骨架”。' -f $TargetRigPath),
    '先本地导入 canary_animation，确认时间推进、骨骼变化和视觉形变。',
    '金丝雀通过后按 animation_import.actions 将其余动作全部导入本地并试听；默认只发布最终选中的动作。',
    '每个已发布 AnimationId 都必须授权给当前 Universe，并在 fresh Play 中确认 Length 大于 0、TimePosition 推进且骨骼变化。',
    'model_all_in_one.fbx 若存在，只作预览，不作为跨电脑正式动画交付。'
)
if ($null -ne $plan.PSObject.Properties['required_order_zh']) {
    $plan.required_order_zh = $requiredOrder
} else {
    $plan | Add-Member -NotePropertyName required_order_zh -NotePropertyValue $requiredOrder
}

Write-Utf8Json -Value $plan -Path $planPath
[pscustomobject][ordered]@{
    status = 'ANIMATION_IMPORT_PLAN_READY'
    plan = $planPath
    target_rig_path = $TargetRigPath
    rest_pose_ui_zh = '导入的骨架（第二项）'
    action_count = $actions.Count
    local_import_policy = '全部先本地导入和预览，默认只发布最终选中的动作。'
} | ConvertTo-Json -Depth 5
