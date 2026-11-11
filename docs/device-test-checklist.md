# Device test checklist (Phase 5)

What the simulator can't check, run on the iPhone. Each row: what to do, what good looks like,
what to note if it fails. Mark each ✓ / ✗ with the date.

## Before starting

| Step | Why |
|---|---|
| Redeploy the push server (`sudo ./deploy/install.sh`) | At Station pushes, bus countdown pushes, `/bus-timetable`, `?days=30`, `/diagnostics`, `/docks`, `/routes` (own planner) all need it |
| Install a **Release** build (TestFlight or Product › Profile) for timing, battery and hitch checks | Debug is 30–60× slower in the walk router and planners; use Debug only for logs |
| Settings › Developer › Logging: turn on Energy and Networking, Start Recording | For the Energy Log rows below |
| Note iOS version, phone model, battery %, Low Power Mode off | Results depend on them |
| Pull the app log after each session: `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier dev.dctp.leeway --source "Library/Application Support/Diagnostics/log.txt"` | Times and failures are logged there (`AppLog`) |

## Battery and background

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Energy over a real trip | Logging on. Plan a ~20 min trip in New Trip, Go, walk, ride, walk to arrival. Stop recording; Instruments › Import Logged Data from Device | Energy mostly Low; High only during the walks with the screen on; no CPU between steps with the screen off | Time of each High stretch and what was on screen; % battery used |
| Location stops after arrival | Walk to arrival, then lock the phone | Blue location pill gone within a minute; no location in Energy Log after | How long it stayed. Go → End within seconds keeps the pill (known iOS 27.2 SpringBoard bug, not the app) |
| Location stops when the countdown's gone | Start a walk, swipe the Live Activity away, background the app | Pill goes; app opens again without a walk restarting location | Whether a widget/shortcut/bus countdown replaced it |
| Coarse location on rides | Tap I'm on the train; lock the phone for the ride | Pill shows (coarse, ~3 km); Energy Log low; no precise fixes | Battery % over the ride |
| Dynamic Island ends | Ride to your stop, walk out to arrival with the app closed | Island moves to the walk out, then ends at arrival or soon after, not lingering | How long it lingered after arrival |
| Indoors start delay | Start a trip from inside a building (Park Slope or Manhattan) | Leave-by time 2 min later while inside; drops back at the first fix outside | Neighbourhood (detection misses where sidewalks are in pieces, e.g. Astoria) |
| Background refresh | Leave the app closed overnight | Timetable refreshed next morning (Settings › Save for Offline shows it, or the log) | Last refresh time |

## Smoothness (Instruments, Release build)

Target for every row: Animation Hitches under 5 ms/s, no hitch over 100 ms.

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Nearby pan | Instruments › Animation Hitches. Pan Nearby around Midtown and Downtown Brooklyn for 30 s, buses on | < 5 ms/s | ms/s, and whether the marks (bubbles, bus pills) change mid-pan; a Time Profiler trace of the worst moment |
| Nearby pinch | Pinch in and out over Atlantic Av, 30 s | < 5 ms/s; lines and station dots scale together, lines not re-drawn a beat behind | ms/s; whether lines jump off their dots at rest |
| Map rotation | Two-finger turn Nearby; tap the compass (North ↔ NY North with NY Special on) | Smooth; needle turns with the map; heading kept on re-framing | ms/s |
| New Trip planning | Plan Park Slope → Times Sq, then three more trips | Trips show without a stall; walk all the way arrives after, no list jump | Time to trips and to walk all the way (log "Planned in") |
| Walking map | Go on a walk; watch the map follow you for 2 min | Map turns slowly on small heading changes, quickly on real turns; no stutter | ms/s |
| Landscape | Turn the phone on Nearby, Navigate, Routes, Settings | Card down the left, map behind; walking stays upright | Clipped card; "Couldn't Find You" card fit (unchecked) |

## Walking

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Night walks | After dark (and once after 1 am), plan walks on Balanced: Park Slope → Gowanus, through or past a park, a waterfront | Route prefers busier streets; "via safer streets" line shows only when it really detours; parks avoided 1–6 am | Start/end, time, screenshot of route; whether the line appeared |
| Sidewalk routes | Walk 3 bench walks (Park Slope 4 Av, Times Sq, Jackson Hts) | Route on your side, crossings at corners, follows you to the other sidewalk | Where it put you in the road or the wrong side |
| Safe crossings | Walk a route with a no-light crossing and a wide one (Queens Blvd, Ocean Pkwy) | Crossing as its own step; grey "No light", yellow for wide | Missing or wrong light tag |
| Cross-street signs | Watch the green blades ahead on a walk | Right street names at each crossing | Wrong names (Harlem crossing, Jackson Hts open items) |
| Vibrate before turns | Sound pill on Vibrate. Walk 3 turns with the phone in a pocket | One buzz about 20 m before each turn; none on the last step; one after a reroute | Distance it buzzed at, double buzzes |
| Spoken directions, speaker | Sound pill on Speak. Walk with music playing | Speaks on Go, each step, 50 m, 20 m, arrival; music ducks, podcasts pause | Missed or late lines; Apple voice instead of Kokoro (pack not installed) |
| Spoken directions, Bluetooth | Same with AirPods, then a Bluetooth speaker | Speech on the headphones, music back up after | Speech on the phone speaker, cut first words |
| Spoken directions, CarPlay | Plan a walk-from-car trip with CarPlay connected | Speech through the car, no CarPlay app needed | Silent, or stuck ducked audio |
| Sound pill | Tap the map button, tap and slide to each option | Pill opens, closes 0.5 s after a pick, choice kept next walk | Choice lost or pill stuck open (not simulator-checked) |
| Voice pack | Fresh TestFlight install, wait on Wi-Fi | Background Assets pack downloads; Kokoro voice used once it's there | Pack state in Settings, time to install |
| Bike navigation | Plan a Citi Bike trip, Go, ride it | Walk to dock, Take bike, ride steps, Leave bike, walk on; never opens Apple Maps; buzz ~60 m before turns | Where it lost the route (untested anywhere) |
| Ride tracking | On the train, tap I'm on the train, keep the app open | Train car moves along the line by times; station fixes shift it; no blue dot | Where it ran ahead/behind |

