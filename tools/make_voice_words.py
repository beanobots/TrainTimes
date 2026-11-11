#!/usr/bin/env python3
"""Builds ios/VoicePack/words.json: how the walking voice (Kokoro) says every word in every
name Leeway can speak, in Kokoro's phonemes, and ios/VoicePack/review.tsv, the ones to check.

    mkdir -p names
    curl -o names/streets.json 'https://data.cityofnewyork.us/resource/inkn-q76z.json?$select=full_street_name,rw_type&$group=full_street_name,rw_type&$limit=50000'
    curl -o names/parks.json 'https://data.cityofnewyork.us/resource/enfh-gkve.json?$select=signname&$limit=20000'
    curl -o names/neighborhoods.json 'https://data.cityofnewyork.us/resource/9nt8-h7nd.json?$select=ntaname&$limit=1000'
    curl -o names/docks.json https://gbfs.citibikenyc.com/gbfs/en/station_information.json
    pip install "misaki[en]" g2p_en
    python3 tools/make_voice_words.py names ios/VoicePack

The names: every street, highway, bridge and tunnel in the city's street map; the bundled
walking map's labels; subway stations, their direction labels and entrance streets; bus
stops and where buses go; parks; neighbourhoods; Citi Bike docks. Each is split into words,
with the city's abbreviations ("PKY", "BLVD") read as the words they stand for. Numbers and
single letters ("Ave N") aren't words here: they're read by rule when spoken.

Each word's phonemes come from, in order:
  nyc      tools/nyc_words.tsv, for how New Yorkers say it ("Houston", "Throop", "Wyckoff")
  misaki   misaki's own dictionary, which Kokoro was trained with
  cmudict  the CMU Pronouncing Dictionary, through g2p_en
  guess    g2p_en's model, for words in neither: these are the ones review.tsv lists first
eSpeak (GPL) is never used. Kokoro says nothing for a word it has no phonemes for, which is
why every word has to be here.
"""
import collections, json, pathlib, re, sqlite3, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "ios"

# How New Yorkers say names that dictionaries get wrong or don't have: tools/nyc_words.tsv.
NYC = {}
for line in open(pathlib.Path(__file__).with_name("nyc_words.tsv"), encoding="utf-8"):
    if line.startswith("#") or line.startswith("word\t") or not line.strip():
        continue
    word, phonemes, sure, *_ = line.rstrip("\n").split("\t")
    NYC[word] = (phonemes, sure)

