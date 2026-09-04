# Validation record

## 2026-09-04 — v2.4 从“角色”扩展为按结构判断的动画模型

- 面向用户的名称改为 **Roblox 动画模型导入**；稳定调用标识仍保留 `$roblox-animated-character-import`，避免已安装 Skill、离线包和旧文档失效。
- 默认用途改为 `animated-model`。审计不再按人形外观判断，而是输出 `asset_kind`：骨骼动画、只有骨架无动作、非骨架动画待复核、静态模型候选或无模型。
- 人物、动物、僵尸、怪物以及用骨骼驱动的车辆/机械共用骨骼动画管线。对象关键帧、约束、驱动器或引擎控制器动画返回 `ANIMATION_BAKE_REQUIRED`，要求烘焙到骨骼或在 Roblox 用关节重建；静态资源返回 `STATIC_MODEL_CANDIDATE`，不会伪造骨架或动作。
- 真实怪物源 `Scorchfang_Scorpion.blend` 在 Windows PowerShell 5.1 下以 `animated-model` 审计：`BONE_ANIMATED_MODEL`、3,786 三角面、1 套骨架、17 个动作，状态 `CONVERSION_REQUIRED`，原有四骨骼影响与格式转换门禁仍然生效。
- 真实 `model_bind.fbx`（有骨架、无动作）返回 `RIGGED_MODEL_WITHOUT_ACTIONS` / `ANIMATION_DATA_MISSING`；临时静态 OBJ 返回 `STATIC_MODEL_CANDIDATE`；临时无骨架对象关键帧 `.blend` 返回 `NON_ARMATURE_ANIMATION_REVIEW_REQUIRED` / `ANIMATION_BAKE_REQUIRED`。
- 首次干净 PowerShell 5.1 前向测试发现两项跨电脑缺陷：调用子 PowerShell 脚本后读取未初始化的 `$LASTEXITCODE`，以及无 BOM UTF-8 JSON 被按系统代码页读取。前者改为以 intake 报告状态为准，后者在审计、批处理、主管线和素材登记脚本中显式使用 UTF-8。
- `run_batch.ps1 -PlanOnly -IntendedUse animated-model` 返回 `BATCH_PLANNED`；原动画计划回归在 PowerShell 5.1 / 7 均通过 23 个断言；PowerShell/Python 语法、Skill 快速结构校验和 `git diff --check` 通过。
- 本轮没有拿真实车辆资源做 Studio 播放，因此只确认“能识别并正确分流”与已有怪物骨骼管线回归，不能宣称任意车辆动画已直接兼容 Roblox。

## 2026-09-04 — v2.3 逐资源决策与中文资源卡

- 纠正 v2.2 将蝎子有效选项推广为通用要求的问题。新计划休息姿势为 `UNDECIDED`，Codex 检查后登记候选、理由及证据；支持当前界面三种选项，不按位置选择。
- `test_animation_import_plan.ps1` 在 Windows PowerShell 5.1 和 PowerShell 7 均通过 23 个断言：默认不猜选项、理由/证据门禁、三个显式选项、不变范围保留、换文件/目标复核、旧硬编码迁移、按动作名登记发布 ID、保留用户报告而不自动升级通过状态。
- 回归使用微型假文件测试计划身份与状态逻辑，**不测试 FBX 解析、真实选项正确性或 Studio 批量导入**。
- 10 个 PowerShell 脚本在 PowerShell 7 解析无错误，5 个 Python 脚本 AST 检查与 Skill 快速结构校验通过。
- 私有蝎子计划修正发布窗口的 Attack02 映射，移除错误的 Attack01 关联。用户反馈分享后 Play 播放一次，标为 `USER_REPORTED_SINGLE_PLAY`；本轮没有重新连接 Studio、上传资产或另存项目。
- 中文资源卡分别说明原始与最终三角面、骨架/动作、外观规格、必要修复、导入兼容性与未测设备性能。没有重新转换原资源；原始 3,786 三角面与现有导出回读一致。
- 这轮证明计划与说明纠偏，不代表在多种新原始资源、另一台电脑或全部动画上已完成前向验收。

## 2026-09-03 — v2.1 Roblox 贴图标准化门禁

针对 Studio 拒绝导入的私有蝎子基础色贴图加入上传前自动化。来源文件为 2048×2048、8 位 RGB PNG，普通解码和尺寸检查通过，但包含 `pHYs` 与 XMP `iTXt` 辅助块；没有保留 Studio 原始错误文本，因此不能把 XMP 声明为唯一根因。

