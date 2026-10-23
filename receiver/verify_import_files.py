#!/usr/bin/env python3
"""Checks generated FIT files against the source archives (workout.json), read-only.

Decodes each FIT with `fitparse` (independent of the library that wrote it) and compares:
times, sport, totals, every GPS point (position, altitude), and how many heart rate,
cadence and power samples of the archive are represented in the FIT records.

Usage: uv run --with fitparse python3 verify_import_files.py EXPORT_DIR FIT_DIR
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from fitparse import FitFile

HK = "HKQuantityTypeIdentifier"
TOLERANCE_S = 15  # a sample counts as represented if a record carries it within this delay


def t(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def series(doc, identifier):
    for q in doc.get("quantityTypes", []):
        if q["typeIdentifier"] == HK + identifier:
            out = []
            for s in q["samples"]:
                if s.get("series"):
                    out += [(t(v["endDate"]), v["value"]) for v in s["series"]]
                else:
                    out.append((t(s["startDate"]), s["value"]))
            return sorted(out)
    return []


def covered(samples, record_times):
    """Number of samples with a FIT record at most TOLERANCE_S later carrying a value."""
    if not samples:
        return 0
    times = sorted(record_times)
    import bisect
    n = 0
    for when, _ in samples:
        when = when.replace(microsecond=0)  # FIT records have 1-second resolution
        i = bisect.bisect_left(times, when)
        if i < len(times) and (times[i] - when).total_seconds() <= TOLERANCE_S:
            n += 1
    return n


def check(archive, fit_path):
    doc = json.loads(archive.read_text(encoding="utf-8"))
    w = doc["workout"]
    problems = []
    fit = FitFile(str(fit_path))
    fit.parse()  # raises on a corrupt file / bad CRC
    records = [{f.name: f.value for f in m} for m in fit.get_messages("record")]
    session = next({f.name: f.value for f in m} for m in fit.get_messages("session"))

    start, end = t(w["startDate"]).replace(microsecond=0), t(w["endDate"]).replace(microsecond=0)
    if session["start_time"].replace(tzinfo=timezone.utc) != start:
        problems.append(f"start {session['start_time']} != {start}")
    dist = (w.get("totalDistance") or {}).get("value")
    if dist and abs((session.get("total_distance") or 0) - dist) > 1:
        problems.append(f"distance {session.get('total_distance')} != {dist:.1f}")

    gps = [p for r in doc["routes"] for p in r["points"] if p["horizontalAccuracy"] >= 0]
    fit_gps = [r for r in records if r.get("position_lat") is not None]
    if len(fit_gps) != len(gps):
        problems.append(f"GPS points {len(fit_gps)} != {len(gps)}")
    else:
        semis = 2 ** 31 / 180
        worst = max((abs(r["position_lat"] / semis - p["latitude"]) + abs(r["position_long"] / semis - p["longitude"])
                     for r, p in zip(fit_gps, gps)), default=0)
        if worst > 1e-6:
            problems.append(f"position drift {worst:.2e} deg")
        alt_missing = sum(1 for r, p in zip(fit_gps, gps)
                          if p["verticalAccuracy"] >= 0 and r.get("altitude") is None and r.get("enhanced_altitude") is None)
        if alt_missing:
            problems.append(f"{alt_missing} altitudes missing")

    stamps = [r["timestamp"] for r in records]
    if stamps != sorted(stamps):
        problems.append("timestamps not in order")
    if records and (stamps[0].replace(tzinfo=timezone.utc) < start.replace(second=0) or stamps[-1].replace(tzinfo=timezone.utc) > end.replace(microsecond=0).replace(second=59)):
        problems.append("records outside workout time")

    result = {"gps": (len(fit_gps), len(gps))}
    for name, field in (("HeartRate", "heart_rate"), ("CyclingCadence", "cadence"), ("CyclingPower", "power")):
        src = series(doc, name)
        rec_times = [r["timestamp"].replace(tzinfo=timezone.utc) for r in records if r.get(field) is not None]
        n = covered(src, rec_times)
        result[name] = (n, len(src))
        if src and n < len(src):
            problems.append(f"{name}: {len(src) - n} of {len(src)} samples not in FIT")
    # Compare with the samples actually in the archive (the summary statistic may include purged ones).
    hr_vals = [r["heart_rate"] for r in records if r.get("heart_rate")]
    src_hr = [v for _, v in series(doc, "HeartRate")]
    if hr_vals and src_hr and abs(max(hr_vals) - round(max(src_hr))) > 1:
        problems.append(f"max HR {max(hr_vals)} != {max(src_hr):.0f}")
    return result, problems, session


def main(argv):
    exports, fit_dir = Path(argv[1]), Path(argv[2])
    archives = {}
    for a in exports.glob("*/workout.json"):
        doc = json.loads(a.read_text(encoding="utf-8"))
        if not doc.get("isDemoData"):
            archives[t(doc["workout"]["startDate"]).astimezone().strftime("%Y-%m-%d_%H%M")] = a
    fits = sorted(fit_dir.glob("*.fit"))
    print(f"{len(archives)} archives, {len(fits)} FIT files")
    failures = 0
    for f in fits:
        archive = archives.pop(f.name[:15], None)
        if archive is None:
            print(f"BAD {f.name}: no matching archive")
            failures += 1
            continue
        try:
            result, problems, session = check(archive, f)
        except Exception as exc:  # unreadable file
            print(f"BAD {f.name}: unreadable ({exc})")
            failures += 1
            continue
        failures += bool(problems)
        gps, hr = result["gps"], result["HeartRate"]
        print(f"{'OK ' if not problems else 'BAD'} {f.name}: GPS {gps[0]}/{gps[1]}, FC {hr[0]}/{hr[1]}, "
              f"cadence {result['CyclingCadence'][0]}/{result['CyclingCadence'][1]}, puissance {result['CyclingPower'][0]}/{result['CyclingPower'][1]}, "
              f"{session.get('sport')}/{session.get('sub_sport')}" + ("" if not problems else "  <- " + "; ".join(problems)))
    for key in archives:
        print(f"BAD archive {key} has no FIT file")
        failures += 1
    print(f"\n{failures} problème(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
