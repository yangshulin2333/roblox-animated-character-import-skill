#!/usr/bin/env python3
"""Fresh-import every FBX in a generated bundle and check portable invariants."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import traceback

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from inspect_in_blender import collect_report, load_source, write_json


def argv_after_separator() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--report")
    args = parser.parse_args(argv_after_separator())

    bundle = Path(args.bundle).expanduser().resolve()
    manifest = json.loads((bundle / "bundle_manifest.json").read_text(encoding="utf-8"))
    fbx_records = [
        item for item in manifest.get("files", []) if item.get("kind") in {"model", "animation"}
    ]
    results = []
    blockers = []

    for record in fbx_records:
        relative = record["path"]
        path = (bundle / relative).resolve()
        path.relative_to(bundle)
        load_source(path)
        report = collect_report(path)
        action_count = int(report["summary"]["action_count"])
        local_errors = list(report.get("blockers", []))
        if record["kind"] == "model" and action_count != 0:
            local_errors.append(
                {"code": "MODEL_HAS_ANIMATION", "message": f"Bind model imported {action_count} actions."}
            )
        if record["kind"] == "animation" and action_count != 1:
            local_errors.append(
                {
                    "code": "ANIMATION_TRACK_COUNT",
                    "message": f"Animation FBX imported {action_count} actions instead of exactly one.",
                }
            )
        results.append(
            {
                "path": relative,
                "kind": record["kind"],
                "declared_action": record.get("action"),
                "summary": report["summary"],
                "imported_actions": [item["name"] for item in report.get("actions", [])],
                "errors": local_errors,
                "warnings": report.get("warnings", []),
            }
        )
        if local_errors:
            blockers.append({"path": relative, "errors": local_errors})

    output = {
        "schema_version": "1.0",
        "status": "ROUNDTRIP_PASS" if not blockers else "ROUNDTRIP_BLOCKED",
        "blender_version": __import__("bpy").app.version_string,
        "files": results,
        "blockers": blockers,
    }
    report_path = (
        Path(args.report).expanduser().resolve()
        if args.report
        else bundle / "readback_report.json"
    )
    write_json(report_path, output)
    print(
        "ROBLOX_BUNDLE_READBACK",
        json.dumps({"status": output["status"], "files": len(results)}, ensure_ascii=False),
    )
    return 0 if not blockers else 3


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ROBLOX_BUNDLE_READBACK_FAILED {type(exc).__name__}: {exc}", file=sys.stderr)
        traceback.print_exc()
        raise SystemExit(2)
