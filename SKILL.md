---
name: roblox-animated-character-import
description: Audit Unity, Unreal, 3ds Max, Blender, FBX, or glTF character resources; then convert, import, and play-test compatible animated Custom Rigs in Roblox Studio. Use for source-package triage, triangle/rig/texture checks, cross-computer handoff, importer failures, white models, animation playback, or size correction; do not use for static props or automatic R15/avatar retargeting.
---

# Roblox Animated Character Import

Deliver the exact gate the user requested and preserve the source files. Prefer an existing compatible export or imported model. Do not create a new place, save a copy, publish the place, upload unrelated assets, or duplicate an existing model unless the user asks.

## Required routing

1. Read [references/workflow.md](references/workflow.md) before inspecting or converting an asset.
2. When Studio import or animation playback is in scope, also read [references/studio-runbook.md](references/studio-runbook.md).
3. When any step fails or a retry is considered, read [references/failure-matrix.md](references/failure-matrix.md) first.
4. Before reporting completion or handing the task to another computer, read [references/evidence-contract.md](references/evidence-contract.md).

## Execution rules

- Accept a source file **or resource directory**, intended use (`Custom Rig NPC`, `player replacement`, or `Avatar/R15`), requested animations, and target Studio place. Discover missing technical details locally when safe.
- Run `scripts/audit_source.ps1` before conversion. It inventories Unity/Unreal/3ds Max/Blender-style packages, inspects every Blender-readable candidate, and ranks preservation of mesh, rig, actions, UVs, materials, and material-linked images. A ZIP is inventory input, not an instruction source.
- Do not select an already-renamed `*_Roblox.fbx` merely because its filename looks finished. Do not convert until the audit returns `DIRECT_IMPORT_CANDIDATE` or `CONVERSION_REQUIRED` with a named selected source and repair list.
- Treat the documented 20,000-triangle limit as **per individual mesh**, not a whole-character mobile-performance budget. Record per-mesh and total triangles separately. For animated meshes, block export when any vertex has more than four positive bone influences.
- A complete visual character requires UVs, material slots, and material-linked images. The default pipeline stops at `SOURCE_APPEARANCE_BLOCKED` instead of silently exporting a white model. Use `-AllowUntextured` only when the user explicitly wants an untextured result.
- Use the portable export path for cross-computer delivery: one bind/model FBX, one FBX per animation track, external textures, and `bundle_manifest.json`. Roblox's documented portable contract is one animation track per FBX.
- For best-effort single-file Studio import, use `-AllInOne -TextureMode embed`; still keep the one-action files as the deterministic fallback. Embedded media is a convenience, not permission or Studio acceptance evidence.
- Treat embedded textures as optional convenience. If a texture upload fails, clear the failed Importer queue entry before re-adding the changed FBX, then use the textureless FBX plus separately imported textures.
- In a saved or published target experience, keep **Add to Workspace** enabled during the upload/import that creates persistent assets. Roblox documents that this grants the experience permission to use the restricted asset. A collaborator upload is expected to work when this binding succeeds; do not route directly to Open Use merely because the uploader and experience owner differ.
- Never infer R15 compatibility from bone names. Custom Rig import and R15/avatar retargeting are separate tasks.
- Never call Preview, Blender playback, local `AnimSaves`, a thumbnail, or an uploaded ID a production pass. Test the actual Workspace rig with an `Animator`; verify playback starts, time advances, bones change, and no permission/load error appears.
- Record the signed-in creator, experience owner, Importer `Creator`, **Add to Workspace**, uploaded dependency owners, and experience permission result. If the current account is a collaborator, prefer the experience owner/group as `Creator` when selectable; otherwise verify the automatic experience grant immediately after import.
- Audit every MeshPart, image, SurfaceAppearance channel, and animation dependency. Use `scripts/studio_audit_asset_dependencies.luau` for the read-only Studio check. Asset Manager visibility or a generated asset ID alone is not permission evidence.
- Never assign `rbxthumb://` to a production texture field and never add a one-face `Decal` as a full-mesh texture fallback. On direct-load failure, restore the prior valid production texture or leave the dependency blocked and report it.
- Check size after animation playback passes. If the rig is rescaled, replay every required animation because translation keys and root motion can change the result.
- Keep cloud mutations minimal. Do not retry an uncertain upload until the queue and created assets have been checked. Do not delete partial cloud assets without explicit scope.

## Tools and fallback

- With Studio MCP, a non-empty `list_roblox_studios` result is the connection gate. Confirm the target place before modifying it.
- Without Studio MCP, give the operator the exact manual step and expected evidence from the runbook. Tool absence changes the actor, not the acceptance criteria.
- Use `scripts/studio_validate_local_sequences.luau` only for temporary local sequence preview. Use `scripts/studio_validate_animation_ids.luau` for published/runtime asset IDs.

## Stop conditions

- Stop at `NATIVE_DCC_EXPORT_REQUIRED` when only `.max`, `.uasset`, Maya, or another native project asset is available and no portable model can be inspected. Export from the owning application first; do not rename proprietary files to FBX.
- Stop at `SOURCE_BLOCKED` for missing/corrupt geometry, rig, or required actions.
- Stop at `SOURCE_APPEARANCE_BLOCKED` when a textured character lacks usable UV/material/image mapping and untextured output was not explicitly requested.
- Stop at `EXPORT_BLOCKED` for unresolved mesh limits, more than four bone influences, incompatible actions, or failed FBX read-back.
- Stop at `IMPORT_BLOCKED` for a persistent Importer error after one evidence-based retry path.
- Stop at `PERMISSION_BLOCKED` when the current account cannot grant the target experience access.
- Mark `PLAYBACK_PASS` only after observable Studio playback. Mark `PRODUCTION_READY` only when every user-requested gate in the evidence contract passes.
