# 批量处理、断点续跑与去重

本文件定义批处理外壳。单个角色仍使用 `audit_source.ps1` 和 `run_pipeline.ps1`；`run_batch.ps1` 负责把大量、来源各异的原始资源拆成独立任务，并保存可恢复状态。

## 为什么仍然只保留一个 Skill

用户只需要调用 `$roblox-animated-character-import`。内部拆为三个阶段，而不是让用户记三个 Skill：

1. **资源审计**：识别压缩格式/引擎，检测三角面、骨架、权重、动作、UV、材质和贴图映射。
2. **本地转换**：只转换已通过来源门禁的候选，输出正式便携包并全新进程回读。
3. **Studio 验收**：在准确体验里上传/复用依赖，先验收一个金丝雀动作，再处理其余动作。

这种拆分保留了“一步调用”的体验，同时让失败任务能从原阶段继续，避免重新解包、重新导出和重复上传。

## 批处理入口

先只发现任务，不解包、不转换：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_batch.ps1 `
  -Source "D:\原始资源目录" `
  -OutputRoot "D:\Roblox批处理\本批次" `
  -PlanOnly
```

审计并转换：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_batch.ps1 `
  -Source "D:\原始资源目录" `
  -OutputRoot "D:\Roblox批处理\本批次" `
  -Convert
```

修正明确阻止原因后断点继续：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_batch.ps1 `
  -Source "D:\原始资源目录" `
  -OutputRoot "D:\Roblox批处理\本批次" `
  -Convert -Resume -JobConfigPath ".\batch-job-config.json"
```

规则：

- 同目录的 `.part1.rar` 到 `.partN.rar` 是**一个任务**，不是 N 个模型；
- 同目录的独立 ZIP/7z/RAR/UnityPackage 或直接模型文件分别成为任务；
- 一个任务失败不阻止其他任务收集证据；
- `-Resume` 复用已经到达 `READY_FOR_STUDIO` 或更高状态的任务；
- 失败转换不会覆盖旧产物，而是创建新的 `bundle_attempt_NNN`；
- 不加 `-FixMaxInfluences` 时，超过四权重会停在 `HUMAN_DECISION_REQUIRED`；
- 多任务批次禁止使用一个全局 `-BaseColorTexture`，必须逐任务显式配置，避免串贴图。

## 每任务配置

配置按 `source_name`、`source` 或稳定 `job_id` 匹配。示例见 `examples/batch-job-config.example.json`。

```json
{
  "schema_version": "1.0",
  "jobs": [
    {
      "source_name": "character.unitypackage",
      "fix_max_influences": true,
      "base_color_texture": "textures/character_color.png",
      "material_name": "Character_BaseColor",
      "max_texture_dimension": 4096,
      "no_texture_tool_install": false,
      "texture_mode": "separate",
      "include_preview_all_in_one": false,
      "allow_untextured": false
    }
  ]
}
```

相对贴图路径以配置文件所在目录为基准。`base_color_texture` 只用于已经从原始 Prefab/Material/DCC 关系中核验的单张基础色修复；复杂 PBR、透明或多材质角色仍必须建立明确通道映射。

## 机器可读状态

```text
批次输出/
  batch_manifest.json
  texture_index.json
  studio_asset_registry.json        # 第一次登记云端素材后出现
  <任务名-指纹>/
    job_state.json
    audit_attempt_001/
      source_audit.json
    bundle_attempt_001/
      model_bind.fbx
      animations/*.fbx
      textures/*
      bundle_manifest.json
      bundle_validation.json
    studio_import_plan.json
```

`job_state.json` 是恢复源，必须保留：

- 原始源和内容指纹；
- 已尝试次数；
- 当前状态和最高证据门禁；
- 选中的源文件；
- 当前有效 bundle、校验报告和 Studio 导入计划；
- Studio 目标、创建的 AssetId 和验收证据（进入 Studio 后补充）。

状态含义：

