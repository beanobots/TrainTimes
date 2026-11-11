# TrainTimesServer

Keeps the app's Lock Screen countdown (its Live Activity) up to date while the
app isn't running, for each countdown registered with it by its push token.
Every `POLL_SECONDS` the server reads the MTA's feeds with the app's own code
(`Sources/TrainCore/Shared` links to `../ios/Shared`). It sends an ActivityKit
push through APNs when the train's time, the train, the next trains or the
notice change, plus a low-priority refresh every 5 minutes (see `PUSH_EARLIER_SECONDS` and the rest below). Between
passes it wakes as each countdown's train is due and pushes it on to the next
train it last had, still showing two trains after it from those the last pass
read, so it never sits at 0:00; the next pass brings that train's new times. After 30 minutes it ends the countdown.

Requests that change registrations are signed with App Attest, so only the
genuine app on a real device can make them.

**The app registers its countdowns.** It starts each one with
`pushType: .token` (`ios/App/TrainActivityController.swift`), and
`ios/App/ActivityPush.swift` sends each push token iOS gives it to
`POST /activities`, with the phone's widget push token, and deletes it when the
countdown ends or its token changes. `ios/App/PushServer.swift` signs those
requests, one at a time, with the App Attest key `ios/App/AppAttest.swift`
makes and keeps in the Keychain, as
[In the app, in order](#in-the-app-in-order) describes. A registration that
fails (no server, no App Attest in the simulator) is tried again, backing off
up to 30 minutes, each time the app opens and from a background refresh; until
then the countdown gets new times only while the app runs. The app has the
Push Notifications entitlement (`aps-environment`), and
`NSSupportsLiveActivitiesFrequentUpdates` in its Info.plist, so iOS doesn't
throttle the server's high-priority pushes.

**Only builds signed by one team can use it**: the team whose APNs key it has
(`APNS_TEAM_ID`), with the bundle ID that `APP_ID` and `APNS_TOPIC` name. That's
a build from Xcode with a paid developer account, or from TestFlight or the App
Store. A build signed with a free Apple ID can't use it, as a free account can't
have push notifications.

## How it's reached

It runs on the Mac mini as a LaunchDaemon under the hidden user `traintimes`,
and listens on 127.0.0.1:8080 only. A Cloudflare Tunnel, set up in the
Cloudflare dashboard (Zero Trust › Networks › Tunnels), forwards
`https://<hostname>` to `http://127.0.0.1:8080` through `cloudflared` on the
same Mac. Nothing else should reach port 8080.

Every request therefore comes from cloudflared. The server takes the client's
address from `CF-Connecting-IP`, but only when the connection comes from
loopback. Otherwise it uses the peer's address. It uses the client's address
only for rate limits, and logs it only as a keyed hash.

## Configuration

| Variable | Default | |
|---|---|---|
| `APNS_KEY_PATH` | required | the APNs auth key (.p8) |
| `APNS_KEY_ID` | required | its key ID |
| `APNS_TEAM_ID` | required | `XUU899AG4D` |
| `APNS_TOPIC` | `dev.dctp.leeway.push-type.liveactivity` | |
| `DATA_DIR` | required | holds `traintimes.sqlite`, the timetables and, in `gtfs/`, the MTA's GTFS zips they're built from |
| `ATTEST_MODE` | `on` | `off` is for development only, e.g. the simulator; it then needs `API_SECRET` |
| `ATTEST_ENVIRONMENT` | `production` | `development` (builds from Xcode), `production` (TestFlight, App Store) or `both` |
| `APP_ID` | `XUU899AG4D.dev.dctp.leeway` | the App ID App Attest checks |
| `API_SECRET` | | only with `ATTEST_MODE=off`; at least 16 characters |
| `HOST` | `127.0.0.1` | |
| `PORT` | `8080` | |
| `POLL_SECONDS` | `20` | a pass that runs over skips ticks; passes never overlap |
| `PUSH_EARLIER_SECONDS` | `15` | an update when the train's time moves more than this earlier |
| `PUSH_LATER_SECONDS` | `60` | an update when it moves more than this later |
| `PUSH_FOLLOWING_SECONDS` | `60` | an update when a following train moves this much or more |
| `REFRESH_SECONDS` | `300` | a low-priority refresh once the last push is this old, 60 to 3600 |
| `PUSH_CONCURRENCY` | `100` | pushes in flight at once, over the shared HTTP/2 APNs clients |
| `MAX_REGISTRATIONS` | `100000` | in all |
| `MAX_REGISTRATIONS_PER_KEY` | `5` | live countdowns per attest key; registering one more drops that key's oldest |
| `RATE_LIMIT_PER_MINUTE` | `30` | per client address, on every route |
| `RATE_LIMIT_BURST` | same as per minute | the deploy plist leaves it out, so it follows `RATE_LIMIT_PER_MINUTE` |
| `FEED_RATE_LIMIT_PER_MINUTE` | `240` | per client address, on `GET /feeds` only, which uses none of the limit above |
| `FEED_RATE_LIMIT_BURST` | `120` | |
| `MAX_KEYS_PER_IP_PER_DAY` | `10` | keys attested per client address per UTC day; attestations that fail don't count |
| `ROUTES_PER_IP_PER_DAY` | `1000` | trips `GET /routes` plans per client address per UTC day |
| `ROUTES_PER_DAY` | `200000` | the same for everyone together |
| `BUS_TIME_API_KEY` | | MTA Bus Time's API key ([free](https://register.developer.obanyc.com)), for `GET /buses`; without it, that route isn't offered |
| `BUS_TIME_PER_IP_PER_DAY` | `2000` | requests to Bus Time per client address per UTC day, for `GET /buses` and `GET /buses/nearby`; what's kept, or already being asked for, doesn't count |
| `BUS_TIME_PER_DAY` | `100000` | the same for everyone together |
| `DIAGNOSTICS_PER_KEY_PER_DAY` | `20` | `POST /diagnostics` reports per attest key per UTC day; `0` takes none |
| `MAX_DIAGNOSTICS` | `1000` | reports kept in all; past that, the oldest go |
| `LOG_PUSHES` | `0` | `1` logs every push; otherwise each pass logs its totals |
| `LOG_FILE` | | the plist's `StandardOutPath`: once newsyslog has rotated it, the server writes to the new file within a minute |

The limits per client address count an IPv6 address by its /64, since a host
is commonly given a whole /64.

## API

Every response is empty unless stated otherwise. Over the rate limit, any
route answers `429` with `Retry-After: 60`. Bodies are limited to 4 KB, or
16 KB for `/attest`. Dates are what `JSONEncoder` writes by default: seconds
since 2001-01-01.

### `GET /health`

`200` with `ok`. It needs no authentication and tells nothing else.

### `GET /feeds?name=<feed>`: an MTA feed, for the app and widgets

The app and its widgets read every MTA feed here first, and from the MTA only
if this can't be reached or fails. `name` is the feed's name after the MTA's
`.../mtagtfsfeeds/`, unescaped: `nyct/gtfs-nqrw`, `nyct/gtfs` (the numbered
lines), `camsys/subway-alerts.json` or `nyct/nyct_ene.json`. No other address
can be asked for. The answer is the feed's bytes as the MTA sent them. The
server reads the train feeds once each `POLL_SECONDS`, the alerts once a
minute and the elevator outages every 2 minutes (never more often than
`POLL_SECONDS`), while anyone's counting down a train or a feed's been asked
for in the last 5 minutes, and the countdowns use the same copies. A request is
answered from them, but for the first after an idle spell, as at night, when
the copy's gone: that reads the MTA, once however many ask, and waits up to 4
seconds for it. A feed read the same as before keeps what was cut and gzipped
from it. A copy is passed on until it's twice its read interval and 10
seconds old (`2 × POLL_SECONDS + 10` for a train feed), so one failed read
doesn't matter; after that, `502` until the MTA can be read again. It needs no
authentication, as widgets can't sign requests, and has its own rate limit
(`FEED_RATE_LIMIT_PER_MINUTE`), as one refresh reads several feeds per widget.

| Status | Meaning |
|---|---|
| `200` | the feed |
| `400` | no `name` |
| `404` | not a feed the app reads |
| `502` | no recent copy: just started, or the MTA couldn't be read for a while (or in 4 seconds, after an idle spell) |

### `GET /timetable[?days=30]` and `GET /bus-timetable`: the timetables the app falls back on

The MTA's timetable, for when its feeds can't be reached, as the app's
`Timetable` encodes it (zlib-compressed). The server builds each once a day
from the MTA's GTFS, New York time, and keeps it in `DATA_DIR` for a restart:
the subway's week at 04:00 (`timetable.bin`), its 30 days at 04:30
(`timetable-30.bin`, with `days=30`, for phones saving it for offline; the
week's until it's built) and the buses' week at 05:00 (`bus-timetable.bin`,
from the six borough and MTA Bus feeds). Each GTFS zip is kept in
`DATA_DIR/gtfs/` with its `ETag` and asked for with `If-None-Match`, so it's
downloaded again only once the MTA has changed it (the week's and the month's
builds share the subway's). A build that fails is tried again an
hour later, the last one still served. No authentication, like `GET /feeds`.
Each has an `ETag`: with `If-None-Match` it, `304`.

| Status | Meaning |
|---|---|
| `200` | the timetable |
| `304` | the phone has this one |
| `503` | not built yet |

### `GET /routes?from=<lat,lon>&to=<lat,lon>[&at=<time>][&bus=1][&subway=0]`: trips between two places

New Trip, and the Share extension for directions shared from Apple Maps or
Google Maps, whose links say nothing of which trains they take, send a start
and end and get trips between them, best first: each trip's rides, in order.
The server plans them itself on the timetables it builds (`TransitPlanner`, by
RAPTOR): the quickest with one ride and with two, then by subway alone and by
bus alone, and without each line those ride, walking up to 1.2 km to the first
stop and from the last (2.4 km where that finds nothing), and changing on foot
between stops 400 m apart or the MTA's timed transfers. `at`, in seconds since
1970, is when to leave, from now to a week on; it defaults to now. Both places
must be in New York City. It needs no authentication, as app extensions can't
use the app's App Attest key, so it plans at most `ROUTES_PER_IP_PER_DAY` trips
a day for each client address and `ROUTES_PER_DAY` for everyone. The same trip
asked again within 2 minutes (places to about 10 m, leaving in the same minute,
the same `bus` and `subway`) is answered with what was planned and counts
toward neither. Where trips go isn't logged or stored.

With `bus=1`, trips by bus are planned as well, and with `subway=0` by bus
alone. Each ride's `mode` is `subway` or `bus`, `seconds` how long it takes and
`leaves` when it leaves (in seconds since 1970) by the timetable, `stops` the
stops ridden, and a bus ride's `headsign` where it's going. Without `bus=1`,
only trains: an app that predates buses can't match them to stations.
`GET /buses` gives the next buses for a bus ride. The Staten Island Railway
(`SI`) is a `subway` ride.

```json
{"routes": [{"legs": [
  {"line": "R", "mode": "subway", "headsign": "Forest Hills - 71 Av", "stops": 5,
   "from": {"name": "Prospect Av", "latitude": 40.6654, "longitude": -73.9929},
   "to": {"name": "DeKalb Av", "latitude": 40.6906, "longitude": -73.9818}},
  {"line": "B", "mode": "subway", "headsign": "Bedford Park Blvd", "stops": 14,
   "from": {"name": "DeKalb Av", "latitude": 40.6906, "longitude": -73.9818},
   "to": {"name": "81 St - Museum of Natural History", "latitude": 40.7814, "longitude": -73.9721}}
]}]}
```

| Status | Meaning |
|---|---|
| `200` | the routes; none if there's no trip |
| `400` | `from` or `to` missing, malformed or outside the city |
| `429` | over a daily limit, with `Retry-After` until midnight UTC |
| `502` | no timetable built yet for what's asked |

### `GET /buses?line=<line>&stop=<lat,lon>`: the next buses, for a route's bus ride

Only with `BUS_TIME_API_KEY`. `line` is the ride's line as `GET /routes` gives
it (`B63`, `M15-SBS`; send `+` as `%2B`), and `stop` its `from`. The server
finds MTA Bus Time's stop for that line within 150 m, the nearest, and answers
with it and its next buses on that line, soonest first, from Bus Time's SIRI
StopMonitoring. `expected` is when Bus Time expects the bus from where it is;
`aimed`, the timetable's time, is all there is for a bus yet to leave its
terminal. Dates are seconds since 2001, as above. It needs no
authentication, like `GET /routes`, so Bus Time is asked at most
`BUS_TIME_PER_IP_PER_DAY` times a day for each client address and
`BUS_TIME_PER_DAY` for everyone. The stop found is kept for a day and its
buses for 30 seconds, and asking together asks Bus Time once, so phones don't
add to what Bus Time is asked. The line's buses come from the stop's every
line kept for a countdown or `GET /buses/nearby`, when that has some; Bus Time
not answering for a stop is kept 30 seconds too.

```json
{"stop": {"id": "308209", "name": "4 AV/9 ST", "latitude": 40.6697, "longitude": -73.9877, "direction": "NE"},
 "arrivals": [
  {"line": "B63", "destination": "BAY RIDGE SHORE RD via 5 AV", "expected": 783106385,
   "stopsAway": 0, "distance": "approaching"},
  {"line": "B63", "destination": "BAY RIDGE SHORE RD via 5 AV", "expected": 783106920,
   "aimed": 783106800, "stopsAway": 9, "distance": "1.4 miles away"}
]}
```

| Status | Meaning |
|---|---|
| `200` | the stop and its buses; none if none are on their way |
| `400` | `line` or `stop` missing or malformed, or `stop` outside the city |
| `404` | no `BUS_TIME_API_KEY`, or no stop for that line near there |
| `429` | over a daily limit, with `Retry-After` until midnight UTC |
| `502` | Bus Time refused or couldn't be reached |

### `GET /buses/nearby?at=<lat,lon>`: the closest stop each way, for Nearby

Only with `BUS_TIME_API_KEY`, and with no authentication, like `GET /buses`.
For Transit Directions' Nearby with buses on: the bus stop nearest `at` within
a quarter mile, then the nearest stop on one of its lines going the other way
(by Bus Time's compass `direction`, if there is one), each with its next
buses on every line, soonest first, as `GET /buses` gives them. `meters` is
from `at`. The stops around a point (to three decimals, about 100 m) are kept
for a day, and each stop's buses for 30 seconds.

```json
{"ways": [
  {"stop": {"id": "308209", "name": "4 AV/9 ST", "latitude": 40.6697, "longitude": -73.9877, "direction": "NE"},
   "meters": 42, "arrivals": [{"line": "B63", "destination": "COBBLE HILL", "expected": 783106385, "stopsAway": 2}]},
  {"stop": {"id": "308210", "name": "4 AV/9 ST", "latitude": 40.6699, "longitude": -73.9874, "direction": "SW"},
   "meters": 61, "arrivals": []}
]}
```

| Status | Meaning |
|---|---|
| `200` | up to two ways; none if no stop is within a quarter mile |
| `400` | `at` missing, malformed or outside the city |
| `404` | no `BUS_TIME_API_KEY` |
| `429` | over a daily limit, with `Retry-After` until midnight UTC |
| `502` | Bus Time refused or couldn't be reached |

### `GET /docks`: Citi Bike docks near a place, for Nearby and the widgets

No authentication, like the feeds. Citi Bike's GBFS feed gives the whole city's
counts as one file of about 1 MB; the server reads it at most once a minute,
its own `ttl` (where the docks are, once a day), once however many ask, and
gives each phone only the docks it shows. A read that fails isn't tried again
for 30 seconds (where the docks are, 10 minutes), the last copy served
meanwhile:

| Query | |
|---|---|
| `at=<lat,lon>` | docks nearest there, nearest first |
| `limit=<1–10>` | how many, 5 if not given |
| `within=<meters>` | how far to look, at most 2000, 800 if not given |
| `has=` | `any` (the default), `service` (taking or leaving bikes), `bike`, `ebike` or `either` (with one to take) |
| `ids=<a,b>` | instead of `at`: those docks (up to 10), in that order |
| `places=1` | instead: every dock's place and name, counts all 0; with an `ETag` (`If-None-Match` it, `304`) and `Cache-Control: max-age=3600` |

```json
{"docks": [
  {"id": "66db6387-0aca-11e7-82f6-3863bb44ef7c", "name": "4 Av & 9 St", "lat": 40.6700, "lon": -73.9880,
   "bikes": 3, "eBikes": 2, "docks": 10, "renting": true, "returning": true}
]}
```

| Status | |
|---|---|
| `304` | `places=1`: the phone has these |
| `400` | no `at` in the city, or `limit`, `within`, `has` or `ids` out of range |
| `502` | Citi Bike couldn't be reached |

### `GET /attest/challenge`

`200` with `{"challenge":"<54 characters, base64url>","expiresIn":300}`, and
`Cache-Control: no-store`. A challenge is good for 5 minutes. The server keeps
nothing for one it issues: it's 16 random bytes and its expiry, with an
HMAC-SHA256 of both under a key made at start, so asking for any number of
them, from any number of addresses, fills nothing and refuses no one (only the
rate limit applies). A signed request's challenge isn't used up, as its
assertion's counter already stops it being sent again; an attestation's is
used once, noted only after the attestation checks out. A restart makes a new
key, so challenges from before it are refused with `401`, and the app asks for
another.

### `POST /attest`: once per App Attest key

```json
{"keyID": "<the key ID from generateKey(), as is (base64)>",
 "attestation": "<attestKey's result, base64>",
 "challenge": "<a fresh challenge>"}
```

`attestation` comes from
`DCAppAttestService.shared.attestKey(keyID, clientDataHash: SHA256(Data(challenge.utf8)))`.

| Status | Meaning |
|---|---|
| `204` | attested; the key can sign requests |
| `400` | malformed |
| `401` | challenge unknown, expired or used, or the attestation didn't verify |
| `409` | this key is already attested |
| `429` | over `MAX_KEYS_PER_IP_PER_DAY`, with `Retry-After` the seconds until midnight UTC |

### `POST /activities`: register or replace a countdown

The body is JSON, written by a plain `JSONEncoder`:

```json
{
  "token": "<the activity's push token, hex>",
  "environment": "sandbox | production",
  "selection": {"stationID":"R34","routes":["R"],"direction":"N",
                "elevatorAlerts":false,"serviceAlerts":true,"walkMinutes":0},
  "trip": "<ContentState.trip>",
  "started": 814058304.3,
  "alertKinds": [0, 1, 2, 3],
  "state": {"train":814058484.0,"trip":"091200_R..N","isLive":true,
            "following":[814058844.0],"updated":814058304.3}
}
```

`selection` is `JSONEncoder().encode(selection)`. `started` is optional, and
so is `alertKinds` (`AppSettings.alertKinds`). `environment` is APNs's
environment, not App Attest's. `state` is optional too: the countdown's
`ContentState` as the app last posted it, `JSONEncoder().encode(state)`. With
it, the first push moves on from the train the countdown shows, as every
later push does; without it, the first push is to `trip`, or once that has
gone, to the first train you can reach from now. A countdown registered again
with a new push token is often past its first train, so send it then.

`change` is optional: a Transfers widget's countdown sends its `Change`,
`JSONEncoder().encode(change)`, e.g. `{"stationID":"R31","routes":["D","N"],...}`.
The countdown then mentions the changed-to lines' alerts at the change, going
their way, as well as its own train's. One that's no longer a change for
`selection`'s train is dropped rather than refused.

`widgetToken` is optional: the phone's WidgetKit push token
(`WidgetCenter.shared.currentPushInfo?.token`), hex. With it, each time a push
gives the countdown another train, its train another minute or liveness, or a
following train coming, going or moving `PUSH_FOLLOWING_SECONDS` or more, the
server also sends that phone a widgets push (topic
`<bundle ID>.push-type.widgets`, from `APNS_TOPIC`), so its Next train and
Transfers widgets reload and show the same times (they read them from
`GET /activities/<token>/state`). Not for a move on to the next train between
passes, which the widgets make themselves. One APNs no longer knows is
forgotten, and the countdown's pushes go on.

Headers:

```
Content-Type: application/json
X-Attest-Key: <keyID>
X-Attest-Challenge: <a fresh challenge>
X-Attest-Assertion: <base64 of generateAssertion(keyID, clientDataHash: SHA256(clientData))>
```

`clientData` is the UTF-8 bytes of four lines, joined by `\n`, with no newline
at the end:

```
<challenge>
POST
/activities
<lowercase hex SHA-256 of the exact body bytes sent>
```

| Status | Meaning |
|---|---|
| `204` | saved |
| `400` | malformed; a `widgetToken` that isn't hex; a station or line that doesn't exist; a `walkMinutes` outside 0-180; a `trip` over 256 bytes; or a `state` bigger than the app posts: its `trip`, `terminal` or `notice` over 256 bytes, its `route` over 16, more than 10 `following` trains or `followingRoutes`, or a line in `followingRoutes` over 16 bytes |
| `401` | not signed, signed for something else, an old counter, a used challenge, or a key attested in an environment `ATTEST_ENVIRONMENT` no longer allows |
| `403` | the token belongs to another key |
| `503` | `MAX_REGISTRATIONS` reached (a key at `MAX_REGISTRATIONS_PER_KEY` still registers, dropping its oldest) |

### `GET /activities/<token>/state`: the countdown's times, for the phone's widgets

Unsigned, as widgets can't sign requests: the push token, which only APNs and
the phone know, is what it takes. The answer is the `ContentState` last pushed
to the countdown, as ActivityKit decodes it (dates in seconds since 2001), and
nothing about whose it is.

| Status | Meaning |
|---|---|
| `200` | its last pushed state |
| `400` | the token isn't hex |
| `404` | no such countdown, or nothing pushed to it yet |

### `DELETE /activities/<token>`: stop pushing to a countdown

This takes the same three headers. The path is `/activities/` followed by the
lowercase hex token, exactly as in the request line. The method is `DELETE`,
and the body is empty, so its hash is
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

| Status | Meaning |
|---|---|
| `204` | deleted, or already gone |
| `403` | another key registered it |

### `POST /diagnostics`: a crash or hang report, from a phone sharing diagnostics

Sent by the app (`ios/App/Diagnostics.swift`) only once Share Diagnostics is on
in its Settings: a MetricKit report from the launch after a crash, hang, CPU or
disk-write exception, or slow launch, with the app's own recent log lines. It's
signed like `POST /activities`, with the path `/diagnostics`, and is at most
512 KB:

```json
{
  "kind": "crash",
  "app": "1.0 (3)",
  "os": "iOS Version 27.1 (Build 24B5)",
  "device": "iPhone17,1",
  "metricKit": { "crashDiagnostics": [ … ] },
  "log": "2026-11-01T14:03:22Z notice PushServer: …\n…"
}
```

`kind` is `crash`, `hang`, `cpu`, `disk` or `launch`; `metricKit` is
`MXDiagnosticPayload.jsonRepresentation()`. Each is saved, as sent, to
`DATA_DIR/diagnostics/<UTC time>-<kind>-<random>.json`, readable only by the
server's user, and deleted after 30 days. There's no route to read them: look
in that folder.

| Status | Meaning |
|---|---|
| `204` | saved |
| `400` | not a report as above |
| `413` | over 512 KB |
| `429` | over `DIAGNOSTICS_PER_KEY_PER_DAY`, with `Retry-After` until midnight UTC |

### In the app, in order

1. **Once per install:**
   1. `keyID = try await DCAppAttestService.shared.generateKey()`, then keep `keyID` in the Keychain.
   2. Get a challenge.
   3. Call `attestKey(keyID, clientDataHash: SHA256(challenge.utf8))`.
   4. `POST /attest`. Treat `409` as success.
2. **To start a countdown**, after `Activity.request(…, pushType: .token)` gives a push token:
   1. Get a challenge.
   2. Encode the body.
   3. Build `clientData` and call `generateAssertion`.
   4. `POST /activities`.
3. **When the push token changes**, do step 2 again with the new token and
   the countdown's state as it is now, then DELETE the old one.
4. **When the countdown ends:**
   1. Get a challenge.
   2. Sign `DELETE /activities/<token>` with an empty body.
   3. Send the DELETE.
5. **On `401`**, retry once with a fresh challenge. If that fails too, the key
   may be gone: keys unused for 90 days are forgotten. Generate and attest a
   new key, then retry.

Assertions must be made one at a time, so each counter is above the last.

### `ATTEST_MODE=off`

Instead of the `X-Attest-*` headers, send `Authorization: Bearer $API_SECRET`.
The `/attest` routes then answer `404`.

```sh
curl -X POST "https://$HOST/activities" -H "Authorization: Bearer $API_SECRET" \
  -H 'Content-Type: application/json' -d @registration.json
curl -X DELETE "https://$HOST/activities/$TOKEN" -H "Authorization: Bearer $API_SECRET"
```

## Privacy

The database holds only what pushing needs:

- **Each countdown:** its push token, station and lines, trip, start time and
  last state (pushed, or as the app sent it), the phone's widget push token if
  sent, and which key registered it. Its
  row is deleted when the countdown ends (8 h), is deleted by the app, or APNs
  says the token is gone.
- **Each attest key:** its ID, public key, counter, environment, and when it
  was made and last used. It's deleted after 90 days unused, along with
  anything it registered.

Crash and hang reports, from people who turn on Share Diagnostics, are files
in `DATA_DIR/diagnostics/` beside the database, deleted after 30 days. Each
holds the app's version, the iOS version, the iPhone model, MetricKit's report
(call stacks and the like) and the app's last log lines, which never say where
someone is or is going. Nothing in a report says which phone or key sent it.

`GET /routes` plans a trip on the server, sending its start and end to no one,
and keeps the routes found for 2 minutes in memory, under the start and end to
about 10 m, with nothing about who asked.
`GET /buses` passes the stop's place and line to MTA Bus Time, and keeps the
stop it finds for a day and its buses for 30 seconds, with nothing about who
asked. `GET /buses/nearby` passes Bus Time where you are, rounded to about
100 m, and keeps the same. `GET /docks` sends Citi Bike nothing about who
asked or where.

No IP addresses are stored. Logs show tokens only by their first 8
characters, and key IDs and IPs only as keyed hashes that change on every
restart.

## Install, operate, update

It runs on macOS 14 or later, and builds with Swift 6.2 or later, which the
dependencies need (Xcode 26, which needs macOS 15.6 or later). It builds only
on macOS, whose SDK has the `SQLite3` module it uses for the system's
libsqlite3.

    sudo ./deploy/install.sh

The first run does the setup, then stops before starting the daemon:

1. It creates the user and installs into `/usr/local/traintimes`. That and
   the program are root's; only `data/`, `server.log` and the .p8 key are
   `traintimes`'s, and the script never recurses into or follows them.
2. It has newsyslog rotate `server.log`
   (`/etc/newsyslog.d/com.traintimes.server.conf`).
3. It puts the plist in `/Library/LaunchDaemons`.

You then:

1. Copy the .p8 in:
   `sudo install -o traintimes -m 600 AuthKey_….p8 /usr/local/traintimes/`.
2. Replace the plist's `XXXX`s.
3. Run the script again to start the daemon.

A plist from before App Attest still works, with the defaults above. Delete
its `API_SECRET`. The script keeps an installed plist, so one from before log
rotation needs `LOG_FILE` added (the script reminds you). Delete its
`RATE_LIMIT_BURST` too, so the burst follows the rate.

- **Logs:** `tail -f /usr/local/traintimes/server.log`. The log and the plist
  are readable by the admin group (mode 640), for the admin app in `mac/`; the
  key and the database aren't. It has one line per pass with its totals
  (and how many attest keys there are), and a line for each registration,
  drop and error.
  Refused requests get at most 20 lines a minute, and the errors of a full
  server (`MAX_REGISTRATIONS` reached) 20 more; the count
  of the rest is logged with the next one.
  newsyslog rotates the log once it's over 10 MB, keeping 7 old ones
  (`server.log.0` is the newest).
- **Backup:** `traintimes.sqlite` is in WAL mode. Copy it with SQLite's online
  backup, which is safe while the server runs:

      sudo sqlite3 /usr/local/traintimes/data/traintimes.sqlite ".backup '/path/to/traintimes-backup.sqlite'"

  To restore:
  1. `sudo launchctl bootout system/com.traintimes.server`.
  2. Copy the backup over `traintimes.sqlite`. Delete any `-wal` and `-shm`
     files, then `chown traintimes` it, mode 600.
  3. Run `sudo ./deploy/install.sh`.

  A lost database only means apps have to attest again and re-register, which
  they do on their next `401`.
- **Update:** `git pull`, then `sudo ./deploy/install.sh`. It rebuilds, swaps
  in the new binary and restarts the daemon, keeping the plist and the
  database. An old `registrations.json` in `DATA_DIR` is moved into the
  database once, then deleted. The countdown's state is the app's own type
  (`ios/Shared/Countdown.swift`), and running countdowns and the database
  hold states made before an update, so a field added to it must be
  optional; update the server before releasing an app that sends one.
  The subway and bus timetables it downloads itself, but its bus stops' lines
  (`bus_stop_lines.json`) are built in: after the MTA's new bus schedules,
  make it again (the repo's README, "Where the data comes from") and update.
  Until then, countdowns at stops new in them are refused, each logged as
  "bus countdown refused: stop … not in bus_stop_lines.json" with its lines.
  After editing the plist, reload it:

      sudo launchctl bootout system/com.traintimes.server
      sudo ./deploy/install.sh

- **Testing APNs:** `send-test` pushes a sample countdown (train in 5 min) to
  one token, using the APNs settings above:

      APNS_KEY_PATH=… APNS_KEY_ID=… APNS_TEAM_ID=XUU899AG4D \
        "$(swift build -c release --show-bin-path)/TrainTimesServer" send-test --token <hex> --environment sandbox

- **Tests:** `swift test`. They include real App Attest attestations and an
  assertion recorded by
  [node-app-attest](https://github.com/uebelack/node-app-attest) (MIT),
  checked against Apple's root.
