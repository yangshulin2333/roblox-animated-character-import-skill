[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [ValidateSet('custom-rig-npc', 'player-replacement', 'avatar-r15')]
    [string]$IntendedUse = 'custom-rig-npc',

    [string]$BlenderPath,

    [string]$ArchiveToolPath,

    [switch]$Convert,

    [switch]$FixMaxInfluences,

    [switch]$IncludePreviewAllInOne,

    [switch]$AllowUntextured,

    [string]$BaseColorTexture,

    [string]$MaterialName = 'Roblox_BaseColor',

    [ValidateRange(256, 4096)]
    [int]$MaxTextureDimension = 4096,

    [switch]$NoTextureToolInstall,

    [ValidateSet('linked', 'separate', 'embed', 'none')]
    [string]$TextureMode = 'separate',

    [string]$JobConfigPath,

    [string]$TargetUniverseId,

    [string]$CreatorId,

    [switch]$PlanOnly,

    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $absolute = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $absolute
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $temporary = $absolute + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 24
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $absolute -Force
}

function Get-TextSha256 {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-SafeStem {
    param([string]$Value, [string]$Fallback = 'resource')
    $stem = [regex]::Replace($Value, '[^\p{L}\p{Nd}._-]+', '_').Trim('.', '_', '-')
    if (-not $stem) { $stem = $Fallback }
    if ($stem.Length -gt 56) { $stem = $stem.Substring(0, 56).TrimEnd('.', '_', '-') }
    return $stem
}

function Get-MultipartDescriptor {
    param([System.IO.FileInfo]$File)
    if ($File.Name -notmatch '^(?<stem>.+)\.part(?<number>\d+)\.rar$') { return $null }
    $stem = [string]$Matches.stem
    $members = @(
        Get-ChildItem -LiteralPath $File.DirectoryName -File |
            Where-Object { $_.Name -match ('^' + [regex]::Escape($stem) + '\.part\d+\.rar$') } |
            Sort-Object { if ($_.Name -match '\.part(?<number>\d+)\.rar$') { [int]$Matches.number } else { 0 } }
    )
    if ($members.Count -eq 0) { return $null }
    return [pscustomobject][ordered]@{
        name = $stem
        source = $members[0].FullName
        type = 'rar-multipart'
        members = @($members | ForEach-Object { $_.FullName })
    }
}

function Get-SourceJobs {
    param([string]$ResolvedSource)
    $item = Get-Item -LiteralPath $ResolvedSource
    if (-not $item.PSIsContainer) {
        $multipart = Get-MultipartDescriptor -File $item
        if ($multipart) { return @($multipart) }
        return @([pscustomobject][ordered]@{
            name = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
            source = $item.FullName
            type = 'single-source'
            members = @($item.FullName)
        })
    }

    $archiveExtensions = @('.zip', '.7z', '.rar', '.gz', '.tgz', '.tar', '.unitypackage')
    $modelExtensions = @('.blend', '.fbx', '.glb', '.gltf', '.obj', '.max', '.ma', '.mb', '.c4d', '.uasset', '.uproject')
    $directFiles = @(Get-ChildItem -LiteralPath $item.FullName -File | Sort-Object Name)
    $jobs = New-Object System.Collections.Generic.List[object]
    $consumed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $directFiles) {
        if ($consumed.Contains($file.FullName)) { continue }
        $multipart = Get-MultipartDescriptor -File $file
        if ($multipart) {
            foreach ($member in @($multipart.members)) { [void]$consumed.Add([string]$member) }
            $jobs.Add($multipart)
            continue
        }
        if ($file.Extension.ToLowerInvariant() -in $archiveExtensions) {
            [void]$consumed.Add($file.FullName)
            $jobs.Add([pscustomobject][ordered]@{
                name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                source = $file.FullName
                type = 'archive'
                members = @($file.FullName)
            })
        }
    }

    foreach ($file in $directFiles) {
        if ($consumed.Contains($file.FullName)) { continue }
        if ($file.Extension.ToLowerInvariant() -in $modelExtensions) {
            $jobs.Add([pscustomobject][ordered]@{
                name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                source = $file.FullName
                type = 'model-file'
                members = @($file.FullName)
            })
        }
    }

    if ($jobs.Count -eq 0) {
        $jobs.Add([pscustomobject][ordered]@{
            name = $item.Name
            source = $item.FullName
            type = 'directory'
            members = @()
        })
    }
    return $jobs.ToArray()
}