- 新增 `normalize_roblox_textures.ps1/.py`，支持单图和正式 `separate` 交付包；
- 首次跨盘测试暴露 Windows `TEMP` 位于 C:、输出位于 D: 时 `os.replace()` 失败，已改为先复制到目标目录的同卷临时文件再原子替换；
- 标准化输出 `Monster15_Color01_Roblox.png`：2048×2048、8 位 RGB，只有 `IHDR/IDAT/IEND`，无 XMP/DPI，输出 SHA-256 为 `2cf885478a6402ff66a2f8132a382253087a935cc34e10a4af783f9c4d0762a2`；
- 重新解码的像素与原图逐字节相同，没有缩放或颜色变化；
- 整包回归自动更新 `texture_manifest.json`、`bundle_manifest.json` 和哈希，强化后的 `validate_bundle.py` 返回 `BUNDLE_PASS`；
- 主管线回归从原始 `Monster15_AllAnim.fbx` 导出绑定模型和 `Attack01`，自动完成贴图标准化、Blender 新进程回读及交付包校验，最终 `ROUNDTRIP_PASS`；
- 回归输出：`D:\Work\RobloxPipelineTextureRegression_20260903_233617`；私有贴图和模型不进入仓库。

本轮只证明本地编码、结构和像素门禁。修复版图片是否通过 Roblox 上传、审核、体验权限和 fresh Play 仍需要 Studio 实测，不能提前标记 `STUDIO_IMPORT_PASS`。

## 2026-09-03 — v2 批处理与外部贴图正式契约

使用同一私有蝎子原始 GZIP/UnityPackage 执行 `run_batch.ps1 -Convert -FixMaxInfluences -BaseColorTexture ...`：

- 原始包 SHA-256：`cf4fe0dd622ea363ffd4291109069e1396b418b45fe488b5e189900eb69a71a1`；
- 批处理从原始包重新解包、审计并选中标准化后的 `Monster15_AllAnim.fbx`；
- 输出默认使用 `TextureMode=separate`，没有生成 `model_all_in_one.fbx`；
- 正式交付为 1 个 `model_bind.fbx`、17 个单动作 FBX、1 张外部基础色贴图及 JSON 清单；
- Blender 新进程回读和 `bundle_validation.json` 均通过，最高状态为 `ROUNDTRIP_PASS`；
- 生成 `job_state.json`、`batch_manifest.json`、`texture_index.json` 和 `studio_import_plan.json`，批次状态为 `READY_FOR_STUDIO`；
- 前两次调用层参数转发错误被记录为失败尝试，修正后用同一任务 `-Resume` 完成，证明失败证据和断点路径有效；
- 重新打包后的离线 ZIP 可安装到空目录，Skill 快速校验通过；其中 7 个 PowerShell 脚本均使用 UTF-8 BOM，并在 Windows PowerShell 5.1 解析为 0 错误；离线安装副本实际执行 `run_batch.ps1 -PlanOnly` 返回 `BATCH_PLANNED`；
- 本轮没有再次上传 Roblox 云端素材，也没有保存/另存 Studio 项目，因此没有新增 `STUDIO_IMPORT_PASS` 或运行时权限结论。

回归输出保留在私有本机任务目录；本机路径和私有模型不进入仓库。

## 2026-09-03 — 原始 UnityPackage 与 RAR5 分卷入口

本轮使用两个私有原始资源做回归测试，资源本身不进入仓库。

### UnityPackage/GZIP 正常路径

- 输入扩展名为 `.gz`，文件签名为 GZIP，解压前缀确认内部是 TAR `ustar` 和 Unity GUID 目录。
- `intake_source.ps1 -Extract` 安全列出 2,834 个 TAR 条目，并还原 600 条 UnityPackage 逻辑资源记录。
- 还原结果检测到 Unity 生态、1 个核心 FBX、135 张纹理、0 个路径冲突和 0 个嵌套压缩包。
- `audit_source.ps1` 可以直接接收原始 `.gz`，无需用户预先手动解压或指出 FBX。
- 内容审计选中 `Monster15_AllAnim.fbx`：1 个网格、3,786 个三角面、1 套骨架、17 个动作。
- 审计返回 `CONVERSION_REQUIRED`，原因是 359 个顶点超过四骨骼影响，并且原 FBX 没有保留材质槽/图片引用；没有把它误报为可直接导入。

### RAR5 分卷阻止路径

- 一个目录内的 `part1.rar` 到 `part4.rar` 被识别为 1 个资源组，而不是 4 个独立任务。
- 四卷连续、无缺卷，总大小 7,703,820,318 字节。
- 本机 PATH 中的 7-Zip 9.10 无法读取 RAR5；脚本返回 `EXTRACTOR_REQUIRED`，并给出中文下一步。
- 该结果只说明解包工具不兼容，不能据此判定 Unreal 模型损坏。
- 自动安装新版工具被当前执行策略拦截，因此没有替换旧 7-Zip，也没有解包这套私有资源。

## 2026-09-03 — Windows / Blender 5.1.1 / Roblox Studio

The test source is a privately supplied animated Custom Rig and is not included in this repository.

### Blender source and conversion

