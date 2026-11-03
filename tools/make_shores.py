#!/usr/bin/env python3
"""Builds ios/Shared/WalkReachShores.swift, the shores of the city's islands,
so a walk to a station isn't timed across the water (WalkReach.swift).

From NYC's Borough Boundaries, clipped to the shoreline (data.cityofnewyork.us
gthc-hcne): each borough as its islands.

    curl -o boroughs.geojson 'https://data.cityofnewyork.us/resource/gthc-hcne.geojson'
    python3 tools/make_shores.py boroughs.geojson ios/Shared/WalkReachShores.swift

Brooklyn and Queens aren't written: they're Long Island, wherever no other
shore is. Marble Hill, Manhattan's but joined to the Bronx since the Harlem
was cut through, is written as the Bronx's. Islands smaller than Liberty
Island, the marshes of Jamaica Bay among them, are left out.
"""
import json
import math
import sys

from make_shapes import encode, simplify

TOLERANCE = 30  # meters a simplified shore may stray from the city's
# Where there's no narrow water to tell apart, fewer points do
LOOSER = {"statenIsland": 60, "rockaway": 50, "broadChannel": 50}
SMALLEST = 0.05  # square kilometers


def near(centroid, lat, lon, within=0.01):
    return abs(centroid[0] - lat) < within and abs(centroid[1] - lon) < within


# Each island kept: its land in WalkReach, the borough it's in, and how it's known
ISLANDS = [
    ("manhattan", "Manhattan", lambda area, c: area > 50),
    ("bronx", "Manhattan", lambda area, c: near(c, 40.8746, -73.9117)),  # Marble Hill
    ("randalls", "Manhattan", lambda area, c: near(c, 40.7924, -73.9259)),
    ("roosevelt", "Manhattan", lambda area, c: near(c, 40.7600, -73.9518)),
    ("governors", "Manhattan", lambda area, c: near(c, 40.6895, -74.0174)),
    ("liberty", "Manhattan", lambda area, c: near(c, 40.6903, -74.0458, 0.002)),
    ("ellis", "Manhattan", lambda area, c: near(c, 40.6992, -74.0406, 0.002)),
    ("bronx", "Bronx", lambda area, c: area > 100),
    ("rikers", "Bronx", lambda area, c: near(c, 40.7936, -73.8808)),
    ("northBrother", "Bronx", lambda area, c: near(c, 40.8006, -73.8990, 0.002)),
    ("cityIsland", "Bronx", lambda area, c: near(c, 40.8488, -73.7868, 0.003)),
    ("hart", "Bronx", lambda area, c: near(c, 40.8536, -73.7717, 0.003)),
    ("statenIsland", "Staten Island", lambda area, c: area > 100),
    ("broadChannel", "Queens", lambda area, c: 4 < area < 5),
    ("rockaway", "Queens", lambda area, c: 20 < area < 22),
]


def area(ring):
    """Square kilometers inside `ring`, (longitude, latitude) pairs."""
    scale = 111.32 * math.cos(math.radians(40.7)), 111.32
    total = 0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        total += x1 * scale[0] * y2 * scale[1] - x2 * scale[0] * y1 * scale[1]
    return abs(total) / 2


def main(source, target):
    with open(source) as file:
        boroughs = json.load(file)["features"]
    shores = []
    for borough in boroughs:
        name = borough["properties"]["boroname"]
        for polygon in borough["geometry"]["coordinates"]:
            ring = polygon[0]  # not its lakes
            size = area(ring)
            if size < SMALLEST:
                continue
            centroid = (sum(p[1] for p in ring) / len(ring), sum(p[0] for p in ring) / len(ring))
            land = next((land for land, of, known in ISLANDS if of == name and known(size, centroid)), None)
            if land is None:
                continue
            points = [(lat, lon) for lon, lat in ring]
            # In two halves, as a closed ring starts and ends at the same point
            half = len(points) // 2
            tolerance = LOOSER.get(land, TOLERANCE)
            shore = simplify(points[:half + 1], tolerance)[:-1] + simplify(points[half:], tolerance)[:-1]
            shores.append((land, shore))
    lines = [
        "// Made by tools/make_shores.py from NYC's Borough Boundaries; don't edit.",
        "",
        "extension WalkReach {",
        "    /// Each island's shore, as alternating latitude and longitude changes in hundred-thousandths",
        "    /// of a degree, from the last point (the first from 0).",
        "    static let shoreData: [(Land, String)] = [",
    ]
    for land, shore in shores:
        lines.append(f'        (.{land}, "{",".join(str(n) for n in encode(shore))}"),')
    lines += ["    ]", "}", ""]
    with open(target, "w") as file:
        file.write("\n".join(lines))
    print(f"{len(shores)} shores, {sum(len(s) for _, s in shores)} points")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