function Get-JobFingerprint {
    param($Descriptor)
    if (@($Descriptor.members).Count -gt 0) {
        $records = @(
            foreach ($path in @($Descriptor.members)) {
                $file = Get-Item -LiteralPath $path
                $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                '{0}|{1}|{2}' -f $file.Name, [int64]$file.Length, $hash
            }
        )
        return [pscustomobject][ordered]@{
            method = 'member_sha256_v1'
            value = Get-TextSha256 -Text ($records -join "`n")
            members = $records
        }
    }

    $root = [System.IO.Path]::GetFullPath([string]$Descriptor.source).TrimEnd('\', '/')
    $records = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object {
                $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                '{0}|{1}|{2}' -f $relative, [int64]$_.Length, $_.LastWriteTimeUtc.Ticks
            }
    )
    return [pscustomobject][ordered]@{
        method = 'directory_inventory_v1'
        value = Get-TextSha256 -Text ($records -join "`n")
        members = @("files=$($records.Count)")
    }
}

function Ensure-Property {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-JobState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$NextAction = '',
        [string]$ErrorText = ''
    )
    Ensure-Property -Object $State -Name 'status' -Value $Status
    Ensure-Property -Object $State -Name 'current_stage' -Value $Stage
    Ensure-Property -Object $State -Name 'next_action_zh' -Value $NextAction
    Ensure-Property -Object $State -Name 'last_error' -Value $ErrorText
    Ensure-Property -Object $State -Name 'updated_at' -Value ''
    $State.status = $Status
    $State.current_stage = $Stage
    $State.next_action_zh = $NextAction
    $State.last_error = $ErrorText
    $State.updated_at = [DateTimeOffset]::Now.ToString('o')
}

function Resolve-ConfigTexturePath {
    param([string]$PathValue, [string]$ConfigDirectory)
    if (-not $PathValue) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return [System.IO.Path]::GetFullPath($PathValue) }
    return [System.IO.Path]::GetFullPath((Join-Path $ConfigDirectory $PathValue))
}

function Get-JobOptions {
    param($Descriptor, [string]$JobId, $Config, [string]$ConfigDirectory)
    $options = [ordered]@{
        fix_max_influences = [bool]$FixMaxInfluences
        include_preview_all_in_one = [bool]$IncludePreviewAllInOne
        allow_untextured = [bool]$AllowUntextured
        base_color_texture = if ($BaseColorTexture) { [System.IO.Path]::GetFullPath($BaseColorTexture) } else { $null }
        material_name = $MaterialName
        max_texture_dimension = $MaxTextureDimension
        no_texture_tool_install = [bool]$NoTextureToolInstall
        texture_mode = $TextureMode
    }
    if ($Config) {
        $match = @($Config.jobs | Where-Object {
            $candidateJobId = if ($null -ne $_.PSObject.Properties['job_id']) { [string]$_.job_id } else { '' }
            $candidateSourceName = if ($null -ne $_.PSObject.Properties['source_name']) { [string]$_.source_name } else { '' }
            $candidateSource = if ($null -ne $_.PSObject.Properties['source']) { [string]$_.source } else { '' }
            ($candidateJobId -and $candidateJobId -eq $JobId) -or
            ($candidateSourceName -and $candidateSourceName -eq [System.IO.Path]::GetFileName([string]$Descriptor.source)) -or
            ($candidateSource -and [System.IO.Path]::GetFullPath($candidateSource) -eq [System.IO.Path]::GetFullPath([string]$Descriptor.source))
        } | Select-Object -First 1)
        if ($match.Count -gt 0) {
            $override = $match[0]
            if ($null -ne $override.PSObject.Properties['fix_max_influences']) { $options.fix_max_influences = [bool]$override.fix_max_influences }
            if ($null -ne $override.PSObject.Properties['include_preview_all_in_one']) { $options.include_preview_all_in_one = [bool]$override.include_preview_all_in_one }
            if ($null -ne $override.PSObject.Properties['allow_untextured']) { $options.allow_untextured = [bool]$override.allow_untextured }
            if ($null -ne $override.PSObject.Properties['base_color_texture']) { $options.base_color_texture = Resolve-ConfigTexturePath -PathValue ([string]$override.base_color_texture) -ConfigDirectory $ConfigDirectory }
            if ($null -ne $override.PSObject.Properties['material_name']) { $options.material_name = [string]$override.material_name }
            if ($null -ne $override.PSObject.Properties['max_texture_dimension']) { $options.max_texture_dimension = [int]$override.max_texture_dimension }
            if ($null -ne $override.PSObject.Properties['no_texture_tool_install']) { $options.no_texture_tool_install = [bool]$override.no_texture_tool_install }
            if ($null -ne $override.PSObject.Properties['texture_mode']) { $options.texture_mode = [string]$override.texture_mode }
        }
    }
    return [pscustomobject]$options
}

