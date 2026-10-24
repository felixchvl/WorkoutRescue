#!/usr/bin/env python3
"""Generates FIT files for bike rides reconstructed from Arc Timeline, read-only on inputs.

Track: the map-matched version or the raw Arc track, per the user's choice. Records carry
position, altitude (interpolated for added points), cumulative distance and smoothed speed.
No heart rate records are written: nothing measured, nothing invented.

Summary: moving time (segments above 3 km/h), average moving speed, robust max speed, and
calories estimated from the user's own rides (least squares on the last 12 months of the FIT
history database: kcal = a*moving_minutes + b*km). For rides that overlap a watch workout
whose route had been purged, the real watch summary (times, distance, energy, avg/max HR)
replaces the estimates.

Writes OUT_DIR/<date>_<HHMM>_Velo_reconstitue.fit and OUT_DIR/estimations.csv (estimated
calories and average heart rate, for reference only).

Usage: uv run --with fit-tool --with numpy python3 make_reconstructed_fit.py WORK_DIR \
       BIKE_CHOICES RECALAGE_CHOICES FIT_DB WATCH_EXPORTS OUT_DIR
"""
import csv
import json
import math
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import numpy as np

PARIS = ZoneInfo("Europe/Paris")
MOVING_KMH = 3.0
MIN_WINDOW_S = 4
MAX_SPEED_MS = 20.0  # 72 km/h: anything faster on a city bike is a GPS artefact


def haversine(a, b):
    r = 6371008.8
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def calibrate(db_path):
    db = sqlite3.connect(db_path)
    last = db.execute("select max(start_utc) from activities where sport='cycling'").fetchone()[0]
    since = (datetime.fromisoformat(last.replace("Z", "+00:00")) - timedelta(days=365)).isoformat()
    rows = np.array(db.execute(
        "select timer_s/60.0, distance_m/1000.0, calories, avg_hr, avg_speed_kmh from activities where sport='cycling' "
        "and start_utc >= ? and timer_s > 180 and distance_m > 300 and calories > 0 and gps_records > 0", (since,)).fetchall(), dtype=float)
    (a, b), *_ = np.linalg.lstsq(rows[:, :2], rows[:, 2], rcond=None)
    ok = ~np.isnan(rows[:, 3])
    (h0, h1), *_ = np.linalg.lstsq(np.column_stack([np.ones(ok.sum()), rows[ok, 4]]), rows[ok, 3], rcond=None)
    return {"kcal_per_min": a, "kcal_per_km": b, "hr0": h0, "hr_per_kmh": h1, "n": len(rows)}


def build_points(trip, matched, use_repaired):
    if use_repaired and matched and matched["status"] == "ok":
        pts = [{"t": datetime.fromisoformat(p["t"]), "lat": p["lat"], "lon": p["lon"], "alt": p["alt"], "src": p["src"]} for p in matched["points"]]
    else:
        pts = [{"t": datetime.fromisoformat(p["t"]), "lat": p["lat"], "lon": p["lon"],
                "alt": p["alt"] if (p["vacc"] or -1) >= 0 else None, "src": "raw"}
               for p in trip["points"] if p["hacc"] is not None and 0 < p["hacc"] <= 200]
    pts.sort(key=lambda p: p["t"])
    # Doppler speed measured by the iPhone (more reliable than position differences), for points
    # that are still the recorded ones.
    sensor = {datetime.fromisoformat(p["t"]): p["speed"] for p in trip["points"]
              if p["speed"] is not None and 0 <= p["speed"] <= MAX_SPEED_MS}
    for p in pts:
        p["sensor_speed"] = sensor.get(p["t"]) if p["src"] == "raw" else None
    # Altitude for points without one: linear interpolation in time between known neighbours.
    known = [i for i, p in enumerate(pts) if p["alt"] is not None]
    for i, p in enumerate(pts):
        if p["alt"] is None and known:
            before = max((k for k in known if k < i), default=None)
            after = min((k for k in known if k > i), default=None)
            if before is not None and after is not None:
                span = (pts[after]["t"] - pts[before]["t"]).total_seconds() or 1
                w = (p["t"] - pts[before]["t"]).total_seconds() / span
                p["alt"] = pts[before]["alt"] + w * (pts[after]["alt"] - pts[before]["alt"])
            else:
                p["alt"] = pts[before if before is not None else after]["alt"]
    dist, moving = 0.0, 0.0
    for prev, p in zip([None] + pts, pts):
        if prev is None:
            p["dist"] = 0.0
            continue
        d = haversine((prev["lat"], prev["lon"]), (p["lat"], p["lon"]))
        dt = (p["t"] - prev["t"]).total_seconds()
        dist += d
        p["dist"] = dist
        if 0 < dt <= 60 and d / dt * 3.6 >= MOVING_KMH:
            moving += dt
    # Speed: distance over a centred window of at least MIN_WINDOW_S (two GPS fixes a fraction of a
    # second apart would otherwise give absurd values), capped at a plausible bike speed.
    for i, p in enumerate(pts):
        j, k = i, i
        while (pts[k]["t"] - pts[j]["t"]).total_seconds() < MIN_WINDOW_S and (j > 0 or k < len(pts) - 1):
            if j > 0:
                j -= 1
            if k < len(pts) - 1:
                k += 1
        dt = (pts[k]["t"] - pts[j]["t"]).total_seconds()
        computed = min(MAX_SPEED_MS, (pts[k]["dist"] - pts[j]["dist"]) / dt) if dt > 0 else 0.0
        p["speed"] = p["sensor_speed"] if p["sensor_speed"] is not None else computed
    return pts, dist, moving


