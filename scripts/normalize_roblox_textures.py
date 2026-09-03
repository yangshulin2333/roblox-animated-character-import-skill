#!/usr/bin/env python3
"""Create deterministic, metadata-free PNG textures for Roblox Studio.

The script has two modes:

* ``--input/--output`` normalizes one image without touching the source.
* ``--bundle`` normalizes every external texture declared by a ``separate``
  export bundle and updates its manifests atomically.

Pillow is intentionally the only non-standard dependency.  The PowerShell
wrapper next to this file locates it or installs the pinned wheel into a local
per-user tool cache without requiring administrator rights.
"""

from __future__ import annotations

import argparse
from io import BytesIO
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import sys
import tempfile
import traceback
import uuid
import zlib

from PIL import Image, ImageCms, ImageOps


POLICY_NAME = "roblox_png_v1"
SUPPORTED_INPUT_EXTENSIONS = {
    ".png",
    ".jpg",
    ".jpeg",
    ".tga",
    ".bmp",
    ".gif",
    ".tif",
    ".tiff",
    ".dds",
    ".webp",
}
SAFE_PNG_CHUNKS = {"IHDR", "IDAT", "IEND"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def publish_staged_file(staged: Path, destination: Path) -> None:
    """Publish through a temporary file on the destination volume.

    ``os.replace`` is atomic only when both paths are on the same filesystem.
    Windows commonly keeps ``TEMP`` on C: while delivery bundles live on D:,
    so copying to a sibling temporary file is required before the final replace.
    """

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(
        f".{destination.name}.tmp-{os.getpid()}-{uuid.uuid4().hex}"
    )
    try:
        shutil.copyfile(staged, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def safe_bundle_path(bundle: Path, relative: str) -> Path:
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts:
        raise ValueError(f"Unsafe bundle path: {relative}")
    candidate = (bundle / Path(*pure.parts)).resolve()
    candidate.relative_to(bundle)
    return candidate


def inspect_png(path: Path) -> dict:
    data = path.read_bytes()
    errors: list[str] = []
    chunks: list[str] = []
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return {
            "valid": False,
            "chunks": chunks,
            "bit_depth": None,
            "color_type": None,
            "trailing_bytes": None,
            "errors": ["PNG signature is missing"],
        }

    offset = 8
    bit_depth = None
    color_type = None
    saw_iend = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            errors.append("PNG chunk exceeds file length")
            break
        chunk_type_bytes = data[offset + 4 : offset + 8]
        try:
            chunk_type = chunk_type_bytes.decode("ascii")
        except UnicodeDecodeError:
            chunk_type = repr(chunk_type_bytes)
            errors.append("PNG chunk type is not ASCII")
        payload = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : end])[0]
        actual_crc = zlib.crc32(chunk_type_bytes + payload) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            errors.append(f"CRC mismatch in {chunk_type}")
        chunks.append(chunk_type)
        if chunk_type == "IHDR":
            if length != 13:
                errors.append("IHDR length is not 13")
            else:
                bit_depth = payload[8]
                color_type = payload[9]
        if chunk_type == "IEND":
            saw_iend = True
            offset = end
            break
        offset = end

    trailing = len(data) - offset
    if not saw_iend:
        errors.append("IEND chunk is missing")
    if trailing:
        errors.append(f"PNG has {trailing} trailing bytes")
    return {
        "valid": not errors,
        "chunks": chunks,
        "bit_depth": bit_depth,
        "color_type": color_type,
        "trailing_bytes": trailing,
        "errors": errors,
    }


def has_alpha(image: Image.Image) -> bool:
    if "A" in image.getbands():
        return True
    return image.mode == "P" and "transparency" in image.info


def convert_embedded_profile(image: Image.Image, output_mode: str) -> tuple[Image.Image, bool, str | None]:
    profile = image.info.get("icc_profile")
    if not profile:
        return image.convert(output_mode), False, None
    try:
        alpha = image.getchannel("A") if has_alpha(image) else None
        source_profile = ImageCms.ImageCmsProfile(BytesIO(profile))
        target_profile = ImageCms.createProfile("sRGB")
        converted = ImageCms.profileToProfile(
            image.convert("RGB"),
            source_profile,
            target_profile,
            outputMode="RGB",
        )
        if output_mode == "RGBA":
            converted.putalpha(alpha if alpha is not None else Image.new("L", converted.size, 255))
        return converted, True, None
    except Exception as exc:
        return image.convert(output_mode), False, f"ICC profile conversion failed; RGB values were preserved: {exc}"