function New-StudioImportPlan {
    param([string]$JobId, [string]$BundleDir, [string]$PlanPath)
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $BundleDir 'bundle_manifest.json') | ConvertFrom-Json
    $textureManifest = Get-Content -Raw -LiteralPath (Join-Path $BundleDir 'texture_manifest.json') | ConvertFrom-Json
    $model = @($manifest.files | Where-Object { $_.kind -eq 'model' } | Select-Object -First 1)
    $animations = @($manifest.files | Where-Object { $_.kind -eq 'animation' })
    $preview = @($manifest.files | Where-Object { $_.kind -eq 'all_in_one' } | Select-Object -First 1)
    $textures = @(
        foreach ($texture in @($textureManifest.textures | Where-Object { $_.delivered_file })) {
            [pscustomobject][ordered]@{
                file = Join-Path $BundleDir ([string]$texture.delivered_file).Replace('/', '\')
                sha256 = [string]$texture.sha256
                roblox_asset_id = $null
                status = 'UPLOAD_OR_REUSE_REQUIRED'
            }
        }
    )
    $plan = [ordered]@{
        schema_version = '1.1'
        status = 'READY_FOR_STUDIO'
        job_id = $JobId
        formal_contract = 'model_bind_plus_one_action_files'
        model_fbx = if ($model.Count -gt 0) { Join-Path $BundleDir ([string]$model[0].path).Replace('/', '\') } else { $null }
        texture_mode = [string]$manifest.export_settings.texture_mode
        texture_preparation = if ($null -ne $manifest.PSObject.Properties['texture_normalization']) { $manifest.texture_normalization } else { $null }
        textures = $textures
        canary_animation = if ($animations.Count -gt 0) { Join-Path $BundleDir ([string]$animations[0].path).Replace('/', '\') } else { $null }
        remaining_animations = @($animations | Select-Object -Skip 1 | ForEach-Object { Join-Path $BundleDir ([string]$_.path).Replace('/', '\') })
        preview_all_in_one = if ($preview.Count -gt 0) { Join-Path $BundleDir ([string]$preview[0].path).Replace('/', '\') } else { $null }
        required_order_zh = @(
            '在准确的目标体验中导入 model_bind.fbx，并启用 Add to Workspace。',
            '只上传 texture_manifest.json 中 delivered_file 指向的 Roblox 标准化 PNG；不要上传原始贴图或历史副本。',
            '上传后检查直接 rbxassetid 加载和当前体验权限。',
            '先导入 canary_animation，确认动作开始、时间推进、骨骼变化和形变正常。',
            '金丝雀动作通过后再导入其余单动作 FBX。',
            'model_all_in_one.fbx 若存在，只作预览，不作为跨电脑正式动画交付。'
        )
    }
    Write-Utf8Json -Value $plan -Path $PlanPath
}

if (-not (Test-Path -LiteralPath $Source)) { throw "找不到原始资源：$Source" }
$resolvedSource = (Resolve-Path -LiteralPath $Source).Path
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

if (Test-Path -LiteralPath $resolvedOutputRoot) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutputRoot -Force)
    if ($existing.Count -gt 0 -and -not $Resume) {
        throw "批处理输出目录不是空目录。若要从 job_state.json 继续，请加 -Resume：$resolvedOutputRoot"
    }
} else {
    New-Item -ItemType Directory -Path $resolvedOutputRoot | Out-Null
}

$config = $null
$configDirectory = $null
if ($JobConfigPath) {
    if (-not (Test-Path -LiteralPath $JobConfigPath -PathType Leaf)) { throw "找不到批处理配置：$JobConfigPath" }
    $resolvedConfig = (Resolve-Path -LiteralPath $JobConfigPath).Path
    $configDirectory = Split-Path -Parent $resolvedConfig
    $config = Get-Content -Raw -LiteralPath $resolvedConfig | ConvertFrom-Json
    if ($null -eq $config.PSObject.Properties['jobs']) { throw '批处理配置缺少 jobs 数组。' }
}

$descriptors = @(Get-SourceJobs -ResolvedSource $resolvedSource)
if ($descriptors.Count -gt 1 -and $BaseColorTexture) {
    throw '批次包含多个资源，不能把一个全局 -BaseColorTexture 套到所有角色。请用 -JobConfigPath 为各任务显式配置。'
}

$auditScript = Join-Path $PSScriptRoot 'audit_source.ps1'
$pipelineScript = Join-Path $PSScriptRoot 'run_pipeline.ps1'
$jobStates = New-Object System.Collections.Generic.List[object]
$batchStartedAt = [DateTimeOffset]::Now.ToString('o')

foreach ($descriptor in $descriptors) {
    $fingerprint = Get-JobFingerprint -Descriptor $descriptor
    $jobId = (Get-SafeStem -Value ([string]$descriptor.name)) + '-' + $fingerprint.value.Substring(0, 12)
    $jobDir = Join-Path $resolvedOutputRoot $jobId
    $statePath = Join-Path $jobDir 'job_state.json'
    New-Item -ItemType Directory -Force -Path $jobDir | Out-Null

    if ($Resume -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if ([string]$state.source_fingerprint.value -ne [string]$fingerprint.value) {
            throw "任务 $jobId 的原始资源指纹已变化。请使用新的输出目录重新执行。"
        }
    } else {
        $state = [pscustomobject][ordered]@{
            schema_version = '2.0'
            job_id = $jobId
            display_name = [string]$descriptor.name
            requested_source = [string]$descriptor.source
            source_type = [string]$descriptor.type
            source_fingerprint = $fingerprint
            intended_use = $IntendedUse
            status = 'DISCOVERED'
            current_stage = 'DISCOVERY'
            highest_verified_gate = $null
            audit_report = $null
            selected_source = $null
            bundle_dir = $null
            bundle_validation = $null
            studio_import_plan = $null
            studio = [pscustomobject][ordered]@{
                status = 'STUDIO_PENDING'
                target_universe_id = $TargetUniverseId
                creator_id = $CreatorId
                created_asset_ids = @()
                evidence = @()
            }
            attempts = [pscustomobject][ordered]@{ audit = 0; conversion = 0; studio = 0 }
            next_action_zh = '运行本地审计。'
            last_error = ''
            created_at = [DateTimeOffset]::Now.ToString('o')
            updated_at = [DateTimeOffset]::Now.ToString('o')
        }
        Write-Utf8Json -Value $state -Path $statePath
    }

    if ($PlanOnly) {
        Set-JobState -State $state -Status 'DISCOVERED' -Stage 'DISCOVERY' -NextAction '去掉 -PlanOnly 后运行审计；需要转换时同时加 -Convert。'
        Write-Utf8Json -Value $state -Path $statePath
        $jobStates.Add($state)
        continue
    }

    try {
        $terminalLocalStates = @('READY_FOR_STUDIO', 'STUDIO_IMPORT_PASS', 'LOCAL_PLAYBACK_PASS', 'RUNTIME_PLAYBACK_PASS', 'PRODUCTION_READY')
        if ($Resume -and [string]$state.status -in $terminalLocalStates) {
            $jobStates.Add($state)
            continue
        }

        $state.attempts.audit = [int]$state.attempts.audit + 1
        $auditDir = Join-Path $jobDir ('audit_attempt_{0:d3}' -f [int]$state.attempts.audit)
        $auditReport = Join-Path $auditDir 'source_audit.json'
        Set-JobState -State $state -Status 'AUDIT_RUNNING' -Stage 'AUDIT' -NextAction '等待原始容器、模型、三角面、骨架、动画和外观检测。'
        Write-Utf8Json -Value $state -Path $statePath

        $auditArguments = @{
            Source = [string]$descriptor.source
            IntendedUse = $IntendedUse
            ReportDir = $auditDir
            ReportPath = $auditReport
            HashSources = $true
        }
        if ($BlenderPath) { $auditArguments.BlenderPath = $BlenderPath }
        if ($ArchiveToolPath) { $auditArguments.ArchiveToolPath = $ArchiveToolPath }
        & $auditScript @auditArguments | Out-Null
        $auditExit = $LASTEXITCODE
        if (-not (Test-Path -LiteralPath $auditReport -PathType Leaf)) { throw "审计没有生成报告：$auditReport" }
        $audit = Get-Content -Raw -LiteralPath $auditReport | ConvertFrom-Json
        $state.audit_report = $auditReport
        $state.selected_source = [string]$audit.selected_source

        if ([string]$audit.status -notin @('DIRECT_IMPORT_CANDIDATE', 'CONVERSION_REQUIRED')) {
            Set-JobState -State $state -Status ([string]$audit.status) -Stage 'AUDIT_BLOCKED' -NextAction ([string]$audit.next_action_zh) -ErrorText ("audit exit=" + $auditExit)
            Write-Utf8Json -Value $state -Path $statePath
            $jobStates.Add($state)
            continue
        }

        $state.highest_verified_gate = 'SOURCE_PASS'
        if (-not $Convert) {
            Set-JobState -State $state -Status 'AUDIT_PASS' -Stage 'AUDIT_COMPLETE' -NextAction '审计已完成；确认自动修复和外观映射后，加 -Convert -Resume 继续。'
            Write-Utf8Json -Value $state -Path $statePath
            $jobStates.Add($state)
            continue
        }

        $options = Get-JobOptions -Descriptor $descriptor -JobId $jobId -Config $config -ConfigDirectory $configDirectory
        if ($options.texture_mode -notin @('linked', 'separate', 'embed', 'none')) { throw "无效 texture_mode：$($options.texture_mode)" }
        if ($options.base_color_texture -and -not (Test-Path -LiteralPath $options.base_color_texture -PathType Leaf)) {
            throw "配置的基础色贴图不存在：$($options.base_color_texture)"
        }

        $selected = @($audit.candidates | Where-Object { [string]$_.path -eq [string]$audit.selected_source } | Select-Object -First 1)
        $reasonCodes = if ($selected.Count -gt 0) { @($selected[0].reason_codes) } else { @() }
        if ('MAX_INFLUENCES_EXCEEDED' -in $reasonCodes -and -not $options.fix_max_influences) {
            Set-JobState -State $state -Status 'HUMAN_DECISION_REQUIRED' -Stage 'CONVERSION_GATE' -NextAction '该模型存在每顶点超过四根骨骼影响。确认接受临时裁减并复验全部动作后，为该任务设置 fix_max_influences=true。'
            Write-Utf8Json -Value $state -Path $statePath
            $jobStates.Add($state)
            continue
        }
        if ($selected.Count -gt 0 -and -not [bool]$selected[0].appearance_mapping_ready -and -not $options.base_color_texture -and -not $options.allow_untextured) {
            Set-JobState -State $state -Status 'SOURCE_APPEARANCE_BLOCKED' -Stage 'CONVERSION_GATE' -NextAction '从原始材质/Prefab/DCC 文件核验贴图映射，并在 Job 配置中指定 base_color_texture；不要盲猜相似文件名。'
            Write-Utf8Json -Value $state -Path $statePath
            $jobStates.Add($state)
            continue
        }

        $state.attempts.conversion = [int]$state.attempts.conversion + 1
        $bundleDir = Join-Path $jobDir ('bundle_attempt_{0:d3}' -f [int]$state.attempts.conversion)
        $state.bundle_dir = $bundleDir
        Set-JobState -State $state -Status 'CONVERSION_RUNNING' -Stage 'CONVERSION' -NextAction '等待 Blender 导出、全新进程回读和清单校验。'
        Write-Utf8Json -Value $state -Path $statePath

        $pipelineArguments = @{
            Source = [string]$audit.selected_source
            OutputDir = $bundleDir
            AllActions = $true
            TextureMode = [string]$options.texture_mode
            MaterialName = [string]$options.material_name
            MaxTextureDimension = [int]$options.max_texture_dimension
        }
        if ($BlenderPath) { $pipelineArguments.BlenderPath = $BlenderPath }
        if ($options.fix_max_influences) { $pipelineArguments.FixMaxInfluences = $true }
        if ($options.include_preview_all_in_one) { $pipelineArguments.AllInOne = $true }
        if ($options.allow_untextured) { $pipelineArguments.AllowUntextured = $true }
        if ($options.base_color_texture) { $pipelineArguments.BaseColorTexture = [string]$options.base_color_texture }
        if ($options.no_texture_tool_install) { $pipelineArguments.NoTextureToolInstall = $true }
        & $pipelineScript @pipelineArguments | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "转换脚本退出码为 $LASTEXITCODE" }

        $validationPath = Join-Path $bundleDir 'bundle_validation.json'
        if (-not (Test-Path -LiteralPath $validationPath -PathType Leaf)) { throw "缺少交付包校验报告：$validationPath" }
        $validation = Get-Content -Raw -LiteralPath $validationPath | ConvertFrom-Json
        if ([string]$validation.status -ne 'BUNDLE_PASS') { throw "交付包未通过校验：$validationPath" }

        $planPath = Join-Path $jobDir 'studio_import_plan.json'
        New-StudioImportPlan -JobId $jobId -BundleDir $bundleDir -PlanPath $planPath
        $state.bundle_validation = $validationPath
        $state.studio_import_plan = $planPath
        $state.highest_verified_gate = 'ROUNDTRIP_PASS'
        Set-JobState -State $state -Status 'READY_FOR_STUDIO' -Stage 'STUDIO_GATE' -NextAction '按 studio_import_plan.json 在准确目标体验中导入绑定模型，只上传已通过 TEXTURE_NORMALIZATION_PASS 的 delivered_file，再验证一个金丝雀动作；通过后再批量导入其余动作。'
        Write-Utf8Json -Value $state -Path $statePath
    } catch {
        Set-JobState -State $state -Status 'JOB_BLOCKED' -Stage 'FAILED' -NextAction '保留本次 attempt 目录和错误证据；修正明确原因后使用 -Resume，只继续未通过的任务。' -ErrorText $_.Exception.Message
        Write-Utf8Json -Value $state -Path $statePath
    }
    $jobStates.Add($state)
}

$textureOccurrences = New-Object System.Collections.Generic.List[object]
foreach ($state in $jobStates) {
    if (-not [string]$state.bundle_dir) { continue }
    $textureManifestPath = Join-Path ([string]$state.bundle_dir) 'texture_manifest.json'
    if (-not (Test-Path -LiteralPath $textureManifestPath -PathType Leaf)) { continue }
    $textureManifest = Get-Content -Raw -LiteralPath $textureManifestPath | ConvertFrom-Json
    foreach ($texture in @($textureManifest.textures | Where-Object { $_.delivered_file -and $_.sha256 })) {
        $textureOccurrences.Add([pscustomobject][ordered]@{
            job_id = [string]$state.job_id
            file = Join-Path ([string]$state.bundle_dir) ([string]$texture.delivered_file).Replace('/', '\')
            sha256 = ([string]$texture.sha256).ToLowerInvariant()
        })
    }
}

$registryPath = Join-Path $resolvedOutputRoot 'studio_asset_registry.json'
$registry = $null
if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
}
$textureIndex = @(
    foreach ($group in @($textureOccurrences | Group-Object sha256 | Sort-Object Name)) {
        $known = @()
        if ($registry) {
            $known = @($registry.entries | Where-Object {
                [string]$_.kind -eq 'image' -and
                [string]$_.sha256 -eq [string]$group.Name -and
                [string]$_.universe_id -eq $TargetUniverseId -and
                [string]$_.creator_id -eq $CreatorId -and
                [string]$_.verification_status -eq 'RUNTIME_FETCH_PASS'
            })
        }
        [pscustomobject][ordered]@{
            sha256 = [string]$group.Name
            occurrences = @($group.Group)
            duplicate_count = [Math]::Max(0, @($group.Group).Count - 1)
            reusable_asset_id = if ($known.Count -gt 0) { [string]$known[0].asset_id } else { $null }
            reuse_status = if (-not $TargetUniverseId -or -not $CreatorId) {
                'TARGET_CONTEXT_REQUIRED'
            } elseif ($known.Count -gt 0) {
                'REUSE_VERIFIED'
            } else {
                'UPLOAD_REQUIRED'
            }
        }
    }
)
Write-Utf8Json -Value ([ordered]@{
    schema_version = '1.0'
    target_universe_id = $TargetUniverseId
    creator_id = $CreatorId
    entries = $textureIndex
    note_zh = '只有贴图 SHA-256、Creator、Universe 均相同，且登记为 RUNTIME_FETCH_PASS 时才允许自动复用 Roblox AssetId。'
}) -Path (Join-Path $resolvedOutputRoot 'texture_index.json')

$statuses = @($jobStates | ForEach-Object { [string]$_.status })
$batchStatus = if ($PlanOnly) {
    'BATCH_PLANNED'
} elseif (@($statuses | Where-Object { $_ -notin @('READY_FOR_STUDIO', 'STUDIO_IMPORT_PASS', 'LOCAL_PLAYBACK_PASS', 'RUNTIME_PLAYBACK_PASS', 'PRODUCTION_READY') }).Count -eq 0) {
    'READY_FOR_STUDIO'
} elseif (@($statuses | Where-Object { $_ -in @('JOB_BLOCKED', 'SOURCE_BLOCKED', 'SOURCE_APPEARANCE_BLOCKED', 'NATIVE_DCC_EXPORT_REQUIRED', 'HUMAN_DECISION_REQUIRED', 'ARCHIVE_MULTIPART_INCOMPLETE', 'EXTRACTOR_REQUIRED') }).Count -gt 0) {
    'BATCH_ATTENTION_REQUIRED'
} else {
    'BATCH_AUDIT_COMPLETE'
}

$batchManifest = [ordered]@{
    schema_version = '2.0'
    status = $batchStatus
    requested_source = $resolvedSource
    output_root = $resolvedOutputRoot
    intended_use = $IntendedUse
    mode = if ($PlanOnly) { 'plan-only' } elseif ($Convert) { 'audit-and-convert' } else { 'audit-only' }
    formal_delivery_contract = 'model_bind_plus_one_action_files_and_external_textures'
    default_texture_mode = $TextureMode
    preview_all_in_one_default = $false
    target_universe_id = $TargetUniverseId
    creator_id = $CreatorId
    job_count = $jobStates.Count
    jobs = $jobStates.ToArray()
    texture_index = Join-Path $resolvedOutputRoot 'texture_index.json'
    studio_asset_registry = $registryPath
    started_at = $batchStartedAt
    updated_at = [DateTimeOffset]::Now.ToString('o')
    next_action_zh = if ($batchStatus -eq 'READY_FOR_STUDIO') {
        '逐任务按 studio_import_plan.json 执行 Studio 导入和金丝雀动作验收。'
    } elseif ($batchStatus -eq 'BATCH_ATTENTION_REQUIRED') {
        '只处理各 job_state.json 中的明确阻止原因，然后使用 -Resume 继续；不要重跑已通过任务。'
    } else {
        '查看各任务审计结论；需要转换时使用 -Convert -Resume。'
    }
}
$batchManifestPath = Join-Path $resolvedOutputRoot 'batch_manifest.json'
Write-Utf8Json -Value $batchManifest -Path $batchManifestPath
$batchManifest | ConvertTo-Json -Depth 8

if ($batchStatus -eq 'BATCH_ATTENTION_REQUIRED') { exit 2 }