def write_fit(path, pts, summary):
    from fit_tool.fit_file_builder import FitFileBuilder
    from fit_tool.profile.messages.activity_message import ActivityMessage
    from fit_tool.profile.messages.event_message import EventMessage
    from fit_tool.profile.messages.file_id_message import FileIdMessage
    from fit_tool.profile.messages.lap_message import LapMessage
    from fit_tool.profile.messages.record_message import RecordMessage
    from fit_tool.profile.messages.session_message import SessionMessage
    from fit_tool.profile.profile_type import Event, EventType, FileType, Manufacturer, Sport, SubSport

    ms = lambda dt: int(dt.replace(microsecond=0).timestamp()) * 1000
    builder = FitFileBuilder(auto_define=True, min_string_size=50)
    fid = FileIdMessage()
    fid.type = FileType.ACTIVITY
    fid.manufacturer = Manufacturer.DEVELOPMENT.value
    fid.product = 1
    fid.time_created = ms(summary["start"])
    fid.serial_number = 0x0A2C0001
    builder.add(fid)
    ev = EventMessage()
    ev.event, ev.event_type, ev.timestamp = Event.TIMER, EventType.START, ms(summary["start"])
    builder.add(ev)
    last_sec = None
    for p in pts:
        sec = ms(p["t"])
        if sec == last_sec:  # FIT has 1-second resolution: one record per second
            continue
        last_sec = sec
        r = RecordMessage()
        r.timestamp = sec
        r.position_lat, r.position_long = p["lat"], p["lon"]
        if p["alt"] is not None:
            r.altitude = p["alt"]
        r.distance = p["dist"]
        r.speed = p["speed"]
        builder.add(r)
    ev = EventMessage()
    ev.event, ev.event_type, ev.timestamp = Event.TIMER, EventType.STOP_ALL, ms(summary["end"])
    builder.add(ev)
    for cls in (LapMessage, SessionMessage):
        m = cls()
        m.timestamp, m.start_time = ms(summary["end"]), ms(summary["start"])
        m.total_elapsed_time = (summary["end"] - summary["start"]).total_seconds()
        m.total_timer_time = summary["moving_s"]
        m.total_distance = summary["distance_m"]
        m.total_calories = int(round(summary["calories"]))
        m.avg_speed = summary["avg_speed_ms"]
        m.max_speed = summary["max_speed_ms"]
        if summary.get("avg_hr"):  # only real watch values, never estimates
            m.avg_heart_rate = int(round(summary["avg_hr"]))
        if summary.get("max_hr"):
            m.max_heart_rate = int(round(summary["max_hr"]))
        m.sport, m.sub_sport = Sport.CYCLING, SubSport.ROAD
        if cls is SessionMessage:
            m.first_lap_index, m.num_laps = 0, 1
        builder.add(m)
    act = ActivityMessage()
    act.timestamp, act.total_timer_time, act.num_sessions = ms(summary["end"]), summary["moving_s"], 1
    builder.add(act)
    builder.build().to_file(str(path))


