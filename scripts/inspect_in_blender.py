#!/usr/bin/env python3
"""Inspect a Blender/FBX/GLTF animated asset without saving the source scene."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import traceback

import bpy
from mathutils import Vector


SUPPORTED = {".blend", ".fbx", ".glb", ".gltf", ".obj"}
EPSILON = 1e-8


def argv_after_separator() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_source(source: Path) -> None:
    suffix = source.suffix.lower()
    if suffix not in SUPPORTED:
        raise ValueError(f"Unsupported source type: {suffix}")

    if suffix == ".blend":
        try:
            bpy.ops.wm.open_mainfile(filepath=str(source), load_ui=False, use_scripts=False)
        except TypeError:
            # Older/newer Blender builds can expose a slightly different operator schema.
            bpy.ops.wm.open_mainfile(filepath=str(source), load_ui=False)
        return

    bpy.ops.wm.read_factory_settings(use_empty=True)
    if suffix == ".fbx":
        result = bpy.ops.import_scene.fbx(filepath=str(source), use_anim=True)
    elif suffix in {".glb", ".gltf"}:
        result = bpy.ops.import_scene.gltf(filepath=str(source))
    else:
        if hasattr(bpy.ops.wm, "obj_import"):
            result = bpy.ops.wm.obj_import(filepath=str(source))
        else:
            result = bpy.ops.import_scene.obj(filepath=str(source))
    if "FINISHED" not in result:
        raise RuntimeError(f"Blender importer returned {sorted(result)}")


def image_record(image: bpy.types.Image) -> dict:
    packed = bool(getattr(image, "packed_file", None))
    raw_path = str(getattr(image, "filepath", "") or "")
    absolute = ""
    exists = False
    if raw_path:
        try:
            absolute = bpy.path.abspath(raw_path, library=image.library)
        except TypeError:
            absolute = bpy.path.abspath(raw_path)
        exists = os.path.isfile(absolute)
    return {
        "name": image.name,
        "source": str(image.source),
        "size": [int(image.size[0]), int(image.size[1])],
        "packed": packed,
        "filepath": raw_path,
        "resolved_exists": exists,
        "missing_external": bool(raw_path and not packed and not exists),
    }


def action_record(action: bpy.types.Action) -> dict:
    frame_range = [float(action.frame_range[0]), float(action.frame_range[1])]
    slots = []
    for slot in list(getattr(action, "slots", []) or []):
        slots.append(
            {
                "identifier": str(getattr(slot, "identifier", "")),
                "target_id_type": str(getattr(slot, "target_id_type", "")),
            }
        )
    layers = list(getattr(action, "layers", []) or [])
    fcurves = list(getattr(action, "fcurves", []) or [])
    return {
        "name": action.name,
        "frame_range": frame_range,
        "finite_frame_range": all(math.isfinite(value) for value in frame_range),
        "slots": slots,
        "layer_count": len(layers),
        "legacy_fcurve_count": len(fcurves),
    }


def matrix_is_finite(matrix) -> bool:
    return all(math.isfinite(float(value)) for row in matrix for value in row)


def collect_report(source: Path | None = None) -> dict:
    armatures = sorted(
        (obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"),
        key=lambda item: item.name,
    )
    meshes = sorted(
        (obj for obj in bpy.context.scene.objects if obj.type == "MESH"),
        key=lambda item: item.name,
    )

    all_bone_names: set[str] = set()
    root_bone_names: set[str] = set()
    armature_records = []
    for armature in armatures:
        bones = list(armature.data.bones)
        roots = [bone for bone in bones if bone.parent is None]
        all_bone_names.update(bone.name for bone in bones)
        root_bone_names.update(bone.name for bone in roots)
        animation_data = armature.animation_data
        assigned_action = None
        nla_actions: set[str] = set()
        if animation_data:
            assigned_action = animation_data.action.name if animation_data.action else None
            for track in animation_data.nla_tracks:
                for strip in track.strips:
                    if strip.action:
                        nla_actions.add(strip.action.name)
        armature_records.append(
            {
                "name": armature.name,
                "bone_count": len(bones),
                "roots": [
                    {
                        "name": bone.name,
                        "head_local": [float(value) for value in bone.head_local],
                        "distance_from_origin": float(Vector(bone.head_local).length),
                    }
                    for bone in roots
                ],
                "assigned_action": assigned_action,
                "nla_actions": sorted(nla_actions),
                "world_matrix_finite": matrix_is_finite(armature.matrix_world),
            }
        )

    mesh_records = []
    total_triangles = 0
    total_vertices = 0
    total_over_four = 0
    total_root_weighted = 0
    maximum_influences = 0
    world_points = []

    for obj in meshes:
        data = obj.data
        data.calc_loop_triangles()
        triangle_count = len(data.loop_triangles)
        total_triangles += triangle_count
        total_vertices += len(data.vertices)

        group_names = {group.index: group.name for group in obj.vertex_groups}
        over_four = 0
        root_weighted = 0
        mesh_maximum = 0
        for vertex in data.vertices:
            positive_bone_groups = [
                group
                for group in vertex.groups
                if group.weight > EPSILON and group_names.get(group.group) in all_bone_names
            ]
            influence_count = len(positive_bone_groups)
            mesh_maximum = max(mesh_maximum, influence_count)
            if influence_count > 4:
                over_four += 1
            if any(group_names.get(group.group) in root_bone_names for group in positive_bone_groups):
                root_weighted += 1

        maximum_influences = max(maximum_influences, mesh_maximum)
        total_over_four += over_four
        total_root_weighted += root_weighted

        modifiers = [
            modifier.object.name
            for modifier in obj.modifiers
            if modifier.type == "ARMATURE" and modifier.object is not None
        ]
        materials = [slot.material.name if slot.material else None for slot in obj.material_slots]
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            if all(math.isfinite(float(value)) for value in point):
                world_points.append(point)

        mesh_records.append(
            {
                "name": obj.name,
                "vertices": len(data.vertices),
                "triangles": triangle_count,
                "triangle_limit_ok": triangle_count <= 20000,
                "material_slots": materials,
                "uv_layers": [layer.name for layer in data.uv_layers],
                "armature_modifiers": modifiers,
                "maximum_positive_bone_influences": mesh_maximum,
                "vertices_over_four_influences": over_four,
                "vertices_weighted_to_root": root_weighted,
                "world_matrix_finite": matrix_is_finite(obj.matrix_world),
            }
        )

    bounds = None
    if world_points:
        minimum = [min(point[index] for point in world_points) for index in range(3)]
        maximum = [max(point[index] for point in world_points) for index in range(3)]
        bounds = {
            "minimum": [float(value) for value in minimum],
            "maximum": [float(value) for value in maximum],
            "size": [float(maximum[index] - minimum[index]) for index in range(3)],
        }

    used_materials = {}
    for obj in meshes:
        for slot in obj.material_slots:
            if slot.material:
                used_materials[slot.material.name_full] = slot.material

    material_records = []
    material_images = {}
    material_image_node_count = 0
    for material_name in sorted(used_materials):
        material = used_materials[material_name]
        image_nodes = []
        if material.use_nodes and material.node_tree:
            for node in material.node_tree.nodes:
                if node.type == "TEX_IMAGE" and node.image:
                    material_image_node_count += 1
                    material_images[node.image.name_full] = node.image
                    image_nodes.append(
                        {
                            "node": node.name,
                            "image": node.image.name,
                            "has_output_link": any(bool(output.links) for output in node.outputs),
                        }
                    )
        material_records.append(
            {
                "name": material.name,
                "use_nodes": bool(material.use_nodes),
                "image_nodes": image_nodes,
            }
        )

    images = [image_record(image) for image in sorted(bpy.data.images, key=lambda item: item.name)]
    used_images = [
        image_record(material_images[name]) for name in sorted(material_images)
    ]
    actions = [action_record(action) for action in sorted(bpy.data.actions, key=lambda item: item.name)]

    blockers = []
    warnings = []
    if not meshes:
        blockers.append({"code": "NO_MESH", "message": "No mesh object was imported."})
    if not armatures:
        blockers.append({"code": "NO_ARMATURE", "message": "No armature was imported."})
    if any(not item["triangle_limit_ok"] for item in mesh_records):
        blockers.append(
            {"code": "MESH_TRIANGLE_LIMIT", "message": "At least one mesh exceeds 20,000 triangles."}
        )
    if total_over_four:
        blockers.append(
            {
                "code": "MAX_INFLUENCES_EXCEEDED",
                "message": f"{total_over_four} vertices have more than four positive bone influences.",
            }
        )
    if total_root_weighted:
        warnings.append(
            {
                "code": "TOP_LEVEL_BONE_HAS_WEIGHTS",
                "message": (
                    f"{total_root_weighted} vertices have positive weight on a top-level bone. "
                    "Review the intended Roblox root manually; top-level deform bones are not always the designated Root."
                ),
            }
        )
    if any(not item["world_matrix_finite"] for item in mesh_records + armature_records):
        blockers.append({"code": "NONFINITE_TRANSFORM", "message": "An object transform is not finite."})
    if not actions:
        warnings.append({"code": "NO_ACTIONS", "message": "No Blender Action was found."})
    if len(armatures) > 1:
        warnings.append(
            {
                "code": "MULTIPLE_ARMATURES",
                "message": "Multiple armatures require an explicit target before export.",
            }
        )
    if sum(len(item["roots"]) for item in armature_records) != 1:
        warnings.append(
            {
                "code": "ROOT_COUNT_REVIEW",
                "message": "The imported scene does not have exactly one root bone; review hierarchy manually.",
            }
        )
    missing_images = [item["name"] for item in used_images if item["missing_external"]]
    if missing_images:
        warnings.append(
            {
                "code": "MISSING_TEXTURE_FILES",
                "message": f"Missing external images: {', '.join(missing_images)}",
            }
        )

    source_info = None
    if source:
        source_info = {
            "name": source.name,
            "extension": source.suffix.lower(),
            "size_bytes": source.stat().st_size,
            "sha256": sha256_file(source),
        }

    return {
        "schema_version": "1.0",
        "status": "SOURCE_PASS" if not blockers else "SOURCE_REVIEW_REQUIRED",
        "blender_version": bpy.app.version_string,
        "source": source_info,
        "scene": {
            "fps": float(bpy.context.scene.render.fps)
            / float(bpy.context.scene.render.fps_base or 1.0),
            "frame_start": int(bpy.context.scene.frame_start),
            "frame_end": int(bpy.context.scene.frame_end),
            "units": {
                "system": str(bpy.context.scene.unit_settings.system),
                "scale_length": float(bpy.context.scene.unit_settings.scale_length),
                "length_unit": str(bpy.context.scene.unit_settings.length_unit),
            },
            "bounds": bounds,
        },
        "summary": {
            "mesh_count": len(meshes),
            "armature_count": len(armatures),
            "action_count": len(actions),
            "image_count": len(images),
            "material_count": len(material_records),
            "material_image_count": len(used_images),
            "material_image_node_count": material_image_node_count,
            "vertices": total_vertices,
            "triangles": total_triangles,
            "maximum_positive_bone_influences": maximum_influences,
            "vertices_over_four_influences": total_over_four,
            "vertices_weighted_to_root": total_root_weighted,
        },
        "meshes": mesh_records,
        "armatures": armature_records,
        "actions": actions,
        "images": images,
        "materials": material_records,
        "material_images": used_images,
        "blockers": blockers,
        "warnings": warnings,
    }


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args(argv_after_separator())

    source = Path(args.source).expanduser().resolve()
    report_path = Path(args.report).expanduser().resolve()
    if not source.is_file():
        raise FileNotFoundError(source)

    load_source(source)
    report = collect_report(source)
    write_json(report_path, report)
    print("ROBLOX_CHARACTER_INSPECTION_OK", json.dumps(report["summary"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        error = {
            "schema_version": "1.0",
            "status": "SOURCE_BLOCKED",
            "error": f"{type(exc).__name__}: {exc}",
            "traceback": traceback.format_exc(),
        }
        argv = argv_after_separator()
        if "--report" in argv:
            try:
                write_json(Path(argv[argv.index("--report") + 1]).expanduser().resolve(), error)
            except Exception:
                pass
        print("ROBLOX_CHARACTER_INSPECTION_FAILED", error["error"], file=sys.stderr)
        raise SystemExit(2)
