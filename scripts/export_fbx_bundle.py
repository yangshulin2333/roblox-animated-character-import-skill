#!/usr/bin/env python3
"""Export a source asset as a portable Roblox Custom Rig FBX bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import sys
import traceback
import unicodedata

import bpy

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from inspect_in_blender import EPSILON, collect_report, load_source, sha256_file, write_json


ALLOWED_PREEXISTING = {"preflight_report.json", "inspection_report.json"}


def argv_after_separator() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def portable_stem(value: str, fallback: str) -> str:
    normalized = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    normalized = re.sub(r"[^A-Za-z0-9._-]+", "_", normalized).strip("._-")
    return normalized or fallback


def ensure_output_directory(output_dir: Path) -> None:
    if output_dir.exists():
        unexpected = [item.name for item in output_dir.iterdir() if item.name not in ALLOWED_PREEXISTING]
        if unexpected:
            raise FileExistsError(
                "Output directory is not empty. Refusing to overwrite: " + ", ".join(sorted(unexpected))
            )
    else:
        output_dir.mkdir(parents=True)


def select_target_armature(name: str | None):
    armatures = sorted(
        (obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"),
        key=lambda item: item.name,
    )
    if name:
        matches = [item for item in armatures if item.name == name]
        if not matches:
            raise ValueError(f"Armature not found: {name}")
        return matches[0]
    if len(armatures) != 1:
        raise ValueError(f"Expected exactly one armature, found {len(armatures)}. Pass --armature.")
    return armatures[0]


def meshes_for_armature(armature) -> list:
    bone_names = {bone.name for bone in armature.data.bones}
    all_meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    associated = []
    for mesh in all_meshes:
        modifier_match = any(
            modifier.type == "ARMATURE" and modifier.object == armature for modifier in mesh.modifiers
        )
        parent_match = mesh.parent == armature
        group_match = any(group.name in bone_names for group in mesh.vertex_groups)
        if modifier_match or parent_match or group_match:
            associated.append(mesh)
    if not associated and len([obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]) == 1:
        associated = all_meshes
    if not associated:
        raise ValueError(f"No mesh could be associated with armature {armature.name}")
    return sorted(associated, key=lambda item: item.name)


def influence_summary(meshes: list, armature) -> dict:
    bone_names = {bone.name for bone in armature.data.bones}
    over_four = 0
    maximum = 0
    for mesh in meshes:
        group_names = {group.index: group.name for group in mesh.vertex_groups}
        for vertex in mesh.data.vertices:
            count = sum(
                1
                for membership in vertex.groups
                if membership.weight > EPSILON and group_names.get(membership.group) in bone_names
            )
            maximum = max(maximum, count)
            if count > 4:
                over_four += 1
    return {"maximum": maximum, "vertices_over_four": over_four}


def limit_influences(meshes: list, armature, maximum: int) -> dict:
    bone_names = {bone.name for bone in armature.data.bones}
    changed_vertices = 0
    removed_links = 0
    for mesh in meshes:
        group_names = {group.index: group.name for group in mesh.vertex_groups}
        for vertex in mesh.data.vertices:
            memberships = [
                (membership.group, float(membership.weight))
                for membership in vertex.groups
                if membership.weight > EPSILON and group_names.get(membership.group) in bone_names
            ]
            if len(memberships) <= maximum:
                continue
            memberships.sort(key=lambda item: item[1], reverse=True)
            keep = memberships[:maximum]
            remove = memberships[maximum:]
            kept_sum = sum(weight for _, weight in keep)
            if kept_sum <= EPSILON:
                raise ValueError(f"Cannot normalize vertex {vertex.index} on mesh {mesh.name}")
            for group_index, _ in remove:
                mesh.vertex_groups[group_index].remove([vertex.index])
            for group_index, weight in keep:
                mesh.vertex_groups[group_index].add([vertex.index], weight / kept_sum, "REPLACE")
            changed_vertices += 1
            removed_links += len(remove)
    return {"changed_vertices": changed_vertices, "removed_weight_links": removed_links}


def used_materials(meshes: list) -> list:
    materials = {}
    for mesh in meshes:
        for slot in mesh.material_slots:
            if slot.material:
                materials[slot.material.name_full] = slot.material
    return [materials[name] for name in sorted(materials)]


def image_nodes(materials: list) -> list[tuple]:
    records = []
    for material in materials:
        if not material.use_nodes or not material.node_tree:
            continue
        for node in material.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image:
                records.append((material, node, node.image))
    return records


def packed_extension(image) -> str:
    suffix = Path(str(image.filepath or "")).suffix.lower()
    if suffix:
        return suffix
    return {
        "PNG": ".png",
        "JPEG": ".jpg",
        "TARGA": ".tga",
        "BMP": ".bmp",
    }.get(str(getattr(image, "file_format", "")), ".bin")


def copy_and_or_strip_textures(meshes: list, output_dir: Path, mode: str) -> tuple[dict, list]:
    materials = used_materials(meshes)
    nodes = image_nodes(materials)
    texture_dir = output_dir / "textures"
    if mode == "separate":
        texture_dir.mkdir(parents=True, exist_ok=True)

    delivered_by_image = {}
    texture_records = []
    warnings = []
    used_names: set[str] = set()

    for _, _, image in nodes:
        key = image.name_full
        if key in delivered_by_image:
            continue
        raw_path = str(image.filepath or "")
        raw_basename = re.split(r"[\\/]", raw_path)[-1] if raw_path else ""
        resolved = Path(bpy.path.abspath(raw_path, library=image.library)).resolve() if raw_path else None
        packed = getattr(image, "packed_file", None)

        record = {
            "image_name": image.name,
            "original_basename": raw_basename or None,
            "packed": bool(packed),
            "delivered_file": None,
            "sha256": None,
        }

        if mode == "separate":
            suffix = packed_extension(image)
            base = portable_stem(Path(raw_basename).stem if raw_basename else image.name, "texture")
            candidate = f"{base}{suffix}"
            counter = 2
            while candidate.lower() in used_names:
                candidate = f"{base}_{counter}{suffix}"
                counter += 1
            used_names.add(candidate.lower())
            destination = texture_dir / candidate

            if resolved and resolved.is_file():
                shutil.copy2(resolved, destination)
            elif packed:
                destination.write_bytes(bytes(packed.data))
            else:
                raise FileNotFoundError(f"Texture used by the model is missing: {image.name} ({raw_path})")

            record["delivered_file"] = destination.relative_to(output_dir).as_posix()
            record["sha256"] = sha256_file(destination)
            delivered_by_image[key] = destination

        texture_records.append(record)

    if mode in {"separate", "none"}:
        for _, node, _ in nodes:
            node.image = None
        if nodes:
            warnings.append(
                "Image texture nodes were disconnected only in the temporary scene before FBX export."
            )

    material_map = []
    for material, node, image in nodes:
        material_map.append(
            {
                "material": material.name,
                "node": node.name,
                "image": image.name,
                "delivered_file": (
                    delivered_by_image[image.name_full].relative_to(output_dir).as_posix()
                    if image.name_full in delivered_by_image
                    else None
                ),
            }
        )

    manifest = {
        "schema_version": "1.0",
        "texture_mode": mode,
        "textures": texture_records,
        "material_image_nodes": material_map,
        "warnings": warnings,
    }
    return manifest, nodes


def select_export_objects(armature, meshes: list) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    for item in [armature, *meshes]:
        item.hide_set(False)
        item.select_set(True)
    bpy.context.view_layer.objects.active = armature


def export_fbx(path: Path, armature, meshes: list, bake_animation: bool, texture_mode: str) -> None:
    select_export_objects(armature, meshes)
    result = bpy.ops.export_scene.fbx(
        filepath=str(path),
        use_selection=True,
        object_types={"ARMATURE", "MESH"},
        use_mesh_modifiers=True,
        use_triangles=True,
        axis_forward="Z",
        axis_up="Y",
        apply_scale_options="FBX_SCALE_UNITS",
        bake_space_transform=False,
        add_leaf_bones=False,
        use_armature_deform_only=False,
        armature_nodetype="NULL",
        bake_anim=bake_animation,
        bake_anim_use_all_bones=True,
        bake_anim_use_nla_strips=False,
        bake_anim_use_all_actions=False,
        bake_anim_force_startend_keying=False,
        bake_anim_step=1.0,
        bake_anim_simplify_factor=0.0,
        path_mode="COPY" if texture_mode == "embed" else "STRIP",
        embed_textures=texture_mode == "embed",
    )
    if "FINISHED" not in result:
        raise RuntimeError(f"FBX exporter returned {sorted(result)} for {path.name}")


def try_assign_action(armature, action) -> tuple[bool, str | None]:
    animation_data = armature.animation_data_create()
    try:
        animation_data.action = action
        slots = list(getattr(action, "slots", []) or [])
        if hasattr(animation_data, "action_slot") and slots:
            current_slot = getattr(animation_data, "action_slot", None)
            if current_slot not in slots:
                object_slots = [slot for slot in slots if str(getattr(slot, "target_id_type", "")) == "OBJECT"]
                if object_slots:
                    animation_data.action_slot = object_slots[0]
        return True, None
    except Exception as exc:
        try:
            animation_data.action = None
        except Exception:
            pass
        return False, f"{type(exc).__name__}: {exc}"


def requested_actions(args, armature) -> tuple[list, list]:
    actions = sorted(bpy.data.actions, key=lambda item: item.name)
    by_name = {action.name: action for action in actions}
    if args.action:
        missing = [name for name in args.action if name not in by_name]
        if missing:
            raise ValueError("Required action(s) not found: " + ", ".join(missing))
        candidates = [by_name[name] for name in args.action]
        explicit = True
    elif args.all_actions:
        candidates = actions
        explicit = False
    else:
        return [], []

    compatible = []
    skipped = []
    for action in candidates:
        frame_range = [float(action.frame_range[0]), float(action.frame_range[1])]
        if not all(math.isfinite(value) for value in frame_range) or frame_range[1] < frame_range[0]:
            reason = "invalid or non-finite frame range"
            if explicit:
                raise ValueError(f"Action {action.name}: {reason}")
            skipped.append({"name": action.name, "reason": reason})
            continue
        ok, error = try_assign_action(armature, action)
        if ok:
            compatible.append(action)
        elif explicit:
            raise ValueError(f"Action {action.name} is not compatible with {armature.name}: {error}")
        else:
            skipped.append({"name": action.name, "reason": error})
    return compatible, skipped


def file_record(path: Path, output_dir: Path, kind: str, action: str | None = None) -> dict:
    return {
        "kind": kind,
        "action": action,
        "path": path.relative_to(output_dir).as_posix(),
        "size_bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--armature")
    parser.add_argument("--action", action="append", default=[])
    parser.add_argument("--all-actions", action="store_true")
    parser.add_argument("--texture-mode", choices=("separate", "embed", "none"), default="separate")
    parser.add_argument("--fix-max-influences", action="store_true")
    args = parser.parse_args(argv_after_separator())
    if args.all_actions and args.action:
        raise ValueError("Use either --all-actions or one or more --action values, not both.")

    source = Path(args.source).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    if not source.is_file():
        raise FileNotFoundError(source)
    ensure_output_directory(output_dir)

    load_source(source)
    pre_export_report = collect_report(source)
    armature = select_target_armature(args.armature)
    meshes = meshes_for_armature(armature)

    root_names = {bone.name for bone in armature.data.bones if bone.parent is None}
    root_weighted = sum(
        1
        for mesh in meshes
        for vertex in mesh.data.vertices
        if any(
            membership.weight > EPSILON
            and mesh.vertex_groups[membership.group].name in root_names
            for membership in vertex.groups
        )
    )
    root_review = None
    if root_weighted:
        root_review = {
            "top_level_bones": sorted(root_names),
            "weighted_vertices": root_weighted,
            "message": (
                "At least one top-level bone has mesh weights. Verify which bone is the intended Roblox Root; "
                "the exporter did not remove weights or reparent bones automatically."
            ),
        }

    triangle_failures = []
    for mesh in meshes:
        mesh.data.calc_loop_triangles()
        if len(mesh.data.loop_triangles) > 20000:
            triangle_failures.append(f"{mesh.name}={len(mesh.data.loop_triangles)}")
    if triangle_failures:
        raise ValueError("Meshes exceed 20,000 triangles: " + ", ".join(triangle_failures))

    before_influences = influence_summary(meshes, armature)
    influence_fix = {"changed_vertices": 0, "removed_weight_links": 0}
    if before_influences["vertices_over_four"]:
        if not args.fix_max_influences:
            raise ValueError(
                f"{before_influences['vertices_over_four']} vertices exceed four influences. "
                "Re-run with --fix-max-influences only if the deformation change is accepted."
            )
        influence_fix = limit_influences(meshes, armature, 4)
    after_influences = influence_summary(meshes, armature)
    if after_influences["vertices_over_four"]:
        raise RuntimeError("Influence limiting did not produce a compliant result.")

    actions, skipped_actions = requested_actions(args, armature)
    if args.all_actions and not actions:
        raise ValueError("--all-actions was requested but no compatible skeletal Action was found.")

    texture_manifest, _ = copy_and_or_strip_textures(meshes, output_dir, args.texture_mode)
    write_json(output_dir / "texture_manifest.json", texture_manifest)

    animation_data = armature.animation_data_create()
    for track in animation_data.nla_tracks:
        track.mute = True

    original_pose_position = armature.data.pose_position
    animation_data.action = None
    armature.data.pose_position = "REST"
    bpy.context.view_layer.update()

    model_path = output_dir / "model_bind.fbx"
    export_fbx(model_path, armature, meshes, False, args.texture_mode)
    files = [file_record(model_path, output_dir, "model")]

    armature.data.pose_position = "POSE"
    animation_dir = output_dir / "animations"
    if actions:
        animation_dir.mkdir(parents=True, exist_ok=True)
    used_stems: set[str] = set()
    exported_actions = []
    for index, action in enumerate(actions, start=1):
        ok, error = try_assign_action(armature, action)
        if not ok:
            raise ValueError(f"Action became incompatible during export: {action.name}: {error}")
        start = math.floor(float(action.frame_range[0]))
        end = math.ceil(float(action.frame_range[1]))
        bpy.context.scene.frame_start = start
        bpy.context.scene.frame_end = end
        bpy.context.scene.frame_set(start)
        bpy.context.view_layer.update()

        base_stem = portable_stem(action.name, f"action_{index:03d}")
        stem = base_stem
        collision = 2
        while stem.lower() in used_stems:
            stem = f"{base_stem}_{collision}"
            collision += 1
        used_stems.add(stem.lower())
        action_path = animation_dir / f"{stem}.fbx"
        export_fbx(action_path, armature, meshes, True, args.texture_mode)
        files.append(file_record(action_path, output_dir, "animation", action.name))
        exported_actions.append(
            {
                "name": action.name,
                "file": action_path.relative_to(output_dir).as_posix(),
                "frame_start": start,
                "frame_end": end,
            }
        )

    animation_data.action = None
    armature.data.pose_position = original_pose_position

    for texture in texture_manifest["textures"]:
        if texture["delivered_file"]:
            path = output_dir / texture["delivered_file"]
            files.append(file_record(path, output_dir, "texture"))
    files.append(file_record(output_dir / "texture_manifest.json", output_dir, "metadata"))

    manifest = {
        "schema_version": "1.0",
        "status": "EXPORT_PASS" if not skipped_actions and not root_review else "EXPORT_REVIEW_REQUIRED",
        "source": {
            "name": source.name,
            "size_bytes": source.stat().st_size,
            "sha256": sha256_file(source),
        },
        "blender_version": bpy.app.version_string,
        "target": {
            "rig_type": "Custom",
            "armature": armature.name,
            "mesh_names": [mesh.name for mesh in meshes],
            "one_animation_track_per_fbx": True,
        },
        "export_settings": {
            "axis_forward": "Z",
            "axis_up": "Y",
            "apply_scalings": "FBX Unit Scale",
            "add_leaf_bones": False,
            "all_actions_in_one_fbx": False,
            "simplify": 0.0,
            "texture_mode": args.texture_mode,
        },
        "influences": {
            "before": before_influences,
            "fix": influence_fix,
            "after": after_influences,
        },
        "root_review": root_review,
        "actions": exported_actions,
        "skipped_actions": skipped_actions,
        "files": files,
        "source_inspection_summary": pre_export_report["summary"],
        "notes": [
            "The source file was opened in a temporary Blender session and was not saved.",
            "Studio import, asset permissions, and runtime playback still require separate evidence.",
        ],
    }
    write_json(output_dir / "bundle_manifest.json", manifest)
    print(
        "ROBLOX_CHARACTER_EXPORT_OK",
        json.dumps(
            {
                "status": manifest["status"],
                "files": len(files) + 1,
                "actions": len(exported_actions),
                "skipped_actions": len(skipped_actions),
            },
            ensure_ascii=False,
        ),
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ROBLOX_CHARACTER_EXPORT_FAILED {type(exc).__name__}: {exc}", file=sys.stderr)
        traceback.print_exc()
        raise SystemExit(2)
