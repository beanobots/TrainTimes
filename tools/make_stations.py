#!/usr/bin/env python3
"""Builds ios/Shared/stations.json and ios/Shared/equipment.json from MTA data.

    curl -o Stations.csv http://web.mta.info/developers/data/nyct/subway/Stations.csv
    curl -o entrances.json 'https://data.ny.gov/resource/i9wp-a4ja.json?$limit=5000'
    curl -o equipment.json https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fnyct_ene_equipments.json
    python3 tools/make_stations.py Stations.csv entrances.json equipment.json ios/Shared

Each station keeps its GTFS stop id (the real-time feeds name platforms by adding
N or S to it), the lines that serve it as real-time route ids, the labels the MTA
gives its two directions, where it is and where its entrances are, and how
accessible it is. The MTA lists a station's sets of platforms apart, such as
Atlantic Av-Barclays Ctr's D N R, B Q and 2 3 4 5; the app joins those with the
same name in the same complex into one station. The equipment list ties each elevator and escalator to its
station complex, so the outage feed, which names only the equipment, can be
matched to a station, and to the stops whose platforms it serves.
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


def entrances_by_stop(path):
    with open(path, encoding="utf-8") as file:
        rows = json.load(file)
    entrances = {}
    for row in rows:
        entrance = {
            "lat": round(float(row["entrance_latitude"]), 6),
            "lon": round(float(row["entrance_longitude"]), 6),
            "type": row["entrance_type"],
        }
        if row.get("entry_allowed") == "NO":
            entrance["exitOnly"] = True
        # A station on two levels lists both its stops: "A32; D20"
        for stop in row["gtfs_stop_id"].split(";"):
            entrances.setdefault(stop.strip(), []).append(entrance)
    return entrances


def equipment(path, complexes):
    """The elevators and escalators at subway stations, by id, including those a
    building owner runs rather than the MTA (they're in the outage feed too).
    Each lists the GTFS stops whose platforms it serves, where the MTA says."""
    with open(path, encoding="utf-8") as file:
        rows = json.load(file)
    machines = {}
    for row in sorted(rows, key=lambda row: row["equipmentno"]):
        if row["stationcomplexid"] not in complexes:
            continue
        machine = {
            "complex": row["stationcomplexid"],
            "elevator": row["equipmenttype"] == "EL",
            "ada": row["ADA"] == "Y",
            "serving": row["serving"],
            "alternative": (row.get("alternativeroute") or "").strip(),
        }
        # "L03/R20": 14 St-Union Sq's L and its N Q R W
        stops = [stop.strip() for stop in (row.get("elevatorsgtfsstopid") or "").split("/") if stop.strip()]
        if stops:
            machine["stops"] = stops
        machines[row["equipmentno"]] = machine
    return machines


def main(source, entrances_path, equipment_path, target_dir):
    with open(source, encoding="utf-8-sig", newline="") as file:
        rows = list(csv.DictReader(file))
    entrances = entrances_by_stop(entrances_path)
    stations = [
        {
            "id": row["GTFS Stop ID"],
            "name": row["Stop Name"],
            "short": short_name(row["Stop Name"]),
            "borough": BOROUGHS[row["Borough"]],
            "routes": route_ids(row),
            "north": row["North Direction Label"],
            "south": row["South Direction Label"],
            "lat": float(row["GTFS Latitude"]),
            "lon": float(row["GTFS Longitude"]),
            "complex": row["Complex ID"],
            # 0: not accessible, 1: accessible, 2: partly (see adaNotes)
            "ada": int(row["ADA"]),
            "adaNotes": row["ADA Direction Notes"],
            "entrances": entrances.get(row["GTFS Stop ID"], []),
        }
        for row in rows
    ]
    unmatched = sorted(set(entrances) - {station["id"] for station in stations})
    if unmatched:
        print(f"warning: entrances of unknown stops left out: {', '.join(unmatched)}", file=sys.stderr)
    # The entrance list files a complex's shared entrances under one of its stations
    by_complex = {}
    for station in stations:
        by_complex.setdefault(station["complex"], []).extend(station["entrances"])
    for station in stations:
        if not station["entrances"]:
            station["entrances"] = by_complex[station["complex"]]
    stations.sort(key=lambda station: (station["name"].lower(), station["borough"]))
    target = f"{target_dir}/stations.json"
    with open(target, "w", encoding="utf-8") as file:
        file.write("[\n" + ",\n".join(json.dumps(s, ensure_ascii=False) for s in stations) + "\n]\n")
    print(f"{len(stations)} stations, {sum(len(s['entrances']) for s in stations)} entrances -> {target}")

    machines = equipment(equipment_path, {station["complex"] for station in stations})
    target = f"{target_dir}/equipment.json"
    with open(target, "w", encoding="utf-8") as file:
        file.write("{\n" + ",\n".join(f"{json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}" for k, v in machines.items()) + "\n}\n")
    print(f"{len(machines)} elevators and escalators -> {target}")


if __name__ == "__main__":
    main(*sys.argv[1:5])
