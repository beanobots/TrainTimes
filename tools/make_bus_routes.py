#!/usr/bin/env python3
"""Builds ios/Shared/bus_routes.json, each bus line's stops in order each way it
runs, with their names and the timetable's minutes between them, from the
MTA's bus GTFS schedules, for changing between a bus and the subway on a
saved widget (BusRoutes.swift): the stops along a bus ride to change at, the
stops near a station to change to, and when a bus gets to a stop further on.

    (download and unzip the feeds as make_bus_shapes.py says)
    python3 tools/make_bus_routes.py ios/Shared gtfs_b gtfs_bx gtfs_m gtfs_q gtfs_si gtfs_busco

Each line's ways are its commonest stop patterns each direction (up to
PATTERNS, so branches and short turns are covered), the commonest headsign of
each, and each stop's minutes from the first, averaged over the pattern's
trips. Lines are named as make_bus_shapes.py names them ("M15+"). Written as
{"stops": [[code, latitude, longitude, name], ...],
 "lines": {"B63": [{"to": headsign, "stops": [index, ...], "minutes": [...]}, ...]}},
positions in hundred-thousandths of a degree, codes as on the stops' signs
(Bus Time's stop codes), minutes to a tenth.
"""
import csv
import json
import sys
from collections import Counter, defaultdict

from make_bus_shapes import canonical

PATTERNS = 3  # each direction's commonest stop patterns kept


def seconds(clock):
    hours, minutes, secs = (int(part) for part in clock.split(":"))
    return hours * 3600 + minutes * 60 + secs


def main(target_dir, feeds):
    stops = {}  # code: (latitude, longitude, name)
    # (line, direction): pattern (tuple of codes): [trip count, headsigns, summed offsets]
    patterns = defaultdict(dict)
    for feed in feeds:
        with open(f"{feed}/stops.txt", encoding="utf-8-sig", newline="") as file:
            for stop in csv.DictReader(file):
                stops[stop["stop_id"]] = (round(float(stop["stop_lat"]) * 1e5), round(float(stop["stop_lon"]) * 1e5),
                                          stop["stop_name"].strip())
        trips = {}  # trip id: (line, direction, headsign)
        with open(f"{feed}/trips.txt", encoding="utf-8-sig", newline="") as file:
            for trip in csv.DictReader(file):
                trips[trip["trip_id"]] = (canonical(trip["route_id"]), trip.get("direction_id", "0"),
                                          trip.get("trip_headsign", "").strip())
        calls = defaultdict(list)  # trip id: [(sequence, code, seconds)]
        with open(f"{feed}/stop_times.txt", encoding="utf-8-sig", newline="") as file:
            for row in csv.DictReader(file):
                if row["trip_id"] in trips and row["arrival_time"]:
                    calls[row["trip_id"]].append((int(row["stop_sequence"]), row["stop_id"], seconds(row["arrival_time"])))
        for trip_id, stops_called in calls.items():
            stops_called.sort()
            line, direction, headsign = trips[trip_id]
            codes = tuple(code for _, code, _ in stops_called)
            start = stops_called[0][2]
            offsets = [time - start for _, _, time in stops_called]
            entry = patterns[(line, direction)].setdefault(codes, [0, Counter(), [0] * len(codes)])
            entry[0] += 1
            entry[1][headsign] += 1
            entry[2] = [total + offset for total, offset in zip(entry[2], offsets)]
    used = {}
    rows = []
    lines = defaultdict(list)
    for (line, _direction), found in sorted(patterns.items()):
        kept = sorted(found.items(), key=lambda item: -item[1][0])[:PATTERNS]
        for codes, (count, headsigns, totals) in kept:
            indices = []
            for code in codes:
                if code not in used:
                    used[code] = len(rows)
                    latitude, longitude, name = stops[code]
                    rows.append([code, latitude, longitude, name])
                indices.append(used[code])
            lines[line].append({"to": headsigns.most_common(1)[0][0], "stops": indices,
                                "minutes": [round(total / count / 60, 1) for total in totals]})
    with open(f"{target_dir}/bus_routes.json", "w", encoding="utf-8") as file:
        json.dump({"stops": rows, "lines": lines}, file, separators=(",", ":"))
        file.write("\n")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
