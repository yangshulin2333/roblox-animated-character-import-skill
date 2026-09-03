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
    for record in model_records + animation_records + all_in_one_records:
        if not str(record.get("path", "")).lower().endswith(".fbx"):
            errors.append(f"Non-FBX model/animation entry: {record.get('path')}")
    if not manifest.get("target", {}).get("one_animation_track_per_fbx"):
        errors.append("Manifest does not declare one animation track per FBX")

    report = {
        "schema_version": "1.0",
        "status": "BUNDLE_PASS" if not errors else "BUNDLE_BLOCKED",
        "bundle_manifest_sha256": sha256_file(manifest_path),
        "files_checked": checked,
        "errors": errors,
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
