# Validation record

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

回归输出位于本机 `D:\Work\RobloxBatchV2_Scorpion_20260903_205227`；私有模型不进入仓库。

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
