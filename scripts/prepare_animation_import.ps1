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

    [ValidateSet('UNDECIDED', 'IMPORTED_SKELETON', 'IMPORTED_SKELETON_ZERO_ROTATIONS', 'ANIMATION_EDITOR_SKELETON')]
    [string]$RestPoseSource,
    [string]$RestPoseReason,
    [string]$RestPoseEvidence,
    [ValidateSet('PROPOSED', 'USER_REPORTED_WORKING', 'VERIFIED')]
    [string]$RestPoseDecisionStatus = 'PROPOSED',

    [string]$PublishedActionName,
    [ValidatePattern('^\d+$')]
    [string]$PublishedAssetId,

    [ValidateSet('GRANT_REQUIRED', 'GRANTED', 'PERMISSION_BLOCKED', 'RUNTIME_FETCH_PASS', 'MODERATION_PENDING')]
    [string]$ExperiencePermissionStatus
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
$oldExperience = Read-ExistingValue -Object $oldImport -Name 'experience'
$newUniverse = if ($UniverseId) { $UniverseId } else { Read-ExistingValue $oldExperience 'universe_id' }
if ([bool]$PublishedActionName -ne [bool]$PublishedAssetId) { throw '发布记录必须同时提供 PublishedActionName 和 PublishedAssetId，不能按队列位置猜动作。' }
if ($ExperiencePermissionStatus -and -not $PublishedAssetId) { throw '权限记录必须同时提供动作名和发布 ID。' }
if (-not $RestPoseSource -and ($RestPoseReason -or $RestPoseEvidence -or $PSBoundParameters.ContainsKey('RestPoseDecisionStatus'))) { throw '记录判断理由/证据时必须指定 RestPoseSource。' }
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