# The city's abbreviations, as words. Ones that mean more than one thing ("ST": Street or
# Saint) are read by where they are when spoken; both meanings are words here anyway.
ABBREVIATIONS = {
    "ST": "street saint", "AVE": "avenue", "AV": "avenue", "BLVD": "boulevard", "PKWY": "parkway",
    "PKY": "parkway", "PL": "place", "RD": "road", "DR": "drive", "TER": "terrace", "CT": "court",
    "LN": "lane", "SQ": "square", "EXPY": "expressway", "EXPWY": "expressway", "HWY": "highway",
    "TPKE": "turnpike", "CIR": "circle", "PLZ": "plaza", "ALY": "alley", "BRG": "bridge",
    "BR": "bridge", "CONC": "concourse", "ESPL": "esplanade", "PROM": "promenade", "BDWK": "boardwalk",
    "OPAS": "overpass", "PTH": "path", "LP": "loop", "XING": "crossing", "PK": "park", "GRN": "green",
    "HTS": "heights", "STA": "station", "CTR": "center", "CTRL": "central", "JCT": "junction",
    "HOSP": "hospital", "MT": "mount", "FT": "fort", "PT": "point", "BCH": "beach", "BLDG": "building",
    "CC": "community college", "HS": "high school", "JHS": "junior high school", "PS": "public school",
    "IS": "intermediate school", "MS": "middle school", "UNIV": "university", "COLL": "college",
    "SVC": "service", "ENT": "entrance", "EXT": "extension", "APPR": "approach", "GDNS": "gardens",
    "PLGD": "playground", "TERM": "terminal", "TRL": "trail", "WHSE": "warehouse", "N": "north",
    "S": "south", "E": "east", "W": "west", "NE": "northeast", "NW": "northwest", "SE": "southeast",
    "SW": "southwest", "JR": "junior", "SR": "senior", "CUNY": "cuny", "SUNY": "suny",
    # Which way a road or bus goes
    "NB": "northbound", "SB": "southbound", "EB": "eastbound", "WB": "westbound",
    # The city's and the MTA's shorter forms
    "BL": "boulevard", "PY": "parkway", "EP": "expressway", "FWY": "freeway", "RDWY": "roadway",
    "DRV": "drive", "RP": "ramp", "TP": "turnpike", "BRDG": "bridge", "TNNL": "tunnel", "TNL": "tunnel",
    "RVR": "river", "PRK": "park", "PZ": "plaza", "LK": "lake", "HL": "hill", "HLLS": "hills",
    "CRK": "creek", "CV": "cove", "PNT": "point", "PND": "pond", "GLN": "glen", "MDW": "meadow",
    "RDG": "ridge", "SHR": "shore", "MNR": "manor", "CMNS": "commons", "CR": "crescent",
    "CRCL": "circle", "TR": "trail", "GRDN": "garden", "GDN": "garden", "TWR": "tower",
    "TWRS": "towers", "VLG": "village", "GRND": "grand", "CNTR": "center", "CNTRL": "central",
    "CTY": "city", "LVL": "level", "TRML": "terminal", "TRM": "terminal", "TRMNL": "terminal",
    "HSNG": "housing", "HQ": "headquarters", "LTD": "limited", "PSYCH": "psychiatric",
    "MSGR": "monsignor", "FR": "father", "CPL": "corporal", "MJR": "major", "HBR": "harbor",
    "FRRY": "ferry", "FRY": "ferry", "RTE": "route", "CHNNL": "channel", "DWNTWN": "downtown",
    "CNTRLINE": "centerline", "NVY": "navy", "FRMS": "farms", "PLS": "plains", "WWTP": "wastewater plant",
    # Bus signs, shortened to fit
    "BKLYN": "brooklyn", "BKLN": "brooklyn", "BK": "brooklyn", "BX": "bronx", "MN": "manhattan",
    "QN": "queens", "WSHNGTN": "washington", "TRMNT": "tremont", "HRDNG": "harding",
    "BRCKNR": "bruckner", "SCHYLR": "schuyler", "GFRDS": "giffords", "GWNUS": "gowanus",
    "NSTRND": "nostrand", "RGRS": "rogers", "FLBSH": "flatbush", "MTRPLTN": "metropolitan",
    "WSTCHSTR": "westchester", "WDSWRTH": "wadsworth", "RCHMND": "richmond", "WLMSBRG": "williamsburg",
    "MARINRS": "mariners", "HBKN": "hoboken", "QBORO": "queensboro", "CHSHLM": "chisholm",
    # Places by their initials, read as the words
    "GCP": "grand central parkway", "HRD": "harlem river drive", "GW": "george washington",
    "GWB": "george washington bridge", "WFC": "world financial center", "WTC": "world trade center",
    "FMCP": "flushing meadows corona park", "QBCC": "queensborough community college",
    "HBLR": "hudson bergen light rail", "BBT": "brooklyn battery tunnel", "P.S": "public school",
    "N.J": "new jersey", "G.W": "george washington", "B.B.T": "brooklyn battery tunnel",
    "LGA": "laguardia", "BWAY": "broadway", "FORDHM": "fordham",
    # And more of the city's
    "PED": "pedestrian", "TERR": "terrace", "CRES": "crescent", "DY": "driveway", "DVWY": "driveway",
    "FRWY": "freeway", "AVS": "avenues", "STS": "streets", "TUNL": "tunnel", "ISL": "island",
    "STWY": "stairway", "GRDNS": "gardens", "RT": "route", "WM": "william", "LT": "lieutenant",
    "SGT": "sergeant", "PFC": "private first class", "PVT": "private", "ISLD": "island",
    "EXY": "expressway", "RY": "roadway", "SHRE": "shore", "THRWY": "thruway", "NICH": "nicholas",
    "RDGE": "ridge", "BEP": "belt parkway",
    "&": "and", "+": "plus",
}
# Said letter by letter, by rule.
LETTERS = {"MLK", "FDR", "JFK", "RFK", "US", "NYC", "NYCHA", "NYPD", "DSNY", "BMT", "IRT", "IND",
           "LIRR", "SBS", "MTA", "PATH", "BQE", "LIE", "CBE", "MDE", "SIR", "JJ", "JZ", "TLC", "CS", "BC",
           "JC", "CP", "R&L", "J.S", "LIJ"}
