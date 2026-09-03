# Validation record

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
