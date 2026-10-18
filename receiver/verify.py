#!/usr/bin/env python3
"""Checks the integrity of received exports, read-only.

For every stored file: recompute SHA-256 and compare with receipts.jsonl; parse workout JSON
(schema, UUID, route completeness, point/sample counts) and GPX (well-formed, point count).
Exit code 0 only when everything is consistent.

Usage: python3 verify.py [EXPORT_DIR] [--json]
"""
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

GPX_NS = "{http://www.topografix.com/GPX/1/1}"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_json(path, folder_uuid):
    doc = json.loads(path.read_text(encoding="utf-8"))
    problems = []
    if doc.get("format") != "workoutrescue.workout":
        problems.append("unexpected format")
    workout = doc.get("workout", {})
    if str(workout.get("uuid", "")).upper() != folder_uuid:
        problems.append("UUID differs from folder")
    routes = doc.get("routes", [])
    points = sum(len(r.get("points", [])) for r in routes)
    for r in routes:
        expected = r.get("expectedPointCount")
        if r.get("error") or (expected is not None and expected != len(r.get("points", []))):
            problems.append("route {} incomplete ({} of {} points, error={})".format(r.get("uuid"), len(r.get("points", [])), expected, r.get("error")))
    samples = {q.get("typeIdentifier", "?").replace("HKQuantityTypeIdentifier", ""): len(q.get("samples", [])) for q in doc.get("quantityTypes", [])}
    info = {"schema": doc.get("schemaVersion"), "demo": doc.get("isDemoData"), "activity": workout.get("activityType", {}).get("name"),
            "start": workout.get("startDate"), "routes": len(routes), "gps_points": points, "samples": samples,
            "warnings": doc.get("warnings", [])}
    return info, problems


def check_gpx(path):
    count = 0
    segments = 0
    for _, element in ET.iterparse(path, events=("end",)):
        if element.tag == GPX_NS + "trkpt":
            count += 1
            element.clear()
        elif element.tag == GPX_NS + "trkseg":
            segments += 1
    return {"segments": segments, "points": count}, []


def verify(root):
    root = Path(root)
    receipts = {}
    receipts_file = root / "receipts.jsonl"
    if receipts_file.exists():
        for line in receipts_file.read_text(encoding="utf-8").splitlines():
            if line.strip():
                record = json.loads(line)
                receipts[record["file"]] = record
    report, failures = [], 0
    for folder in sorted(p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")):
        for file in sorted(f for f in folder.iterdir() if f.is_file() and f.name != "receipts.jsonl"):
            relative = file.relative_to(root).as_posix()
            entry = {"file": relative, "bytes": file.stat().st_size, "sha256": sha256(file), "problems": []}
            receipt = receipts.get(relative)
            if receipt is None:
                entry["problems"].append("no receipt")
            elif receipt["sha256"] != entry["sha256"] or receipt["bytes"] != entry["bytes"]:
                entry["problems"].append("content differs from receipt")
            try:
                if file.suffix == ".json":
                    info, problems = check_json(file, folder.name)
                else:
                    info, problems = check_gpx(file)
                entry.update(info)
                entry["problems"] += problems
            except Exception as exc:  # report, keep going
                entry["problems"].append("unreadable: {}".format(exc))
            failures += bool(entry["problems"])
            report.append(entry)
    return report, failures


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).with_name("exports")
    report, failures = verify(root)
    if "--json" in argv:
        print(json.dumps({"files": report, "failures": failures}, indent=2, sort_keys=True))
    else:
        for e in report:
            status = "OK " if not e["problems"] else "BAD"
            detail = "gps={} samples={}".format(e.get("gps_points"), sum(e.get("samples", {}).values())) if "gps_points" in e else "gpx points={}".format(e.get("points"))
            print("{} {} {} B sha256={}… {}{}".format(status, e["file"], e["bytes"], e["sha256"][:16], detail,
                                                     "" if not e["problems"] else "  <- " + "; ".join(e["problems"])))
        print("{} file(s), {} with problems".format(len(report), failures))
    return 1 if failures or not report else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
