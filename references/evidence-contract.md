# Evidence and handoff contract

Use this contract to prevent “works on my machine” reports. Every claim must name the machine, file identity, Studio target, and highest observed gate.

## Evidence files

| File / evidence | Produced by | Proves | Does not prove |
| --- | --- | --- | --- |
| `source_intake.json` | `intake_source.ps1` | 原始容器、分卷、标准化路径和资源生态 | 模型适用于 Roblox |
| `preflight_report.json` or console JSON | `preflight.ps1` | source/tool discovery on this computer | asset compatibility |
| `inspection_report.json` | Blender inspector | source geometry/rig/action facts | Studio import/playback |
| `bundle_manifest.json` | Blender exporter | exact delivered files, actions, hashes, in-memory fixes | Roblox acceptance |
| `bundle_validation.json` | bundle validator | manifest files exist and hashes match | FBX semantics |
| fresh Blender read-back report | Blender inspector | exported FBX can be parsed independently | Studio behavior |
| Importer queue screenshot/log | Studio | selected file/settings/error | Workspace object/runtime |
| Workspace tree + bounds | Studio | actual object created | animation works |
| local playback report | Studio | temporary sequence drives the rig | published/runtime permission |
| published playback report | fresh Play session | asset ID loads and animates in target experience | mobile performance |
| device profiling record | target client | measured performance under stated load | every other device/configuration |

## Required statuses

Use exactly one highest status and list lower gates separately:

- `PREFLIGHT_PASS`
- `SOURCE_PASS`
- `EXPORT_PASS`
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
# Animated character import report

- Date/time and timezone:
- Operator/Codex version:
- Computer/OS:
- Blender version/path:
- Roblox Studio version/place:
- Signed-in creator:
- Experience owner:
- Importer Creator:
- Target already saved/published: yes | no
- Upload to Roblox: yes | no
- Add to Workspace: yes | no
- Source filename and SHA-256:
- 原始容器类型、分卷成员和标准化路径：
- Unity/Unreal/Blender/3ds Max 生态识别结果：
- Source-package audit status and selected candidate:
- Intended use: custom-rig-npc | player-replacement | avatar-r15
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

## Export facts

- Model FBX:
- Action FBXs:
- Texture mode:
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
