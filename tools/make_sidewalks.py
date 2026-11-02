#!/usr/bin/env python3
"""Builds sidewalks.sqlite, every sidewalk in the city, for the server to put
walks on the sidewalk rather than down the middle of the street, where Apple
Maps' walking directions run (`Sidewalks.swift` on the server reads it).

From NYC's Planimetric Database: Sidewalk (data.cityofnewyork.us, 52n9-sdep),
drawn from aerial photos: each block's sidewalk as a polygon, its outer ring
the curb and any hole in it the building line.

    curl -o sidewalk.geojson \\
        'https://data.cityofnewyork.us/resource/52n9-sdep.geojson?$limit=60000'
    python3 tools/make_sidewalks.py sidewalk.geojson sidewalks.sqlite
    sudo install -o traintimes -g wheel -m 600 sidewalks.sqlite /usr/local/traintimes/data/

Each ring is simplified to within `TOLERANCE` and kept as a blob of varints:
how many rings, then for each how many points and their latitude and
longitude changes in millionths of a degree (zigzagged, carrying on from the
ring before), the outer ring first. An R*Tree, `sidewalk_boxes`, finds those
near a point. `info` says where it's from and the format, which
`Sidewalks.swift` checks.
"""
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone

from make_shapes import simplify

TOLERANCE = 0.25  # meters a simplified ring may stray from the city's
FORMAT = 1  # the blob's layout, as `Sidewalks.format` expects
SOURCE = "NYC Planimetric Database: Sidewalk (data.cityofnewyork.us 52n9-sdep)"


def varint(value, out):
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return


def zigzag(value):
    return value * 2 if value >= 0 else -value * 2 - 1


def encode(rings):
    """`rings`, each a list of (latitude, longitude), as the blob above."""
    out = bytearray()
    varint(len(rings), out)
    last_lat = last_lon = 0
    for ring in rings:
        varint(len(ring), out)
        for lat, lon in ring:
            lat, lon = round(lat * 1e6), round(lon * 1e6)
            varint(zigzag(lat - last_lat), out)
            varint(zigzag(lon - last_lon), out)
            last_lat, last_lon = lat, lon
    return bytes(out)


def main(source, target):
    with open(source, encoding="utf-8") as file:
        features = json.load(file)["features"]
    if os.path.exists(target):
        os.remove(target)
    db = sqlite3.connect(target)
    db.executescript("""
        CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE sidewalks (id INTEGER PRIMARY KEY, source_id TEXT, rings BLOB NOT NULL);
        CREATE VIRTUAL TABLE sidewalk_boxes USING rtree(id, min_lat, max_lat, min_lon, max_lon);
    """)
    kept = before = after = 0
    for feature in features:
        geometry = feature.get("geometry") or {}
        polygons = geometry.get("coordinates") or []
        if geometry.get("type") == "Polygon":
            polygons = [polygons]
        for polygon in polygons:
            # GeoJSON's [longitude, latitude], each ring closed
            rings = [simplify([(lat, lon) for lon, lat in ring], TOLERANCE) for ring in polygon]
            rings = [ring for ring in rings if len(ring) >= 4]
            if not rings:
                continue
            before += sum(len(ring) for ring in polygon)
            after += sum(len(ring) for ring in rings)
            kept += 1
            lats = [lat for lat, _ in rings[0]]
            lons = [lon for _, lon in rings[0]]
            db.execute("INSERT INTO sidewalks (id, source_id, rings) VALUES (?, ?, ?)",
                       (kept, (feature.get("properties") or {}).get("source_id"), encode(rings)))
            db.execute("INSERT INTO sidewalk_boxes VALUES (?, ?, ?, ?, ?)",
                       (kept, min(lats), max(lats), min(lons), max(lons)))
    db.executemany("INSERT INTO info VALUES (?, ?)", [
        ("source", SOURCE),
        ("format", str(FORMAT)),
        ("built", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
        ("polygons", str(kept)),
        ("points", str(after)),
    ])
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"{kept} sidewalks, {before} points simplified to {after}, "
          f"{os.path.getsize(target) / 1e6:.1f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} sidewalk.geojson sidewalks.sqlite")
    main(sys.argv[1], sys.argv[2])