# Endings place names are made with: "Eastchester" is east + chester, "Rosedale" rose + dale.
ENDINGS = {"chester", "view", "bridge", "dale", "ville", "wood", "woods", "point", "port", "haven",
           "ton", "side", "field", "fields", "hurst", "land", "lands", "wick", "mere", "water", "crest",
           "brook", "hill", "hills", "park", "way", "gate", "shore", "beach", "worth", "burgh", "boro",
           "borough", "ford", "mont", "more", "vale", "stone", "berg", "hall", "house", "town", "dam",
           "girt", "kill", "neck", "meadow", "meadows", "cliff", "lawn", "dell", "glen", "grove",
           "manor", "heights", "ridge", "harbor", "bay", "wall", "well", "ham", "mount", "ocean"}
# Road types never walked, so never in directions: driveways, ramps, U-turns, ferry routes.
UNWALKED = {"8", "9", "13", "14"}

ARPABET = {
    "AA": "ɑ", "AE": "æ", "AO": "ɔ", "AW": "W", "AY": "I", "EH": "ɛ", "EY": "A", "IH": "ɪ", "IY": "i",
    "OW": "O", "OY": "Y", "UH": "ʊ", "UW": "u", "B": "b", "CH": "ʧ", "D": "d", "DH": "ð", "F": "f",
    "G": "ɡ", "HH": "h", "JH": "ʤ", "K": "k", "L": "l", "M": "m", "N": "n", "NG": "ŋ", "P": "p",
    "R": "ɹ", "S": "s", "SH": "ʃ", "T": "t", "TH": "θ", "V": "v", "W": "w", "Y": "j", "Z": "z",
    "ZH": "ʒ",
}


def from_arpabet(phones):
    """g2p_en's ARPAbet ("G AW1 AH0 N AH0 S") in Kokoro's phonemes ("ɡˈWənəs")."""
    out = []
    for p in phones:
        base, stress = (p[:-1], p[-1]) if p[-1].isdigit() else (p, None)
        mark = {"1": "ˈ", "2": "ˌ"}.get(stress, "")
        if base == "AH":
            out.append(mark + ("ʌ" if stress in ("1", "2") else "ə"))
        elif base == "ER":
            out.append(mark + ("ɜɹ" if stress in ("1", "2") else "əɹ"))
        elif base in ARPABET:
            out.append(mark + ARPABET[base])
    return "".join(out)


def names(source_dir):
    """Every name Leeway can say, with where it's from."""
    found = []
    add = lambda kind, name: name and found.append((kind, name.strip()))

    for row in json.load(open(source_dir / "streets.json")):
        if row.get("rw_type") in UNWALKED:
            continue
        kind ={"2": "highway", "3": "bridge", "4": "tunnel"}.get(row.get("rw_type"), "street")
        add(kind, row.get("full_street_name"))
    with sqlite3.connect(ROOT / "App/walkgraph.sqlite") as db:
        for (label,) in db.execute("select label from names"):
            add("street", label)
    for station in json.load(open(ROOT / "Shared/stations.json")):
        add("station", station["name"])
        add("station", station.get("short"))
        add("direction", station.get("north"))
        add("direction", station.get("south"))
        for entrance in station.get("entrances", []):
            for street in entrance.get("streets", []):
                add("street", street)
    buses = json.load(open(ROOT / "Shared/bus_routes.json"))
    for stop in buses["stops"]:
        add("bus stop", re.sub(r"\(.*?\)", "", stop[3]))
    for ways in buses["lines"].values():
        for way in ways:
            add("bus direction", way["to"])
    for park in json.load(open(source_dir / "parks.json")):
        add("park", park.get("signname"))
    for place in json.load(open(source_dir / "neighborhoods.json")):
        add("neighborhood", place.get("ntaname"))
    for dock in json.load(open(source_dir / "docks.json"))["data"]["stations"]:
        add("dock", dock.get("name"))
    return found


def words_of(name):
    """`name`'s words as spoken, lower case: "W 43 ST" → ["west", "street", "saint"]."""
    out = []
    name = re.sub(r"\b(MC|Mc) (?=[A-Za-z])", r"\1", name)  # "MC ARTHUR RD": McArthur
    for raw in re.split(r"[\s/\-–—,;:()\[\]\"*]+", name):
        token = raw.strip(".'’")
        if not token or any(c.isdigit() for c in token):
            continue  # numbers, and "43rd", "B44+", are read by rule
        upper = token.upper()
        if upper in LETTERS or (len(token) == 1 and token.isalpha()):
            continue  # letters, read by rule
        if re.fullmatch(r"[IVXLC]{2,}", token):
            continue  # Roman numerals, in a few parks' names: read by rule
        if upper in ABBREVIATIONS:
            out += ABBREVIATIONS[upper].split()
            continue
        if not re.search(r"[AEIOUY]", upper):
            out.append(("?abbr", token))  # an abbreviation we don't know yet
            continue
        word = token.lower().replace("’", "'")
        if re.fullmatch(r"[a-z][a-z'.&]*", word):
            out.append(word.strip("."))
    return out