def watch_summary(watch_dir, uuid):
    for f in watch_dir.glob("*/workout.json"):
        d = json.loads(f.read_text())
        w = d["workout"]
        if w["uuid"].upper() == uuid.upper():
            hr = next((s for s in w["statistics"] if s["typeIdentifier"].endswith("HeartRate")), {})
            return {"start": datetime.fromisoformat(w["startDate"].replace("Z", "+00:00")),
                    "end": datetime.fromisoformat(w["endDate"].replace("Z", "+00:00")), "moving_s": w["durationSeconds"],
                    "distance_m": (w.get("totalDistance") or {}).get("value"),
                    "calories": (w.get("totalEnergyBurned") or {}).get("value"),
                    "avg_hr": hr.get("average"), "max_hr": hr.get("maximum")}
    return None


def main(argv):
    work, bike_file, recal_file, db_path, watch_dir, out = map(Path, argv[1:7])
    out.mkdir(parents=True, exist_ok=True)
    trips = {t["id"]: t for t in json.loads((work / "trips.json").read_text())["trips"]}
    matched = {m["id"]: m for m in json.loads((work / "matched.json").read_text())["trips"]}
    bike = [i for i, c in json.loads(bike_file.read_text())["choices"].items() if c == "velo"]
    recal = json.loads(recal_file.read_text())["choices"]
    cal = calibrate(db_path)
    print(f"calibration sur {cal['n']} sorties : kcal = {cal['kcal_per_min']:.2f}·min + {cal['kcal_per_km']:.2f}·km ; "
          f"FC ≈ {cal['hr0']:.0f} + {cal['hr_per_kmh']:.2f}·km/h")
    rows = []
    for tid in sorted(bike, key=lambda i: trips[i]["start"]):
        trip, m = trips[tid], matched.get(tid)
        use_repaired = recal.get(tid, "corrige") == "corrige"
        pts, dist, moving = build_points(trip, m, use_repaired)
        if len(pts) < 2:
            continue
        # Max speed from the iPhone's measured speed when available (position jumps excluded).
        speeds = sorted(p["sensor_speed"] for p in pts if p["sensor_speed"] is not None) or sorted(p["speed"] for p in pts)
        # Duration = total elapsed time, like the watch's own rides (the calorie model was calibrated on
        # those durations); the moving-only average is reported separately in estimations.csv.
        elapsed = (pts[-1]["t"] - pts[0]["t"]).total_seconds()
        km, minutes = dist / 1000, elapsed / 60
        summary = {"start": pts[0]["t"], "end": pts[-1]["t"], "moving_s": elapsed, "distance_m": dist,
                   "calories": cal["kcal_per_min"] * minutes + cal["kcal_per_km"] * km,
                   "avg_speed_ms": dist / elapsed if elapsed else 0.0, "max_speed_ms": speeds[int(len(speeds) * 0.98)]}
        origin = "Arc"
        if trip["watch_overlap"]:
            ws = watch_summary(watch_dir, trip["watch_overlap"][0]["uuid"])
            if ws:
                pts = [p for p in pts if ws["start"] - timedelta(seconds=60) <= p["t"] <= ws["end"] + timedelta(seconds=60)] or pts
                summary.update({k: v for k, v in ws.items() if v is not None})
                summary["avg_speed_ms"] = summary["distance_m"] / summary["moving_s"] if summary["moving_s"] else 0.0
                origin = "Arc + résumé montre"
        local = summary["start"].astimezone(PARIS)
        name = f"{local:%Y-%m-%d_%H%M}_Velo_reconstitue.fit"
        write_fit(out / name, pts, summary)
        est_hr = cal["hr0"] + cal["hr_per_kmh"] * (summary["avg_speed_ms"] * 3.6)
        rows.append({"fichier": name, "debut": f"{local:%Y-%m-%d %H:%M}", "origine": origin,
                     "trace": "corrigée" if use_repaired and m and m["status"] == "ok" else "brute",
                     "km": round(summary["distance_m"] / 1000, 2), "minutes": round(summary["moving_s"] / 60, 1),
                     "vitesse_moy_kmh": round(summary["avg_speed_ms"] * 3.6, 1),
                     "minutes_en_mouvement": round(moving / 60, 1),
                     "vitesse_moy_en_mouvement_kmh": round(dist / moving * 3.6, 1) if moving else None,
                     "vitesse_max_kmh": round(summary["max_speed_ms"] * 3.6, 1), "calories": round(summary["calories"]),
                     "calories_source": "montre" if origin != "Arc" else "estimation",
                     "fc_moyenne": round(summary.get("avg_hr") or est_hr), "fc_source": "montre" if summary.get("avg_hr") else "estimation"})
    with open(out / "estimations.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), delimiter=";")
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} fichiers FIT dans {out}")


if __name__ == "__main__":
    main(sys.argv)
