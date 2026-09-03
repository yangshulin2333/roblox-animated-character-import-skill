# Roblox 带动画角色导入 Skill

一个可移植的 Codex Skill。输入可以是 UnityPackage/GZIP、Unreal 工程或 UAsset 包、3ds Max、Blender、FBX、glTF、ZIP、7z、RAR 分卷以及混合资源目录；它先整理和分析原始资源，再转换、导入并实际播放验证 Roblox Custom Rig 角色。

它解决的不是“某个模型在我电脑上导入成功”，而是把另一台电脑最容易漏掉的前置条件和验收门禁固定下来：Blender 版本、FBX 单动作契约、4 骨骼权重、Studio 导入队列缓存、协作者上传时的 Creator 与 Add to Workspace、每个贴图/网格依赖的体验授权、动画真实播放、缩放后的二次播放。

## 安装

Windows PowerShell：

```powershell
git clone https://github.com/yangshulin2333/roblox-animated-character-import-skill "$env:USERPROFILE\.codex\skills\roblox-animated-character-import"
```

重启或新开 Codex 任务后使用：

```text
$roblox-animated-character-import 把 D:\path\character.zip 导入当前 Roblox Studio，优先验证全部动作；只在必要时用 Blender 修改，不另存 Studio 副本。
```

如果界面使用 `@` 选择能力，在 Skill 列表中选择 **Roblox 带动画角色导入**；Skill 的稳定标识仍是 `$roblox-animated-character-import`。

## 最短使用方式

对原始包执行一体化审计；脚本会先识别容器、生成独立检测工作目录，再检查模型内容，这一步不会转换或覆盖原模型：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\audit_source.ps1 `
  -Source "D:\原始资源或压缩包" `
  -IntendedUse custom-rig-npc `
  -ReportDir "D:\检测报告\资源名"
```

它会按文件签名识别真实格式，归并 RAR 分卷，还原 UnityPackage 的 GUID 资源结构，然后逐个检查可读候选，并按网格、Roblox 三角面、骨架、动作、UV、材质和贴图保留情况选择真正的源文件。`*_Roblox.fbx` 这样的文件名不算通过证据。

如果只想确认原始包是什么，不解包：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\intake_source.ps1 `
  -Source "D:\原始资源" `
  -WorkDir "D:\检测工作区\资源名"
```

生成跨电脑交接包：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_pipeline.ps1 `
  -Source "D:\path\character.blend" `
  -OutputDir "D:\path\RobloxExport" `
  -AllActions `
  -FixMaxInfluences `
  -AllInOne `
  -TextureMode embed
```

默认行为：

- 不覆盖源文件；
- 不自动另存 Roblox Studio 项目；
- 默认拒绝缺少 UV、材质槽或材质贴图引用的角色，避免再次生成白模；
- 输出一个绑定模型 FBX、每个动作一个 FBX、JSON 清单，并可额外输出带嵌入贴图和全部动作的 `model_all_in_one.fbx`；
- 检测到每顶点超过 4 根骨骼影响时停止。确认需要自动裁减时再加 `-FixMaxInfluences`；
- 输出目录非空时停止，避免覆盖上一轮结果。
- 在已保存/已发布的目标体验中上传时，优先依靠 **Add to Workspace** 自动授予当前体验使用权限；不会把“设置为开放使用”当成协作者项目的默认修复。
- 禁止用 `rbxthumb://` 或单面 `Decal` 冒充完整 MeshPart 贴图；可用 `scripts/studio_audit_asset_dependencies.luau` 做只读依赖审计。

## 重要边界

这套 Skill 无法保证任意第三方模型都能 100% 导入。损坏文件、未授权资产、不可兼容骨架、Roblox 审核或账户权限都可能阻止完成。它保证的是：每一步都有可复现输入、明确状态、失败恢复路径和可核验证据，不再把“预览正常”误报为“运行正常”。

原始资源规则见 [references/source-intake.md](references/source-intake.md)，完整流程见 [references/workflow.md](references/workflow.md)，Studio 操作见 [references/studio-runbook.md](references/studio-runbook.md)。

脚本的真实运行记录见 [VALIDATION.md](VALIDATION.md)。

## 安全与分发

仓库不包含模型、贴图、Cookie、API Key、Roblox 账号信息或本机绝对路径。请确认你对导入和分发的角色资源拥有相应权利。
