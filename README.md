# Roblox 动画模型导入 Skill

一个可移植的 Codex Skill。输入可以是人物、动物、僵尸、怪物、机械或车辆，也可以来自 UnityPackage/GZIP、Unreal 工程或 UAsset 包、3ds Max、Blender、FBX、glTF、ZIP、7z、RAR 分卷以及混合资源目录。它先按真实结构判断静态、骨骼动画或非骨架动画，再选择转换、导入和 Roblox Studio 验证路线。

目标是让用户交出原始资源后，得到清楚的适用性评估和可在目标 Studio 使用的结果。Codex 负责必要转换、贴图兼容处理、逐资源判断动画结构、骨架导入设置与验证；用户只配合必要的账号操作和效果选择。不同资源可能需要不同设置，不能把某个案例的成功选项当成通用固定值。

## 你会拿到什么

先给一张中文资源卡：包里有什么、结构分类、模型总三角面/最大单网格三角面、骨骼和动作、贴图规格、必要修复、适用性和待测风险。你只要求检测就到此停止；已要求导入则在授权范围内继续处理。

交付时说明哪些在 Studio 实测、哪些来自你的反馈、哪些尚未验证。需要手动操作时只给当前步骤的准确文件/对象、选项名和预期结果；脚本和 JSON 由 Codex 维护，不要求你学习整条技术管线。

## 安装

Windows PowerShell：

```powershell
git clone https://github.com/yangshulin2333/roblox-animated-character-import-skill "$env:USERPROFILE\.codex\skills\roblox-animated-character-import"
```

重启或新开 Codex 任务后使用：

```text
$roblox-animated-character-import 把 D:\path\model.zip 导入当前 Roblox Studio。先判断它是骨骼动画、非骨架动画还是静态模型；适用时转换并优先验证全部动作，只在必要时用 Blender 修改，不另存 Studio 副本。
```

如果界面使用 `@` 选择能力，在 Skill 列表中选择 **Roblox 动画模型导入**；Skill 的稳定标识仍是 `$roblox-animated-character-import`，保留旧标识是为了兼容已安装版本和已有文档。

## 最短使用方式

大量资源优先走批处理入口。先预览会拆成几个任务（不解包、不转换）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_batch.ps1 `
  -Source "D:\原始资源目录" `
  -OutputRoot "D:\Roblox批处理\本批次" `
  -PlanOnly
```

确认后审计并转换；中断或修正配置后加 `-Resume`，已完成任务不会重复导出：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_batch.ps1 `
  -Source "D:\原始资源目录" `
  -OutputRoot "D:\Roblox批处理\本批次" `
  -Convert
```

对原始包执行一体化审计；脚本会先识别容器、生成独立检测工作目录，再检查模型内容，这一步不会转换或覆盖原模型：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\audit_source.ps1 `
  -Source "D:\原始资源或压缩包" `
  -IntendedUse animated-model `
  -ReportDir "D:\检测报告\资源名"
```

它会按文件签名识别真实格式，归并 RAR 分卷，还原 UnityPackage 的 GUID 资源结构，然后逐个检查可读候选，并按网格、Roblox 三角面、骨架、动作、UV、材质和贴图保留情况选择真正的源文件。报告中的 `asset_kind` 说明它属于骨骼动画、缺动作的骨架、非骨架动画还是静态模型；`*_Roblox.fbx` 这样的文件名不算通过证据。

如果只想确认原始包是什么，不解包：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\intake_source.ps1 `
  -Source "D:\原始资源" `
  -WorkDir "D:\检测工作区\资源名"
```

生成跨电脑交接包：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_pipeline.ps1 `
  -Source "D:\path\animated_model.blend" `
  -OutputDir "D:\path\RobloxExport" `
  -AllActions `
  -FixMaxInfluences
```

绑定模型进入 Workspace 后，为大量动作生成可续跑的 Studio 队列：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\prepare_animation_import.ps1 `
  -StudioImportPlan "D:\本批次\模型任务\studio_import_plan.json" `
  -TargetRigPath "Workspace.实际模型名" `
  -UniverseId "目标UniverseId" `
  -PlaceId "目标PlaceId" `
  -ExperienceOwner "体验所有者" `
  -AnimationUploader "动画上传者"
```

此命令只建队列，未判定时返回 `REST_POSE_REVIEW_REQUIRED`。Codex 检查源/目标的绑定姿势、层级和变换后，通过 `-RestPoseSource` 与 `-RestPoseReason` 记录候选设置，用一个代表动作验证后再批量复用。不能固定选择第几项。默认全部动作先本地导入预览，只发布用户最终选中的动作；按动作名登记 ID，检查体验权限，缺失才授权，再用 fresh Play 验证。

默认行为：

- 不覆盖源文件；
- 不自动另存 Roblox Studio 项目；
- 默认拒绝缺少 UV、材质槽或材质贴图引用的模型，避免再次生成白模；
- 默认输出一个绑定模型 FBX、每个动作一个 FBX、外部贴图和 JSON 清单；
- 正式外部贴图会自动重编码为 8 位 RGB/RGBA、无应用元数据的 `*_Roblox.png`，完成 CRC、像素回读和 SHA-256 校验；Studio 只上传 `texture_manifest.json` 的 `delivered_file`；
- 默认最大贴图边长为 4096；需要移动端 2048/1024 时使用 `-MaxTextureDimension` 显式选择；
- `-AllInOne` 只额外生成预览用 `model_all_in_one.fbx`，不作为跨电脑正式动画契约；
- 检测到每顶点超过 4 根骨骼影响时停止。确认需要自动裁减时再加 `-FixMaxInfluences`；
- 输出目录非空时停止，避免覆盖上一轮结果。
- 在已保存/已发布的目标体验中上传时，优先依靠 **Add to Workspace** 自动授予当前体验使用权限；不会把“设置为开放使用”当成协作者项目的默认修复。
- 禁止用 `rbxthumb://` 或单面 `Decal` 冒充完整 MeshPart 贴图；可用 `scripts/studio_audit_asset_dependencies.luau` 做只读依赖审计。

## 重要边界

这套 Skill 无法保证任意第三方模型都能 100% 导入。损坏文件、未授权资产、不可兼容骨架、Roblox 审核或账户权限都可能阻止完成。它保证的是：每一步都有可复现输入、明确状态、失败恢复路径和可核验证据，不再把“预览正常”误报为“运行正常”。

原始资源规则见 [references/source-intake.md](references/source-intake.md)，批处理见 [references/batch-workflow.md](references/batch-workflow.md)，贴图标准化见 [references/texture-preflight.md](references/texture-preflight.md)，完整流程见 [references/workflow.md](references/workflow.md)，Studio 操作见 [references/studio-runbook.md](references/studio-runbook.md)。

脚本的真实运行记录见 [VALIDATION.md](VALIDATION.md)。

## 安全与分发

仓库不包含模型、贴图、Cookie、API Key、Roblox 账号信息或本机绝对路径。请确认你对导入和分发的模型资源拥有相应权利。