def main(source_dir, target_dir):
    from misaki import en
    from g2p_en import G2p
    import nltk

    spoken_names = names(source_dir)
    count = collections.Counter()
    kinds = collections.defaultdict(collections.Counter)
    examples = collections.defaultdict(list)
    unknown_abbreviations = collections.Counter()
    for kind, name in spoken_names:
        for word in words_of(name):
            if isinstance(word, tuple):
                unknown_abbreviations[word[1]] += 1
                continue
            count[word] += 1
            kinds[word][kind] += 1
            if len(examples[word]) < 2 and name not in examples[word]:
                examples[word].append(name)

    misaki = en.G2P(trf=False, british=False, fallback=None)
    cmudict = nltk.corpus.cmudict.dict()
    guesser = G2p()

    def by_misaki(word):
        for form in (word.capitalize(), word):
            phonemes, tokens = misaki(form)
            if len(tokens) == 1 and tokens[0].phonemes and "❓" not in phonemes:
                return phonemes
        return None

    def known(word):
        """`word`'s phonemes from the list, misaki or the CMU dictionary, and which; else None."""
        if word in NYC:
            return NYC[word][0], "nyc"
        if phonemes := by_misaki(word):
            return phonemes, "misaki"
        if word in cmudict:
            return from_arpabet(cmudict[word][0]), "cmudict"
        return None

    def plural(word):
        """"rockaways", "ann's": a known word and its s."""
        stem = re.sub(r"'?s$", "", word)
        if stem == word or len(stem) < 3 or not (found := known(stem)):
            return None
        phonemes = found[0]
        ending = "s" if phonemes[-1] in "ptkfθ" else ("ɪz" if phonemes[-1] in "szʃʒʧʤ" else "z")
        return phonemes + ending, "plural"

    def compound(word):
        """"eastchester": two known words, east and chester, stressed on the first. Only when the
        second is a place-name ending, or both are in misaki's dictionary: "capodanno" isn't
        cap + o + danno."""
        best = None
        for i in range(3, len(word) - 2):
            first, second = known(word[:i]), known(word[i:])
            if not (first and second):
                continue
            if word[i:] not in ENDINGS and not (first[1] == second[1] == "misaki" and min(i, len(word) - i) >= 4):
                continue
            # "-ton" is light at the end of a name: Castleton is CASS-ul-tən, not -TUN
            ending = "tən" if word[i:] == "ton" else second[0].replace("ˈ", "ˌ")
            if best is None or min(i, len(word) - i) > best[0]:
                best = (min(i, len(word) - i), first[0] + ending)
        return (best[1], "compound") if best else None

    words, sources = {}, {}
    for word in sorted(count):
        found = known(word) or plural(word) or compound(word)
        if not found:
            phonemes = from_arpabet(guesser(word))
            if not phonemes:
                continue
            found = phonemes, "guess"
        words[word], sources[word] = found

    target_dir.mkdir(parents=True, exist_ok=True)
    with open(target_dir / "words.json", "w") as file:
        json.dump(words, file, ensure_ascii=False, separators=(",", ":"), sort_keys=True)

    # To check by ear: NYC "check" ones, then guesses, then the CMU dictionary's, most said first.
    order = {"check": 0, "guess": 1, "compound": 2, "cmudict": 3}
    rows = []
    for word, source in sources.items():
        level = "check" if source == "nyc" and NYC[word][1] == "check" else source
        if level in order:
            rows.append((order[level], -count[word], word, level))
    rows.sort()
    with open(target_dir / "review.tsv", "w") as file:
        file.write("word\tphonemes\tfrom\ttimes\tkinds\texamples\n")
        for _, _, word, level in rows:
            kind = ", ".join(k for k, _ in kinds[word].most_common(3))
            file.write(f"{word}\t{words[word]}\t{level}\t{count[word]}\t{kind}\t{' | '.join(examples[word])}\n")
        for abbreviation, times in unknown_abbreviations.most_common():
            file.write(f"{abbreviation}\t\tabbreviation\t{times}\t\t\n")

    tally = collections.Counter(sources.values())
    print(f"{len(spoken_names)} names, {len(words)} words: " + ", ".join(f"{n} {s}" for s, n in tally.most_common()))
    print(f"{len(unknown_abbreviations)} abbreviations not yet known: "
          + ", ".join(a for a, _ in unknown_abbreviations.most_common(30)))


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
