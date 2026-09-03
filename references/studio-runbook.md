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
| Creator | the intended experience owner or an owner that can grant the experience access |
| Keep Zero Influence Bones | enabled when animation hierarchy uses unweighted parents |
| Scale Unit | `Studs` for the provided exporter contract |
| World Forward / World Up | `Front` / `Top` for the provided exporter contract |
| Merge Meshes | disabled |
| Set Pivot to Scene Origin | enabled unless project pivot requirements differ |
| Uses Cage | disabled for ordinary Custom Rigs without cage meshes |

The Importer supports rig, skinning, animation, and PBR data, but every warning/error must be expanded to the exact child object before continuing. Current setting meanings are documented in the [Roblox Importer](https://create.roblox.com/docs/studio/importer).

### Queue cache rule

If an import row failed and the FBX was regenerated at the same path:

1. record the original error;
2. right-click the failed row and choose **Delete from queue**, or click the broom **Clear queue**;
3. add the regenerated file again;
4. verify the preview metadata changed;
5. retry once.

Do not use only **Reconfigure** as proof the new file was parsed. The official Importer exposes both individual deletion and Clear queue for this purpose.

## 3. Texture path

### Preferred portable path

The generated `model_bind.fbx` is textureless while `textures/` and `texture_manifest.json` are separate. This isolates model/rig import from image upload.

1. Import images through Asset Manager/Importer under the correct Creator.
2. Rebuild the intended material mapping from `texture_manifest.json`.
3. For basic color, assign the uploaded image to the MeshPart texture field expected by the imported asset.
4. For PBR, create/assign a `SurfaceAppearance` and map Color/Normal/Roughness/Metalness channels deliberately.
5. Check alpha mode and double-sided requirements instead of making the entire mesh transparent.

### Permission and moderation acceptance

After assignment, start a fresh Play session and check Output.

- Direct `rbxassetid://` content must render.
- No clickable permission error may remain.
- An asset still under moderation is `PENDING`, not `PASS`.
- An `rbxthumb://` image is only a thumbnail and cannot satisfy texture acceptance.

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
- [ ] Failed queue item cleared before any changed-file retry.
- [ ] Workspace object inspected, not only previewed.
- [ ] Direct textures load in fresh Play; thumbnails not used as substitutes.
- [ ] Every required action has a named local or published asset.
- [ ] Playback start, time progress, bone change, and visual deformation checked.
- [ ] All required actions replayed after resizing.
- [ ] Saving/publishing status reported separately from import status.
