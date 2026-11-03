#!/usr/bin/env python3
"""Builds ios/App/bike_lanes.json, the city's protected bike lanes and paths,
from NYC DOT's bike route map (NYC Open Data mzxg-pwib, updated yearly), for
how much of a Citi Bike ride runs on them (BikeLanes.swift).

    curl -o bike_routes.geojson "https://data.cityofnewyork.us/resource/mzxg-pwib.geojson?\$where=status='Current'&\$limit=50000"
    python3 tools/make_bike_lanes.py bike_routes.geojson ios/App

Protected is DOT's Class I: lanes kept from traffic by a barrier or parked
cars, and paths off the street (greenways, boardwalks, a bridge's path). Not
painted lanes (Class II) or shared streets (Class III). Each segment's two
directions are listed apart in DOT's data (`ft_facilit` along the way it's
drawn, `tf_facilit` against it), so a one-way lane is kept as "along", drawn
the way it runs, and a ride the other way along its street isn't counted.

Written as {"both": [shape, ...], "along": [shape, ...]}, each shape as
make_shapes.py encodes them, simplified to `TOLERANCE`.
"""
import json
import sys

from make_shapes import encode, simplify

TOLERANCE = 2  # meters a simplified lane may stray from DOT's
PROTECTED = {"Protected", "Sidewalk", "Boardwalk", "Unpaved", "Ped Plaza"}


def main(geojson, target_dir):
    with open(geojson, encoding="utf-8") as file:
        features = json.load(file)["features"]
    lanes = {"both": [], "along": []}
    for feature in features:
        properties, geometry = feature["properties"], feature["geometry"]
        if properties.get("status") != "Current" or not geometry:
            continue
        along = properties.get("ft_facilit") in PROTECTED
        against = properties.get("tf_facilit") in PROTECTED
        if not along and not against:
            continue
        for line in geometry["coordinates"]:
            shape = [(lat, lon) for lon, lat, *_ in line]
            if len(shape) < 2:
                continue
            if not along:
                shape.reverse()
            lanes["both" if along and against else "along"].append(encode(simplify(shape, TOLERANCE)))
    with open(f"{target_dir}/bike_lanes.json", "w", encoding="utf-8") as file:
        json.dump(lanes, file, separators=(",", ":"))
        file.write("\n")
    print(f"{len(lanes['both'])} both ways, {len(lanes['along'])} one way")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
