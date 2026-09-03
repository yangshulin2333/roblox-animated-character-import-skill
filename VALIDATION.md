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
