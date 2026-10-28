#!/usr/bin/env python3
"""Extracts trips from an Arc Timeline iCloud backup and proposes a classification to review.

Read-only on the backup. Writes OUT_DIR/trips.json: one entry per trip in the period, with
its samples (time, position, altitude, accuracies, speed, step rate) and computed metrics:
distance, durations, moving speed, step rate, GPS gaps, Île-de-France containment, and a
suggested label with the reasons behind it. Arc's own activity classification is ignored
(unreliable), only kept for information.

Usage: python3 arc_extract.py BACKUP_DIR OUT_DIR [START_UTC END_UTC] [--watch-exports DIR]
"""
import argparse
import gzip
import json
import math
import statistics
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

PARIS = ZoneInfo("Europe/Paris")
# Île-de-France bounding box (generous): trips leaving it are long-distance (TGV...) and excluded.
IDF = (48.10, 49.25, 1.44, 3.56)  # lat min, lat max, lon min, lon max
MIN_DISTANCE_M = 300
MIN_DURATION_S = 120


def parse(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def haversine(a, b):
    r = 6371008.8
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def load_items(backup, months):
    items = []
    for m in months:
        f = backup / "items" / f"{m}.json"
        if f.exists():
            d = json.loads(f.read_text())
            items += d if isinstance(d, list) else d["items"]
    return items


def load_samples(backup, start, end):
    samples, day = [], start - timedelta(days=7)
    seen = set()
    while day <= end + timedelta(days=7):
        year, week, _ = day.isocalendar()
        name = f"{year}-W{week:02d}.json.gz"
        f = backup / "samples" / name
        if name not in seen and f.exists():
            seen.add(name)
            d = json.loads(gzip.open(f).read())
            samples += d if isinstance(d, list) else d["samples"]
        day += timedelta(days=1)
    return samples


def metrics(points):
    """points: time-sorted dicts with t, lat, lon, alt, hacc, vacc, speed, stephz, moving."""
    good = [p for p in points if p["hacc"] is not None and 0 < p["hacc"] <= 100]
    dist, max_jump_speed, gaps = 0.0, 0.0, []
    for a, b in zip(good, good[1:]):
        d = haversine((a["lat"], a["lon"]), (b["lat"], b["lon"]))
        dt = (b["t"] - a["t"]).total_seconds()
        dist += d
        if dt > 60 and d > 300:
            gaps.append({"seconds": dt, "meters": d, "kmh": d / dt * 3.6})
        if dt > 0:
            max_jump_speed = max(max_jump_speed, d / dt * 3.6) if dt >= 5 else max_jump_speed
    speeds = [p["speed"] * 3.6 for p in points if p["speed"] is not None and p["speed"] >= 0 and p["moving"] == 1]
    steps = [p["stephz"] for p in points if p["stephz"] is not None and p["moving"] == 1]
    duration = (points[-1]["t"] - points[0]["t"]).total_seconds() if len(points) > 1 else 0
    inside = sum(1 for p in good if IDF[0] <= p["lat"] <= IDF[1] and IDF[2] <= p["lon"] <= IDF[3])
    srt = sorted(speeds)
    pct = lambda q: srt[min(len(srt) - 1, int(len(srt) * q))] if srt else None
    return {
        "distance_m": dist, "duration_s": duration, "points": len(points), "good_points": len(good),
        "speed_median_kmh": statistics.median(speeds) if speeds else None, "speed_p90_kmh": pct(0.9),
        "speed_p98_kmh": pct(0.98), "avg_speed_kmh": dist / duration * 3.6 if duration else None,
        "stephz_median": statistics.median(steps) if steps else None,
        "walking_fraction": sum(1 for s in steps if s >= 1.2) / len(steps) if steps else None,
        "gps_gaps": gaps, "inside_idf_fraction": inside / len(good) if good else None,
    }


def classify(m):
    """Suggested label + human-readable reasons. The user validates every trip anyway."""
    reasons = []
    inside = m["inside_idf_fraction"]
    if inside is not None and inside < 0.9:  # tolerate an isolated aberrant GPS point
        return "hors_idf", [f"{1 - inside:.0%} du trajet hors Île-de-France (voyage / train)"]
    if m["distance_m"] < MIN_DISTANCE_M or m["duration_s"] < MIN_DURATION_S:
        return "trop_court", [f"{m['distance_m']:.0f} m en {m['duration_s'] / 60:.1f} min"]
    med, p90 = m["speed_median_kmh"] or 0, m["speed_p90_kmh"] or 0
    walk = m["walking_fraction"] or 0
    if m["gps_gaps"]:
        g = max(m["gps_gaps"], key=lambda g: g["meters"])
        if g["kmh"] > 15:
            reasons.append(f"trou GPS de {g['seconds'] / 60:.1f} min sur {g['meters'] / 1000:.1f} km (souterrain ?)")
    if p90 > 45:
        reasons.append(f"vitesses élevées (p90 {p90:.0f} km/h)")
    if reasons:
        return "a_verifier", reasons + [f"médiane {med:.1f} km/h"]
    # Above ~10 km/h detected "steps" are pedalling with the phone in a pocket, not walking.
    if 8 <= med <= 32:
        return "velo", [f"médiane {med:.1f} km/h"]
    if med < 8 and walk >= 0.3:
        return "marche", [f"pas détectés {walk:.0%} du temps, {med:.1f} km/h"]
    if med < 8:
        return "a_verifier", [f"lent sans pas détectés ({med:.1f} km/h) : vélo dans les bouchons ou GPS qui dérive ?"]
    return "a_verifier", [f"profil inhabituel : médiane {med:.1f} km/h"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("backup", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("start", nargs="?", default="2026-08-31T22:00:00Z")  # 1 Sept 00:00 Paris
    ap.add_argument("end", nargs="?", default="2026-10-14T10:00:00Z")    # end of the gap to rebuild
    ap.add_argument("--watch-exports", type=Path, help="WorkoutRescue exports, to flag trips matching watch workouts")
    args = ap.parse_args()
    start, end = parse(args.start), parse(args.end)
    months = sorted({(start + timedelta(days=d)).strftime("%Y-%m") for d in range((end - start).days + 1)})
    items = [i for i in load_items(args.backup, months)
             if not i["base"]["isVisit"] and not i["base"]["deleted"] and not i["base"]["disabled"]
             and start <= parse(i["base"]["startDate"]) < end]
    by_item = {}
    for s in load_samples(args.backup, start, end):
        if s.get("disabled") or s.get("timelineItemId") is None:
            continue
        by_item.setdefault(s["timelineItemId"], []).append(s)

    watch = []
    if args.watch_exports:
        for f in args.watch_exports.glob("*/workout.json"):
            d = json.loads(f.read_text())
            w = d["workout"]
            watch.append({"uuid": w["uuid"], "start": parse(w["startDate"]), "end": parse(w["endDate"]),
                          "activity": w["activityType"]["name"], "has_route": bool(d["routes"]),
                          "distance_m": (w.get("totalDistance") or {}).get("value")})

    trips = []
    for it in sorted(items, key=lambda i: i["base"]["startDate"]):
        raw = sorted(by_item.get(it["base"]["id"], []), key=lambda s: s["date"])
        points = [{"t": parse(s["date"]), "lat": s.get("latitude"), "lon": s.get("longitude"), "alt": s.get("altitude"),
                   "hacc": s.get("horizontalAccuracy"), "vacc": s.get("verticalAccuracy"), "speed": s.get("speed"),
                   "course": s.get("course"), "stephz": s.get("stepHz"), "moving": s.get("movingState")}
                  for s in raw if s.get("latitude") is not None]
        if not points:
            continue
        m = metrics(points)
        label, reasons = classify(m)
        t0, t1 = points[0]["t"], points[-1]["t"]
        overlap = [w for w in watch if w["start"] < t1 and w["end"] > t0]
        trips.append({
            "id": it["base"]["id"], "start": t0.isoformat(), "end": t1.isoformat(),
            "start_local": t0.astimezone(PARIS).strftime("%Y-%m-%d %H:%M"), "label": label, "reasons": reasons,
            "metrics": m, "arc_activity": it.get("trip", {}).get("classifiedActivityType"),
            "watch_overlap": [{"uuid": w["uuid"], "activity": w["activity"], "has_route": w["has_route"],
                               "distance_m": w["distance_m"]} for w in overlap],
            "points": [{**p, "t": p["t"].isoformat()} for p in points],
        })
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "trips.json").write_text(json.dumps({"start": args.start, "end": args.end, "trips": trips}))
    counts = {}
    for t in trips:
        counts[t["label"]] = counts.get(t["label"], 0) + 1
    print(f"{len(trips)} trajets : " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1])))
    for t in trips:
        if t["watch_overlap"]:
            w = t["watch_overlap"][0]
            print(f"  recouvre une séance montre : {t['start_local']} {t['metrics']['distance_m'] / 1000:.2f} km Arc "
                  f"↔ {w['activity']} {(w['distance_m'] or 0) / 1000:.2f} km montre, tracé montre: {'oui' if w['has_route'] else 'NON'}")


if __name__ == "__main__":
    main()
