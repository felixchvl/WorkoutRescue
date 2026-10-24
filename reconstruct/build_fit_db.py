#!/usr/bin/env python3
"""Builds a local SQLite database from a folder of FIT files (e.g. the HealthFit iCloud export),
read-only on the files. Used to calibrate estimates for reconstructed rides and for free queries.

Tables
  activities(id, file, start_utc, sport, sub_sport, elapsed_s, timer_s, distance_m, calories,
             avg_hr, max_hr, ascent_m, avg_speed_kmh, max_speed_kmh, records, gps_records, hr_records)
  records(activity_id, t_utc, lat, lon, alt_m, hr, speed_kmh, distance_m, cadence, power)

Usage: uv run --with fitparse python3 build_fit_db.py FIT_DIR DB_PATH [--workers N]
"""
import argparse
import os
import sqlite3
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

SEMI = 180 / 2 ** 31


def parse_file(path):
    from fitparse import FitFile
    try:
        fit = FitFile(str(path))
        fit.parse()
    except Exception as exc:  # corrupt / unsupported file: reported, not fatal
        return {"file": path.name, "error": str(exc)}
    session = next((m.get_values() for m in fit.get_messages("session")), {})
    records = []
    for m in fit.get_messages("record"):
        v = m.get_values()
        t = v.get("timestamp")
        if t is None:
            continue
        lat, lon = v.get("position_lat"), v.get("position_long")
        speed = v.get("enhanced_speed", v.get("speed"))
        records.append((t.isoformat() + "Z", lat * SEMI if lat is not None else None, lon * SEMI if lon is not None else None,
                        v.get("enhanced_altitude", v.get("altitude")), v.get("heart_rate"),
                        speed * 3.6 if speed is not None else None, v.get("distance"), v.get("cadence"), v.get("power")))
    start = session.get("start_time") or (records and records[0][0])
    speed = session.get("enhanced_avg_speed", session.get("avg_speed"))
    vmax = session.get("enhanced_max_speed", session.get("max_speed"))
    return {
        "file": path.name, "start": start.isoformat() + "Z" if hasattr(start, "isoformat") else start,
        "sport": str(session.get("sport")), "sub_sport": str(session.get("sub_sport")),
        "elapsed": session.get("total_elapsed_time"), "timer": session.get("total_timer_time"),
        "distance": session.get("total_distance"), "calories": session.get("total_calories"),
        "avg_hr": session.get("avg_heart_rate"), "max_hr": session.get("max_heart_rate"),
        "ascent": session.get("total_ascent"), "avg_speed": speed * 3.6 if speed is not None else None,
        "max_speed": vmax * 3.6 if vmax is not None else None, "records": records,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fit_dir", type=Path)
    ap.add_argument("db", type=Path)
    ap.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 4) - 2))
    args = ap.parse_args()
    files = sorted(p for p in args.fit_dir.glob("*.fit"))
    if args.db.exists():
        args.db.unlink()
    db = sqlite3.connect(args.db)
    db.executescript("""
        CREATE TABLE activities(id INTEGER PRIMARY KEY, file TEXT UNIQUE, start_utc TEXT, sport TEXT, sub_sport TEXT,
          elapsed_s REAL, timer_s REAL, distance_m REAL, calories REAL, avg_hr REAL, max_hr REAL, ascent_m REAL,
          avg_speed_kmh REAL, max_speed_kmh REAL, records INTEGER, gps_records INTEGER, hr_records INTEGER);
        CREATE TABLE records(activity_id INTEGER, t_utc TEXT, lat REAL, lon REAL, alt_m REAL, hr INTEGER,
          speed_kmh REAL, distance_m REAL, cadence INTEGER, power INTEGER);
        CREATE TABLE errors(file TEXT, error TEXT);
    """)
    done = 0
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        for res in pool.map(parse_file, files, chunksize=8):
            done += 1
            if "error" in res:
                db.execute("INSERT INTO errors VALUES (?, ?)", (res["file"], res["error"]))
                continue
            recs = res["records"]
            cur = db.execute(
                "INSERT INTO activities(file,start_utc,sport,sub_sport,elapsed_s,timer_s,distance_m,calories,avg_hr,max_hr,"
                "ascent_m,avg_speed_kmh,max_speed_kmh,records,gps_records,hr_records) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (res["file"], res["start"], res["sport"], res["sub_sport"], res["elapsed"], res["timer"], res["distance"],
                 res["calories"], res["avg_hr"], res["max_hr"], res["ascent"], res["avg_speed"], res["max_speed"],
                 len(recs), sum(1 for r in recs if r[1] is not None), sum(1 for r in recs if r[4])))
            db.executemany("INSERT INTO records VALUES (?,?,?,?,?,?,?,?,?,?)", [(cur.lastrowid, *r) for r in recs])
            if done % 200 == 0:
                db.commit()
                print(f"{done}/{len(files)}", flush=True)
    db.execute("CREATE INDEX records_activity ON records(activity_id)")
    db.commit()
    n, e = db.execute("SELECT count(*) FROM activities").fetchone()[0], db.execute("SELECT count(*) FROM errors").fetchone()[0]
    print(f"terminé : {n} activités, {e} fichiers illisibles, base {args.db}")


if __name__ == "__main__":
    main()
