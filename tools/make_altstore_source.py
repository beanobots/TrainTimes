#!/usr/bin/env python3
"""Writes an AltStore source (source.json) describing a built TrainTimes.ipa.

    python3 tools/make_altstore_source.py TrainTimes.ipa source.json \\
        --download-url https://github.com/beanobots/TrainTimes/releases/download/v1.0.57/TrainTimes.ipa \\
        --icon-url https://github.com/beanobots/TrainTimes/releases/download/latest/icon.png

The download URL should be the build's own, which the next build doesn't
replace: AltStore refuses an .ipa whose version isn't the one in the source it
last read. Everything else AltStore checks is read from the .ipa itself, so the
source always matches the app: the bundle id and version from Info.plist, the
entitlements from each executable's signature (AltStore refuses an app whose
entitlements differ from what its source declares), and any privacy usage
descriptions.
Format: https://faq.altstore.io/developers/make-a-source
"""
import argparse
import datetime
import json
import os
import plistlib
import re
import sys
import zipfile

# AltStore adds these itself; a source should leave them out.
IMPLICIT_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier", "get-task-allow"}
# CSMAGIC_EMBEDDED_ENTITLEMENTS, big-endian, as code signatures are
ENTITLEMENTS_MAGIC = b"\xfa\xde\x71\x71"


def bundles(ipa):
    """(Info.plist, executable bytes) for the app and each of its extensions."""
    names = ipa.namelist()
    app = next(re.match(r"(Payload/[^/]+\.app/)Info\.plist$", n).group(1) for n in names if re.match(r"Payload/[^/]+\.app/Info\.plist$", n))
    roots = [app] + sorted({re.match(rf"({re.escape(app)}PlugIns/[^/]+\.appex/)", n).group(1) for n in names if re.match(rf"{re.escape(app)}PlugIns/[^/]+\.appex/Info\.plist$", n)})
    for root in roots:
        info = plistlib.loads(ipa.read(root + "Info.plist"))
        yield info, ipa.read(root + info["CFBundleExecutable"])


def entitlements(executable):
    """The entitlements in a signature: the XML plist in its code signature's
    entitlements blob, which starts with its magic number and its length. Going
    by those, other XML in the executable can't be taken for it."""
    keys = set()
    for match in re.finditer(ENTITLEMENTS_MAGIC, executable):
        start = match.end() + 4
        length = int.from_bytes(executable[match.end():start], "big")
        try:
            value = plistlib.loads(executable[start:match.start() + length])
        except Exception:
            continue
        if isinstance(value, dict):
            keys.update(value)
    return keys


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("ipa")
    parser.add_argument("out")
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--icon-url", required=True)
    parser.add_argument("--notes", default="", help="what's new in this build")
    args = parser.parse_args()

    with zipfile.ZipFile(args.ipa) as ipa:
        found = list(bundles(ipa))
    app_info = found[0][0]
    entitlement_keys = set()
    privacy = {}
    for info, executable in found:
        keys = entitlements(executable)
        # The app and the widget are signed with their App Group, so none means
        # the signature couldn't be read, and the source would leave them out
        if not keys:
            sys.exit(f"{args.ipa}: no entitlements in {info['CFBundleExecutable']}'s signature")
        entitlement_keys |= keys - IMPLICIT_ENTITLEMENTS
        # Where the app and an extension say different things, the app's
        for key, value in info.items():
            if key.endswith("UsageDescription"):
                privacy.setdefault(key, value)

    version = {
        "version": app_info["CFBundleShortVersionString"],
        "buildVersion": app_info["CFBundleVersion"],
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "localizedDescription": args.notes or "The latest build.",
        "downloadURL": args.download_url,
        "size": os.path.getsize(args.ipa),
        "minOSVersion": app_info.get("MinimumOSVersion", "17.0"),
    }
    app = {
        "name": app_info.get("CFBundleDisplayName", app_info["CFBundleName"]),
        "bundleIdentifier": app_info["CFBundleIdentifier"],
        "developerName": "beanobots",
        "subtitle": "The next train at your station, on your Home Screen.",
        "localizedDescription": (
            "Live countdowns to the next NYC subway train at the station, line and direction you choose, "
            "from the MTA's real-time feeds. Widgets for the Home Screen and Lock Screen (each can show its "
            "own station), a walking time that tells you when to leave, a Lock Screen and Dynamic Island "
            "countdown once you're on your way, service alerts, elevator outages, station maps, and Siri: "
            "\"When's my next train in Train Times?\""
        ),
        "iconURL": args.icon_url,
        "tintColor": "#2B3B55",
        "category": "utilities",
        "versions": [version],
        "appPermissions": {
            "entitlements": sorted(entitlement_keys),
            "privacy": privacy,
        },
        # Older AltStore versions read the latest version from these instead of "versions"
        "version": version["version"],
        "versionDate": version["date"],
        "versionDescription": version["localizedDescription"],
        "downloadURL": version["downloadURL"],
        "size": version["size"],
    }
    source = {
        "name": "Train Times",
        "identifier": "com.rtrainwidget.source",
        "subtitle": "Next-train widgets for the NYC subway.",
        "description": "Builds of Train Times from github.com/beanobots/TrainTimes.",
        "iconURL": args.icon_url,
        "website": "https://github.com/beanobots/TrainTimes",
        "tintColor": "#2B3B55",
        "apps": [app],
        "news": [],
    }
    with open(args.out, "w", encoding="utf-8") as file:
        json.dump(source, file, indent=2, ensure_ascii=False)
        file.write("\n")
    print(f"{args.out}: {app['name']} {version['version']} ({version['buildVersion']}), {version['size']} bytes, "
          f"entitlements {app['appPermissions']['entitlements']}, privacy {sorted(privacy)}", file=sys.stderr)


if __name__ == "__main__":
    main()