def normalize_to_stage(source: Path, stage_output: Path, max_dimension: int) -> dict:
    if not source.is_file():
        raise FileNotFoundError(source)
    if source.suffix.lower() not in SUPPORTED_INPUT_EXTENSIONS:
        raise ValueError(f"Unsupported texture extension: {source.suffix}")

    source_hash = sha256_file(source)
    source_png = inspect_png(source) if source.suffix.lower() == ".png" else None
    warnings: list[str] = []
    with Image.open(source) as opened:
        frame_count = int(getattr(opened, "n_frames", 1))
        if frame_count > 1:
            opened.seek(0)
            warnings.append(f"Animated image has {frame_count} frames; only frame 1 is used as a texture")
        opened.load()
        source_format = opened.format
        source_mode = opened.mode
        source_size = [int(opened.width), int(opened.height)]
        metadata_keys = sorted(str(key) for key in opened.info.keys())
        exif_bytes = opened.getexif().tobytes() if hasattr(opened, "getexif") else b""
        transposed = ImageOps.exif_transpose(opened)
        orientation_applied = transposed.size != opened.size or transposed.tobytes() != opened.tobytes()
        output_mode = "RGBA" if has_alpha(transposed) else "RGB"
        normalized, profile_converted, profile_warning = convert_embedded_profile(transposed, output_mode)
        if profile_warning:
            warnings.append(profile_warning)

    resized = False
    if max(normalized.size) > max_dimension:
        normalized.thumbnail((max_dimension, max_dimension), Image.Resampling.LANCZOS, reducing_gap=3.0)
        resized = True
        warnings.append(
            f"Texture was resized from {source_size[0]}x{source_size[1]} to "
            f"{normalized.width}x{normalized.height}"
        )

    # Rebuild from raw pixels so EXIF/XMP/text chunks and application profiles
    # cannot leak into the delivered PNG.
    clean = Image.frombytes(normalized.mode, normalized.size, normalized.tobytes())
    stage_output.parent.mkdir(parents=True, exist_ok=True)
    clean.save(stage_output, format="PNG", optimize=False, compress_level=9)

    output_png = inspect_png(stage_output)
    if not output_png["valid"]:
        raise ValueError("Normalized PNG structure is invalid: " + "; ".join(output_png["errors"]))
    unsafe_chunks = [name for name in output_png["chunks"] if name not in SAFE_PNG_CHUNKS]
    if unsafe_chunks:
        raise ValueError("Normalized PNG contains ancillary chunks: " + ", ".join(unsafe_chunks))
    if output_png["bit_depth"] != 8 or output_png["color_type"] not in {2, 6}:
        raise ValueError(
            f"Normalized PNG must be 8-bit RGB/RGBA, got bit_depth={output_png['bit_depth']} "
            f"color_type={output_png['color_type']}"
        )

    with Image.open(stage_output) as reopened:
        reopened.load()
        if reopened.mode != clean.mode or reopened.size != clean.size:
            raise ValueError("Normalized PNG read-back mode or dimensions changed")
        pixel_data_verified = reopened.tobytes() == clean.tobytes()
    if not pixel_data_verified:
        raise ValueError("Normalized PNG pixel read-back differs from the encoded pixels")

    source_pixel_equivalent = False
    if not resized and not orientation_applied and not profile_converted:
        with Image.open(source) as original:
            original.seek(0)
            original.load()
            source_pixel_equivalent = original.convert(clean.mode).tobytes() == clean.tobytes()

    return {
        "status": "TEXTURE_NORMALIZATION_PASS",
        "policy": POLICY_NAME,
        "source_file": str(source),
        "source_sha256": source_hash,
        "source_format": source_format,
        "source_mode": source_mode,
        "source_dimensions": source_size,
        "source_metadata_keys": metadata_keys,
        "source_exif_bytes": len(exif_bytes),
        "source_png": source_png,
        "output_file": str(stage_output),
        "output_sha256": sha256_file(stage_output),
        "output_format": "PNG",
        "output_mode": clean.mode,
        "output_dimensions": [int(clean.width), int(clean.height)],
        "output_png": output_png,
        "resized": resized,
        "orientation_applied": orientation_applied,
        "icc_profile_converted_to_srgb": profile_converted,
        "source_pixel_equivalent": source_pixel_equivalent,
        "pixel_data_verified": pixel_data_verified,
        "warnings": warnings,
    }


