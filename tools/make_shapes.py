#!/usr/bin/env python3
"""Builds ios/App/shapes.json, the track each line runs along, from the MTA's
GTFS schedule, for New Trip's map (TripMap.swift).

    curl -o google_transit.zip http://web.mta.info/developers/data/nyct/subway/google_transit.zip
    unzip google_transit.zip -d gtfs
    python3 tools/make_shapes.py gtfs ios/App

Each line is keyed by its GTFS route id, which the real-time feeds share ("6X"
is the 6 express, "GS" the 42 St Shuttle), and lists the shapes its trips run:
the longest first, leaving out any that runs along one already listed, such as
trains that turn back early. Each is simplified to within `TOLERANCE` meters
(Douglas-Peucker), then written as latitudes and longitudes in hundred-
thousandths of a degree (about a meter), each after the first as the change
from the one before, to keep the file small. The app cuts the stretch of a
shape between two stations from it.

Only the app's map uses it, so it isn't copied to the server, as lines.json is.
"""
import csv
import json
import math
import sys
from collections import Counter, defaultdict

TOLERANCE = 5  # meters a simplified shape may stray from the MTA's
OVERLAP = 25  # meters within which a shape runs along another
METERS_PER_DEGREE = 111_320
LATITUDE = 40.7  # New York's, for meters per degree of longitude


def meters(point):
    """`point` (latitude, longitude) as meters east and north on a flat map."""
    return (point[1] * METERS_PER_DEGREE * math.cos(math.radians(LATITUDE)),
            point[0] * METERS_PER_DEGREE)


def distance_to_segment(point, start, end):
    """Meters from `point` to the segment from `start` to `end`."""
    (px, py), (ax, ay), (bx, by) = meters(point), meters(start), meters(end)
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0 if length == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def simplify(points, tolerance):
    """Douglas-Peucker: the fewest of `points` that keep within `tolerance`
    meters of the rest."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        farthest, at = 0, None
        for index in range(first + 1, last):
            off = distance_to_segment(points[index], points[first], points[last])
            if off > farthest:
                farthest, at = off, index
        if at is not None and farthest > tolerance:
            keep[at] = True
            stack += [(first, at), (at, last)]
    return [point for point, kept in zip(points, keep) if kept]


def runs_along(shape, other):
    """Whether `shape` keeps within `OVERLAP` of `other` all the way, either
    way along it (sampled, as shapes are long)."""
    step = max(1, len(shape) // 40)
    return all(any(distance_to_segment(point, other[i], other[i + 1]) <= OVERLAP
                   for i in range(len(other) - 1))
               for point in shape[::step])


def encode(shape):
    """`shape` as alternating latitude and longitude changes, in hundred-
    thousandths of a degree."""
    flat, last_lat, last_lon = [], 0, 0
    for lat, lon in shape:
        lat, lon = round(lat * 1e5), round(lon * 1e5)
        flat += [lat - last_lat, lon - last_lon]
        last_lat, last_lon = lat, lon
    return flat


def main(gtfs_dir, target_dir):
    with open(f"{gtfs_dir}/trips.txt", encoding="utf-8-sig", newline="") as file:
        trips = defaultdict(Counter)  # route: how many trips run each shape
        for trip in csv.DictReader(file):
            if trip.get("shape_id"):
                trips[trip["route_id"]][trip["shape_id"]] += 1
    with open(f"{gtfs_dir}/shapes.txt", encoding="utf-8-sig", newline="") as file:
        points = defaultdict(list)
        for row in csv.DictReader(file):
            points[row["shape_id"]].append((int(row["shape_pt_sequence"]),
                                            float(row["shape_pt_lat"]), float(row["shape_pt_lon"])))
    shapes = {}
    for route, counts in sorted(trips.items()):
        candidates = [simplify([(lat, lon) for _, lat, lon in sorted(points[shape])], TOLERANCE)
                      for shape in counts if shape in points]
        kept = []
        for shape in sorted(candidates, key=len, reverse=True):
            if not any(runs_along(shape, other) for other in kept):
                kept.append(shape)
        shapes[route] = [encode(shape) for shape in kept]
    with open(f"{target_dir}/shapes.json", "w", encoding="utf-8") as file:
        json.dump(shapes, file, separators=(",", ":"))
        file.write("\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
