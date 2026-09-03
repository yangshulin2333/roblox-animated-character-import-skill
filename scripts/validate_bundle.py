#!/usr/bin/env python3
"""Validate portable bundle structure and SHA-256 identities."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import traceback


def argv_after_separator() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_bundle_path(bundle: Path, relative: str) -> Path:
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts:
        raise ValueError(f"Unsafe manifest path: {relative}")
    candidate = (bundle / Path(*pure.parts)).resolve()
    candidate.relative_to(bundle)
    return candidate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--report")
    args = parser.parse_args(argv_after_separator())

    bundle = Path(args.bundle).expanduser().resolve()
    manifest_path = bundle / "bundle_manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(manifest_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    errors = []
    warnings = []
    checked = []
    file_records = manifest.get("files", [])
    for record in file_records:
        relative = record.get("path")
        if not isinstance(relative, str):
            errors.append("Manifest file entry has no string path")
            continue
        try:
            path = safe_bundle_path(bundle, relative)
        except Exception as exc:
            errors.append(str(exc))
            continue
        if not path.is_file():
            errors.append(f"Missing file: {relative}")
            continue
        actual_hash = sha256_file(path)
        expected_hash = record.get("sha256")
        if actual_hash != expected_hash:
            errors.append(f"SHA-256 mismatch: {relative}")
        checked.append(
            {
                "path": relative,
                "size_bytes": path.stat().st_size,
                "sha256": actual_hash,
                "match": actual_hash == expected_hash,
            }
        )

    appearance_manifest_path = bundle / "appearance_manifest.json"
    appearance_manifest_sha256 = None
    appearance_files_checked = []
    if appearance_manifest_path.is_file():
        appearance_manifest_sha256 = sha256_file(appearance_manifest_path)
        appearance_manifest = json.loads(appearance_manifest_path.read_text(encoding="utf-8-sig"))
        if appearance_manifest.get("status") != "APPEARANCE_BUNDLE_PASS":
            errors.append("Appearance manifest is not APPEARANCE_BUNDLE_PASS")
        appearances = appearance_manifest.get("appearances", [])
        declared_appearance_count = appearance_manifest.get("appearance_count")
        if declared_appearance_count != len(appearances):
            errors.append(
                f"Appearance count {len(appearances)} does not match declared count {declared_appearance_count}"
            )
        seen_appearance_paths = set()
        for record in appearance_manifest.get("material_catalog", []):
            relative = record.get("texture")
            if not isinstance(relative, str):
                errors.append("Appearance material entry has no string texture path")
                continue
            if relative in seen_appearance_paths:
                continue
            seen_appearance_paths.add(relative)
            try:
                path = safe_bundle_path(bundle, relative)
            except Exception as exc:
                errors.append(str(exc))
                continue
            if not path.is_file():
                errors.append(f"Missing appearance texture: {relative}")
                continue
            actual_hash = sha256_file(path)
            expected_hash = record.get("texture_sha256")
            if actual_hash != expected_hash:
                errors.append(f"Appearance SHA-256 mismatch: {relative}")
            appearance_files_checked.append(
                {
                    "path": relative,
                    "size_bytes": path.stat().st_size,
                    "sha256": actual_hash,
                    "match": actual_hash == expected_hash,
                }
            )

    model_records = [record for record in file_records if record.get("kind") == "model"]
    animation_records = [record for record in file_records if record.get("kind") == "animation"]
    all_in_one_records = [record for record in file_records if record.get("kind") == "all_in_one"]
    declared_actions = manifest.get("actions", [])
    if len(model_records) != 1:
        errors.append(f"Expected one model FBX, found {len(model_records)}")
    if len(animation_records) != len(declared_actions):
        errors.append(
            f"Animation record count {len(animation_records)} does not match declared actions {len(declared_actions)}"
        )
    if len(all_in_one_records) > 1:
        errors.append(f"Expected at most one all-in-one FBX, found {len(all_in_one_records)}")
    schema_version = str(manifest.get("schema_version", "1.0"))
    for record in all_in_one_records:
        if schema_version >= "1.1" and record.get("role") != "preview_only":
            errors.append("All-in-one FBX must be declared preview_only")
        elif schema_version < "1.1" and record.get("role") != "preview_only":
            warnings.append("Legacy all-in-one FBX has no preview_only declaration")
    for record in model_records + animation_records + all_in_one_records:
        if not str(record.get("path", "")).lower().endswith(".fbx"):
            errors.append(f"Non-FBX model/animation entry: {record.get('path')}")
    if not manifest.get("target", {}).get("one_animation_track_per_fbx"):
        errors.append("Manifest does not declare one animation track per FBX")
    if schema_version >= "1.1" and manifest.get("target", {}).get("formal_runtime_contract") != "model_bind_plus_one_action_files":
        errors.append("Manifest does not declare the formal bind-plus-one-action runtime contract")
    elif schema_version < "1.1" and not manifest.get("target", {}).get("formal_runtime_contract"):
        warnings.append("Legacy bundle has no formal runtime contract declaration")

    report = {
        "schema_version": "1.0",
        "status": "BUNDLE_PASS" if not errors else "BUNDLE_BLOCKED",
        "bundle_manifest_sha256": sha256_file(manifest_path),
        "appearance_manifest_sha256": appearance_manifest_sha256,
        "files_checked": checked,
        "appearance_files_checked": appearance_files_checked,
        "errors": errors,
        "warnings": warnings,
    }
    report_path = (
        Path(args.report).expanduser().resolve()
        if args.report
        else bundle / "bundle_validation.json"
    )
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("ROBLOX_BUNDLE_VALIDATION", json.dumps({"status": report["status"], "files": len(checked)}))
    return 0 if not errors else 3


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ROBLOX_BUNDLE_VALIDATION_FAILED {type(exc).__name__}: {exc}", file=sys.stderr)
        traceback.print_exc()
        raise SystemExit(2)