- 1 mesh, 1,911 vertices, 3,786 triangles.
- 1 armature and 17 skeletal Actions.
- Source maximum: 9 positive bone influences; 359 vertices exceeded four influences.
- Opt-in in-memory correction changed 359 vertices, removed 659 lower-weight links, and produced a maximum of four influences.
- Two weighted top-level bones remained. The exporter did not delete, merge, reparent, or unweight them; it returned `EXPORT_REVIEW_REQUIRED` for Studio playback review.
- Packed 2048×2048 base-color PNG was delivered separately. Its SHA-256 matched the original external PNG byte-for-byte.

### Portable bundle

- 1 bind/model FBX and 17 one-action FBXs were generated.
- A fresh Blender process imported all 18 FBXs.
- The bind/model file contained zero Actions after read-back.
- Every action FBX contained exactly one Action after read-back.
- Bundle validation checked 20 declared files with matching SHA-256 values: 18 FBXs, 1 texture, and 1 texture manifest.
- Result: `ROUNDTRIP_PASS`; root hierarchy remains an explicit Studio review item.

### Studio-local playback

- Existing imported Workspace model: 1 skinned MeshPart, 78 Bones, `AnimationController`, `Animator`, and 17 local `KeyframeSequence` entries.
- `studio_validate_local_sequences.luau` was executed in Edit mode.
- Result: 17/17 `LOCAL_PLAYBACK_PASS`.
- For every action, track load succeeded, `IsPlaying` was true, `TimePosition` advanced through `Animator:StepAnimations()`, and 71–76 Bone transforms changed.

### Not claimed by this validation

- The newly split 17 FBXs were not uploaded again because doing so would create duplicate cloud assets without a delivery need.
- Published AnimationIds were not created, so `RUNTIME_PLAYBACK_PASS` and cross-owner permission were not revalidated by the new scripts.
- The separate texture was not uploaded again; moderation and direct `rbxassetid://` loading remain target-account checks.
- No mobile/PC performance claim was made.

This record validates the local scripts and gate behavior. It is not a promise that every third-party asset or Roblox account configuration will pass.

## 2026-09-03 — collaborator texture regression

A live collaborative Studio place exposed a workflow defect: a failed restricted image had been hidden behind an `rbxthumb://` MeshPart texture and a one-face `Decal`. One collaborator saw a plausible preview while another saw partial and incorrectly mapped color.

The new read-only `studio_audit_asset_dependencies.luau` check was run against that Workspace model and returned `DEPENDENCY_AUDIT_BLOCKED`. It detected:

- a valid direct MeshId;
- a forbidden thumbnail in `MeshPart.TextureID`;
- a failed direct image dependency;
- a face/projection Decal under the MeshPart.

The workflow now treats a saved/published target-place import with **Add to Workspace** enabled as the primary automatic experience-grant path. It does not recommend Open Use as the default repair for a collaborative project, and it cannot pass a model that relies on a thumbnail or Decal fallback.

## 2026-09-03 — source-selection and white-model regression

The same resource directory contained a `.blend`, the original multi-action FBX, and a derived `_Roblox.fbx`. The derived FBX passed triangle and influence checks but had zero material slots and zero material-linked images. Selecting it by filename produced a structurally valid white model.

The new `audit_source.ps1` compared all candidates and selected the `.blend` because it retained one UV layer, one used material, one material-linked 2048×2048 image, one armature, and 17 Actions. It reported `CONVERSION_REQUIRED` because 359 vertices exceeded four influences and Blender format still required export.

After opt-in influence limiting, the pipeline generated and freshly read back an embedded `model_all_in_one.fbx` with:

- 1 mesh, 1,911 vertices, and 3,786 triangles;
- 4 maximum positive bone influences and zero vertices over four;
- 1 UV layer, 1 material slot, and 1 embedded material-linked image;
- 17 Actions after independent FBX read-back.

The live Studio dependency audit was also strengthened to use `PreloadAsync()` callback results. For image `118366329830724`, metadata and editor-side pixel reading succeeded, but MeshPart preloading returned `AssetFetchStatus.Failure`; this is now classified as an experience permission/binding failure rather than a valid texture pass.

## 2026-09-04 — same-rig animation import and permission regression

The portable scorpion bundle was tested again in the live `MAX模型` experience.

- The target `Workspace.Scorchfang_V2` contained 81 Bones, one skinned MeshPart, one `AnimationController`, and a server-visible `Animator`.
- The bind mesh and normalized texture dependencies both returned successful preload results.
- In this scorpion test the user selected **“导入的骨架”** and reached the Animation Editor timeline. The earlier workflow incorrectly generalized that result; v2.3 removes the fixed option and requires per-asset assessment and representative-action validation.
- The canary animation was published under a collaborator's personal creator, while the target Universe belonged to a different user. Concrete account and asset identifiers remain only in the private job plan and are not included in this public repository.
- Fresh Play returned an experience-access error for that animation; the track length remained zero and no animation played.

Result: mesh and texture gates passed, and the local import mapping was identified. Runtime animation remains `PERMISSION_BLOCKED` until the published AnimationId is granted to the exact target Universe and a new Play session proves positive length, advancing time, and Bone changes. The presence of an `Animator` is not evidence of asset permission.
