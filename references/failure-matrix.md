# Failure and recovery matrix

Read this before retrying. A retry must change a relevant condition and must not create uncontrolled duplicate cloud assets.

| Symptom / evidence | Likely class | Recovery | Stop condition |
| --- | --- | --- | --- |
| `.gz` 实际是 UnityPackage | 原始容器识别 | 按 GZIP/TAR 签名读取 Unity GUID、`pathname` 和 `asset`，还原逻辑目录 | 路径不安全或 TAR 损坏时 `SOURCE_INTAKE_BLOCKED` |
| `.part1.rar` 到 `.partN.rar` 同名连续 | RAR 分卷 | 归并为一个资源组，从 part1 联合检测；不要逐卷处理 | 缺卷时 `ARCHIVE_MULTIPART_INCOMPLETE` |
| RAR5 被旧版 7-Zip 报为无法打开 | 解包工具版本 | 指定支持 RAR5 的新版 7-Zip/7zz，再改变工具条件重试一次 | `EXTRACTOR_REQUIRED`，不能据此判定模型损坏 |
| 一个目录包含多个独立压缩包 | 批次拆分 | 用 `run_batch.ps1` 将每个独立包变成任务；RAR 分卷仍合并为一个任务 | 单任务入口才返回 `SOURCE_SELECTION_REQUIRED` |
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
| 动画 FBX 导入后姿势错乱或要求休息姿势来源 | 绑定姿势、层级、轴向或导出变换不匹配 | Codex 比较源/目标骨架，按 Studio 操作手册判断候选，用一个代表动作试播；记录实际选项名与证据，不固定第几项 | `PLAYBACK_BLOCKED`，不得盲目批量继续；不能靠选项完成的重定向另行处理 |
| Multi-action FBX behaves differently on another PC | Unsupported portability assumption | Export one animation track per FBX and import each onto the same target rig | do not use multi-action result as cross-PC evidence |
| Model is about 100× too large/small or sideways | Units/axes | Recheck FBX Unit Scale, exporter axes, Importer Scale Unit and World Forward/Up; avoid stacking arbitrary factors | `IMPORT_BLOCKED` if orientation/scale remains unknown |
| `base_color_texture` upload fails | Texture upload transaction | Record error, generate/use textureless FBX and separate images, remove failed queue row, add file again | `IMPORT_BLOCKED` after one changed-condition retry |
| `.png` 本地可打开但 Studio 图片导入器拒绝 | 编码、色深、颜色模式、元数据或解析器差异 | 在上传前运行 `normalize_roblox_textures.ps1`；只上传清单中的 `*_Roblox.png`，并保留来源/输出哈希和回读报告 | 未达到 `TEXTURE_NORMALIZATION_PASS` 时为 `TEXTURE_COMPATIBILITY_BLOCKED` |
| 贴图包含 16 位、调色板、CMYK、EXIF/ICC/XMP/iTXt、异常 CRC 或尾随数据 | 图片兼容性 | 解码后重建为 8 位 RGB/RGBA PNG，应用方向、移除非必要块、CRC 和像素回读；不得覆盖原图 | 解码或回读失败即停止，不上传原图碰运气 |
| 标准化后的 `*_Roblox.png` 仍被 Studio 拒绝 | 上传服务、审核、限额或账号边界 | 记录精确错误、Creator、审核和队列副作用；同哈希只在条件改变后重试一次 | 不再归因为普通图片格式；按证据进入 `IMPORT_BLOCKED`/`PERMISSION_BLOCKED`/`PENDING` |
| 自动贴图工具缺失 | 本地工具链 | 允许脚本把固定 Pillow 版本安装到用户级 CodexTools 缓存，或预装 Pillow；禁用自动安装时使用 `-NoTextureToolInstall` | `TEXTURE_TOOL_REQUIRED` |
| 上传嵌入贴图 FBX 后出现多张同内容半成品图片 | 非原子上传/重复依赖 | 停止重试，记录已创建 ID；改用默认 `separate` 包并按 SHA-256 查 `texture_index.json` | 未查清已有云端副作用前不得再次上传 |
| Changed FBX shows the same old error immediately | Import queue cache | Delete the individual row or Clear queue with broom, then re-add and confirm preview metadata | stop if a clean re-add still fails |
| Mesh imports but appears white | Missing mapping, permission, or moderation | Check image upload result, material assignment, direct content load, Output, and moderation state separately | `PERMISSION_BLOCKED` or `TEXTURE_BLOCKED` |
| `TextureID` is populated and an editor-side image API can read pixels, but MeshPart preload fails | The logged-in uploader owns the image but the differently owned experience lacks runtime permission | Re-import the material-linked/embedded FBX with Add to Workspace in the exact experience, or grant that experience access | `PERMISSION_BLOCKED` |
| FBX has UVs but no material slots or material-linked image | A conversion selected a lossy derivative instead of the richer DCC source | Audit sibling candidates; select the source preserving rig/actions/UV/material/image and regenerate the FBX | `SOURCE_APPEARANCE_BLOCKED` |
| Importer preview stays white after an FBX was regenerated at the same path | Existing queue/preview still holds the old parsed file | Delete the queue row, close/re-add the FBX, and verify its hash/preview changed | one changed-condition retry only |
| Asset ID and metadata exist but direct texture does not render | Permission/moderation/fetch | Grant creator/game permission if owned; start a fresh Play session; wait for moderation if pending | do not mark pass based on metadata |
| `rbxthumb://` displays the image | Thumbnail-only | Remove it as production evidence and test direct `rbxassetid://` | `TEXTURE_BLOCKED` until direct content works |
| One collaborator sees a full model while another sees partial/incorrect color | Account-specific thumbnail/cache or ungranted child dependency | Audit every MeshPart/SurfaceAppearance/Decal; remove `rbxthumb://` and one-face Decal fallbacks; verify target-place automatic grant and direct IDs in fresh Play | `PERMISSION_BLOCKED` or `TEXTURE_BLOCKED` until both views agree |
| Complete model was imported by a collaborator but a child texture is restricted | Import did not bind every dependency to the target game, Add to Workspace was disabled, or the image was uploaded separately | In the exact saved/published target, use Add to Workspace and the current-experience grant path; verify each dependency owner/status | do not jump directly to Open Use |
| Studio Output offers “share access” | Restricted asset | Account owner reviews and grants the intended experience access | `PERMISSION_BLOCKED` if current user lacks authority |
| Importer Creator differs from experience owner | Ownership boundary, not automatic failure | Prefer the intended owner/group; for collaborator-personal uploads, verify Add to Workspace auto-granted the target game before runtime claim | stop only if direct dependency fetch still fails |
| Imported model has `AnimSaves` but Play does nothing | Missing runtime setup | Add/find `AnimationController` + server-created `Animator`; locally register sequences only for preview | `PLAYBACK_BLOCKED` |
| Track loads but `Length == 0` | Asset not ready, wrong ID, or permission | bounded wait, inspect Output, verify ID/owner/game access | stop after timeout; do not spin indefinitely |
| 动画发布成功，但 fresh Play 报“体验没有访问权限”且 `Length == 0` | 动画上传者与体验所有者不同，目标 Universe 未获授权 | 点击 Output 的权限错误，Quick Share 到准确体验；fresh Play 复验。不要重新导出、重新上传或把 Animator 当作权限修复 | `PERMISSION_BLOCKED`，直到素材所有者完成授权 |
| `IsPlaying` true but no bone changes | Wrong rig/action mapping | Compare pose names/hierarchy, target rig, animation source, and expected moving bones | `PLAYBACK_BLOCKED` |
| Track plays once but loop jumps | Source or conversion seam | Compare first/last poses and root translation; repair only if seamless loop is required | action pass may be non-looping only if user accepts |
| Model scaled and root motion becomes wrong | Post-scale animation | replay all actions; inspect translation keys, attachments, feet, and collision | `SCALE_BLOCKED` |
| Upload result is uncertain after timeout | Partial cloud mutation | inspect queue and Asset Manager before retrying; record any created IDs | stop if state cannot be determined safely |
| 批处理在第 N 个模型失败 | 批次局部失败 | 保留 `bundle_attempt_NNN` 和 `job_state.json`，修正条件后 `-Resume` | 不得删除批次根目录或重跑已到 `READY_FOR_STUDIO` 的任务 |
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
