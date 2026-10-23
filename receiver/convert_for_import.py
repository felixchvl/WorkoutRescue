#!/usr/bin/env python3
"""Converts received WorkoutRescue archives (workout.json) into TCX and FIT activity files,
so they can be imported into Apple Health (HealthFit, Ride Import, Better Workouts...),
Strava, Garmin Connect, intervals.icu, etc.

Read-only on the archives. One TCX (standard library) and one FIT (needs the `fit-tool`
package) per workout, named <local start>_<activity>.<ext>. Demo archives are skipped.

Usage:
  python3 convert_for_import.py EXPORT_DIR OUTPUT_DIR            # TCX only
  uv run --with fit-tool python3 convert_for_import.py EXPORT_DIR OUTPUT_DIR   # TCX + FIT

Each trackpoint is placed on a GPS point (or, without GPS, on a heart rate sample) and carries
the most recent heart rate / cadence / power reading of the previous 15 seconds. Distance is the
running sum of HealthKit distance samples when present, otherwise computed from the GPS points.
"""
import bisect
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

STALE_SECONDS = 15
HK = "HKQuantityTypeIdentifier"
TCX_SPORT = {13: "Biking", 37: "Running"}


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def samples(doc, identifier):
    """[(time, value)] sorted, series expanded; empty when the type is absent."""
    for q in doc.get("quantityTypes", []):
        if q["typeIdentifier"] == HK + identifier:
            out = []
            for s in q["samples"]:
                if s.get("series"):
                    out += [(parse_time(v["endDate"]), v["value"]) for v in s["series"]]
                else:
                    out.append((parse_time(s["startDate"]), s["value"]))
            return sorted(out, key=lambda x: x[0])
    return []


class Channel:
    """Most recent value at or before t, if not older than STALE_SECONDS."""

    def __init__(self, values):
        self.times = [t for t, _ in values]
        self.values = [v for _, v in values]

    def at(self, t):
        i = bisect.bisect_right(self.times, t) - 1
        if i < 0 or (t - self.times[i]).total_seconds() > STALE_SECONDS:
            return None
        return self.values[i]


def haversine(a, b):
    r = 6371008.8
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def build_points(doc):
    """Merged, time-ordered trackpoints."""
    hr = Channel(samples(doc, "HeartRate"))
    cadence = Channel(samples(doc, "CyclingCadence"))
    power = Channel(samples(doc, "CyclingPower"))
    distance_samples = (samples(doc, "DistanceCycling") or samples(doc, "DistanceWalkingRunning")
                        or samples(doc, "DistanceSwimming"))
    cumulative, total = [], 0.0
    for t, v in distance_samples:
        total += v
        cumulative.append((t, total))
    dist_times = [t for t, _ in cumulative]

    gps = [p for r in doc.get("routes", []) for p in r["points"]
           if p["horizontalAccuracy"] >= 0 and -90 <= p["latitude"] <= 90 and -180 <= p["longitude"] <= 180]
    points = []
    if gps:
        previous, run = None, 0.0
        for p in gps:
            here = (p["latitude"], p["longitude"])
            if previous:
                run += haversine(previous, here)
            previous = here
            points.append({"time": parse_time(p["timestamp"]), "lat": p["latitude"], "lon": p["longitude"],
                           "alt": p["altitude"] if p["verticalAccuracy"] >= 0 else None,
                           "speed": p["speed"] if p["speed"] >= 0 else None, "gps_distance": run})
    else:
        points = [{"time": t} for t in hr.times]
    if not points:
        # Summary-only workout (details purged by the watch): start and end only, no invented samples.
        s = summary(doc)
        return [{"time": s["start"], "distance": 0.0, "hr": None, "cadence": None, "power": None},
                {"time": s["end"], "distance": s["distance"], "hr": None, "cadence": None, "power": None}]

    for pt in points:
        t = pt["time"]
        pt["hr"] = hr.at(t)
        pt["cadence"] = cadence.at(t)
        pt["power"] = power.at(t)
        if cumulative:
            i = bisect.bisect_right(dist_times, t) - 1
            pt["distance"] = cumulative[i][1] if i >= 0 else 0.0
        else:
            pt["distance"] = pt.get("gps_distance")
    return points


