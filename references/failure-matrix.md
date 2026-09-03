# Failure and recovery matrix

Read this before retrying. A retry must change a relevant condition and must not create uncontrolled duplicate cloud assets.

| Symptom / evidence | Likely class | Recovery | Stop condition |
| --- | --- | --- | --- |
| Source path does not exist on another PC | Handoff/path | Use the recipient's absolute source path; never reuse sender paths | `SOURCE_BLOCKED` if the actual asset is absent |
| `.fbx` path is a directory or ZIP wrapper | Input shape | Inventory the path and locate the real model file | stop if no supported file exists |
| Blender executable not found | Environment | Pass `-BlenderPath`, set `BLENDER_EXE`, or install a compatible Blender version | `PREFLIGHT_BLOCKED` |
| Blender background log says MCP cannot start | Tool mode | Ignore MCP for background scripts; use Blender CLI for inspection and GUI only for visual work | stop only if the Blender import itself fails |
| 3ds Max/material nodes are ignored | Material translation | Rebuild basic/PBR mapping from actual images; do not assume DCC shader nodes transfer | `SOURCE_BLOCKED` if required textures are missing and no repair is authorized |
| Any mesh exceeds 20,000 triangles | Geometry | Split/reduce that mesh, then read back and check deformation | `EXPORT_BLOCKED` until each exported mesh passes current Roblox rules |
| Vertex has more than four bone influences | Skinning | Prefer manual weight cleanup; optional `-FixMaxInfluences` keeps strongest four and renormalizes | `EXPORT_BLOCKED` until report is clean and joints are visually retested |
| Intended Roblox Root is weighted or far from origin | Rig | First distinguish the designated Root from a top-level deform bone; repair root influence/transform in a temporary scene | stop if animation space cannot be preserved |
| Several top-level bones are present | Rig ambiguity | Inspect hierarchy/actions; do not auto-delete roots or merge skeletons. A weighted top-level deform bone is not automatically the designated Roblox Root | `EXPORT_REVIEW_REQUIRED` until Studio playback confirms the hierarchy |
| Action cannot be assigned in Blender | Action slot/rest pose | Select compatible action slot or retarget explicitly; verify frame range | `EXPORT_BLOCKED` for required action |
| Multi-action FBX behaves differently on another PC | Unsupported portability assumption | Export one animation track per FBX and import each onto the same target rig | do not use multi-action result as cross-PC evidence |
| Model is about 100× too large/small or sideways | Units/axes | Recheck FBX Unit Scale, exporter axes, Importer Scale Unit and World Forward/Up; avoid stacking arbitrary factors | `IMPORT_BLOCKED` if orientation/scale remains unknown |
| `base_color_texture` upload fails | Texture upload transaction | Record error, generate/use textureless FBX and separate images, remove failed queue row, add file again | `IMPORT_BLOCKED` after one changed-condition retry |
| Changed FBX shows the same old error immediately | Import queue cache | Delete the individual row or Clear queue with broom, then re-add and confirm preview metadata | stop if a clean re-add still fails |
| Mesh imports but appears white | Missing mapping, permission, or moderation | Check image upload result, material assignment, direct content load, Output, and moderation state separately | `PERMISSION_BLOCKED` or `TEXTURE_BLOCKED` |
| Asset ID and metadata exist but direct texture does not render | Permission/moderation/fetch | Grant creator/game permission if owned; start a fresh Play session; wait for moderation if pending | do not mark pass based on metadata |
| `rbxthumb://` displays the image | Thumbnail-only | Remove it as production evidence and test direct `rbxassetid://` | `TEXTURE_BLOCKED` until direct content works |
| Studio Output offers “share access” | Restricted asset | Account owner reviews and grants the intended experience access | `PERMISSION_BLOCKED` if current user lacks authority |
| Importer Creator differs from experience owner | Ownership mismatch | Prefer uploading under the intended owner/group or grant both collaborator and experience permissions | stop before runtime claim |
| Imported model has `AnimSaves` but Play does nothing | Missing runtime setup | Add/find `AnimationController` + server-created `Animator`; locally register sequences only for preview | `PLAYBACK_BLOCKED` |
| Track loads but `Length == 0` | Asset not ready, wrong ID, or permission | bounded wait, inspect Output, verify ID/owner/game access | stop after timeout; do not spin indefinitely |
| `IsPlaying` true but no bone changes | Wrong rig/action mapping | Compare pose names/hierarchy, target rig, animation source, and expected moving bones | `PLAYBACK_BLOCKED` |
| Track plays once but loop jumps | Source or conversion seam | Compare first/last poses and root translation; repair only if seamless loop is required | action pass may be non-looping only if user accepts |
| Model scaled and root motion becomes wrong | Post-scale animation | replay all actions; inspect translation keys, attachments, feet, and collision | `SCALE_BLOCKED` |
| Upload result is uncertain after timeout | Partial cloud mutation | inspect queue and Asset Manager before retrying; record any created IDs | stop if state cannot be determined safely |
| MCP configured but `list_roblox_studios` is empty | Connection | reconnect plugin/session or use manual runbook | not an asset failure; no automated Studio claim |
| Studio window is unresponsive | Tool/UI | at 60 seconds capture state/log; at 5 minutes report blocked; do not kill an unsaved user window | `TOOL_BLOCKED` |
| Save As was cancelled | Persistence only | leave current scene open and report unsaved state separately | import/playback result remains whatever was observed |

## Retry budget

- Local deterministic import/read-back: retry once after a specific setting or file change.
- Roblox upload/import: inspect queue and created assets first; retry once only after changing the relevant condition.
- Permission failure: no repeated retry. Route to the asset/experience owner.
- Moderation pending: wait or recheck later; do not re-upload identical content to bypass moderation.

## Cleanup inventory

| Resource | Default cleanup |
| --- | --- |
| Explicit local output directory | preserve for diagnosis; never recursively delete automatically |
| Failed Importer queue row | remove before changed-file retry |
| Imported Workspace test model | keep unless user asks to undo/remove |
| Uploaded mesh/image/animation asset | never delete automatically; record ID and owner |
| Temporary Studio local sequence/hash | expires with session; not production state |
| Source model/ZIP/textures | never modify or delete |