def normalize_one(source: Path, output: Path, max_dimension: int, replace_output: bool) -> dict:
    if source.resolve() == output.resolve():
        raise ValueError("Direct mode refuses to overwrite the source texture; choose a new output path")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="roblox_texture_") as temporary:
        staged = Path(temporary) / "normalized.png"
        result = normalize_to_stage(source, staged, max_dimension)
        result["output_file"] = str(output)
        existing_identical = output.is_file() and sha256_file(output) == result["output_sha256"]
        if output.exists() and not existing_identical and not replace_output:
            raise FileExistsError(f"Output exists and differs; refusing to overwrite: {output}")
        if not existing_identical:
            publish_staged_file(staged, output)
        result["status"] = (
            "TEXTURE_ALREADY_NORMALIZED" if existing_identical else "TEXTURE_NORMALIZATION_PASS"
        )
        result["output_sha256"] = sha256_file(output)
        result["output_size_bytes"] = output.stat().st_size
        return result


def unique_png_relative(old_relative: str, occupied: set[str], reusable: set[str]) -> str:
    old = PurePosixPath(old_relative)
    stem = old.stem if old.stem.lower().endswith("_roblox") else f"{old.stem}_Roblox"
    candidate = old.with_name(stem + ".png")
    stem = candidate.stem
    counter = 2
    while candidate.as_posix().lower() in occupied and candidate.as_posix().lower() not in reusable:
        candidate = candidate.with_name(f"{stem}_{counter}.png")
        counter += 1
    occupied.add(candidate.as_posix().lower())
    return candidate.as_posix()


def update_studio_import_plan(bundle: Path, texture_manifest: dict) -> str | None:
    """Refresh the sibling batch plan when repairing an existing bundle."""

    plan_path = bundle.parent / "studio_import_plan.json"
    if not plan_path.is_file():
        return None
    plan = json.loads(plan_path.read_text(encoding="utf-8-sig"))
    model_fbx = plan.get("model_fbx")
    if not isinstance(model_fbx, str):
        return None
    try:
        Path(model_fbx).resolve().relative_to(bundle)
    except (OSError, ValueError):
        return None

    existing_by_hash = {
        str(item.get("sha256", "")).lower(): item for item in plan.get("textures", [])
    }
    textures = []
    for record in texture_manifest.get("textures", []):
        relative = record.get("delivered_file")
        digest = str(record.get("sha256", "")).lower()
        if not relative or not digest:
            continue
        existing = existing_by_hash.get(digest, {})
        textures.append(
            {
                "file": str(safe_bundle_path(bundle, relative)),
                "sha256": digest,
                "roblox_asset_id": existing.get("roblox_asset_id"),
                "status": existing.get("status", "UPLOAD_OR_REUSE_REQUIRED"),
            }
        )
    # Texture repair must not downgrade newer plans that also contain animation
    # import settings and per-action state.
    if str(plan.get("schema_version", "1.0")) in {"", "1.0"}:
        plan["schema_version"] = "1.1"
    plan["textures"] = textures
    plan["texture_preparation"] = {
        "status": "TEXTURE_NORMALIZATION_PASS",
        "policy": POLICY_NAME,
        "max_dimension": texture_manifest.get("normalization_policy", {}).get(
            "max_dimension"
        ),
        "upload_only_delivered_files": True,
    }
    order = plan.get("required_order_zh")
    if isinstance(order, list):
        order[:] = [
            item
            for item in order
            if "texture_manifest.json" not in str(item)
            and "delivered_file" not in str(item)
            and "rbxassetid" not in str(item)
        ]
        order.insert(
            1,
            "只上传 texture_manifest.json 的 delivered_file 指向的 *_Roblox.png，并检查直接 rbxassetid 加载。",
        )
    atomic_write_json(plan_path, plan)
    return str(plan_path)