def summary(doc):
    w = doc["workout"]
    stats = {s["typeIdentifier"].replace(HK, ""): s for s in w.get("statistics", [])}
    hr = stats.get("HeartRate", {})
    return {
        "start": parse_time(w["startDate"]), "end": parse_time(w["endDate"]), "duration": w["durationSeconds"],
        "distance": (w.get("totalDistance") or {}).get("value"),
        "energy": (w.get("totalEnergyBurned") or {}).get("value"),
        "hr_avg": hr.get("average"), "hr_max": hr.get("maximum"),
        "activity": w["activityType"]["rawValue"], "activity_name": w["activityType"]["name"],
    }


def to_tcx(doc, points):
    s = summary(doc)
    sport = TCX_SPORT.get(s["activity"], "Other")
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" '
           'xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">',
           '<Activities>', f'<Activity Sport="{sport}">', f'<Id>{iso(s["start"])}</Id>',
           f'<Lap StartTime="{iso(s["start"])}">', f'<TotalTimeSeconds>{s["duration"]:.3f}</TotalTimeSeconds>',
           f'<DistanceMeters>{(s["distance"] or 0):.2f}</DistanceMeters>',
           f'<Calories>{int(round(s["energy"] or 0))}</Calories>']
    if s["hr_avg"]:
        out.append(f'<AverageHeartRateBpm><Value>{int(round(s["hr_avg"]))}</Value></AverageHeartRateBpm>')
    if s["hr_max"]:
        out.append(f'<MaximumHeartRateBpm><Value>{int(round(s["hr_max"]))}</Value></MaximumHeartRateBpm>')
    out += ['<Intensity>Active</Intensity>', '<TriggerMethod>Manual</TriggerMethod>', '<Track>']
    for p in points:
        tp = [f'<Trackpoint><Time>{iso(p["time"])}</Time>']
        if "lat" in p:
            tp.append(f'<Position><LatitudeDegrees>{p["lat"]!r}</LatitudeDegrees><LongitudeDegrees>{p["lon"]!r}</LongitudeDegrees></Position>')
            if p.get("alt") is not None:
                tp.append(f'<AltitudeMeters>{p["alt"]:.3f}</AltitudeMeters>')
        if p.get("distance") is not None:
            tp.append(f'<DistanceMeters>{p["distance"]:.2f}</DistanceMeters>')
        if p.get("hr"):
            tp.append(f'<HeartRateBpm><Value>{max(1, min(255, int(round(p["hr"]))))}</Value></HeartRateBpm>')
        if p.get("cadence") is not None:
            tp.append(f'<Cadence>{max(0, min(254, int(round(p["cadence"]))))}</Cadence>')
        ext = []
        if p.get("speed") is not None:
            ext.append(f'<ns3:Speed>{p["speed"]:.3f}</ns3:Speed>')
        if p.get("power") is not None:
            ext.append(f'<ns3:Watts>{int(round(p["power"]))}</ns3:Watts>')
        if ext:
            tp.append('<Extensions><ns3:TPX>' + "".join(ext) + '</ns3:TPX></Extensions>')
        tp.append('</Trackpoint>')
        out.append("".join(tp))
    out += ['</Track>', '</Lap>',
            f'<Notes>{escape("Recovered with WorkoutRescue from Apple Watch (" + doc["workout"]["uuid"] + ")")}</Notes>',
            '</Activity>', '</Activities>', '</TrainingCenterDatabase>', '']
    return "\n".join(out).encode("utf-8")


