# Roblox Studio import and playback runbook

Use this document only when Studio import, asset upload, or animation playback is in scope.

## 1. Connection and target gate

### Studio MCP route

1. Call `list_roblox_studios`.
2. A non-empty list is the connection gate.
3. If several places are open, match the human-readable place name/ID and confirm before editing.
4. Check Studio state before choosing Edit, Server, or Client tools.

Do not treat an installed MCP configuration or a running Studio process as a connected session.

### Manual route

Record:

- Studio version if visible;
- open place name and place/universe ID when published;
- signed-in Roblox username;
- experience owner (user or group);
- UI language.

These values explain failures that cannot be reproduced from the FBX alone.

## 2. Import the base model

Use **File → Import** and add `model_bind.fbx` from the generated bundle.

Recommended Custom Rig settings:

| Setting | Value / decision |
| --- | --- |
| Rig Type | `Custom` unless R15/avatar validation was explicitly completed |
| Import Only As Model | enabled |
| Add to Workspace | enabled for current-place testing |
| Upload to Roblox | disabled for local iteration; enabled only when persistent asset IDs are required |
| Creator | prefer the target experience owner/group; a collaborator's personal creator is allowed only when the automatic game grant is verified |
| Keep Zero Influence Bones | enabled when animation hierarchy uses unweighted parents |
| Scale Unit | `Studs` for the provided exporter contract |
| World Forward / World Up | `Front` / `Top` for the provided exporter contract |
| Merge Meshes | disabled |
| Set Pivot to Scene Origin | enabled unless project pivot requirements differ |
| Uses Cage | disabled for ordinary Custom Rigs without cage meshes |

