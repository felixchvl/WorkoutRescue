#!/usr/bin/env python3
"""Looks for moves that may be missing from the timeline, read-only on the Arc backup.

Rebuilds the full Arc chronology (visits and trips) and flags:
  - jumps: the next item starts more than JUMP_M away from where the previous one ended,
    i.e. a move happened that Arc did not record as a trip;
  - holes: no location data at all for more than HOLE_MIN minutes.
Each suspect gets the implied speed (distance / time between the two fixes) as a hint:
bike-like, walk-like or public transport-like.

Writes WORK_DIR/gaps.json and WORK_DIR/chronologie.html (one map per day: validated bike
rides, other trips, places, and suspected missing moves as red dashed lines).

Usage: python3 timeline_gaps.py BACKUP_DIR WORK_DIR BIKE_CHOICES WATCH_EXPORTS [START END]
"""
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).parent))
from arc_extract import haversine, load_items, load_samples, parse  # noqa: E402

PARIS = ZoneInfo("Europe/Paris")
JUMP_M = 400
HOLE_MIN = 45
IDF = (48.10, 49.25, 1.44, 3.56)


def hint(meters, seconds):
    if seconds <= 0:
        return "instantané (données manquantes)", None
    kmh = meters / seconds * 3.6
    if kmh < 7:
        return "à pied ou arrêt", kmh
    if kmh <= 30:
        return "compatible vélo", kmh
    return "transport (métro, voiture…)", kmh


def main(argv):
    backup, work, bike_file, watch_dir = Path(argv[1]), Path(argv[2]), Path(argv[3]), Path(argv[4])
    start = parse(argv[5]) if len(argv) > 5 else parse("2026-09-10T22:00:00Z")
    end = parse(argv[6]) if len(argv) > 6 else parse("2026-10-22T22:00:00Z")
    months = sorted({(start + timedelta(days=d)).strftime("%Y-%m") for d in range((end - start).days + 1)})
    items = [i for i in load_items(backup, months) if not i["base"]["deleted"] and not i["base"]["disabled"]
             and parse(i["base"]["endDate"]) > start and parse(i["base"]["startDate"]) < end]
    samples = defaultdict(list)
    for s in load_samples(backup, start, end):
        if not s.get("disabled") and s.get("latitude") is not None and 0 < (s.get("horizontalAccuracy") or 999) <= 100:
            samples[s.get("timelineItemId")].append(s)
    bike = {i for i, c in json.loads(bike_file.read_text())["choices"].items() if c == "velo"}
    watch = []
    for f in watch_dir.glob("*/workout.json"):
        d = json.loads(f.read_text())
        if not d.get("isDemoData"):
            watch.append((parse(d["workout"]["startDate"]), parse(d["workout"]["endDate"]), d["workout"]["activityType"]["name"]))

    timeline = []
    for it in sorted(items, key=lambda i: i["base"]["startDate"]):
        b = it["base"]
        ss = sorted(samples.get(b["id"], []), key=lambda s: s["date"])
        if b["isVisit"]:
            v = it.get("visit", {})
            if v.get("latitude") is None:
                continue
            first = last = (v["latitude"], v["longitude"])
            t0, t1 = parse(b["startDate"]), parse(b["endDate"])
            kind = "lieu"
        else:
            if not ss:
                continue
            first, last = (ss[0]["latitude"], ss[0]["longitude"]), (ss[-1]["latitude"], ss[-1]["longitude"])
            t0, t1 = parse(ss[0]["date"]), parse(ss[-1]["date"])
            on_watch = any(ws < t1 and we > t0 for ws, we, _ in watch)
            kind = "velo" if b["id"] in bike or on_watch else "trajet"
        inside = IDF[0] <= first[0] <= IDF[1] and IDF[2] <= first[1] <= IDF[3]
        timeline.append({"id": b["id"], "kind": kind, "t0": t0, "t1": t1, "first": first, "last": last, "idf": inside,
                         "path": [(s["latitude"], s["longitude"]) for s in ss[::max(1, len(ss) // 300)]] if kind != "lieu" else []})

    # Order by actual (sample) times and compare each item with the latest-ending previous one,
    # so that overlapping or oddly dated Arc items do not create fake holes.
    timeline.sort(key=lambda it: it["t0"])
    suspects = []
    latest = None
    for b in timeline:
        a, latest = latest, b if latest is None or b["t1"] >= latest["t1"] else latest
        if a is None or b is latest and a is b:
            continue
        if not (a["idf"] and b["idf"]):
            continue  # travel days outside Ile-de-France are out of scope
        dist = haversine(a["last"], b["first"])
        gap = (b["t0"] - a["t1"]).total_seconds()
        if gap < 0 and dist <= JUMP_M:
            continue
        if dist > JUMP_M or gap > HOLE_MIN * 60:
            label, kmh = hint(dist, gap)
            t_from, t_to = a["t1"].astimezone(PARIS), b["t0"].astimezone(PARIS)
            same_day = t_from.date() == t_to.date()
            suspects.append({"day": t_from.strftime("%Y-%m-%d"),
                             "from_time": t_from.strftime("%H:%M"),
                             "to_time": t_to.strftime("%H:%M") if same_day else t_to.strftime("%d/%m %H:%M"),
                             "from": a["last"], "to": b["first"], "km": round(dist / 1000, 2), "minutes": round(gap / 60),
                             "kmh": round(kmh, 1) if kmh else None, "hint": label if dist > JUMP_M else "trou d'enregistrement sur place",
                             "after": a["kind"], "before": b["kind"],
                             "from_dt": a["t1"].astimezone(PARIS).isoformat(), "to_dt": b["t0"].astimezone(PARIS).isoformat()})

    days = defaultdict(lambda: {"items": [], "suspects": []})
    for it in timeline:
        if it["idf"]:
            d = it["t0"].astimezone(PARIS).strftime("%Y-%m-%d")
            days[d]["items"].append({"kind": it["kind"], "t": f"{it['t0'].astimezone(PARIS):%H:%M}–{it['t1'].astimezone(PARIS):%H:%M}",
                                     "path": it["path"] or [it["first"]]})
    for s in suspects:
        days[s["day"]]["suspects"].append(s)
    (work / "gaps.json").write_text(json.dumps(suspects, ensure_ascii=False, indent=1))
    page = (Path(__file__).parent / "chronologie_template.html").read_text(encoding="utf-8")
    (work / "chronologie.html").write_text(page.replace("__DATA__", json.dumps(dict(sorted(days.items())), ensure_ascii=False)), encoding="utf-8")

    moves = [s for s in suspects if s["km"] * 1000 > JUMP_M]
    print(f"{len(timeline)} éléments dans la chronologie, {len(moves)} sauts de plus de {JUMP_M} m, "
          f"{len(suspects) - len(moves)} trous d'enregistrement sur place")
    by = defaultdict(list)
    for s in moves:
        by[s["hint"]].append(s)
    for k, v in by.items():
        print(f"  {k} : {len(v)}")


if __name__ == "__main__":
    main(sys.argv)