$fileHashes = @{}
foreach ($file in $files) {
    $full = [IO.Path]::GetFullPath($file)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "动画 FBX 不存在：$full" }
    $fileHashes[$full.ToLowerInvariant()] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
}
$modelFile = Read-ExistingValue $plan 'model_fbx'
$modelHash = if ($modelFile -and (Test-Path -LiteralPath $modelFile -PathType Leaf)) { (Get-FileHash -LiteralPath $modelFile -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
$scope = [ordered]@{
    target_rig_path = $TargetRigPath
    universe_id = $newUniverse
    model_sha256 = $modelHash
    action_files = @($fileHashes.Keys | Sort-Object | ForEach-Object { [ordered]@{ file = $_; sha256 = $fileHashes[$_] } })
}
$scopeJson = $scope | ConvertTo-Json -Depth 8 -Compress
$oldDecision = Read-ExistingValue $oldImport 'rest_pose_decision'
$oldScope = Read-ExistingValue $oldDecision 'scope'
$sameScope = $modelHash -and $oldScope -and (($oldScope | ConvertTo-Json -Depth 8 -Compress) -ceq $scopeJson)
$labels = @{
    UNDECIDED = '待 Codex 检查本资源后判断'
    IMPORTED_SKELETON = '导入的骨架'
    IMPORTED_SKELETON_ZERO_ROTATIONS = '导入的骨架（旋转归零）'
    ANIMATION_EDITOR_SKELETON = '动画编辑器骨架'
}
$choice = 'UNDECIDED'
$decision = [ordered]@{ status = 'REVIEW_REQUIRED'; reason_zh = ''; evidence = ''; scope = $scope }
if ($RestPoseSource -and $RestPoseSource -ne 'UNDECIDED') {
    if ([string]::IsNullOrWhiteSpace($RestPoseReason)) { throw '休息姿势选项必须带有本资源的判断理由 RestPoseReason。' }
    if ($RestPoseDecisionStatus -ne 'PROPOSED' -and [string]::IsNullOrWhiteSpace($RestPoseEvidence)) { throw '已验证或用户反馈必须附 RestPoseEvidence，不能只填通过状态。' }
    if (-not $modelHash) { throw '缺少绑定模型文件，无法登记设置适用范围。' }
    $choice = $RestPoseSource
    $decision.status = $RestPoseDecisionStatus
    $decision.reason_zh = $RestPoseReason
    $decision.evidence = $RestPoseEvidence
} elseif (-not $RestPoseSource -and $sameScope -and (Read-ExistingValue $oldDecision 'reason_zh')) {
    $oldChoice = [string](Read-ExistingValue $oldImport 'rest_pose_source')
    if ($labels.ContainsKey($oldChoice)) {
        $choice = $oldChoice
        $decision.status = Read-ExistingValue $oldDecision 'status' 'REVIEW_REQUIRED'
        $decision.reason_zh = Read-ExistingValue $oldDecision 'reason_zh' ''
        $decision.evidence = Read-ExistingValue $oldDecision 'evidence' ''
    }
}
$sameChoice = $sameScope -and ((Read-ExistingValue $oldImport 'rest_pose_source') -eq $choice)
$sameUniverse = (Read-ExistingValue $oldExperience 'universe_id') -eq $newUniverse
$publishedMatches = 0
$actions = New-Object System.Collections.Generic.List[object]
for ($index = 0; $index -lt $files.Count; $index++) {
    $file = [System.IO.Path]::GetFullPath($files[$index])
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "动画 FBX 不存在：$file" }
    $key = $file.ToLowerInvariant()
    $old = if ($oldActionsByFile.ContainsKey($key)) { $oldActionsByFile[$key] } else { $null }
    $sameFile = $old -and ((Read-ExistingValue $old 'sha256') -eq $fileHashes[$key])
    $actionName = Read-ExistingValue -Object $old -Name 'action'
    if (-not $actionName) { $actionName = [System.IO.Path]::GetFileNameWithoutExtension($file) }
    $localStatus = if ($sameFile -and $sameChoice) { Read-ExistingValue $old 'local_import_status' 'PENDING' } else { 'PENDING' }
    $assetIdValue = Read-ExistingValue -Object $old -Name 'published_asset_id'
    $permissionStatus = Read-ExistingValue -Object $old -Name 'experience_permission_status' -Fallback 'NOT_APPLICABLE_UNTIL_PUBLISHED'
    $runtimeStatus = if ($sameFile -and $sameChoice -and $sameUniverse) { Read-ExistingValue $old 'runtime_playback_status' 'NOT_TESTED' } else { 'NOT_TESTED' }
    if (-not $sameUniverse) { $permissionStatus = if ($assetIdValue) { 'GRANT_REQUIRED' } else { 'NOT_APPLICABLE_UNTIL_PUBLISHED' } }
    $publishedSourceStatus = if (-not $assetIdValue) { 'NOT_PUBLISHED' } elseif ($sameFile) { Read-ExistingValue $old 'published_source_status' 'MAPPING_REVIEW_REQUIRED' } else { 'STALE_SOURCE_REVIEW_REQUIRED' }
    if ($PublishedActionName -and $actionName -ceq $PublishedActionName) {
        $publishedMatches++
        if ($assetIdValue -ne $PublishedAssetId) { $runtimeStatus = 'NOT_TESTED'; $permissionStatus = 'GRANT_REQUIRED' }
        $assetIdValue = $PublishedAssetId
        $publishedSourceStatus = 'OPERATOR_MAPPED'
        if ($ExperiencePermissionStatus) { $permissionStatus = $ExperiencePermissionStatus }
        if ($permissionStatus -eq 'PERMISSION_BLOCKED') { $runtimeStatus = 'PERMISSION_BLOCKED' }
    }
    $actions.Add([pscustomobject][ordered]@{
        order = $index + 1
        role = if ($index -eq 0) { 'CANARY' } else { 'REMAINING' }
        action = $actionName
        file = $file
        sha256 = $fileHashes[$key]
        local_import_status = $localStatus
        published_asset_id = $assetIdValue
        published_source_status = $publishedSourceStatus
        experience_permission_status = $permissionStatus
        runtime_playback_status = $runtimeStatus
        playback_evidence = if ($sameFile -and $sameChoice -and $sameUniverse -and $runtimeStatus -ne 'NOT_TESTED') { Read-ExistingValue $old 'playback_evidence' } else { $null }
    })
}
if ($PublishedActionName -and $publishedMatches -ne 1) { throw '动作名必须精确匹配且只能匹配一项；没有写入发布记录。' }

$plan.schema_version = '1.3'
$animationImport = [pscustomobject][ordered]@{
    rig_type = 'CUSTOM'
    target_rig_path = $TargetRigPath
    rest_pose_source = $choice
    rest_pose_ui_zh = $labels[$choice]
    rest_pose_decision = $decision
    applicability_zh = '仅适用于所记录的目标、绑定模型和动作文件；源/目标绑定姿势或变换改变后需重新判断。路径相同不保证目标骨架未变。'
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
    ('在动画编辑器选择 {0}；休息姿势：{1}；判断状态：{2}。候选须经代表动作试播后才批量复用。' -f $TargetRigPath, $labels[$choice], $decision.status),
    '先本地导入 canary_animation，确认时间推进、骨骼变化和视觉形变。',
    '金丝雀通过后按 animation_import.actions 将其余动作全部导入本地并试听；默认只发布最终选中的动作。',
    '按动作名核对发布 ID；检查当前 Universe 权限，缺失才授权，再用 fresh Play 验证。',
    'model_all_in_one.fbx 若存在，只作预览，不作为跨电脑正式动画交付。'
)
if ($null -ne $plan.PSObject.Properties['required_order_zh']) {
    $plan.required_order_zh = $requiredOrder
} else {
    $plan | Add-Member -NotePropertyName required_order_zh -NotePropertyValue $requiredOrder
}

Write-Utf8Json -Value $plan -Path $planPath
[pscustomobject][ordered]@{
    status = if ($choice -eq 'UNDECIDED') { 'REST_POSE_REVIEW_REQUIRED' } else { 'ANIMATION_IMPORT_PLAN_READY' }
    plan = $planPath
    target_rig_path = $TargetRigPath
    rest_pose_ui_zh = $labels[$choice]
    decision_status = $decision.status
    action_count = $actions.Count
    local_import_policy = '全部先本地导入和预览，默认只发布最终选中的动作。'
} | ConvertTo-Json -Depth 5
