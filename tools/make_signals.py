#!/usr/bin/env python3
"""Adds the city's traffic signals to ios/App/sidewalks.sqlite, for walks on
the sidewalk to cross streets where there's a signal, and ones whose walk
signal comes first or stops all the cars (`Sidewalks.choose`, read by
`SidewalkStore.swift`). Run it after `make_sidewalks.py`, which starts the
file afresh.

The city has no list of every signal, so they're from OpenStreetMap: each
signalled crosswalk and junction in the five boroughs (ODbL, attribution
needed). The city's own lists add the signals it has done more with, which
all are signals too:

    VZV Leading Pedestrian Interval Signals (data.cityofnewyork.us xc4v-ntf4)
    Exclusive Pedestrian Signal (Barnes Dance) Locations (8kuj-2n3u)
    Accessible Pedestrian Signal Locations (de3m-c5p4)

    curl -A leeway-tools -o osm_signals.json https://overpass-api.de/api/interpreter \\
        --data-urlencode 'data=[out:json][timeout:150];(
            node["highway"="traffic_signals"](40.49,-74.27,40.92,-73.68);
            node["crossing"="traffic_signals"](40.49,-74.27,40.92,-73.68););out;'
    for id in xc4v-ntf4 8kuj-2n3u de3m-c5p4; do
        curl -o $id.json "https://data.cityofnewyork.us/resource/$id.json?\\$limit=50000"
    done
    python3 tools/make_signals.py osm_signals.json xc4v-ntf4.json \\
        8kuj-2n3u.json de3m-c5p4.json ios/App/sidewalks.sqlite

They're kept as one blob, `signals.points`: how many, then each one's
latitude and longitude changes in millionths of a degree (zigzagged varints,
from the one before, north to south) and its kind, `KIND`'s bits. Points of
one kind within `MERGE` of each other are kept once.
"""
import json
import math
import sqlite3
import sys
from datetime import datetime, timezone

from make_sidewalks import varint, zigzag

SIGNAL, LEADING, EXCLUSIVE = 1, 2, 4  # as `Sidewalks.Signal.Kind` has them
# OSM's signals that stop no one for people on foot: a fire house's, flashing amber or red,
# metering cars onto a highway
NOT_FOR_WALKING = {"emergency", "blinker", "ramp_meter"}
MERGE = 5.0  # meters
SOURCE = ("OpenStreetMap traffic signals (ODbL); NYC DOT Leading Pedestrian Interval, "
          "Exclusive Pedestrian and Accessible Pedestrian Signals")


def osm(path):
    """(latitude, longitude) of each OSM signal in Overpass' JSON (with its tags, `out;`)
    that people on foot cross at."""
    with open(path, encoding="utf-8") as file:
        elements = json.load(file)["elements"]
    points = []
    for element in elements:
        tags = element.get("tags") or {}
        if element.get("type") != "node" or tags.get("traffic_signals") in NOT_FOR_WALKING:
            continue
        points.append((element["lat"], element["lon"]))
    return points


def city(path):
    """(latitude, longitude) of each row of one of the city's lists of signals."""
    with open(path, encoding="utf-8") as file:
        rows = json.load(file)
    points = []
    for row in rows:
        coordinates = (row.get("the_geom") or {}).get("coordinates")
        if coordinates:
            points.append((coordinates[1], coordinates[0]))
    return points


def merged(points):
    """`points` with those within `MERGE` of one already kept left out."""
    kept = []
    cells = {}
    # A cell `MERGE` across each way: a degree of longitude is shorter than one of latitude
    # by the cosine of the city's latitude
    size = MERGE / 111_320
    size_lon = size / math.cos(math.radians(40.7))
    for lat, lon in sorted(points):
        cell = (int(lat / size), int(lon / size_lon))
        east = 111_320 * math.cos(math.radians(lat))
        near = any(
            math.hypot((lat - a) * 111_320, (lon - b) * east) < MERGE
            for dx in (-1, 0, 1) for dy in (-1, 0, 1)
            for a, b in cells.get((cell[0] + dx, cell[1] + dy), [])
        )
        if not near:
            kept.append((lat, lon))
            cells.setdefault(cell, []).append((lat, lon))
    return kept


def encode(signals):
    """`signals`, each (latitude, longitude, kind), as the blob above."""
    out = bytearray()
    varint(len(signals), out)
    last_lat = last_lon = 0
    for lat, lon, kind in signals:
        lat, lon = round(lat * 1e6), round(lon * 1e6)
        varint(zigzag(lat - last_lat), out)
        varint(zigzag(lon - last_lon), out)
        varint(kind, out)
        last_lat, last_lon = lat, lon
    return bytes(out)


def main(osm_path, leading_path, exclusive_path, accessible_path, target):
    kinds = [
        (osm(osm_path), SIGNAL),
        (city(leading_path), SIGNAL | LEADING),
        (city(exclusive_path), SIGNAL | EXCLUSIVE),
        (city(accessible_path), SIGNAL),
    ]
    signals = sorted((lat, lon, kind) for points, kind in kinds for lat, lon in merged(points))
    signals.reverse()  # north to south
    blob = encode(signals)
    db = sqlite3.connect(target)
    db.executescript("""
        DROP TABLE IF EXISTS signals;
        CREATE TABLE signals (points BLOB NOT NULL);
    """)
    db.execute("INSERT INTO signals VALUES (?)", (blob,))
    db.executemany("INSERT OR REPLACE INTO info VALUES (?, ?)", [
        ("signals_source", SOURCE),
        ("signals_built", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
        ("signals", str(len(signals))),
    ])
    db.commit()
    db.execute("VACUUM")
    db.close()
    counts = {name: sum(1 for *_, kind in signals if kind & bit)
              for name, bit in (("signals", SIGNAL), ("leading", LEADING), ("exclusive", EXCLUSIVE))}
    print(f"{counts} in {len(blob) / 1e3:.0f} kB")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit(f"usage: {sys.argv[0]} osm_signals.json leading.json exclusive.json accessible.json sidewalks.sqlite")
    main(*sys.argv[1:])
