# TrainTimesServer

Keeps the app's Lock Screen countdown (its Live Activity) up to date while the
app isn't running, for each countdown registered with it by its push token.
Every `POLL_SECONDS` the server reads the MTA's feeds with the app's own code
(`Sources/TrainCore/Shared` links to `../ios/Shared`). It sends an ActivityKit
push through APNs when the train's time, the train, the next trains or the
notice change, plus a low-priority refresh every 5 minutes. After 8 hours it
ends the countdown, as iOS would.

Requests that change registrations are signed with App Attest, so only the
genuine app on a real device can make them.

**The app doesn't register its countdowns yet.** It doesn't ask iOS for a
countdown's push token and has no App Attest code, so a running server has
nothing to push to, and the countdown still gets new times only while the app
runs. [In the app, in order](#in-the-app-in-order) is what the app will need to
do. It will also need the Push Notifications capability, and
`NSSupportsLiveActivitiesFrequentUpdates` in its Info.plist, or iOS will
throttle the server's high-priority pushes.

**Only builds signed by one team can use it**: the team whose APNs key it has
(`APNS_TEAM_ID`), with the bundle ID that `APP_ID` and `APNS_TOPIC` name. That's
a build from Xcode with a paid developer account, or from TestFlight or the App
Store. Installs from AltStore with a free Apple ID, as the
[main README](../README.md) describes, can't use it: a free account can't have
push notifications, and AltStore signs each install under its owner's own team,
which gives it another App ID.

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
| `APNS_TOPIC` | `com.rtrainwidget.app.push-type.liveactivity` | |
| `DATA_DIR` | required | holds `traintimes.sqlite` |
| `ATTEST_MODE` | `on` | `off` is for development only, e.g. the simulator; it then needs `API_SECRET` |
| `ATTEST_ENVIRONMENT` | `production` | `development` (builds from Xcode), `production` (TestFlight, App Store) or `both` |
| `APP_ID` | `XUU899AG4D.com.rtrainwidget.app` | the App ID App Attest checks |
| `API_SECRET` | | only with `ATTEST_MODE=off`; at least 16 characters |
| `HOST` | `127.0.0.1` | |
| `PORT` | `8080` | |
| `POLL_SECONDS` | `30` | a pass that runs over skips ticks; passes never overlap |
| `PUSH_CONCURRENCY` | `100` | pushes in flight at once, over the shared HTTP/2 APNs clients |
| `MAX_REGISTRATIONS` | `100000` | in all |
| `MAX_REGISTRATIONS_PER_KEY` | `5` | live countdowns per attest key; registering one more drops that key's oldest |
| `RATE_LIMIT_PER_MINUTE` | `30` | per client address, on every route |
| `RATE_LIMIT_BURST` | same as per minute | the deploy plist leaves it out, so it follows `RATE_LIMIT_PER_MINUTE` |
| `MAX_CHALLENGES` | `10000` | outstanding challenges, in all |
| `MAX_CHALLENGES_PER_IP` | `10` | outstanding challenges per client address |
| `MAX_KEYS_PER_IP_PER_DAY` | `10` | keys attested per client address per UTC day; attestations that fail don't count |
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

### `GET /attest/challenge`

`200` with `{"challenge":"<43 characters, base64url>","expiresIn":300}`, and
`Cache-Control: no-store`. Each challenge can be used once, within 5 minutes.
A client with `MAX_CHALLENGES_PER_IP` outstanding gets `429`, with
`Retry-After` the seconds until the first of them expires. The server answers
`503` when `MAX_CHALLENGES` are outstanding in all.

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
| `400` | malformed; a station or line that doesn't exist; a `walkMinutes` outside 0-180; a `trip` over 256 bytes; or a `state` bigger than the app posts: its `trip`, `terminal` or `notice` over 256 bytes, its `route` over 16, more than 10 `following` trains or `followingRoutes`, or a line in `followingRoutes` over 16 bytes |
| `401` | not signed, signed for something else, an old counter, a used challenge, or a key attested in an environment `ATTEST_ENVIRONMENT` no longer allows |
| `403` | the token belongs to another key |
| `503` | `MAX_REGISTRATIONS` reached (a key at `MAX_REGISTRATIONS_PER_KEY` still registers, dropping its oldest) |

### `DELETE /activities/<token>`: stop pushing to a countdown

This takes the same three headers. The path is `/activities/` followed by the
lowercase hex token, exactly as in the request line. The method is `DELETE`,
and the body is empty, so its hash is
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

| Status | Meaning |
|---|---|
| `204` | deleted, or already gone |
| `403` | another key registered it |

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
  last state (pushed, or as the app sent it), and which key registered it. Its
  row is deleted when the countdown ends (8 h), is deleted by the app, or APNs
  says the token is gone.
- **Each attest key:** its ID, public key, counter, environment, and when it
  was made and last used. It's deleted after 90 days unused, along with
  anything it registered.

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

- **Logs:** `sudo tail -f /usr/local/traintimes/server.log`. It has one line
  per pass with its totals, and a line for each registration, drop and error.
  Refused requests get at most 20 lines a minute, and the errors of a full
  server (`MAX_CHALLENGES` or `MAX_REGISTRATIONS` reached) 20 more; the count
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
  optional; update the server before releasing an app that sends one. After
  editing the plist, reload it:

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
