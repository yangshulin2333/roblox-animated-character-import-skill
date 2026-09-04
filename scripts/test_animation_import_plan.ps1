[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('roblox-plan-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$planPath = Join-Path $testDir 'studio_import_plan.json'
$prepare = Join-Path $PSScriptRoot 'prepare_animation_import.ps1'
$count = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:count++
}
function Write-Utf8Json($Value, [string]$Path) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 25), [Text.UTF8Encoding]::new($false))
}
function Read-Plan { [IO.File]::ReadAllText($planPath, [Text.Encoding]::UTF8) | ConvertFrom-Json }
function Run-Plan($Extra = @{}) {
    & $prepare -StudioImportPlan $planPath -TargetRigPath 'Workspace.TestRig' -UniverseId '10' @Extra | Out-Null
}
function Expect-Rejected($Extra, $Message) {
    $before = (Get-FileHash -LiteralPath $planPath).Hash
    $rejected = $false
    try { Run-Plan $Extra } catch { $rejected = $true }
    Assert-True $rejected $Message
    Assert-True ((Get-FileHash -LiteralPath $planPath).Hash -eq $before) 'Rejected request must leave plan unchanged'
}

# These tiny files test plan identity/status logic, not actual FBX parsing.
$model = Join-Path $testDir 'model_bind.fbx'
$a = Join-Path $testDir 'Attack01.fbx'
$b = Join-Path $testDir 'Attack02.fbx'
foreach ($p in @($model, $a, $b)) { [IO.File]::WriteAllText($p, [IO.Path]::GetFileName($p)) }
$manifest = [ordered]@{
    files = @(
        @{ kind = 'model'; path = 'model_bind.fbx' },
        @{ kind = 'animation'; path = 'Attack01.fbx'; action = 'Attack01'; sha256 = (Get-FileHash $a).Hash.ToLowerInvariant() },
        @{ kind = 'animation'; path = 'Attack02.fbx'; action = 'Attack02'; sha256 = (Get-FileHash $b).Hash.ToLowerInvariant() }
    )
    export_settings = @{ texture_mode = 'separate' }
}
Write-Utf8Json $manifest (Join-Path $testDir 'bundle_manifest.json')
Write-Utf8Json @{ textures = @() } (Join-Path $testDir 'texture_manifest.json')
# Load just the actual batch plan factory, without running batch source conversion.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run_batch.ps1'), [ref]$tokens, [ref]$errors)
$factory = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-StudioImportPlan' }, $true)
Invoke-Expression $factory.Extent.Text
New-StudioImportPlan -JobId 'test' -BundleDir $testDir -PlanPath $planPath
Assert-True ((Read-Plan).animation_import.rest_pose_source -eq 'UNDECIDED') 'Batch defaults must not guess rest pose'
Run-Plan
Assert-True ((Read-Plan).animation_import.rest_pose_source -eq 'UNDECIDED') 'Preparation must remain undecided'
Expect-Rejected @{ RestPoseSource = 'IMPORTED_SKELETON' } 'Choice requires per-asset reason'
Expect-Rejected @{ RestPoseSource = 'IMPORTED_SKELETON'; RestPoseReason = 'Candidate'; RestPoseDecisionStatus = 'VERIFIED' } 'Verified requires evidence'
foreach ($choice in @('IMPORTED_SKELETON', 'IMPORTED_SKELETON_ZERO_ROTATIONS', 'ANIMATION_EDITOR_SKELETON')) {
    Run-Plan @{ RestPoseSource = $choice; RestPoseReason = 'Inspected source and target'; RestPoseDecisionStatus = 'PROPOSED' }
    Assert-True ((Read-Plan).animation_import.rest_pose_source -eq $choice) 'Explicit choice must not be overwritten'
    Run-Plan
    Assert-True ((Read-Plan).animation_import.rest_pose_source -eq $choice) 'Unchanged scope preserves per-asset decision'
}
Run-Plan @{ PublishedActionName = 'Attack02'; PublishedAssetId = '222'; ExperiencePermissionStatus = 'GRANTED' }
$p = Read-Plan
Assert-True ($null -eq $p.animation_import.actions[0].published_asset_id) 'Do not assign published ID to first action'
Assert-True ($p.animation_import.actions[1].published_asset_id -eq '222') 'Published ID maps by exact action name'
Assert-True ($p.animation_import.actions[1].local_import_status -eq 'PENDING') 'ID mapping must not invent local playback pass'
Expect-Rejected @{ PublishedActionName = 'Missing'; PublishedAssetId = '333' } 'Unknown action is rejected'
$p.animation_import.actions[1].runtime_playback_status = 'USER_REPORTED_SINGLE_PLAY'
$p.animation_import.actions[1].playback_evidence = 'User reported one play; not tool verified'
Write-Utf8Json $p $planPath
Run-Plan
Assert-True ((Read-Plan).animation_import.actions[1].runtime_playback_status -eq 'USER_REPORTED_SINGLE_PLAY') 'User report must not become automated pass'
& $prepare -StudioImportPlan $planPath -TargetRigPath 'Workspace.OtherRig' -UniverseId '10' | Out-Null
Assert-True ((Read-Plan).animation_import.rest_pose_source -eq 'UNDECIDED') 'Changed rig invalidates rest-pose choice'
Run-Plan @{ RestPoseSource = 'IMPORTED_SKELETON'; RestPoseReason = 'New rig review' }
[IO.File]::AppendAllText($b, 'changed')
Run-Plan
$p = Read-Plan
Assert-True ($p.animation_import.rest_pose_source -eq 'UNDECIDED') 'Changed file invalidates decision'
Assert-True ($p.animation_import.actions[1].runtime_playback_status -eq 'NOT_TESTED') 'Changed file invalidates playback'
Assert-True ($p.animation_import.actions[1].published_asset_id -eq '222' -and $p.animation_import.actions[1].published_source_status -eq 'STALE_SOURCE_REVIEW_REQUIRED') 'Keep old cloud ID for review, not as reusable current source'
$p.animation_import.rest_pose_source = 'IMPORTED_SKELETON'
$p.animation_import.PSObject.Properties.Remove('rest_pose_decision')
Write-Utf8Json $p $planPath
Run-Plan
Assert-True ((Read-Plan).animation_import.rest_pose_source -eq 'UNDECIDED') 'Legacy hardcoded choice is not verified evidence'
[pscustomobject]@{ status = 'PLAN_REGRESSION_PASS'; assertions = $count; fixtures = $testDir; studio_tested = $false } | ConvertTo-Json
