#!/usr/bin/env python3
"""Map-matches validated bike trips against a local OSRM (bicycle profile) and repairs only
what is implausible. Read-only on its inputs; writes WORK_DIR/matched.json.

Per point:
  raw          kept as recorded (within MAX_KEEP_M of the matched cycle network)
  snapped      replaced by its matched position (GPS more than MAX_KEEP_M off the network)
  interpolated added along the most likely cycle route to fill a gap > GAP_S
Points OSRM rejects as outliers are dropped (the gap they leave is filled as above).
A trip whose matching confidence is low is left raw and flagged.

Usage: python3 map_match.py WORK_DIR VALIDATION_JSON [--osrm http://127.0.0.1:5000]
"""
import argparse
import json
import math
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

MAX_KEEP_M = 30        # raw point kept if within this distance of the matched road
GAP_S = 15             # fill time gaps longer than this...
GAP_MIN_M = 60         # ...when the two points are at least this far apart
WINDOW = 120           # points per match request (overlapping windows)
OVERLAP = 10
MIN_CONFIDENCE = 0.2


def haversine(a, b):
    r = 6371008.8
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def osrm(base, service, coords, **params):
    path = ";".join(f"{lon:.6f},{lat:.6f}" for lat, lon in coords)
    query = "&".join(f"{k}={v}" for k, v in params.items())
    with urllib.request.urlopen(f"{base}/{service}/v1/bicycle/{path}?{query}", timeout=60) as r:
        return json.loads(r.read())


def match_points(base, pts):
    """Returns per-point (snapped (lat, lon) or None, snap distance, confidence)."""
    result = [None] * len(pts)
    i = 0
    while i < len(pts):
        win = pts[i:i + WINDOW]
        if len(win) < 2:
            break
        stamps, last = [], None
        for p in win:  # OSRM needs strictly increasing integer timestamps
            s = int(p["t"].timestamp())
            s = s if last is None or s > last else last + 1
            stamps.append(s)
            last = s
        radiuses = [min(40, max(5, p["hacc"] or 20)) for p in win]
        try:
            res = osrm(base, "match", [(p["lat"], p["lon"]) for p in win], timestamps=";".join(map(str, stamps)),
                       radiuses=";".join(f"{r:.1f}" for r in radiuses), gaps="split", tidy="false",
                       overview="false", geometries="geojson")
        except Exception:
            res = {"code": "Error"}
        conf = {k: m.get("confidence", 0) for k, m in enumerate(res.get("matchings", []))}
        for k, tp in enumerate(res.get("tracepoints") or [None] * len(win)):
            idx = i + k
            if result[idx] is not None and k < OVERLAP:  # keep the earlier window's answer in the overlap
                continue
            if tp is None:
                result[idx] = (None, None, 0.0)
            else:
                lon, lat = tp["location"]
                result[idx] = ((lat, lon), tp.get("distance", haversine((pts[idx]["lat"], pts[idx]["lon"]), (lat, lon))),
                               conf.get(tp.get("matchings_index"), 0.0))
        if i + WINDOW >= len(pts):
            break
        i += WINDOW - OVERLAP
    return [r if r is not None else (None, None, 0.0) for r in result]


def route_between(base, a, b):
    try:
        res = osrm(base, "route", [a, b], overview="full", geometries="geojson")
        coords = res["routes"][0]["geometry"]["coordinates"]
        return [(lat, lon) for lon, lat in coords]
    except Exception:
        return []


def repair(base, trip):
    pts = [{"t": datetime.fromisoformat(p["t"]), "lat": p["lat"], "lon": p["lon"], "alt": p["alt"],
            "hacc": p["hacc"], "vacc": p["vacc"], "speed": p["speed"]}
           for p in trip["points"] if p["hacc"] is not None and 0 < p["hacc"] <= 200]
    if len(pts) < 2:
        return {"status": "trop_peu_de_points", "points": []}
    matched = match_points(base, pts)
    confidences = [c for _, _, c in matched if c]
    confidence = sum(confidences) / len(confidences) if confidences else 0.0
    if confidence < MIN_CONFIDENCE:
        out = [{"t": p["t"].isoformat(), "lat": p["lat"], "lon": p["lon"], "alt": p["alt"], "src": "raw"} for p in pts]
        return {"status": "confiance_faible_laisse_brut", "confidence": confidence, "points": out}

    kept = []
    dropped = 0
    for p, (snap, dist, _) in zip(pts, matched):
        if snap is None:
            dropped += 1
            continue
        if dist is not None and dist > MAX_KEEP_M:
            kept.append({**p, "lat": snap[0], "lon": snap[1], "src": "snapped", "snap": snap})
        else:
            kept.append({**p, "src": "raw", "snap": snap})

    out = []
    for a, b in zip(kept, kept[1:] + [None]):
        out.append(a)
        if b is None:
            continue
        dt = (b["t"] - a["t"]).total_seconds()
        if dt > GAP_S and haversine((a["lat"], a["lon"]), (b["lat"], b["lon"])) > GAP_MIN_M:
            path = route_between(base, a["snap"], b["snap"])[1:-1]
            if path:
                seg = [(a["lat"], a["lon"])] + path + [(b["lat"], b["lon"])]
                cum = [0.0]
                for x, y in zip(seg, seg[1:]):
                    cum.append(cum[-1] + haversine(x, y))
                total = cum[-1] or 1.0
                for (lat, lon), d in zip(path, cum[1:-1]):
                    out.append({"t": a["t"] + timedelta(seconds=dt * d / total), "lat": lat, "lon": lon,
                                "alt": None, "src": "interpolated"})
    counts = {s: sum(1 for p in out if p["src"] == s) for s in ("raw", "snapped", "interpolated")}
    dist = lambda ps: sum(haversine((x["lat"], x["lon"]), (y["lat"], y["lon"])) for x, y in zip(ps, ps[1:]))
    return {
        "status": "ok", "confidence": confidence, "dropped_outliers": dropped, **counts,
        "distance_raw_m": dist(pts), "distance_repaired_m": dist(out),
        "points": [{"t": p["t"].isoformat(), "lat": p["lat"], "lon": p["lon"], "alt": p.get("alt"), "src": p["src"]} for p in out],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("work", type=Path)
    ap.add_argument("validation", type=Path)
    ap.add_argument("--osrm", default="http://127.0.0.1:5000")
    args = ap.parse_args()
    trips = {t["id"]: t for t in json.loads((args.work / "trips.json").read_text())["trips"]}
    choices = json.loads(args.validation.read_text())["choices"]
    bike = [trips[i] for i, c in choices.items() if c == "velo" and i in trips]
    results = []
    for n, trip in enumerate(sorted(bike, key=lambda t: t["start"]), 1):
        r = repair(args.osrm, trip)
        r.update({"id": trip["id"], "start_local": trip["start_local"], "start": trip["start"], "end": trip["end"],
                  "watch_overlap": trip["watch_overlap"]})
        results.append(r)
        if r["status"] == "ok":
            print(f"{n:3}/{len(bike)} {trip['start_local']}  conf {r['confidence']:.2f}  brut {r['raw']}  recalés {r['snapped']}  "
                  f"interpolés {r['interpolated']}  aberrants {r['dropped_outliers']}  "
                  f"{r['distance_raw_m'] / 1000:.2f} → {r['distance_repaired_m'] / 1000:.2f} km", flush=True)
        else:
            print(f"{n:3}/{len(bike)} {trip['start_local']}  {r['status']}", flush=True)
    (args.work / "matched.json").write_text(json.dumps({"trips": results}))


if __name__ == "__main__":
    main()
