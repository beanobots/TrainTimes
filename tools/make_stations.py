#!/usr/bin/env python3
"""Builds ios/Shared/stations.json from the MTA's station list.

    curl -o Stations.csv http://web.mta.info/developers/data/nyct/subway/Stations.csv
    python3 tools/make_stations.py Stations.csv ios/Shared/stations.json

Each station keeps its GTFS stop id (the real-time feeds name platforms by adding
N or S to it), the lines that serve it as real-time route ids, and the labels the
MTA gives its two directions.
"""
import csv
import json
import re
import sys

BOROUGHS = {"M": "Manhattan", "Bk": "Brooklyn", "Q": "Queens", "Bx": "Bronx", "SI": "Staten Island"}
STREET = re.compile(r"\b(St|Av|Blvd|Pkwy|Rd|Tpke)$")


def route_ids(row):
    """The list says "S" for all three shuttles and "SIR" for Staten Island; the feeds don't."""
    stop = row["GTFS Stop ID"]
    ids = []
    for token in row["Daytime Routes"].split():
        if token == "S":
            token = "GS" if stop in ("901", "902") else "H" if stop.startswith("H") else "FS"
        elif token == "SIR":
            token = "SI"
        ids.append(token)
    return ids


def short_name(name):
    """"Forest Hills-71 Av" -> "Forest Hills", for the space-starved end of a train's trip."""
    if name == "Broadway-Lafayette St":  # "Broadway" alone would mislead
        return name
    first, dash, rest = name.partition("-")
    first = first.strip()
    # "163 St-Amsterdam Av" stays whole: "163 St" alone would be ambiguous
    return first if dash and first and STREET.search(rest) and not STREET.search(first) else name


def main(source, target):
    with open(source, encoding="utf-8-sig", newline="") as file:
        rows = list(csv.DictReader(file))
    stations = [
        {
            "id": row["GTFS Stop ID"],
            "name": row["Stop Name"],
            "short": short_name(row["Stop Name"]),
            "borough": BOROUGHS[row["Borough"]],
            "routes": route_ids(row),
            "north": row["North Direction Label"],
            "south": row["South Direction Label"],
        }
        for row in rows
    ]
    stations.sort(key=lambda station: (station["name"].lower(), station["borough"]))
    with open(target, "w", encoding="utf-8") as file:
        file.write("[\n" + ",\n".join(json.dumps(s, ensure_ascii=False) for s in stations) + "\n]\n")
    print(f"{len(stations)} stations -> {target}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
