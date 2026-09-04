# Evidence and handoff contract

Use this contract to prevent “works on my machine” reports. Every claim must name the machine, file identity, Studio target, and highest observed gate.

## Evidence files

| File / evidence | Produced by | Proves | Does not prove |
| --- | --- | --- | --- |
| `source_intake.json` | `intake_source.ps1` | 原始容器、分卷、标准化路径和资源生态 | 模型适用于 Roblox |
| `batch_manifest.json` / `job_state.json` | `run_batch.ps1` | 批次拆分、任务指纹、尝试次数、最高门禁和恢复点 | Studio 已导入或云端素材可用 |
| `texture_index.json` / `studio_asset_registry.json` | batch/Studio record scripts | 重复贴图哈希与同 Creator/Universe 的已验证复用记录 | 未经 fresh Play 的素材权限 |
| `preflight_report.json` or console JSON | `preflight.ps1` | source/tool discovery on this computer | asset compatibility |
| `inspection_report.json` | Blender inspector | source geometry/rig/action facts | Studio import/playback |
| `bundle_manifest.json` | Blender exporter | exact delivered files, actions, hashes, in-memory fixes | Roblox acceptance |
| `texture_normalization.json` | texture normalizer | source/output identity, decoded format, metadata removal, dimension/channel policy and pixel read-back | Studio upload, moderation or runtime permission |
| `bundle_validation.json` | bundle validator | manifest files exist and hashes match | FBX semantics |
| fresh Blender read-back report | Blender inspector | exported FBX can be parsed independently | Studio behavior |
| Importer queue screenshot/log | Studio | selected file/settings/error | Workspace object/runtime |
| Workspace tree + bounds | Studio | actual object created | animation works |
| local playback report | Studio | temporary sequence drives the rig | published/runtime permission |
| published playback report | fresh Play session | asset ID loads and animates in target experience | mobile performance |
| `studio_import_plan.json.animation_import` | batch + Studio preparation | target Custom Rig, rest-pose choice, ordered action hashes, local/publish/permission status | visual correctness or runtime permission until separately tested |
| device profiling record | target client | measured performance under stated load | every other device/configuration |

## Required statuses

Use exactly one highest status and list lower gates separately:

- `PREFLIGHT_PASS`
- `SOURCE_PASS`
- `EXPORT_PASS`
- `TEXTURE_NORMALIZATION_PASS`
- `ROUNDTRIP_PASS`
- `STUDIO_IMPORT_PASS`
- `LOCAL_PLAYBACK_PASS`
- `RUNTIME_PLAYBACK_PASS`
- `PERMISSION_PASS`
- `SCALE_PASS`
- `PERFORMANCE_PASS`
- `PRODUCTION_READY`
- or a named `*_BLOCKED` state.

`PRODUCTION_READY` requires all gates the user requested, not every optional gate in the workflow.

## Minimum report template

```markdown
# Animated model import report

- Date/time and timezone:
- Operator/Codex version:
- Computer/OS:
- Blender version/path:
- Roblox Studio version/place:
- Signed-in creator:
- Experience owner:
- Importer Creator:
- Target already saved/published: yes | no
- Animation target rig path:
- Animation rest-pose source: `UNDECIDED` | `IMPORTED_SKELETON` | `IMPORTED_SKELETON_ZERO_ROTATIONS` | `ANIMATION_EDITOR_SKELETON`
- Decision reason, source/target scope, and representative-action evidence:
- Decision status: proposed | user-reported working | tool/visual verified
- Animation uploader and experience owner:
- Target Universe ID:
- Upload to Roblox: yes | no
- Add to Workspace: yes | no
- Source filename and SHA-256:
- 原始容器类型、分卷成员和标准化路径：
- Unity/Unreal/Blender/3ds Max 生态识别结果：
- Source-package audit status and selected candidate:
- Intended use: animated-model | custom-rig-npc | player-replacement | avatar-r15
- Detected asset kind: BONE_ANIMATED_MODEL | RIGGED_MODEL_WITHOUT_ACTIONS | NON_ARMATURE_ANIMATION_REVIEW_REQUIRED | STATIC_MODEL_CANDIDATE | NO_MODEL
- Requested gate:
- Highest observed status:

## Source facts

- Meshes / triangles per mesh:
- Armatures / bones / roots:
- Max positive influences / vertices over four:
- Actions and frame ranges:
- Textures / missing files:
- UV layers / material slots / material-linked images:
- Source units and bounds / selected Studio Scale Unit:

## 中文资源卡（优先交给用户）

- 原始包实际包含：模型/资源组、结构分类、外观、动作、贴图及不能直接迁移的内容。
- 原始/最终总三角面、最大单 Mesh 三角面、网格数和数据来源。
- 骨骼数、权重、动作数量/名称与本次贴图规格。
- 结论：导入兼容性 / NPC或玩家用途 / 手机电脑性能，分别说明。
- Codex 将完成的必要操作；用户当前唯一需要配合的步骤，或“暂不需要”。
- 本模型建议选项与依据；已验证和待验证项。

## Export facts

- Model FBX:
- Action FBXs:
- Texture mode:
- Texture normalization policy/report and delivered `*_Roblox.png` paths:
- In-memory changes:
- Fresh read-back result:

## Studio import

- Queue cleared before changed-file retry: yes | no | not needed
- Settings/preset:
- Workspace model path:
- MeshParts / bones / bounds:
- Importer and Output errors:

## Animation results

| Action | Source present | Studio asset/local sequence | Starts | Time advances | Bone changes | Visual result | After scale |
| --- | --- | --- | --- | --- | --- | --- | --- |

用户报告“授权后播放一次”记为 `USER_REPORTED_SINGLE_PLAY`，标注动作/ID（不能确定时留待核实）和日期；不升级为工具实测的全部动作、循环或性能通过。发布 ID 必须和发布窗口/动作名核对，不能自动归给首个队列项。

## Texture and permissions

- Mesh/image/animation owners:
- Dependency audit result:
- Automatic target-game grant evidence:
- Manual experience permission evidence, if used:
- Moderation state:
- Direct `rbxassetid://` load in fresh Play:
- `PreloadAsync` callback status (do not rely only on cached fetch status):
- Thumbnail fallback used: must be `no` for production pass
- One-face Decal used as full-mesh fallback: must be `no`
- Second collaborator/client visual result, when required:

## Size/performance

- Before/after bounds:
- Target size rule:
- Device/quality/resolution/concurrent rigs:
- Frame time/memory/test duration:

## Open failures and single next action

- Blocking status:
- Exact error:
- Existing side effects/assets:
- Safe next action:
```

## Handoff: sender to recipient

**Payload**

- the generated export directory;
- `batch_manifest.json`、各任务 `job_state.json` 和 `studio_import_plan.json`；
- this Skill or its public repository URL;
- completed report;
- source redistribution statement;
- required Roblox owner/permission action, if any.

**Recipient success response**

```json
{
  "source_sha256_matches": true,
  "bundle_validation": "PASS",
  "studio_place": "name or id",
  "highest_status": "RUNTIME_PLAYBACK_PASS",
  "failed_actions": [],
  "permission_errors": []
}
```

**Recipient failure response**

```json
{
  "ok": false,
  "blocked_at": "IMPORT_BLOCKED",
  "exact_error": "copy the Importer or Output error",
  "retryable": false,
  "queue_cleared": true,
  "created_asset_ids": [],
  "next_action": "asset owner grants the experience permission"
}
```

The recipient must not answer only “failed” or “successful.” The response must identify the gate and evidence.