def normalize_bundle(bundle: Path, max_dimension: int, report_path: Path | None) -> dict:
    bundle = bundle.resolve()
    texture_manifest_path = bundle / "texture_manifest.json"
    bundle_manifest_path = bundle / "bundle_manifest.json"
    if not texture_manifest_path.is_file() or not bundle_manifest_path.is_file():
        raise FileNotFoundError("Bundle must contain texture_manifest.json and bundle_manifest.json")

    texture_manifest = json.loads(texture_manifest_path.read_text(encoding="utf-8-sig"))
    bundle_manifest = json.loads(bundle_manifest_path.read_text(encoding="utf-8-sig"))
    if texture_manifest.get("texture_mode") != "separate":
        raise ValueError("Automatic PNG normalization is supported only for the formal separate texture mode")

    records = [item for item in texture_manifest.get("textures", []) if item.get("delivered_file")]
    report_path = report_path or bundle / "texture_normalization.json"
    if not records:
        report = {
            "schema_version": "1.0",
            "status": "TEXTURE_NORMALIZATION_SKIPPED",
            "policy": POLICY_NAME,
            "bundle": str(bundle),
            "max_dimension": max_dimension,
            "textures": [],
            "warnings": ["Bundle has no delivered external textures"],
        }
        atomic_write_json(report_path, report)
        return report

    old_relatives = {str(item["delivered_file"]).lower() for item in records}
    occupied = {
        item.relative_to(bundle).as_posix().lower()
        for item in bundle.rglob("*")
        if item.is_file() and item.relative_to(bundle).as_posix().lower() not in old_relatives
    }
    used_final: set[str] = set()
    mapping: dict[str, str] = {}
    staged_results: list[tuple[dict, Path, Path, str, str]] = []

    staging = Path(tempfile.mkdtemp(prefix=".texture_normalization_", dir=bundle))
    try:
        for index, record in enumerate(records, start=1):
            old_relative = str(record["delivered_file"])
            source = safe_bundle_path(bundle, old_relative)
            if not source.is_file():
                raise FileNotFoundError(source)
            final_relative = unique_png_relative(
                old_relative,
                occupied | used_final,
                {old_relative.lower()},
            )
            used_final.add(final_relative.lower())
            staged = staging / f"{index:04d}.png"
            normalized = normalize_to_stage(source, staged, max_dimension)
            final = safe_bundle_path(bundle, final_relative)
            mapping[old_relative] = final_relative
            staged_results.append((normalized, staged, final, old_relative, final_relative))

        # Commit only after every image has encoded and passed strict read-back.
        for _, staged, final, _, _ in staged_results:
            final.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staged, final)
        for _, _, final, old_relative, final_relative in staged_results:
            old_path = safe_bundle_path(bundle, old_relative)
            if old_relative.lower() != final_relative.lower() and old_path.exists() and old_path != final:
                old_path.unlink()

        results_by_old = {old: result for result, _, _, old, _ in staged_results}
        for record in texture_manifest.get("textures", []):
            old_relative = record.get("delivered_file")
            if not old_relative or old_relative not in mapping:
                continue
            result = results_by_old[old_relative]
            record["pre_normalization_file"] = old_relative
            record["pre_normalization_sha256"] = record.get("sha256")
            record["delivered_file"] = mapping[old_relative]
            record["sha256"] = result["output_sha256"]
            record["normalization"] = {
                "status": result["status"],
                "policy": POLICY_NAME,
                "source_format": result["source_format"],
                "source_mode": result["source_mode"],
                "source_dimensions": result["source_dimensions"],
                "source_png_chunks": (
                    result["source_png"]["chunks"] if result["source_png"] else None
                ),
                "output_format": result["output_format"],
                "output_mode": result["output_mode"],
                "output_dimensions": result["output_dimensions"],
                "output_png_chunks": result["output_png"]["chunks"],
                "resized": result["resized"],
                "source_pixel_equivalent": result["source_pixel_equivalent"],
                "pixel_data_verified": result["pixel_data_verified"],
                "warnings": result["warnings"],
            }
        for material in texture_manifest.get("material_image_nodes", []):
            delivered = material.get("delivered_file")
            if delivered in mapping:
                material["delivered_file"] = mapping[delivered]
        texture_manifest["schema_version"] = "1.1"
        texture_manifest["normalization_policy"] = {
            "name": POLICY_NAME,
            "format": "PNG",
            "bit_depth": 8,
            "color_modes": ["RGB", "RGBA"],
            "max_dimension": max_dimension,
            "ancillary_chunks_removed": True,
        }
        atomic_write_json(texture_manifest_path, texture_manifest)

        for file_record in bundle_manifest.get("files", []):
            path = file_record.get("path")
            if file_record.get("kind") == "texture" and path in mapping:
                final = safe_bundle_path(bundle, mapping[path])
                file_record["path"] = mapping[path]
                file_record["size_bytes"] = final.stat().st_size
                file_record["sha256"] = sha256_file(final)
            elif path == "texture_manifest.json":
                file_record["size_bytes"] = texture_manifest_path.stat().st_size
                file_record["sha256"] = sha256_file(texture_manifest_path)

        appearance_repair = bundle_manifest.get("appearance_repair")
        if isinstance(appearance_repair, dict) and records:
            first = records[0]
            appearance_repair["delivered_texture"] = first.get("delivered_file")
            appearance_repair["delivered_texture_sha256"] = first.get("sha256")

        report = {
            "schema_version": "1.0",
            "status": "TEXTURE_NORMALIZATION_PASS",
            "policy": POLICY_NAME,
            "bundle": str(bundle),
            "max_dimension": max_dimension,
            "texture_count": len(staged_results),
            "textures": [
                {
                    **result,
                    "output_file": final_relative,
                    "source_file": old_relative,
                }
                for result, _, _, old_relative, final_relative in staged_results
            ],
            "warnings": [warning for result, *_ in staged_results for warning in result["warnings"]],
        }
        report["studio_import_plan_updated"] = update_studio_import_plan(
            bundle, texture_manifest
        )
        atomic_write_json(report_path, report)

        try:
            report_relative = report_path.resolve().relative_to(bundle).as_posix()
        except ValueError:
            report_relative = None
        if report_relative:
            files = bundle_manifest.setdefault("files", [])
            files[:] = [item for item in files if item.get("path") != report_relative]
            files.append(
                {
                    "path": report_relative,
                    "kind": "metadata",
                    "size_bytes": report_path.stat().st_size,
                    "sha256": sha256_file(report_path),
                }
            )

        bundle_manifest["schema_version"] = "1.2"
        bundle_manifest.setdefault("export_settings", {})["texture_normalization"] = POLICY_NAME
        bundle_manifest["texture_normalization"] = {
            "status": report["status"],
            "policy": POLICY_NAME,
            "report": report_relative,
            "max_dimension": max_dimension,
            "texture_count": len(staged_results),
        }
        bundle_manifest.setdefault("notes", []).append(
            "External textures were re-encoded as metadata-free 8-bit RGB/RGBA PNG and read back before Studio import."
        )
        atomic_write_json(bundle_manifest_path, bundle_manifest)
        return report
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--input")
    mode.add_argument("--bundle")
    parser.add_argument("--output")
    parser.add_argument("--report")
    parser.add_argument("--max-dimension", type=int, default=4096)
    parser.add_argument("--replace-output", action="store_true")
    args = parser.parse_args()

    if not 256 <= args.max_dimension <= 4096:
        raise ValueError("--max-dimension must be between 256 and 4096")

    report_path = Path(args.report).expanduser().resolve() if args.report else None
    if args.input:
        if not args.output:
            raise ValueError("--output is required with --input")
        result = normalize_one(
            Path(args.input).expanduser().resolve(),
            Path(args.output).expanduser().resolve(),
            args.max_dimension,
            args.replace_output,
        )
        report = {"schema_version": "1.0", **result}
        if report_path:
            atomic_write_json(report_path, report)
    else:
        if args.output:
            raise ValueError("--output is not used with --bundle")
        report = normalize_bundle(
            Path(args.bundle).expanduser().resolve(),
            args.max_dimension,
            report_path,
        )

    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ROBLOX_TEXTURE_NORMALIZATION_FAILED {type(exc).__name__}: {exc}", file=sys.stderr)
        traceback.print_exc()
        raise SystemExit(2)