## Lock Screen and Dynamic Island

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Lock Screen map | Go on a walk, lock the phone | Full-height 160 pt map card, follows light/dark, no ↻; your dot near the turn; words never cut off | Screenshot; map blank or too close (camera scale) |
| Turn map updates | Walk past two turns locked | Map changes to the next turn; never shows another turn's map | Stale map, gaps |
| Dynamic Island | Start a countdown, go Home | Countdown in the Island, expands on press | Missing or frozen |
| At Station 15 s | Countdown on a train without a walk; watch through 0:00 locked and on a widget | Shows "At Station" for 15 s, then the next train (buses "At Stop" 5 s) | Whether it stuck at 0:00 (server push or app timer missing) |
| Leeway phrasing | Start a countdown with time to spare | "… of leeway" wording on Lock Screen and widgets | Old "to spare" text |

## Server, pushes and widgets

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| App Attest | Fresh install, start a countdown | Server registers it (server log shows the attested key); no "couldn't reach" | Error in app log, server status code |
| Countdown pushes | Start a countdown, lock the phone, wait 10 min | Lock Screen times change without opening the app | Last update time vs now |
| Bus countdown pushes | Start a bus countdown from a saved bus widget's walk pill | Pill lit blue; Lock Screen bus times update | Whether the pill stays lit after it ends |
| Widgets on server pushes | Home Screen with Next train, Saved Route and Nearby widgets; leave 30 min | Times move on; reload counts stay inside the daily budget | Widget showing old times, and since when |
| Widget taps | Tap each widget card, then ✕ | Opens and fetches; closes; Transit Directions taps quick | Slow or blank first draw |
| Diagnostics | Settings › Share Diagnostics on; use the app a day | Reports arrive in the server's diagnostics folder; no places in them | Missing reports; any location in a log line |

## Offline

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Plane mode | Save for Offline on, wait for timetables. Then Airplane Mode | Nearby and widgets show timetable trains; New Trip plans on the phone (subway, and buses from the bus timetable); alerts from the last week | What showed "Couldn't reach" instead |
| Underground | Ride with no signal | Countdown keeps going; no stuck spinners | Screens that hung |

## Real use

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Citi Bike | Plan a trip with Bike and E-Bike; tap a low dock's switch | Dock counts match the Citi Bike app; orange warning under 4; fuller-dock switch works | Count mismatch, dock out of service shown as open |
| Citi Bike widget | Nearest Dock and Favorite Dock widgets | Counts current, tap opens | Stale counts |
| Own bike | My Bike on, plan with transit | Carry/lock steps right; protected-lane % pill when over 5% | Wrong lane share |
| Buses | Nearby with buses on; open a stop; plan a bus trip | Bus pills on the right kerb each way; times match the stop sign; bus wait counted (walk first when a bus barely wins) | Stop on the wrong side; wrong times |
| Home Stop (bus) | Set a bus Home Stop; ask Siri "next bus"; search Spotlight | Siri says the next bus; Spotlight opens the stop on Nearby | Wrong answer |
| Routes | New Route Home → Work; save; check widget rows | Ways across the week, fallbacks shown; widget follows the way that runs | Missing fallback |
| Calendar + Recents | Grant Calendar; open New Trip To with an event today | "Next on Your Calendar" card; recents kept 24 h | No card, wrong place (not simulator-checked) |
| Contacts search | Search a contact's name in New Trip | Their address comes up | Not found |

## Accessibility

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| VoiceOver: Nearby grid | VoiceOver on; swipe through Nearby's line tiles and dock rows | Each tile read once with line, way and times | Tiles read twice or skipped |
| VoiceOver: map marks | Explore Nearby's map by touch | Stations, bus stops and bubbles named | Unnamed marks |
| VoiceOver: open items | Nearby widget refresh toggle, BusBoard refresh button, Settings/Citi Bike tiles, crossing steps | Refresh controls don't swallow their rows; tiles say On/Off once | Which ones repeat (crossing steps may say a street twice: known) |
| Dynamic Type | Largest accessibility size on Nearby, New Trip, a widget | Text wraps, nothing cut | Screenshot |

## First run

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Splash and setup | Delete and reinstall; open | Splash draws, holds 1.5 s, fades to privacy; each path's screens; Meet the Magic Widget page | Stutter, wrong order |
| Permissions | Answer each ask (location, calendar, contacts, notifications) | Asked once each, at its step; app works with each denied | Ask repeated, or broken when denied |
| Run Setup Again | Settings › Run Setup Again | Splash plays, setup keeps your choices | Choices lost |

## Prototyping card (secret Settings tools, not run anywhere)

| Check | What to do | Good | If it fails, note |
|---|---|---|---|
| Each tool | Open each of the 10 tools once (Voice, Voice Mixer, Pretend Time, Pretend Location, Force Offline, Test Live Activity, Test Lock Screen, Diagnostics Tools, Clear Caches, Map Overlays) | Does what it says, turning off restores normal | Tool that crashes or sticks on |