def to_fit(doc, points, path):
    from fit_tool.fit_file_builder import FitFileBuilder
    from fit_tool.profile.messages.activity_message import ActivityMessage
    from fit_tool.profile.messages.event_message import EventMessage
    from fit_tool.profile.messages.file_id_message import FileIdMessage
    from fit_tool.profile.messages.lap_message import LapMessage
    from fit_tool.profile.messages.record_message import RecordMessage
    from fit_tool.profile.messages.session_message import SessionMessage
    from fit_tool.profile.profile_type import Event, EventType, FileType, Manufacturer, Sport

    s = summary(doc)
    sport = {13: Sport.CYCLING, 37: Sport.RUNNING, 52: Sport.WALKING, 24: Sport.HIKING, 46: Sport.SWIMMING}.get(
        s["activity"], getattr(Sport, {41: "SOCCER", 9: "ROCK_CLIMBING"}.get(s["activity"], "GENERIC"), Sport.GENERIC))
    ms = lambda dt: int(dt.timestamp() * 1000)
    builder = FitFileBuilder(auto_define=True, min_string_size=50)

    fid = FileIdMessage()
    fid.type = FileType.ACTIVITY
    fid.manufacturer = Manufacturer.DEVELOPMENT.value
    fid.product = 0
    fid.time_created = ms(s["start"])
    fid.serial_number = 0x0BADCAFE
    builder.add(fid)

    start = EventMessage()
    start.event = Event.TIMER
    start.event_type = EventType.START
    start.timestamp = ms(s["start"])
    builder.add(start)

    for p in points:
        r = RecordMessage()
        r.timestamp = ms(p["time"])
        if "lat" in p:
            r.position_lat = p["lat"]
            r.position_long = p["lon"]
            if p.get("alt") is not None:
                r.altitude = p["alt"]
            if p.get("speed") is not None:
                r.speed = p["speed"]
        if p.get("distance") is not None:
            r.distance = p["distance"]
        if p.get("hr"):
            r.heart_rate = max(1, min(254, int(round(p["hr"]))))
        if p.get("cadence") is not None:
            r.cadence = max(0, min(254, int(round(p["cadence"]))))
        if p.get("power") is not None:
            r.power = int(round(p["power"]))
        builder.add(r)

    stop = EventMessage()
    stop.event = Event.TIMER
    stop.event_type = EventType.STOP_ALL
    stop.timestamp = ms(s["end"])
    builder.add(stop)

    elapsed = (s["end"] - s["start"]).total_seconds()
    for cls in (LapMessage, SessionMessage):
        m = cls()
        m.timestamp = ms(s["end"])
        m.start_time = ms(s["start"])
        m.total_elapsed_time = elapsed
        m.total_timer_time = s["duration"]
        if s["distance"]:
            m.total_distance = s["distance"]
        if s["energy"]:
            m.total_calories = int(round(s["energy"]))
        if s["hr_avg"]:
            m.avg_heart_rate = int(round(s["hr_avg"]))
        if s["hr_max"]:
            m.max_heart_rate = int(round(s["hr_max"]))
        m.sport = sport
        if cls is SessionMessage:
            m.first_lap_index = 0
            m.num_laps = 1
        builder.add(m)

    act = ActivityMessage()
    act.timestamp = ms(s["end"])
    act.total_timer_time = s["duration"]
    act.num_sessions = 1
    builder.add(act)
    builder.build().to_file(str(path))


def main(argv):
    src, dst = Path(argv[1]), Path(argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    try:
        import fit_tool  # noqa: F401
        want_fit = True
    except ImportError:
        want_fit = False
        print("fit-tool not installed: writing TCX only (see usage).")
    for archive in sorted(src.glob("*/workout.json")):
        doc = json.loads(archive.read_text(encoding="utf-8"))
        if doc.get("isDemoData"):
            continue
        s = summary(doc)
        points = build_points(doc)
        stem = f'{s["start"].astimezone():%Y-%m-%d_%H%M}_{s["activity_name"].replace(" ", "")}'
        (dst / f"{stem}.tcx").write_bytes(to_tcx(doc, points))
        if want_fit:
            to_fit(doc, points, dst / f"{stem}.fit")
        gps = sum(1 for p in points if "lat" in p)
        hr = sum(1 for p in points if p.get("hr"))
        print(f"{stem}: {len(points)} points, GPS {gps}, FC {hr}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