The Importer supports rig, skinning, animation, and PBR data, but every warning/error must be expanded to the exact child object before continuing. Current setting meanings are documented in the [Roblox Importer](https://create.roblox.com/docs/studio/importer).

### Collaborator upload and automatic permission

For a game that is already saved or published, Roblox documents that **Add to Workspace** also grants the game permission to use the imported restricted asset. This is the expected path when a collaborator uploads a complete model in the target project.

Before importing:

1. record the signed-in account, experience owner, selected `Creator`, `Upload to Roblox`, and `Add to Workspace`;
2. keep **Add to Workspace** enabled when the result must work in this experience;
3. prefer the experience owner/group as `Creator` when available;
4. if the asset is created under the collaborator's personal account, verify every generated mesh/image dependency received the target-game grant.

Do not conclude that the collaborator relationship itself failed merely because the owner names differ. First determine whether the import was detached from the target game, **Add to Workspace** was disabled, a separately uploaded image missed the game grant, or a dependency remained restricted.

### Queue cache rule

If an import row failed and the FBX was regenerated at the same path:

1. record the original error;
2. right-click the failed row and choose **Delete from queue**, or click the broom **Clear queue**;
3. add the regenerated file again;
4. verify the preview metadata changed;
5. retry once.

Do not use only **Reconfigure** as proof the new file was parsed. The official Importer exposes both individual deletion and Clear queue for this purpose.

## 3. Texture path

### Preferred visual path and fallback

Prefer the audited embedded `model_all_in_one.fbx` or `model_bind.fbx` when it preserves UV, material, and image mapping. If Roblox rejects the embedded image transaction, use the `separate` bundle with `textures/` and `texture_manifest.json` to isolate model/rig import from image upload.

1. Import images through the exact target experience's Asset Manager/Importer under the recorded Creator.
2. When the target is saved/published, use the current-experience grant path; do not default to Open Use.
3. Rebuild the intended material mapping from `texture_manifest.json`.
4. For basic color, assign the uploaded image to the MeshPart UV texture field expected by the imported asset. Dragging an image onto a part can create a one-face `Decal`; that is not a full-mesh UV assignment.
5. For PBR, create/assign a `SurfaceAppearance` and map Color/Normal/Roughness/Metalness channels deliberately.
6. Check alpha mode and double-sided requirements instead of making the entire mesh transparent.

### Permission and moderation acceptance

After assignment, start a fresh Play session and check Output.

- Direct `rbxassetid://` content must render.
- No clickable permission error may remain.
- An asset still under moderation is `PENDING`, not `PASS`.
- An `rbxthumb://` image is only a thumbnail and cannot satisfy texture acceptance.
- Never write `rbxthumb://` into `MeshPart.TextureID`, `SurfaceAppearance` maps, `Decal.Texture`, or other production content fields.
- Run `scripts/studio_audit_asset_dependencies.luau`; any thumbnail content, failed direct dependency, or suspicious one-face Decal fallback keeps the result at `TEXTURE_BLOCKED` or `PERMISSION_BLOCKED`.

### TextureID is set but the mesh stays white

Do not infer the cause from the populated property. Check in this order:

1. Confirm the cloud image contains non-transparent pixels and is the intended asset type.
2. Confirm the uploaded mesh contains UVs with face-to-UV assignments.
3. Run the dependency audit. It calls `PreloadAsync()` and records the callback result instead of trusting only an old cached `GetAssetFetchStatus()` value.
4. If the logged-in Studio user can read the image but `MeshPart.TextureID` preloading returns `Failure`, classify it as an experience permission/binding failure. User ownership proves editor access, not runtime access by a differently owned experience.
5. Re-import a material-linked/embedded FBX in the exact saved experience with **Upload to Roblox** and **Add to Workspace** enabled, or have the image owner grant that experience access. Do not use a thumbnail or one-face Decal.
6. If preload succeeds but the model remains white, clear/reassign the field once, verify `MeshPart.Color` is white, inspect SurfaceAppearance overrides, and compare the mesh's actual UV data.

When the FBX at the same path has changed, delete its old Importer queue row and add it again. An already-open preview can continue showing the previously parsed white version.

Roblox notes that restricted assets need explicit creator/game permission, and the game itself needs permission for script/runtime use. See [asset privacy](https://create.roblox.com/docs/projects/assets/privacy).

## 4. Animation import

Use one animation FBX per action from `animations/`.

For each action:

1. select the imported target rig;
2. open Animation Editor and choose that rig;
3. import the matching FBX animation onto the same skeleton;
4. confirm frame range, pose, root motion, and loop setting;
5. save locally for preview;
6. publish only when persistent runtime use is requested;
7. choose the same intended owner as the experience when possible, otherwise grant collaborator and experience access;
8. record the resulting animation ID.

If the action cannot be imported onto the rig, return to Blender and compare bone hierarchy, rest pose, action slots, and coordinate space. Matching names alone are insufficient.

## 5. Local sequence playback

Use `scripts/studio_validate_local_sequences.luau` when the importer/Animation Editor created local `KeyframeSequence` data such as `AnimSaves`.

This gate proves only:

- the local sequence can be registered for preview;
- `Animator` creates a track;
- the track starts and time advances;
- at least one Bone transform changes.

`KeyframeSequenceProvider` is deprecated and temporary hash IDs do not survive as production animation assets. A local pass must be reported as `LOCAL_PLAYBACK_PASS`, not `RUNTIME_PASS`.

## 6. Published animation playback

Use `scripts/studio_validate_animation_ids.luau` after filling in the target model path and animation IDs.

For an NPC/non-player model:

- create the `Animator` on the server under `AnimationController`;
- load and start the animation on the server for replication.

For a player's character, replication rules differ. The `Animator` must be created on the server; a player-owned character may start tracks from its owning client. See [Animator](https://create.roblox.com/docs/reference/engine/classes/Animator).

Pass each action only when:

- `Animator:LoadAnimation()` succeeds;
- `AnimationTrack.Length > 0` after bounded wait;
- `IsPlaying` becomes true;
- `TimePosition` increases;
- an expected bone changes;
- Output has no permission/load error;
- visual deformation is acceptable.

## 7. Size correction after playback

When action correctness is the priority:

1. record the initial Model bounding box;
2. pass all required actions at original imported scale;
3. calculate one uniform scale for the whole Model;
4. call `Model:ScaleTo()` or use the Studio scale tool on the complete rig;
5. record the final bounding box;
6. replay all required actions;
7. inspect root translation, feet, attachments, and collisions.

Do not scale only a MeshPart while leaving bones, attachments, or collision proxies unchanged.

## 8. Player replacement is a separate gate

A playable character normally needs project-specific work beyond a skinned mesh:

- a `Humanoid` or custom controller;
- a stable root/primary part and collision proxy;
- camera and input integration;
- spawn/respawn handling;
- animation controller replacement and priorities;
- accessories/attachments if required.

Do not claim player replacement from a Custom Rig import alone.

## 9. End-state checklist

- [ ] Correct place and Creator recorded.
- [ ] Saved/published target, Upload to Roblox, and Add to Workspace state recorded.
- [ ] Collaborator upload used the target-place automatic grant path or has explicit game-grant evidence.
- [ ] Failed queue item cleared before any changed-file retry.
- [ ] Workspace object inspected, not only previewed.
- [ ] Direct textures load in fresh Play; thumbnails not used as substitutes.
- [ ] Second collaborator/client sees the same complete materials when cross-account use is required.
- [ ] Every required action has a named local or published asset.
- [ ] Playback start, time progress, bone change, and visual deformation checked.
- [ ] All required actions replayed after resizing.
- [ ] Saving/publishing status reported separately from import status.