| 状态 | 含义 | 后续动作 |
| --- | --- | --- |
| `DISCOVERED` | 只完成资源组发现 | 运行审计 |
| `AUDIT_PASS` | 来源已审计，尚未转换 | 审阅修复项后 `-Convert -Resume` |
| `HUMAN_DECISION_REQUIRED` | 权重裁减等会改变模型 | 人工确认后逐任务配置 |
| `SOURCE_APPEARANCE_BLOCKED` | 继续会生成白模 | 核验外观映射，不得猜贴图 |
| `READY_FOR_STUDIO` | 已达 `ROUNDTRIP_PASS` | 进入准确目标体验验收 |
| `JOB_BLOCKED` | 脚本/工具或转换失败 | 保留 attempt，改变条件后 `-Resume` |

## 正式交付与预览文件

正式跨电脑契约固定为：

- `model_bind.fbx`；
- `animations/` 下每个动作一个 FBX；
- `textures/` 下外部图片；
- JSON 清单、文件大小和 SHA-256。

默认 `TextureMode=separate`，把模型/骨架上传和图片上传拆开，减少 `base_color_texture` 事务失败后重复创建半成品素材的风险。`linked` 或 `embed` 只有在目标 Studio 实测可靠时才使用。

每个 `separate` 任务在进入 `READY_FOR_STUDIO` 前自动把正式外部图片转换为 `*_Roblox.png`，移除应用元数据并完成结构/像素回读。`studio_import_plan.json` 只列标准化后的路径和哈希。默认最大边长 4096；需要移动端降到 2048/1024 时必须逐任务配置 `max_texture_dimension`，不能把一个全局质量决策静默套到不同角色。

`model_all_in_one.fbx` 只有显式 `-IncludePreviewAllInOne` 才生成，并在清单中标记 `preview_only`。它不能替代每动作一个 FBX 的跨电脑契约。

## 贴图哈希去重

`texture_index.json` 按图片 SHA-256 合并重复项。只有以下条件全部相同，才允许复用已有 Roblox 图片 AssetId：

1. 图片 SHA-256 相同；
2. `CreatorId` 相同；
3. `UniverseId` 相同；
4. 该 AssetId 已在新 Play 会话中达到 `RUNTIME_FETCH_PASS`。

完成一次 Studio 验收后登记：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/record_studio_asset.ps1 `
  -RegistryPath "D:\Roblox批处理\本批次\studio_asset_registry.json" `
  -Kind image `
  -File "D:\Roblox批处理\本批次\任务\bundle_attempt_001\textures\Color.png" `
  -AssetId "1234567890" `
  -CreatorId "用户或群组ID" `
  -UniverseId "目标UniverseId" `
  -PlaceId "目标PlaceId" `
  -VerificationStatus RUNTIME_FETCH_PASS
```

素材管理器可见或编辑器缩略图可见只能登记为 `UPLOADED`/`STUDIO_VISIBLE`，不能登记为 `RUNTIME_FETCH_PASS`。

## Studio 人工/自动边界

脚本可以准备文件、哈希、导入顺序和只读验收脚本；`prepare_animation_import.ps1` 还会把目标 Rig、体验身份和逐动作状态写进 `studio_import_plan.json`。账号登录、Creator 选择、实际上传、不可逆权限选择、动画发布和肉眼形变判断仍是人工门禁。批处理到达 `READY_FOR_STUDIO` 不等于模型已能在游戏运行。

动画批量处理不是“把 17 个 FBX 一次交给无头 API”。Roblox 公开的 Studio 动画导入调用仍会显示文件选择/导入界面，且不能直接接收脚本准备好的本地路径。因此通用自动化采用可核验的 UI 循环：锁定同一个 Custom Rig、固定使用“导入的骨架（第二项）”、逐文件导入、逐项检查时间轴，并在失败处停止。默认先全部本地导入，用户试听后只发布选中的动作。

Studio 固定顺序：

1. 导入 `model_bind.fbx`；
2. 上传或复用贴图并验证直接依赖；
3. 只本地导入一个 `canary_animation`，同源单动作 FBX 的休息姿势来源选“导入的骨架（第二项）”；
4. 验证时间推进、骨骼变化和视觉形变；
5. 再将剩余动作全部导入本地并试听，不默认发布；
6. 只发布选中的动作，每个动画 ID 都授权给准确 Universe 后用新 Play 会话验证运行时权限；
7. 最后才调整尺寸和做手机/电脑性能测试。
