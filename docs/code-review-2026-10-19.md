# TrainTimes code review

A review of the whole repository at commit `9be9058` (19 October 2026): the iOS app, widgets and Live Activity, the shared feed code, the push server, the Python tools, the Scriptable script and CI. It looks for duplicated code, bugs, optimizations, and related problems with robustness, accessibility, tests and docs.

## Status after fixing (20 October 2026)

The fixes are on branch `claude/codebase-review-jsby0y`. Each group of fixes was reviewed by a second agent told to find what it broke, and the branch then had four more review rounds; each finding was checked by two more agents, one reproducing it and one trying to refute it. The server's tests (359 now, up from 85) pass on Linux with Swift 6.2.1, and CI built the app and widget after every merge.

**171 of the 174 issues are fixed.** The other three:

- [#102](#102-skipped-stops-and-cancelled-trips-in-the-feed-are-not-recognised) (skipped stops and cancelled trips) is unchanged. None of the 45 captured MTA feeds has one, so there was nothing to check a fix against.
- [#107](#107-dimmed-screen-countdown-handling-exists-only-for-lock-screen-accessories-not-the-small-widget-in-standby-or-the-live-activity-on-the-always-on-lock-screen) (the countdown on a dimmed screen in StandBy and the Live Activity) is unchanged. It needs a device to see what iOS does there.
- [#136](#136-line-bullets-and-their-letters-never-scale-with-dynamic-type-app-station-rows-direction-step-widgets) is partly fixed. The bullets in the train and change pickers and the Transfers header grow with Dynamic Type. The widgets' other bullets keep their size, because the layouts around them are measured to fit.

**Bugs found while fixing**, which the review missed:

- The server bundled its station lists as symlinks, which SwiftPM copies as links that don't resolve, so on macOS the server loaded no stations at all. It now keeps copies, which `tools/make_stations.py` and `make_lines.py` write and CI checks.
- The MTA names a station's two directions once for all its lines. On the Broadway el (M11–M18) those are the J's, and the M runs the other way there, so choosing the M toward Manhattan at Marcy Av showed trains to Middle Village. The same goes for the G at Hoyt-Schermerhorn Sts. `stations.json` now lists which lines run the other way. The M is named by its own trains, and the J, Z and M can be chosen together toward Manhattan.
- The H ends at H19, Broad Channel's shuttle platform, which the station list lacked. Its trains ending there were listed as leaving, headed "Manhattan".
- The server reworked each alert's text for every countdown on every pass, about 6.5 s a pass at 10,000 countdowns. It now does it once a pass.
- Platforms that no elevator serves still fetched the outage feed and could say "Couldn't load elevators".

**Changes riders will notice:**

- "Now" shows in every column.
- Shuttles are spoken by name.
- The app's Nearby rows are ordered and named as the Trains near you widget's are.
- The countdown's notice uses each alert kind's symbol.
- The widget buttons flash when tapped rather than staying lit.
- Lines that never reach Manhattan are headed for where they go.
- Add a Change lists the stops of every chosen line.

**CI and release:**

- A push to `main` builds a new version only when it changes the app or how it's published. Running the workflow by hand publishes too.
- Each build gets its own release, `v1.0.N`. The `latest` release takes its files, but its tag isn't moved.
- The server builds and tests in `build-server.yml`.

## How it was done

- **Finding.** Sixteen reviewers each took one slice of the code or one cross-cutting lens: duplication within the app, duplication across app, server and tools, concurrency and time, and performance and robustness. A completeness critic then sent five more reviewers after areas nobody had covered.
- **Verifying.** A separate verifier checked every finding against the code and was told to refute it. Each high-severity finding got a second, independent verifier.
- **What was run.** The server package was built with Swift 6.2.1 on Linux, using a small SQLite shim, and its 85 tests were run. Several findings were proven with throwaway tests there; the denial-of-service in [#1](#1-a-single-small-post-attest-can-tie-up-a-cpu-core-for-minutes-to-hours-app-attest-accepts-an-unbounded-certificate-chain) was reproduced with timings. Reviewers also ran the decoders and filters against live MTA feeds and `stations.json`.
- **What wasn't run.** Without Xcode the iOS code couldn't be compiled. Findings in the app and widgets come from reading the code, with layout widths worked out from the fonts and frames the code uses.

287 reports were merged into the **174 distinct issues** below: 2 high, 41 medium and 131 low. Four are marked uncertain. Another 21 claims were refuted and are listed in the appendix so nobody chases them again.

| Section | Issues | High | Medium | Low |
|---|---:|---:|---:|---:|
| Security | 4 | 1 | 1 | 2 |
| Bugs | 68 | 1 | 28 | 39 |
| Duplicated code | 21 | | 2 | 19 |
| Optimizations | 6 | | | 6 |
| Robustness | 26 | | 2 | 24 |
| Accessibility | 13 | | 1 | 12 |
| Tests, CI and release | 22 | | 4 | 18 |
| Documentation drift | 10 | | 3 | 7 |
| Dead code | 4 | | | 4 |

## Fix these first

1. **Anyone can hang the push server** [#1](#1-a-single-small-post-attest-can-tie-up-a-cpu-core-for-minutes-to-hours-app-attest-accepts-an-unbounded-certificate-chain). POST `/attest` accepts any number of `x5c` certificates, and chain building is factorial in them: 8 certificates in a 2.9 KB body cost 297 s of CPU. The fix is one line: require exactly two.
2. **Trains that end at your stop are shown as trains leaving it** [#5](#5-trains-that-end-at-your-stop-are-listed-as-trains-leaving-it). This affects widgets, the Live tab, the countdown, transfers and server pushes. Drop arrivals at a trip's last stop, in one shared helper.
3. **Transfers pair you with the wrong trains:**
   - The connecting line's direction letter is assumed to match yours [#13](#13-transfers-assume-the-connecting-line-runs-the-same-ns-direction-so-some-changes-pair-you-with-trains-going-the-wrong-way).
   - The walk is judged per line instead of per platform [#9](#9-across-the-platform-and-walk-time-are-judged-per-line-not-by-the-platforms-the-two-trains-actually-use).
   - Lines that end at the change station are offered [#10](#10-add-a-change-offers-lines-that-end-at-the-change-station-so-the-transfers-widget-pairs-you-with-terminating-trains).
   - Free transfers within a complex can't be set up [#8](#8-a-change-cant-be-set-up-between-differently-named-stations-in-one-complex-eg-lexington-av59-st-to-the-456).
   - A change survives moving the station past it [#12](#12-moving-a-widgets-station-past-its-change-station-keeps-the-change-leaving-the-transfers-widget-permanently-empty).
4. **The Lock Screen countdown:**
   - It re-applies the whole walking time once your train has gone [#17](#17-once-the-tracked-train-has-gone-refresh-re-applies-the-full-walking-time-and-skips-trains-you-can-still-reach).
   - It can start from an hour-old board while saying "Updated now" [#16](#16-a-countdown-can-start-from-a-saved-board-up-to-an-hour-old-while-showing-updated-now).
5. **Feed freshness:**
   - Stale feeds are treated as live because the feed timestamp is never read [#6](#6-a-stale-mta-feed-is-shown-as-live-because-the-feeds-own-timestamp-is-never-checked).
   - Held trains vanish at their arrival time because departure times are ignored [#7](#7-a-train-held-at-the-platform-disappears-at-its-arrival-time-minutes-before-it-actually-leaves).
6. **Failures are hidden or make things worse:**
   - A failed widget reload throws away good trains [#19](#19-a-failed-widget-reload-throws-away-the-trains-it-had-and-shows-couldnt-reach-the-mta-retrying-every-2-minutes).
   - The app keeps old times with no warning [#28](#28-live-tab-station-and-transfer-pages-keep-stale-times-after-a-partial-feed-failure-with-no-warning) [#29](#29-train-page-hides-failed-refreshes-once-loaded-so-old-times-run-out-into-no-trains-predicted).
7. **Saved data can be lost:**
   - A `widgets.json` decode failure wipes every widget [#100](#100-any-widgetsjson-decode-failure-silently-wipes-every-saved-widget).
   - Every launch re-saves validated widgets, so a missing station turns trains into Prospect Av for good [#31](#31-every-app-launch-saves-the-validated-widgets-back-to-disk-so-a-missing-station-or-a-stationsjson-that-fails-to-load-permanently-replaces-saved-trains-with-prospect-av).
   - Favorites are reset the same way [#115](#115-favoritesstore-replaces-every-favorite-with-the-default-widgets-train-and-saves-that-whenever-the-saved-list-fails-to-decode).
8. **Widgets don't fit:**
   - Times of 10:00 or later overflow the Transfers rows and cut off the small widget's countdown [#27](#27-transfers-rows-and-next-change-card-come-out-wider-than-the-widget-at-the-default-text-size-with-1000-times-all-day-with-a-24-hour-clock-the-layout-shifts-the-map-button-overlaps--and-at-xlarge-digits-are-cut-off) [#23](#23-small-widget-the-main-countdown-is-cut-to--when-the-later-column-holds-a-1000-timetable-time-semini-at-default-size-for-multi-line-widgets-every-small-widget-at-larger-text-the-live-later-time-is-measured-at-14-pt-but-drawn-in-dynamic-type-footnote).
   - Five or more line bullets stack into a tall header [#21](#21-five-or-more-line-bullets-stack-two-to-a-row-making-widget-headers-tall-enough-to-clip-the-countdown).
   - Trains near you shows "–" for busy lines before its next reload [#24](#24-trains-near-you-keeps-only-4-trains-per-direction-but-draws-30-minutes-of-entries-so-busy-lines-show--before-the-next-reload).
9. **Before the app starts registering countdowns with the server:**
   - One bad row crash-loops the server at startup [#101](#101-one-undecodable-registration-row-stops-the-server-starting-and-launchd-restarts-it-into-the-same-failure).
   - A failed alerts fetch makes the notice flicker with two priority-10 pushes [#32](#32-a-failed-alerts-or-outages-fetch-makes-the-server-push-the-notice-away-and-then-back-two-priority-10-pushes-each-time).
   - The stale date has drifted from the app's [#18](#18-servers-countdown-stale-date-train--2-min-no-longer-matches-the-apps-train-and-tests-lock-in-the-old-value).
   - The challenge pool can be exhausted from one IPv6 /64 [#2](#2-a-few-clients-can-fill-the-global-challenge-cap-and-lock-everyone-out-of-attestation-and-ipv6-address-rotation-bypasses-every-per-ip-limit).
10. **Tests and CI:**
    - The server's tests don't compile on Swift 6.2 [#142](#142-server-tests-dont-compile-on-swift-62-the-authdata--chain-in-attesttestsupportswift-is-too-complex-to-type-check).
    - CI never builds or tests the server, which compiles 8 app files in Swift 6 mode [#141](#141-ci-never-builds-or-tests-the-server-which-compiles-shared-app-files-in-swift-6-mode-and-nothing-runs-before-merge).
    - An older CI run can overwrite the newer release [#140](#140-ci-has-no-concurrency-control-so-an-older-or-re-run-build-can-replace-the-newer-latest-release).

## Duplicated code at a glance

The two duplicates that matter most cross the app/server boundary:

- **The countdown logic is hand-copied into the server** [#74](#74-the-countdowns-content-state-state-building-logic-and-train-id-format-are-hand-copied-into-the-server). This covers the content state, how the next train is picked, the no-trains case, the 8-hour limit and the train id format. The copy has already drifted in the stale date [#18](#18-servers-countdown-stale-date-train--2-min-no-longer-matches-the-apps-train-and-tests-lock-in-the-old-value).
- **The fetch → decode → filter → sort → once-per-trip pipeline exists four times** [#73](#73-the-train-feed-fetch-and-filter-pipeline-is-written-several-times-in-trainservice-and-again-in-the-servers-poller-which-also-copies-its-private-helpers): three times in `TrainService` and again in `Poller.liveBoards`, which also copies three private helpers.

Moving both into framework-free shared files, which the server already symlinks, removes the drift risk. Inside the app the repeats are smaller but numerous, and several have drifted:

- Minutes-to-go text in 6+ places with different zero labels [#89](#89-minutes-to-go-and-other-small-widget-helpers-are-re-implemented-in-several-places).
- Line-bullet drawing four times [#88](#88-line-bullet-drawing-is-written-four-times).
- The polling loop on four screens [#82](#82-polling-and-refresh-code-is-copy-pasted-across-the-live-tab-station-transfer-and-train-pages).
- The platform line chooser twice [#83](#83-the-platform-by-platform-line-chooser-is-written-twice-and-the-change-version-ignores-step-free-mode).
- The across-the-platform/express rule twice [#76](#76-the-change-picker-re-implements-changes-across-the-platform-and-express-rules).
- Nearby's directions in the app and the widget, now ordered and labelled differently [#75](#75-nearbys-every-line-both-ways-logic-is-copied-between-widget-and-app-which-now-order-and-label-directions-differently).
- Alert presentation [#77](#77-alert-and-elevator-notice-handling-is-duplicated-across-boardnotice-the-nearby-widget-alertssheet-and-traindetail).
- Live/scheduled marks [#93](#93-the-livescheduled-mark-rule-and-mark-views-are-written-separately-on-every-surface).
- Spoken line names [#92](#92-spoken-line-names-are-built-separately-in-5-places-and-have-drifted-shuttles-are-all-s-train-and-a-train-may-be-read-as-the-article).

Each entry below names its severity and area, the IDs it merges, where the code is, what was verified, and a suggested fix.

## Security (4: 1 high, 1 medium, 2 low)

### 1. A single small POST /attest can tie up a CPU core for minutes to hours: App Attest accepts an unbounded certificate chain

**High** · Push server · CF15

**Where:** `server/Sources/TrainCore/AppAttest.swift:117`, `server/Sources/TrainCore/AppAttest.swift:141`, `server/Sources/TrainCore/HTTP.swift:148`

AppAttest.swift:117 accepts any x5c with 2 or more certs and :141 passes all but the leaf to swift-certificates 1.21.0 Verifier.validate, whose chain search is unbounded and exponential in attacker-supplied same-subject/same-key look-alike intermediates and never checks for cancellation. Against the real verifyAttestation I measured ~2x cost per added certificate layer, reaching 20.6 s of CPU at an ~13 KB POST /attest body (under the 16 KB attestBodyLimit), extrapolating to minutes near the limit, and always ending in untrustedChain so no other check can short-circuit it. An unauthenticated caller (free challenge + 10 keys/IP/day, both consumed before verify) can thus spend attacker-controlled CPU per request and, across a few IPs, saturate the Mac mini's cooperative executor and starve the HTTP routes and the Poller.

**Reproduced:** Reproduced with a Swift test against the scratch server build (Linux, debug): an attestation whose x5c is a leaf plus N certificates sharing one subject name and one P-256 key but each with a distinct SAN (so swift-certificates 1.21.0's RFC 4158 loop check, which compares subject+key+SAN, does not prune them) makes Verifier.validate explore ~N! partial chains. Timings: N=5 0.34 s, N=6 3.0 s, N=7 29.5 s, N=8 297 s, with request bodies of 2.0-2.9 KB. POST /attest (HTTP.swift:130-151) needs only a free challenge and one of MAX_KEYS_PER_IP_PER_DAY slots before calling verifyAttestation, which runs synchronously on a cooperative-pool thread. N=10 (~3.6 KB) would be hours per request; a handful of requests stalls HTTP and the Poller.

**Fix:** In AppAttest.swift:117 change the guard from `x5c.count >= 2` to `x5c.count == 2`, matching Apple's format of credCert + App Attest intermediate (confirmed: the recorded fixtures' x5c CBOR header is 0x82). This leaves the DFS at most one candidate path. Add a regression test that an attestation with 3+ x5c entries throws Problem.malformed. Optionally also require `certificates[1].issuer == appleRoot.subject`, and/or wrap verifyAttestation in a request timeout, though bounding x5c is the primary fix.

### 2. A few clients can fill the global challenge cap and lock everyone out of attestation, and IPv6 address rotation bypasses every per-IP limit

**Medium** · Push server · CF16

**Where:** `server/Sources/TrainCore/Limits.swift:77-90`, `server/Sources/TrainCore/Limits.swift:115-122`, `server/Sources/TrainCore/Limits.swift:38-41`, `server/Sources/TrainCore/HTTP.swift:121-129`

ChallengeStore.issue (server/Sources/TrainCore/Limits.swift:77-89) caps only the global number of outstanding challenges (MAX_CHALLENGES, default 10000) and has no per-client share. The only per-client control, the RateLimiter, is keyed by ClientIP.resolve (Limits.swift:115-121) on the full CF-Connecting-IP string, which for IPv6 is the whole /128. A single host with an IPv6 /64 can therefore rotate addresses and fill the store. Verified end to end with default limits: 333 addresses from one /64 obtained 10000 challenges in about 16 s with no 429s, and a fresh client then got 503 from GET /attest/challenge (HTTP.swift:121-125). That blocks attestation (HTTP.swift:139) and every authenticated POST/DELETE /activities (HTTP.swift:250) for as long as the flood runs. The same /128 keying gives every rotated address a fresh MAX_KEYS_PER_IP_PER_DAY allowance (verified: 100 of 100 granted across one /64). An IPv4-only attacker at the default 30/min limit needs about 56 addresses just to fill the store, but only degrades service at that size (legitimate success about 56% with 56 addresses, 16% with 300). Near-total denial over IPv4 takes hundreds of addresses, while over IPv6 it is trivial.

**Fix:** Normalize limiter keys: in ClientIP.resolve, or in a separate helper used for the RateLimiter and DailyLimiter keys, parse the address (inet_pton or SocketAddress) and map IPv6 to its /64 (or /56) prefix, keeping IPv4 as is. In ChallengeStore, track outstanding challenges per normalized client key and cap them at a small number, for example 5-10, passing context.clientIP from the route. Return a distinct result so a client over its own cap gets 429 with Retry-After, and keep 503 only for the global cap. Better still, make challenges stateless: issue an HMAC over (timestamp, nonce, optionally the client prefix) and keep only a short-lived set of consumed challenges to stop replay, so issuance no longer depends on a shared global pool that one client can exhaust.

### 3. Keys attested in an environment the server no longer allows keep authorizing requests

**Low** · Push server · CF20

**Where:** `server/Sources/TrainCore/HTTP.swift:255-273`, `server/Sources/TrainCore/AppAttest.swift:173-195`, `server/Sources/TrainCore/Registrations.swift:332-342`

Narrowing ATTEST_ENVIRONMENT (e.g. both → production) doesn't revoke keys that were already attested. Nothing reads the stored `AttestKey.environment` after attestation except a log line (server/Sources/TrainCore/HTTP.swift:156). Neither `HTTPRoutes.authenticate` (HTTP.swift:242-273) nor `AppAttest.verifyAssertion` (server/Sources/TrainCore/AppAttest.swift:173-195) compares it with the configured environments. So development keys keep authorizing POST/DELETE /activities until they go 90 days unused. This contradicts the AuthMode doc at server/Sources/TrainCore/Config.swift:22 ('assertions, from keys attested in these environments').

**Fix:** In authenticate, right after `guard let key = try await services.store.key(id: keyID)`, add `guard services.attest.environments.contains(key.environment) else { log("auth: key \(Redact.id(keyID)) from \(key.environment.rawValue), not allowed", context); return nil }`. Add an HTTPTests case: attest a key with environments [.development, .production], rebuild the services with [.production], and expect 401.

### 4. install.sh runs recursive chown/chmod as root inside a directory the service user owns, so planted links can reach root files

**Low** · Push server · CF17

**Where:** `server/deploy/install.sh:43`, `server/deploy/install.sh:51`, `server/deploy/install.sh:54-57`, `server/deploy/com.traintimes.server.plist:158-161`

server/deploy/install.sh:54 makes all of /usr/local/traintimes owned by the unprivileged `traintimes` user. Root then operates inside that tree on every rerun: :43 `install -d -m 700 $PREFIX/data` and :55 `chmod 700 ... $PREFIX/data` chmod a symlink's target, :51 `touch server.log` creates a symlink's target, :57 `find ... -name '*.p8' -exec chmod 600` follows symlinks, and :54/:56 `chown -R`/`chmod -R go-rwx` change hard-linked inodes. The launchd log path (server/deploy/com.traintimes.server.plist:72-75, not 158-161) is also in that directory. A compromised daemon could plant links so that the admin's next routine `sudo ./deploy/install.sh` changes the ownership or mode of root files, or creates new ones, possibly escalating to root.

**Fix:** Make $PREFIX, the binary and the bundle root:wheel (dirs 755, binary 755). Create $PREFIX/data with `install -d -o traintimes -m 700` only when it's missing, and never recurse into it as root. Keep the .p8 as root:traintimes 640 (or traintimes 600) in the root-owned directory, and chmod it with `find ... -type f`. Move StandardOutPath/StandardErrorPath to a root-owned directory such as /Library/Logs/TrainTimes/ (pre-created as a traintimes-owned file in that root-owned directory). Drop `chown -R`/`chmod -R` on $PREFIX.

## Bugs (68: 1 high, 28 medium, 39 low)

### 5. Trains that end at your stop are listed as trains leaving it

**High** · Trains and feeds · AF1

**Where:** `ios/Shared/SubwayFeed.swift:186-210`, `ios/Shared/TrainService.swift:89`, `ios/Shared/TrainService.swift:118-121`, `ios/Shared/TrainService.swift:200`, `server/Sources/TrainCore/Poller.swift:247`, `ios/Widget/NearbyWidget.swift:169-185`, `ios/App/LiveView.swift:575-596`

Trains whose trip ends at the chosen platform are reported as departures in that direction. SubwayFeed.tripUpdate (ios/Shared/SubwayFeed.swift:186-209) creates an Arrival at the trip's last stop. No consumer drops arrivals where stop == lastStop: TrainService.board(for:) :89, board(for:change:) :118 and :120, trains(for:) :200, and Poller.liveBoards (server/Sources/TrainCore/Poller.swift:247). The Nearby widget (ios/Widget/NearbyWidget.swift:169-185) and the Live tab's NearbyLineRow (ios/App/LiveView.swift:575-596) take directions from platform-level names, so a line that ends at a shared platform gets a row made only of trains that end there. Checked with live feeds on 2026-10-19 at 19:41 UTC through the real decoder and the real Poller.liveBoards:
- C at 168 St "207 St": 15 of 15 end at 168 St.
- R and M at Forest Hills "Jamaica" (the widget labels it "Queens"): 22 of 22 and 16 of 16.
- 6 at Brooklyn Bridge "Downtown": 26 of 26.
- C at Euclid Av, G at Church Av, W at Whitehall: all end there.
- E,F,M,R toward Jamaica at Forest Hills: 38 of 81 end there.
The B at 145 St depends on the time of day (0 of 14 at this check).

**Fix:** 1. Add a computed `var endsHere: Bool { stop == lastStop }` to Arrival. Codable is unaffected.
2. Exclude `endsHere` arrivals in the origin filters at TrainService.swift:89, :118 and :200, in the change-departures filter at :120, and in Poller.swift:247. Use one shared helper so the server cannot drift from the app.
3. Keep the atChange arrivals (:122) unfiltered, because your own train may end at the change station.
4. Also drop the Nearby direction where the line itself ends: NearbyLine.init in NearbyWidget.swift and NearbyLineRow.directions in LiveView.swift. Station order in lines.json can tell this, as can a per-line check that the platform is the line's first or last stop. Without this, those rows show as empty instead of disappearing.

### 6. A stale MTA feed is shown as live because the feed's own timestamp is never checked

**Medium** · Trains and feeds · CF41

**Where:** `ios/Shared/SubwayFeed.swift:72-96`, `ios/Shared/TrainService.swift:235-244`, `server/Sources/TrainCore/Poller.swift:278-283`, `scriptable/Next R Train.js:101-131`

No consumer reads the GTFS-rt FeedHeader.timestamp (FeedMessage field 1, FeedHeader field 3). SubwayFeed.arrivals (ios/Shared/SubwayFeed.swift:72-96) and stops(after:) skip the header, TrainService and Poller.liveBoards accept any HTTP 200 body, and the Scriptable script (scriptable/Next R Train.js:102-131) does the same. If an MTA feed keeps serving an old snapshot, the widgets, app, Siri, countdown, server pushes and script all keep showing its predictions as live (isLive from is_assigned), labelled "Updated" with the fetch time, until each predicted time passes. Nothing marks the data as stale.

**Fix:** In SubwayFeed.arrivals, handle top-level field 1 by reading the nested message and keeping field 3 (timestamp) as a varint. Return it, or throw a `FeedError.stale` when `now - timestamp > ~180 s` (allowing some clock skew). TrainService and Poller then treat a stale own-line feed as failed, as they do for a missing feed, and drop stale other-line feeds, which the existing try?/optional paths already handle. In the Scriptable script, read field 1 -> 3 the same way and show the 'couldn't reach the MTA' message when it's stale.

### 7. A train held at the platform disappears at its arrival time, minutes before it actually leaves

**Medium** · Trains and feeds · AF2

**Where:** `ios/Shared/SubwayFeed.swift:187-193`, `ios/Shared/TrainService.swift:89`, `ios/Shared/TrainService.swift:118-121`, `ios/Shared/Change.swift:91-94`, `server/Sources/TrainCore/Poller.swift:247`

The decoder keeps only the arrival time (ios/Shared/SubwayFeed.swift:188), and every board filters on `time > now` (ios/Shared/TrainService.swift:89, :118, :120, :200; server/Sources/TrainCore/Poller.swift:247). So a train held at the platform disappears at its arrival time, although the numbered-lines feed predicts a later departure. In today's feed this is mostly 20-30 s (trivial), but there are 120-330 s holds at 238 St 103N, Mets-Willets Pt 702N, Queensboro Plaza 718S and Hunts Point Av 613N. A live 1 train stopped at 103N with departure +55 s was dropped. Change.connections (ios/Shared/Change.swift:91-94) also tests the connecting train's arrival rather than its departure, so it can skip a held connecting train and overstate the wait. The lettered feeds give arrival == departure and are unaffected.

**Fix:** Decode departure too and store it on Arrival as `var departs: Date? = nil`, set only when departure > arrival so Codable is unaffected. Add `var leaves: Date { departs ?? time }`. Use `leaves > now` in the 'gone yet?' filters (TrainService :89, :118, :120, :200; Poller :247) and `departure.leaves >= arrival.time + walk` in Change.connections. Keep `time` for display and leave-by countdowns. If a train shown at or after its arrival should read "now", widget timelines that use `time > date` (e.g. NearbyDirection.next) may need the same change.

### 8. A change can't be set up between differently named stations in one complex (e.g. Lexington Av/59 St to the 4/5/6)

**Medium** · Transfers · AF14, BF26

**Where:** `ios/Shared/Stations.swift:178-193`, `ios/Shared/Change.swift:27`, `ios/Shared/Change.swift:41`, `ios/Shared/Change.swift:73`, `ios/App/ChangePicker.swift:38-42`, `ios/Shared/TrainService.swift:143-146`, `ios/App/ChangePicker.swift:111-114`, `ios/Shared/Change.swift:29-42` (+1 more)

Changes are limited to one name-grouped Station. Stations are grouped by (complex, name) at ios/Shared/Stations.swift:178-193. Change.departureStops and validated use only that station's platforms and routes (ios/Shared/Change.swift:27, 41, 73), and ChangePicker offers only that station's lines (ios/App/ChangePicker.swift:38-42, 111-114). So the 17 complexes whose connected platforms have different names can't be used for a change. Examples are Lexington Av/59 St (N R W) to 59 St (4 5 6), Jackson Hts-Roosevelt Av to 74 St-Broadway (7), Court St (R) to Borough Hall (2 3 4 5), Times Sq-42 St to 42 St-Port Authority, and 14 St (A C E) to 8 Av (L). R riders see only N/W at Lexington Av/59 St, and Court St isn't listed at all.

**Fix:** Add `StationDirectory.stations(inComplex:)`. In changeLines, add the routes of the complex's other stations to `others`. Have Change resolve departureStops and validation against every platform of `station.complex`, e.g. a `complexPlatforms` helper used by departureStops, isAcross and validated. Lines on another named station are never across, so they already count walkMinutes.

Also reported as: BF26 (Add a Change can't express common free transfers between differently named stations in one complex).

### 9. Across-the-platform and walk time are judged per line, not by the platforms the two trains actually use

**Medium** · Transfers · AF13

**Where:** `ios/Shared/Change.swift:30-32`, `ios/Shared/Change.swift:46-65`, `ios/Shared/Change.swift:91-94`, `ios/Widget/RTrainWidget.swift:1098`, `ios/App/ChangePicker.swift:233-235`

Whether a change is across the platform, and the walk counted in the wait, depend on the line, not on the platforms the two trains actually use (ios/Shared/Change.swift:46-48, 63-65, 91-94; ios/Widget/RTrainWidget.swift:1098, 1122; ios/App/ChangePicker.swift:38-41, 233-235). (a) A multi-line selection whose lines reach the change station on different platforms gets no walk for lines on only one of them. Example: N+Q southbound from 14 St-Union Sq changing to the D at Atlantic Av. A Q arriving at D24S is paired with a D leaving R31S 30 s later, shown as a highlighted '1 min' quick change marked EXPRESS. (b) If the change includes lines on several platforms and a connecting train is rerouted onto another of those platforms (an N at D24N for a change to [N, Q]), its wait still has no walk and the widget says 'across the platform'.

**Fix:** In `connections`, compute the walk per pair: `let walk = departure.stop.dropLast() == arrival.stop.dropLast() ? 0 : TimeInterval(walkMinutes * 60)` and use it in the `departures.first` predicate. In RTrainWidget.howToChange, compare `next.stop.dropLast()` with `connection.arrival.stop.dropLast()` instead of calling `isAcross(next.route, ...)`. For the fixed EXPRESS/across labels (isAllAcross, isExpress, ChangePicker), count a route as across only if it shares a platform with every platform in `arrivalPlatforms(for:)`, or if it is reached that way by each selected line.

### 10. Add a Change offers lines that end at the change station, so the Transfers widget pairs you with terminating trains

**Medium** · Transfers · BF25

**Where:** `ios/App/ChangePicker.swift:38-42`, `ios/App/ChangePicker.swift:186-188`, `ios/App/ChangePicker.swift:253-268`, `ios/Shared/Change.swift:40-42`, `ios/Shared/TrainService.swift:119-121`

The change picker (ios/App/ChangePicker.swift:38-42 and 186-188, kept by ios/Shared/Change.swift:69-75) offers lines at the change station that have no departures in the train's direction. Change.departureStops (Change.swift:40-42) forces that direction. TrainService.board(for:change:) (ios/Shared/TrainService.swift:119-121) does not exclude trips that end at that stop. So, for example, a Flushing-bound 7 changing to the G at Court Sq (G22N), an uptown 1/2/3, N/Q/R/W or Queens-bound 7 changing to the S at Times Sq (902N), a downtown 4/5/6 or Hudson Yards-bound 7 changing to the S at Grand Central (901S), or a Manhattan-bound C changing to the FS at Franklin Av (S01N) is paired with trains arriving to end their run. The Transfers widget then shows the wrong waits.

**Fix:** In TrainService.board(for:change:), add `&& $0.stop != $0.lastStop` to the departures filter, so a train ending its run there never counts as a departure. In changeLines(at:from:), ChangeLinesStep.platforms and Change.validated(for:), also drop routes where `station.directionName(selection.direction, of: route).isEmpty`.

### 11. Cutting station names at the first hyphen mangles labels like '47-50 Sts' to '47' and 'Hoyt-Schermerhorn' to 'HOYT'

**Medium** · Transfers · AF74

**Where:** `ios/Widget/RTrainWidget.swift:1108`, `ios/Widget/TransferMap.swift:82`

Two identical copies of 'name up to the first hyphen' (ios/Widget/RTrainWidget.swift:1108 for the large Transfers widget's column label, ios/Widget/TransferMap.swift:82 for the change label drawn at :112) cut any hyphenated name whose first part is a single word. This is not limited to numbered names. Change-capable stations affected: 47-50 Sts-Rockefeller Ctr → '47', 174-175 Sts → '174', 182-183 Sts → '182', Broadway-Lafayette St → 'BROADWAY', Hoyt-Schermerhorn Sts → 'HOYT', Myrtle-Wyckoff Avs → 'MYRTLE', Smith-9 Sts → 'SMITH', Astoria-Ditmars Blvd → 'ASTORIA'. Example: an M widget changing at 47-50 Sts to the B/D reads 'M → 47' and '47'.

**Fix:** Add one Shared helper, e.g. `extension Station { static func label(_ name: String) -> String }`: split at the first hyphen only when the part before it contains a space; otherwise return the whole name. Over all 100 hyphenated names in stations.json, this keeps 'Atlantic Av', 'Times Sq', '14 St' and 'Jay St', and returns the full name for all 23 single-word cases ('47-50 Sts-Rockefeller Ctr', 'Hoyt-Schermerhorn Sts', 'Broadway-Lafayette St' and so on). Alternatively, precompute a `label` field in tools/make_stations.py. Use the helper at RTrainWidget.swift:1108 and TransferMap.swift:82, and add a test covering '47-50 Sts-Rockefeller Ctr', 'Hoyt-Schermerhorn Sts', '174-175 Sts' and 'Atlantic Av-Barclays Ctr'.

### 12. Moving a widget's station past its change station keeps the change, leaving the Transfers widget permanently empty

**Medium** · Transfers · BF24, AF18

**Where:** `ios/App/WidgetsView.swift:306-312`, `ios/Shared/Change.swift:69-75`, `ios/Widget/RTrainWidget.swift:1002-1004`, `ios/Shared/Change.swift:67-75`

ios/App/WidgetsView.swift:304-312 keeps a widget's (or its commuting hours') change when only the station is re-picked, and Change.validated(for:) at ios/Shared/Change.swift:69-75 never checks that the change station is still after the new station on the train's way. Example: R from Prospect Av, Manhattan-bound, changing at Atlantic Av-Barclays Ctr. Re-picking DeKalb Av or Court St (still R, still Manhattan-bound) keeps the change. Change.connections (Change.swift:83-97, guard at :90) then never pairs a train, and the Transfers widget permanently shows "No R trains to Atlantic Av-Barclays Ctr predicted" (RTrainWidget.swift:1002-1004), while the editor shows the change as valid. The same applies to the commuting-hours change, since that TripSections is reused at WidgetsView.swift:424.

**Fix:** In Change.validated(for:), return nil when the change station is not ahead of selection.station on the selection's line. Use lines.json order: for each label in selection.routes, take the min lineStops index over each station's platforms that serve selection.routes. For .north the change index must be less than the station's; for .south it must be greater. If no order is known (the label is missing from lineStops, or an empty map in a bundle without lines.json), keep the change. This needs a small internal accessor next to StationDirectory.inLineOrder (Stations.swift:164), because lineStops is private. A simpler alternative is to clear the change in TripSections whenever old.stationID != new.stationID. Either way, SavedWidgets.validated() then also repairs already-saved widgets on load.

Also reported as: AF18 (A change is kept after the origin station moves past it, leaving the Transfers widget permanently empty).

### 13. Transfers assume the connecting line runs the same N/S direction, so some changes pair you with trains going the wrong way

**Medium** · Transfers · AF11

**Where:** `ios/Shared/Change.swift:39-42`, `ios/Shared/TrainService.swift:107-109`, `ios/App/LiveView.swift:40-42`, `ios/App/WidgetsView.swift:471`

The direction of the line you change to is always the same N/S letter as your own train (ios/Shared/Change.swift:41; ios/App/LiveView.swift:41; ios/App/WidgetsView.swift:471). GTFS N/S is set per line, so at some stations this pairs your train with the change line going the wrong way, with no way to pick the other direction. Example: an L toward Manhattan changing to the J/Z at Broadway Junction is paired only with Jamaica-bound J/Z trains (J27N), and the widget summary reads 'J or Z Jamaica'. A northbound G changing to the 7 at Court Sq gets only Flushing-bound 7s (719N), though most such riders want Manhattan (719S). The same applies to J/Z changes at Canal St, Fulton St and Delancey-Essex.

**Fix:** Add `var direction: Direction?` to `Change`. Decode it with decodeIfPresent and fall back to `selection.direction` when it is nil. Use `change.direction ?? selection.direction` in `departureStops`, `TransferPage.changeTrain` and `ChangeRow.subtitle`. In ChangeLinesStep, pick the default as the direction whose `directionName` on the change line's platform matches the rider's heading (e.g. both contain 'Manhattan'), fall back to the rider's letter, and show a direction toggle when the two platforms' labels disagree.

### 14. Transfers widget map keeps the train at its fetch-time position for the whole timeline

**Medium** · Transfers · AF45

**Where:** `ios/Widget/RTrainWidget.swift:245-256`, `ios/Widget/RTrainWidget.swift:197-218`, `ios/Widget/RTrainWidget.swift:199-210`, `ios/Widget/RTrainWidget.swift:879-883`, `ios/Widget/StopList.swift:114`, `ios/Widget/TransferMap.swift:252`, `ios/Widget/TransferMap.swift:275-287`, `ios/Shared/SubwayFeed.swift:58-60` (+7 more)

Next train drops the feed's train position once it is a minute old (ios/Widget/RTrainWidget.swift:199, 210). The Transfers path's `shown(_:at:selection:keepsStops:)` (ios/Widget/RTrainWidget.swift:245-256) never does, for `first`, `arrival` or `next`. `Arrival.place(now:)` prefers `position` over time (ios/Shared/SubwayFeed.swift:58-60), so two things stay at the fetch-time position in every per-minute entry until the next reload. One is the medium Transfers map's stop list and "N STOPS AWAY" (RTrainWidget.swift:881-882 -> StopList.swift:114). The other is the large Transfers map's "D at 36 St" note (ios/Widget/TransferMap.swift:252, 275-276). The large map's own-train marker moves correctly, because it goes by times.

**Fix:** Pass `fetched: board.fetched` into `shown(_:at:selection:keepsStops:fetched:)`. When `date.timeIntervalSince(fetched) > 60`, set `connection.first.position = nil`, `connection.arrival.position = nil` and `connection.next?.position = nil`. Better, pull the 'strip stops / drop stale position' step into one helper and call it from both the `trains` map and `shown`.

### 15. Elevator outages are matched to the whole station complex, so widgets report outages for elevators that don't serve your line

**Medium** · Alerts and elevator outages · AF12

**Where:** `ios/Shared/Outages.swift:50-53`, `ios/Shared/Outages.swift:21-27`, `tools/make_stations.py:66-81`, `ios/Shared/TrainService.swift:24-27`

Outages are matched by station complex only. ios/Shared/Outages.swift:50-53 checks machine.complex == complex, and equipment.json keeps no per-elevator lines or stops (tools/make_stations.py:66-81 drops linesservedbyelevator and elevatorsgtfsstopid). Board.notice (ios/Shared/TrainService.swift:24-27) therefore reports "Elevator out" for ADA elevators that don't serve the selection's lines. That includes elevators at a differently named station sharing the complex (17 complexes, e.g. 611 Times Sq / Port Authority, 619 Bleecker / Broadway-Lafayette). It affects the widget, Siri and the server's Live Activity (server/Sources/TrainCore/Poller.swift:271-275) whenever elevator alerts are on. Live examples now: EL332 (6 only) flagged on Broadway-Lafayette B/D/F/M, and EL290X (A/C/E) flagged on Times Sq widgets.

**Fix:** 1. In make_stations.py, also emit the elevator's stop ids. Split `elevatorsgtfsstopid` on '/' into "stops", or map `linesservedbyelevator` through route_ids-style token mapping into "routes": S→GS/FS/H by stop, SIR→SI, drop LIRR.
2. Add `stops: [String]?` (or routes) to EquipmentDirectory.Machine and pass it into Outage.
3. In Board.notice (or OutagesFeed.outages with the selection), keep an elevator outage only if its stops are empty/unknown or intersect selection.platforms.map(\.id). Street-to-mezzanine elevators list every platform and keep matching.
4. The app's full list can still show the whole complex, sorted with matching outages first.

### 16. A countdown can start from a saved board up to an hour old while showing 'Updated <now>'

**Medium** · Lock Screen countdown · CF38, BF44, AF37

**Where:** `ios/App/TrainActivityController.swift:73-78`, `ios/App/TrainActivityController.swift:202-225`, `ios/Shared/SharedStore.swift:198-200`, `ios/Shared/SharedStore.swift:212`, `ios/Widget/TrainLiveActivity.swift:101-103`, `ios/App/TrainActivityController.swift:76`, `ios/App/TrainActivityController.swift:222`, `ios/Shared/SharedStore.swift:198` (+4 more)

TrainActivityController.startNow (ios/App/TrainActivityController.swift:76-78) seeds a new Live Activity from SharedStore.loadBoard(for:) (ios/Shared/SharedStore.swift:198-200) with no age check. Boards are pruned only on a later save, relative to that save (SharedStore.swift:212), so the seed can be an hour or more old. state(...) stamps `updated: now` (TrainActivityController.swift:222), so the Lock Screen footer (ios/Widget/TrainLiveActivity.swift:101-103) reads 'Updated <now>'. If the follow-up fetchAll (:103) fails, which is likely on a weak signal, the error is swallowed. The countdown then targets old predictions and an old alert, presented as just updated.

**Fix:** In startNow, use the saved board only if `now.timeIntervalSince(saved.fetched) < 120` (or the widget's 30 s), and otherwise fall through to the quick fetch. Thread the data time into the state: add an `updated:` parameter to state(for:trains:notice:now:following:) and pass `saved.fetched` for the saved-board path, so the footer is honest. Optionally, add `maxAge` to SharedStore.loadBoard.

Also reported as: BF44 (Starting a countdown reuses a saved board of any age and stamps it "Updated <now>"); AF37 (A countdown can start from a saved board up to an hour old yet report "Updated <now>").

### 17. Once the tracked train has gone, refresh re-applies the full walking time and skips trains you can still reach

**Medium** · Lock Screen countdown · CF39, BF43

**Where:** `ios/App/TrainActivityController.swift:202-213`, `ios/App/TrainActivityController.swift:146-154`, `server/Sources/TrainCore/ActivityState.swift:20-32`, `server/Sources/TrainCore/Poller.swift:129-138`, `ios/Widget/TrainLiveActivity.swift:119-129`, `server/Tests/TrainCoreTests/StateBuildingTests.swift:58-61`, `ios/App/TrainActivityController.swift:146`, `ios/App/TrainActivityController.swift:204-213` (+2 more)

Once the tracked trip has left the feed, `TrainActivityController.state(for:trains:notice:now:following:)` (`ios/App/TrainActivityController.swift:204-212`) and its server mirror `ActivityState.state` (`server/Sources/TrainCore/ActivityState.swift:22-31`) fall back to `selection.catchable(upcoming, now:).first`. That applies the full walking time again from 'now'. Meanwhile the on-device `movedOn(at:)` (`ios/Widget/TrainLiveActivity.swift:119-129`) moves to the very next train in `following`, which is not walk-filtered. After a ↻ refresh (`TrainActivityController.swift:146-154`) or a server push (`Poller.swift:129-136`), the countdown jumps from the train `movedOn` showed to a later one. If no remaining train is more than walkMinutes away, state is nil and the countdown says 'No trains predicted', keeps the departed train and has empty `following`, even though reachable trains exist. The only test of this path (`server/Tests/TrainCoreTests/StateBuildingTests.swift:58-61`) uses walkMinutes = 0.

**Fix:** Once a countdown has been running with a tracked trip, don't apply the walk filter again. In both copies, when `trip` is non-empty and not found, use `upcoming.first { $0.time > previousTrain } ?? upcoming.first` instead of `catchable`. Pass the previous state's `train` in: the app has `activity.content.state.train`, and the server has `registration.lastState?.train`. That matches `movedOn`. Keep `catchable` only for the start (trip == nil). Add a StateBuildingTests case with walkMinutes > 0 and a gone tracked trip.

Also reported as: BF43 (Once the tracked train has gone, refresh applies the full walking time from now and skips the train the Lock Screen just moved on to).

### 18. Server's countdown stale date (train + 2 min) no longer matches the app's (train), and tests lock in the old value

**Medium** · Lock Screen countdown · CF1

**Where:** `server/Sources/TrainCore/ActivityState.swift:9-13`, `ios/App/TrainActivityController.swift:188-192`, `ios/Widget/TrainLiveActivity.swift:100-103`, `ios/Widget/TrainLiveActivity.swift:113-130`, `server/Tests/TrainCoreTests/StateBuildingTests.swift:95-97`, `server/Tests/TrainCoreTests/PollerTests.swift:65`, `server/Tests/TrainCoreTests/ContentStateEncodingTests.swift:74`, `ios/Widget/TrainLiveActivity.swift:112-129` (+3 more)

ActivityState.staleDate(for:) (server/Sources/TrainCore/ActivityState.swift:9-13) still returns train + 2 min. The app's TrainActivityController.content(_:) (ios/App/TrainActivityController.swift:190-192) now uses `staleDate: state.train`, and the widget relies on that: TrainLiveActivity.swift:101-103 shows "This train is due", and :113-129 moves on to the following train via movedOn(at:). Countdowns last updated by a server push (Poller.swift:142-144, ServerMain.swift:109-110) are redrawn 2 minutes late, so they sit at 0:00 instead of moving on when the train is due. That shows when no newer push arrives, for example when feeds are down or APNs throttles. StateBuildingTests.swift:95-96, PollerTests.swift:65 and ContentStateEncodingTests.swift:74 assert the drifted value. The bug is latent until the app registers push tokens.

**Fix:** In ActivityState.swift, change staleDate(for:) to return `state.train`, and reword the comment to "Out of date as the train is due (TrainActivityController.content(_:))". Update the tests: StateBuildingTests.swift:95-96 should expect `state(train: 4).train` (now + 4 min) and be renamed. PollerTests.swift:65 should expect `first.state.train`. ContentStateEncodingTests.swift:74 should expect `since1970`.

### 19. A failed widget reload throws away the trains it had and shows 'Couldn't reach the MTA', retrying every 2 minutes

**Medium** · Widgets · AF46, CF43

**Where:** `ios/Widget/RTrainWidget.swift:233`, `ios/Widget/RTrainWidget.swift:105`, `ios/Widget/RTrainWidget.swift:265`, `ios/Shared/SharedStore.swift:198`, `ios/Widget/RTrainWidget.swift:233-237`, `ios/Widget/RTrainWidget.swift:265-284`

In ios/Widget/RTrainWidget.swift:233-237, any failed fetch replaces the widget's whole timeline with a single 'Couldn't reach the MTA' entry. That entry has no trains, no connections and no alert banner, even though the previous timeline still had catchable trains. The last good board is also still in boards.json (SharedStore.swift:198-219, kept up to an hour) and goes unused. With `plan.fetched` nil, `timeline` (RTrainWidget.swift:105) requests another reload every 2 minutes, with no backoff, for as long as fetches keep failing.

**Fix:** Move the entry-building in the `do` body into a helper that takes a `SharedStore.SavedBoard`. In the `catch`: `if let saved = SharedStore.loadBoard(for: selection, change: change)` and it still has catchable trains (or connections, with a change), build the normal entries from `saved` and add a footer such as `problem: "Couldn't update · times from \(saved.fetched.clock)"`. Have the view show that footer alongside the trains instead of in their place. Return the bare error entry only when nothing is catchable. On failure, set the reload to a backoff such as `now + reloadInterval(at: now)` instead of 2 minutes. To respect 'never ones from before ↻', the stale fallback can still be shown after a ↻ tap, as long as it is clearly labelled as old.

Also reported as: CF43 (A failed widget reload throws away the trains it already had and shows "Couldn't reach the MTA").

### 20. Always-On Lock Screen: the rectangular widget reads "Leave in 8:12" with 8:12 the clock time to leave

**Medium** · Widgets · G14

**Where:** `ios/Widget/RTrainWidget.swift:509-513`, `ios/Widget/RTrainWidget.swift:1392-1399`, `ios/Widget/RTrainWidget.swift:496-498`

On the Always-On (dimmed) Lock Screen, lockScreenCountdown (ios/Widget/RTrainWidget.swift:1392-1399) swaps the countdown timer for the wall-clock leave time (`Text(leave.clock)`, format h:mm without AM/PM). The rectangular widget still prefixes it with `Text("Leave in")` when a walking time is set (509-513), so it reads "Leave in 8:12" where 8:12 is a clock time, in the same slot and font as the awake m:ss countdown. Without a walking time it's a bare "8:12" in the countdown slot. The circular widget (496-498) shows a bare clock time under the line letter, likewise indistinguishable from a countdown.

**Fix:** Change the label when dimmed:
- In accessoryRectangular: `if walking { Text(luminanceReduced ? "Leave at" : "Leave in").font(.caption) }`.
- In lockScreenCountdown's luminanceReduced branch: `Text(walking ? leave.clock : "at \(leave.clock)")` (or always prefix "at" there and use "Leave" as the label).
- For accessoryCircular: prefix "at" or add a small `clock` SF Symbol before the time when luminanceReduced, keeping minimumScaleFactor so it fits.

### 21. Five or more line bullets stack two to a row, making widget headers tall enough to clip the countdown

**Medium** · Widgets · AF32

**Where:** `ios/Shared/LineBullet.swift:76-107`, `ios/Shared/LineBullet.swift:83-88`, `ios/Shared/WidgetChoices.swift:3-5`, `ios/Shared/WidgetChoices.swift:18`, `ios/Widget/RTrainWidget.swift:584`, `ios/Widget/RTrainWidget.swift:651`, `ios/Widget/RTrainWidget.swift:1020`, `ios/App/TrainPicker.swift:376` (+2 more)

LineBullets (ios/Shared/LineBullet.swift:98-105) lays out any number of lines from three up as rows of two at 0.6*size with no row limit. Height grows as ceil(n/2)*0.6*size, while width(count:) (LineBullet.swift:83-88) assumes two columns. BulletImage (ios/Shared/WidgetChoices.swift:18-21) uses 3 columns above 4 and always fits a square, so the two have drifted despite BulletImage's doc comment (WidgetChoices.swift:3-5). Choosing 7-9 lines (Atlantic Av, Times Sq, Union Sq, Herald Sq, Fulton St, Canal St, W 4 St) makes the small and medium widget header (ios/Widget/RTrainWidget.swift:651, 86pt for 9 lines) and the Transfers headers (RTrainWidget.swift:896 and :1020) tall enough to clip the countdown and buttons. App rows using LineBullets also grow: TrainPicker.swift:376, WidgetsView.swift:120/478/502, LiveView.swift:388, TrainDetail.swift:116 and Intents.swift:53.

**Fix:** Share one grid rule. In LineBullets, use columns = n <= 4 ? 2 : 3, rows = ceil(n/columns) and bullet = n <= 4 ? size*0.6 : (size*1.2 - 2*2)/3, about 0.39*size. Lay out rows of `columns`, and update width(count:size:) to columns*bullet + (columns-1)*2. Better, factor the columns, rows and bullet computation into one static function and call it from both LineBullets and BulletImage.data(for:). Alternatively, cap the display at 4 bullets plus a '+N' label.

### 22. Live vs timetable is shown only by colour, so tinted and clear Home Screens and StandBy at night drop it; marks aren't forced as they are for Differentiate Without Color

**Medium** · Widgets · G12

**Where:** `ios/Widget/RTrainWidget.swift:336-339`, `ios/Widget/RTrainWidget.swift:682`, `ios/Widget/RTrainWidget.swift:748`, `ios/Widget/RTrainWidget.swift:774-779`, `ios/Widget/RTrainWidget.swift:1497-1500`, `ios/Widget/NearbyWidget.swift:303-309`, `ios/Widget/NearbyWidget.swift:462-469`, `ios/Widget/TransferMap.swift:144`

On tinted and clear Home Screens (widgetRenderingMode .accented), live and timetable times render the same: they differ only by Arrival.statusColor (ios/Widget/RTrainWidget.swift:1499). Live and scheduled marks are added only when Differentiate Without Color or Settings › Mark live times is on (RTrainWidget.swift:337, ios/Widget/NearbyWidget.swift:307), and that setting is off by default (ios/Shared/SharedStore.swift:298).
Affected:
- The next-train countdown.
- The medium and large widgets' later times (748, 774-779).
- Every time in Trains near you (NearbyWidget.swift:462-469), whose view doesn't read the rendering mode at all.
- Transfers times (932, 994, 1063, 1082, 1208; ios/Widget/TransferMap.swift:144).
In StandBy Night Mode (.vibrant, small widget only), a live countdown renders dimmer than a scheduled one. The small widget's LATER train keeps a format cue: live counts down, scheduled shows a clock time.

**Fix:** In TrainWidgetView: `private var marksLive: Bool { withoutColor || renderingMode != .fullColor || entry.settings.marksLiveTimes }`. In NearbyWidgetView, add `@Environment(\.widgetRenderingMode) private var renderingMode` and use the same rule. Also apply marks in the Transfers rows (statusMark or a markSlot). Optionally add `.widgetAccentable(train.isLive)` on the time Texts, so .accented keeps a two-tone cue. Check that the extra mark width doesn't worsen Nearby label truncation on small phones (see G8).

### 23. Small widget: the main countdown is cut to '…' when the LATER column holds a 10:00+ timetable time (SE/mini at default size for multi-line widgets, every small widget at larger text); the live LATER time is measured at 14 pt but drawn in Dynamic Type footnote

**Medium** · Widgets · G6

**Where:** `ios/Widget/RTrainWidget.swift:537-567`, `ios/Widget/RTrainWidget.swift:730-756`, `ios/Widget/RTrainWidget.swift:740`, `ios/Widget/RTrainWidget.swift:717-725`

Small widget (ios/Widget/RTrainWidget.swift:537-567): the timetable LATER time is fixedSize (741-746), so the LATER column always gets its full width. The main countdown, the only compressible child, gets what is left. For a multi-line widget (28-pt countdown plus bullets) with the next train 10 or more minutes away and a 5-character timetable LATER (any time with a 24-hour clock), only about 34-40 pt (SE) or 41-47 pt (mini) of the roughly 82 pt needed remains at the default text size. That is below the 0.6 minimumScaleFactor (1385), so the main countdown truncates; it is borderline on 6.1-inch phones. A single-line widget truncates on SE from xxxLarge. Separately, a live LATER countdown is framed by countdownWidth(size: 14) (740), measured in 14-pt rounded bold, but drawn in Dynamic Type footnote semibold (748). It is scaled to 0.95-0.76 at xL-xxxL and truncates from AX2.

**Fix:** Make the countdown win:
- Give the countdown's inner HStack (549) `.layoutPriority(1)`.
- Replace `.fixedSize()` on the timetable LATER clock (744-745) with `.minimumScaleFactor(0.7)`.
- Wrap the row in `ViewThatFits(in: .horizontal)` with a variant without laterTrain, so LATER is dropped when the countdown can't stay at about 0.75 scale or more. Alternatively, compute the room from countdownWidth and the LATER width and omit `after` when it doesn't fit.
For the live LATER, draw the timer in the font it is measured in: `.font(.system(size: 14, weight: .semibold, design: .rounded))` on the live branch. Or measure it with `UIFont.preferredFont(forTextStyle: .footnote)` at semibold so frame and font agree.

### 24. Trains near you keeps only 4 trains per direction but draws 30 minutes of entries, so busy lines show '–' before the next reload

**Medium** · Widgets · CF40, AF60

**Where:** `ios/Widget/NearbyWidget.swift:183`, `ios/Widget/NearbyWidget.swift:95-98`, `ios/Widget/NearbyWidget.swift:245-247`, `ios/Widget/NearbyWidget.swift:67`, `ios/Widget/RTrainWidget.swift:106-112`, `ios/Widget/RTrainWidget.swift:111`, `ios/Widget/RTrainWidget.swift:232`

ios/Widget/NearbyWidget.swift:183 keeps at most 4 of each line's trains per direction. The timeline at :95-97 has 30 one-minute entries, each showing `NearbyDirection.next(at: entry.date)` (:245-247), and the reload at :67/:98 is fixed at now+5 min by day or now+15 min at night, with no early reload when the kept trains run out (compare RTrainWidget.swift:111). Whenever iOS reloads later than the 4th train's arrival, which is common under the widget budget, a frequent line's direction shows '–' as if no train were coming. The isIdle/'Not running now' folding is worked out only at `now`, so that row stays a normal row showing '–'.

**Fix:** In NearbyLine.init, keep every train due within the timeline's horizon instead of 4, and drop the heavy fields this widget never draws: `let horizon = now.addingTimeInterval(30*60); let own = trains[selection.trainID].map { list -> [Arrival] in var kept = list.filter { $0.route == route }; if let cut = kept.firstIndex(where: { $0.time > horizon }) { kept = Array(kept[...cut]) }; return kept.map { var t = $0; t.approach = []; t.position = nil; return t } }`. Alternatively, keep the cap but compute the earliest last-train time across the shown directions that have trains (`runsOut`), end the entries there and return `.after(max(now+60, min(reload, runsOut)))`, as Provider.timeline does.

Also reported as: AF60 (Trains near you keeps only 4 trains per direction but draws 30 one-minute entries, with no earlier reload when they run out).

### 25. Trains near you never gives back folded lines once farther stations are dropped

**Medium** · Widgets · AF59

**Where:** `ios/Widget/NearbyWidget.swift:275-290`, `ios/Widget/NearbyWidget.swift:142-148`

NearbyLayout.fit (ios/Widget/NearbyWidget.swift:275-290) trims every station with more than 4 rows (leaveOutLastLine, lines 142-148) before dropping the farthest stations, and never restores lines it folded. When dropping stations frees room, the kept station still shows only 4 rows and an "N more lines ›" row, with empty space below.
I reproduced it with the real stations.json:
- Near Times Sq on a 354-pt-tall large widget, the result is Times Sq-42 St alone with 4 of 9 lines and 135 pt empty. All 9 rows (263 pt) would fit.
- Near Grand Central, the S is folded into "1 more line" with 72 pt free.
This contradicts README.md:82.

**Fix:** Choose the station count first, then trim:
```swift
static func fit(_ stations: [NearbyStation], in room: CGFloat) -> [NearbyStation] {
    func total(_ s: [NearbyStation]) -> CGFloat { s.map(\.height).reduce(0, +) + gap * CGFloat(max(s.count - 1, 0)) }
    for count in stride(from: stations.count, through: 1, by: -1) {
        var kept = Array(stations.prefix(count))
        while total(kept) > room, let i = longest(of: kept, over: 4) { kept[i].leaveOutLastLine() }
        if total(kept) <= room { return kept }
        if count == 1 {
            while total(kept) > room, let i = longest(of: kept, over: 1) { kept[i].leaveOutLastLine() }
            return kept
        }
    }
    return []
}
```
Each k starts from untrimmed copies, so lines folded for a larger k come back. Update the doc comment to match.

### 26. Trains near you: two directions per fixed 26-pt row, so direction names truncate at the default size on SE with live marks (Differentiate Without Color), at xLarge on SE/mini, and become just '…' and overlapping rows at accessibility sizes

**Medium** · Widgets · G8

**Where:** `ios/Widget/NearbyWidget.swift:410-419`, `ios/Widget/NearbyWidget.swift:428-452`, `ios/Widget/NearbyWidget.swift:458-485`, `ios/Widget/NearbyWidget.swift:249-270`, `ios/Widget/NearbyWidget.swift:333`

Trains near you puts both directions of a line in one fixed 26-pt row (ios/Widget/NearbyWidget.swift:412-418). Each way's footnote label (433-434, lineLimit 1) gets what's left after a .fixedSize() time (458-483) in about 124 pt (SE) or 132 pt (6.1").
- Direction names truncate at xLarge on SE and mini, and at xxLarge-xxxLarge on all phones (e.g. "Man… 12 min").
- On an SE at the default size, "Manhattan" and "Downtown" are borderline-truncated once a LiveMark is shown. Differentiate Without Color forces the mark (307).
- Row, station-header (405) and small-row (537) heights are fixed. NearbyLayout's constants (249-269) match the drawing, so fit() stays correct. If WidgetKit applies accessibility text sizes, text overflows and overlaps neighbouring rows instead of growing them. The problem label's minHeight (333) can exceed its 22-pt budget there too.

**Fix:** In NearbyWidgetView, read `@Environment(\.dynamicTypeSize)`. Above `.large` (or when marks are on and the way is narrow), either:
- wrap the two way() views in `ViewThatFits(in: .horizontal)` with a fallback that uses short labels ("Up"/"Dn", or arrow symbols with an accessibilityLabel of the full name), or
- cap the widget with `.dynamicTypeSize(...DynamicTypeSize.xxLarge)` on the root VStack, so the fixed NearbyLayout row heights stay valid.
If a stacked one-way-per-line layout is chosen instead, the provider must use the same rule for NearbyLayout.row so fit() stays in step.

### 27. Transfers rows and next-change card come out wider than the widget at the default text size with 10:00+ times (all day with a 24-hour clock); the layout shifts, the map button overlaps ↻, and at xLarge digits are cut off

**Medium** · Widgets · G5

**Where:** `ios/Widget/RTrainWidget.swift:1437-1457`, `ios/Widget/RTrainWidget.swift:888-893`, `ios/Widget/RTrainWidget.swift:941-947`, `ios/Widget/RTrainWidget.swift:1134-1172`, `ios/Widget/RTrainWidget.swift:1200-1221`, `ios/Widget/RTrainWidget.swift:1046-1090`, `ios/Widget/RTrainWidget.swift:853-861`

TransferColumns (ios/Widget/RTrainWidget.swift:1437-1456) never limits the columns to `width`: gap is clamped to at least 6 (1455) even when `used + 18 > width`. The cells in transferRow (1134-1172) and nextCell (1200-1221) are fixedSize in fixed frames, so rows with 5-character times come out wider than the content area:
- Medium transferList (888-893), at the default text size: about 306 pt on a 289-pt SE and on a 297-pt mini, and 317 pt on a 306-pt 6.1-inch phone with its auto-enabled largeText.
- With a 24-hour clock this happens all day.
- The large widget's transferCard times row (1046-1090) overflows on SE and squeezes the ride Capsule to 0 pt on a 6.1-inch phone.
The flexible frame grows to the row's width and the fixed frame at 861 centres it. The times layer, map pill included, shifts left by half the overflow, while ↻ and walk in controlsLayer (438-452) stay put, so the pills misalign or overlap. From xLarge text, the shift passes the 16-pt margin and the edge bullets and digits are clipped.

**Fix:** In TransferColumns.init, compute `needed = used + 3 * 6`. When `needed > width`, drop the arrow and arrival-time columns (expose a `showsArrival` flag that transferRow and transferLabels honour) and recompute. If it is still too wide, scale the row with a common factor, e.g. apply `.minimumScaleFactor` to a single Text built for the trip, or use `.scaleEffect`. An alternative is `ViewThatFits(in: .horizontal)` over the full row and a row without the arrival time, with the outer VStack also given `.frame(width: width, alignment: .leading)` and `.clipped()` so an overflow can never re-centre the layer. In transferCard, give the Capsule `.frame(minWidth: 12)` and drop the arrival time through the same ViewThatFits. Add a unit test that builds TransferColumns with "22:08"-style times at widths 289/297/306 and asserts `used + 3 * gap <= width`.

### 28. Live tab, station and transfer pages keep stale times after a partial feed failure, with no warning

**Medium** · App screens · BF3, CF42

**Where:** `ios/Shared/TrainService.swift:196`, `ios/App/LiveView.swift:365-371`, `ios/App/LiveView.swift:487-493`, `ios/App/LiveView.swift:554-560`, `ios/App/LiveView.swift:256`, `ios/App/LiveView.swift:351`, `ios/App/LiveView.swift:458`, `ios/App/LiveView.swift:697-705` (+6 more)

When some, but not all, of the MTA train feeds fail, the Live tab, StationLive and TransferLive (ios/App/LiveView.swift:365-371, 487-493, 554-560) merge the partial result into their `trains` dictionary. The dictionary keeps the failed selections' previous arrivals, and the failure banner appears only when every selection failed (`fetched.isEmpty`). Stale predictions keep counting down (filters at LiveView.swift:256, 351, 458, 545). Once they pass, the row shows 'No trains' (Minutes, 697-705). A row that never loaded shows '—' and is read as 'Loading' indefinitely. The dictionary is never pruned, so a revisited nearby station can briefly show stale data or 'No trains' until its immediate reload lands.

**Fix:** No change to TrainService is needed, because a selection missing from `fetched` is one that failed. In each view's load(), compute `let failedIDs = Set(selections.map(\.trainID)).subtracting(fetched.keys)`. Then set `trains = fetched`, which also prunes keys that are no longer shown, or keep the old values but track `failedIDs` in @State. Render a per-row 'Couldn't load' (and a matching VoiceOver value) for IDs in `failedIDs` instead of '—' or 'No trains'. Show the 'Couldn't reach the MTA' banner when `!failedIDs.isEmpty`, not only when `fetched.isEmpty`.

Also reported as: CF42 (Live tab, station and transfer pages keep stale times after a partial failure, with no warning).

### 29. Train page hides failed refreshes once loaded, so old times run out into 'No trains predicted'

**Medium** · App screens · BF2

**Where:** `ios/App/TrainDetail.swift:307-310`, `ios/App/TrainDetail.swift:140-148`, `ios/App/TrainDetail.swift:36`

ios/App/TrainDetail.swift:307-310: after the first successful load, failed refreshes (30 s loop :82-87, pull-to-refresh :80) are swallowed because `.failed` is set only when `board == nil`. Nothing on the page shows when the times were fetched or that the update failed. Old live predictions stay green (TrainRow :330) and keep counting down, and `trains` (:36) drops each one as `now` passes it. Once none are left, trainsSection (:146-147) says 'No <lines> trains predicted' when the MTA in fact couldn't be reached. The same text also appears when the board has trains but none can be reached with the walking time, because `trains` is `selection.catchable(...)`. The Live tab (ios/App/LiveView.swift:244-246, :371) does show a 'Couldn't reach the MTA' banner when a refresh fails with trains already on screen.

**Fix:** Add `@State var lastUpdated: Date?` and `@State var refreshFailed = false`. On success, set `lastUpdated = .now` and `refreshFailed = false`. In the catch, when `!Task.isCancelled` and `board != nil`, set `refreshFailed = true`. In trainsSection, while `refreshFailed`, show 'Couldn't update. Times from \(Spoken.clock(lastUpdated))' above the rows. Split the empty case: `board?.trains.isEmpty == true` means 'No X trains predicted', and non-empty board trains with an empty `trains` means 'No X train you can reach in time'.

### 30. Train page: a load for the previous train can overwrite the newly picked train's times and alerts

**Medium** · App screens · BF1, CF37

**Where:** `ios/App/TrainDetail.swift:82-87`, `ios/App/TrainDetail.swift:98-106`, `ios/App/TrainDetail.swift:290-311`, `ios/Shared/TrainService.swift:247-265`, `ios/App/TrainDetail.swift:98-107`, `ios/App/TrainDetail.swift:290-310`, `ios/Shared/TrainService.swift:252-265`

In ios/App/TrainDetail.swift, loadBoard (lines 290-311) assigns its result unconditionally. A load still running for the previous train, which cancellation cannot stop because InFlight.value in ios/Shared/TrainService.swift:247-265 awaits an unstructured Task, can therefore write the old train's board and noticesFetched after the picker's setter (lines 98-106) cleared them. At best the old train's times flash under the new heading. In rarer orderings they stay until the next 30 s load, and the old train's alerts and outages are carried over for up to 10 minutes.

**Fix:** In loadBoard, capture `let trainID = selection.trainID` before the await. After `TrainService.board` returns, add `guard !Task.isCancelled, trainID == selection.trainID else { return }` before touching `noticesFetched`, `board` or `loadState`. Also reset `noticesFetched = nil` in the `chosenTrain` setter next to `board = nil`.

Also reported as: CF37 (TrainDetail: a load for the previous train can overwrite the new train's times (fetches can't be cancelled)).

### 31. Every app launch saves the validated widgets back to disk, so a missing station, or a stations.json that fails to load, permanently replaces saved trains with Prospect Av

**Medium** · Saved state · G20

**Where:** `ios/App/WidgetStore.swift:13-17`, `ios/Shared/SharedStore.swift:269-275`, `ios/Shared/SavedWidgets.swift:109-123`, `ios/Shared/Selection.swift:116-122`, `ios/Shared/Change.swift:69-75`, `ios/Shared/Stations.swift:137-141`, `ios/App/FavoritesStore.swift:23-31`

WidgetStore.init (ios/App/WidgetStore.swift:13-17) runs `SharedStore.saveWidgets(SharedStore.loadWidgets())` on every app launch, not just the first. loadWidgets returns the validated widgets (ios/Shared/SharedStore.swift:274, ios/Shared/SavedWidgets.swift:109-123), so each launch writes the validation result over widgets.json and selection.json. Validation turns any widget or commute train at an unknown station, or with no remaining chosen line, into `Selection.fallback` (Prospect Av R Manhattan, walk 0, default alerts; ios/Shared/Selection.swift:116-122), and drops changes at unknown stations (ios/Shared/Change.swift:69-75). If a release ships a stations.json that fails to decode, StationDirectory.platforms is silently `[]` (ios/Shared/Stations.swift:137-142). The first launch of that build then permanently rewrites every saved widget's train as Prospect Av and drops every change, and a fixed build can't bring them back. A missing file is already caught by CI's `test -f` checks. A decode mismatch isn't, because CI doesn't run the server test that decodes the same file (StateBuildingTests.swift:10-11). FavoritesStore (ios/App/FavoritesStore.swift:23-31) drops such favorites in memory and persists the shorter list at the next edit.

**Fix:** In WidgetStore.init, save only when widgets.json doesn't exist yet (e.g. add `SharedStore.hasSavedWidgets`), as the comment intends. Better still, keep the decoded, unvalidated widgets in memory, validate them only for display, and write a widget's validated form only when the user edits it. Guard `saveWidgets` (and the FavoritesStore didSet) with `guard !StationDirectory.all.isEmpty else { return }`, and add an `assertionFailure` in StationDirectory when stations.json fails to load. Run `swift test` for server/ in CI before publishing, so the existing stationDataLoadsFromTheResourceBundle test catches a stations.json that won't decode.

### 32. A failed alerts or outages fetch makes the server push the notice away and then back, two priority-10 pushes each time

**Medium** · Push server · CF2, BF63

**Where:** `server/Sources/TrainCore/Poller.swift:221-222`, `server/Sources/TrainCore/Poller.swift:238`, `server/Sources/TrainCore/Poller.swift:256-262`, `server/Sources/TrainCore/Poller.swift:271-275`, `server/Sources/TrainCore/ActivityState.swift:39`, `server/Sources/TrainCore/ActivityState.swift:83`, `ios/Shared/TrainService.swift:24`, `ios/Shared/TrainService.swift:29` (+6 more)

A failed fetch or decode of the alerts or outages feed on the server makes the board's alerts or outages nil (server/Sources/TrainCore/Poller.swift:222, :238, :256-262, :271-275). TrainService.alertEntries caches only successes (ios/Shared/TrainService.swift:214-219, :252-264). Board.notice (ios/Shared/TrainService.swift:24, :29) treats nil as "no alerts or outages", contrary to its own doc comment, so ActivityState.state (server/Sources/TrainCore/ActivityState.swift:39) produces a state whose notice is missing or downgraded. isMeaningful (:83) then yields a priority-10 .update for every affected countdown, and when the feed recovers on the next pass the notice comes back with a second priority-10 push. Users see the "Delays" or "Elevator out" warning disappear and return, and each flap spends two priority-10 pushes per countdown. The widget and the app's refreshNow have the same nil-as-none handling (ios/Widget/RTrainWidget.swift:191 also closes an open alert).

**Fix:** In Poller.pass, after computing `state` (Poller.swift:128-138), if `let last = registration.lastState`, and `(board.alerts == nil && registration.selection.serviceAlerts) || (board.outages == nil && registration.selection.elevatorAlerts)`, and `last.notice != "No trains predicted"`, set `state.notice = last.notice`. Add a PollerTests case: one pass with fixtureBoard() pushes a notice, and a second pass with the same trains and `alerts: nil, outages: nil` yields no .update push and keeps the notice. Optionally apply the same last-known-notice rule in the app's refreshNow and the widget's plan.

Also reported as: BF63 (An alerts or outages fetch failure makes the server push removal of the notice, then push it back).

### 33. make_stations.py drops the entrances of W 4 St, 145 St and Queensboro Plaza

**Medium** · Tools, Scriptable and CI · BF50

**Where:** `tools/make_stations.py:62`, `tools/make_stations.py:103`, `tools/make_stations.py:107-113`, `ios/Shared/Stations.swift:99-101`

tools/make_stations.py:62 keys entrances by the raw `gtfs_stop_id`. In the MTA dataset, three multi-level stations list two ids in one field: "A32; D20" W 4 St-Wash Sq (6 entrances, including its elevator), "A12; D13" 145 St A C/B D (6) and "718; R09" Queensboro Plaza (2). The lookup at :103 uses the single Stations.csv id, so these 14 entrances are dropped silently. The complex fallback at :107-113 finds nothing either, since all platforms in those complexes are empty. ios/Shared/stations.json has `"entrances": []` for exactly these six ids, and the app's station map (ios/App/TrainDetail.swift:279-280) says the MTA doesn't list the entrances of W 4 St, 145 St and Queensboro Plaza.

**Fix:** In entrances_by_stop, change the last line to `for stop in row["gtfs_stop_id"].split(";"): entrances.setdefault(stop.strip(), []).append(entrance)`. Station.init (ios/Shared/Stations.swift:99-101) already dedups entrances across the merged platforms, which share a name and complex here. In main, also print or fail on any entrance key that matches no station id. Then regenerate stations.json.

### 34. Change picker says no trains are running when there is simply no later stop with another line

**Low** · Transfers · BF31

**Where:** `ios/App/ChangePicker.swift:60-63`, `ios/App/ChangePicker.swift:107-118`

In ios/App/ChangePicker.swift:107-118, load() keeps only the later stops that have another line. The view at lines 60-63 then says the trains aren't running when trains are running but no later stop offers a change. Example: a southbound R at Bay Ridge Av, whose later stops 77 St, 86 St and Bay Ridge-95 St are R-only.

**Fix:** Store whether the trip had any stops, e.g. `@State private var anyStops = false`, set from the unfiltered result in load(). When the filtered list is empty but anyStops is true, show 'No stops after \(stationName) have another line to change to.' instead of the 'not running' text.

### 35. Transfers widget ignores Mark live/scheduled times and Differentiate Without Color

**Low** · Transfers · AF48

**Where:** `ios/Widget/RTrainWidget.swift:930`, `ios/Widget/RTrainWidget.swift:992`, `ios/Widget/RTrainWidget.swift:1078`, `ios/Widget/RTrainWidget.swift:1203`

On the Transfers widget, Mark live times, Mark scheduled times and Differentiate Without Color have no effect except on the large widget's big countdown, which goes through `countdownLabel` at ios/Widget/RTrainWidget.swift:1050. These all show live versus timetable by colour alone: the medium rows' countdowns (RTrainWidget.swift:930), the large widget's later 'N min' column (992), the met train's time in `transferCard` (1080) and the met train's time in `nextCell` (1205). Users who rely on the marks (Differentiate Without Color, or tinted and clear Home Screens) can't tell live times from timetable times there.

**Fix:** Draw `statusMark(connection.first, size: size * 0.36)` after the countdown in `mediumTransfers`, and after the minutes in `laterTransfers`. In `nextCell` and `transferCard`, put a mark before `next`'s time using the ZStack slot pattern from `timeAndBullet(markSlot:)`, so the columns stay aligned. When any shown train is marked, widen `TransferColumns.lead` / `nextTime` by the mark's width plus spacing, as `laterTrains` does with `markSlot`.

### 36. Transfers widget's alert countdown and walk button follow the next train at your station, not the next one that reaches the change

**Low** · Transfers · AF57

**Where:** `ios/Widget/RTrainWidget.swift:1357`, `ios/Widget/RTrainWidget.swift:196`, `ios/Widget/RTrainWidget.swift:447`, `ios/App/TrainActivityController.swift:205`

On the Transfers widget, the open alert's countdown (ios/Widget/RTrainWidget.swift:1357-1359, via `next` = `entry.trains.first` at :341) and the walk button's Lock Screen countdown (RTrainWidget.swift:447 → TrainActivityController.startNow → `state(..., following: nil)` → ios/App/TrainActivityController.swift:205) both target the first catchable train at the origin. The rest of the Transfers widget counts down to `entry.connections?.first?.first`, the first train that actually reaches the change. When the next origin train doesn't call at the change (lines that split, a reroute, a short-turn), the two disagree.

**Fix:** In `fullAlert`, count down to `entry.transfers && entry.change != nil ? entry.connections?.first?.first : next`, and show no countdown when that is nil. For the walk button on Transfers, add an optional `trip` parameter to `ToggleCountdownIntent`, set from `entry.connections?.first?.first.trip`. Pass it to `startNow` so the first `state` call uses `following: trip`. For later refreshes to stay on connecting trains, the activity also needs to carry the change.

### 37. Turning on commuting hours drops the widget's change, so the Transfers widget shows 'Add a change' during those hours

**Low** · Transfers · BF33

**Where:** `ios/App/WidgetsView.swift:373-381`, `ios/Shared/SavedWidgets.swift:35-43`, `ios/Widget/RTrainWidget.swift:851-869`

Turning on commuting hours at ios/App/WidgetsView.swift:379 creates CommutingHours with the widget's train but no change. During the default hours (07:00-10:00 Mon-Fri, ios/Shared/SavedWidgets.swift:136-139), SavedWidget.shown(at:) (SavedWidgets.swift:35-43) swaps in commute.change == nil. A Transfers widget that showed connections therefore immediately switches to the 'Add a change of trains…' placeholder (ios/Widget/RTrainWidget.swift:851-869) until the user gives the commute a change of its own or picks hours that do not include now.

**Fix:** Use `widget.commute = on ? CommutingHours(selection: widget.selection, change: widget.change) : nil`. TripSections' onChange (WidgetsView.swift:306-311) clears the copied change once a different line or direction is chosen for the commute. With BF24 fixed, it is also cleared when the new station is past the change.

### 38. When your own train is one of the change lines, the Transfers widget still makes you change to a later train

**Low** · Transfers · AF15

**Where:** `ios/Shared/Change.swift:89-96`, `ios/Shared/Change.swift:69-75`

When a train of one of the change lines runs on the selected line, the Transfers widget pairs it with a later train of the change lines, as if the rider had to change (ios/Shared/Change.swift:89-96, with Selection.shows at ios/Shared/Selection.swift:68-72 letting it into `trains`). Example: an R widget at Prospect Av with a change to D/N at Atlantic Av, when an N runs local and stops at R34N. That N is listed as 'N to Atlantic, wait 9 min, then D' (or a later N), although the rider can stay on it.

**Fix:** In `connections`, when `routes.contains(train.route)`, return `Connection(first: train, arrival: arrival, next: arrival)` (wait 0) and have the widget label it 'stay on'. If that's too much UI work, drop such trains from the Transfers list: `guard !routes.contains(train.route) else { return nil }`.

### 39. A route-wide delay outranks a suspension at your station, and alert kinds don't match the Settings labels

**Low** · Alerts and elevator outages · AF20

**Where:** `ios/Shared/Alerts.swift:6-29`, `ios/Shared/Alerts.swift:152-158`

AlertsFeed.kind(of:) (ios/Shared/Alerts.swift:152-158) files MTA "Planned - Part Suspended" and "Planned - Suspended" under .suspended, so the Settings label "Service changes and planned work" (Alerts.swift:22-29) does not cover planned suspensions. They are controlled by the separate "Suspensions" toggle, so this is only a labelling ambiguity. The real effect is the Kind order delays < suspended (Alerts.swift:6-9), used by alerts(for:) at line 149, by TrainService's notice (first alert) and by NearbyLine (NearbyWidget.swift:195). A route-wide delay alert, which in the live feed carries no stop or direction, outranks a suspension at the user's own station. So a suspended station shows "Delays" instead of "Suspended", contrary to README.md:81.

**Fix:** Add a separate `priority` on Kind (suspended first, then delays, then serviceChange, then notice) and sort by it in alerts(for:) and NearbyLine. Leave the Codable raw values unchanged, since they are persisted in AppSettings.alertKinds and in the server registrations. Reword the settings labels, e.g. "Suspensions, planned or not" and "Service changes and other planned work".

### 40. Alerts with no details still show a disclosure arrow that expands to nothing

**Low** · Alerts and elevator outages · BF16

**Where:** `ios/App/TrainDetail.swift:358-382`

In ios/App/TrainDetail.swift:358-382, AlertRow always shows a DisclosureGroup. For alerts with `period == nil` and empty `details`, which the live feed shows is common for 'Delays' alerts (2 of 3 active ones when checked), expanding it shows only an empty, padded row, so the chevron does nothing useful.

**Fix:** In AlertRow.body, when `alert.period == nil && alert.details.isEmpty`, render the label VStack (kind label and header) alone. Otherwise keep the DisclosureGroup. Pull the label into a computed property so both branches share it.

### 41. Staten Island Railway alerts show a grey 'SIR' bullet instead of the blue SI

**Low** · Alerts and elevator outages · AF16

**Where:** `ios/Shared/Lines.swift:33-35`, `ios/Shared/Alerts.swift:61-63`, `ios/Widget/RTrainWidget.swift:1331`

The MTA alerts feed writes the Staten Island Railway as "[SIR]", but Lines.normalized (ios/Shared/Lines.swift:33-35) maps only 5X/6X/7X/FX. So AlertBrief.routes becomes ["SIR"] (ios/Shared/Alerts.swift:61-63), and the widget draws a grey (0x808183) "SIR" bullet in the delay banner (ios/Widget/RTrainWidget.swift:1291, VoiceOver "SIR train" at :1310). The marked alert text gets the same grey bullet (ios/Widget/RTrainWidget.swift:1331), where the blue "SI" bullet belongs. This happens on SI-station widgets whenever an SIR delay or other alert is active. Today's feed has 8 such alerts, one of them an "Expect Delays".

**Fix:** Change Lines.normalized to ["5X": "5", "6X": "6", "7X": "7", "FX": "F", "SIR": "SI"][route] ?? route. This is harmless for the train and alert route_id paths, which never carry "SIR". Add an AlertBriefTests case: AlertBrief(header: "Fallen leaves may slow [SIR] service")?.routes == ["SI"].

### 42. The MTA's affected-stations list is ignored, so riders upstream of skipped or suspended stops get no alert

**Low** · Alerts and elevator outages · AF21

**Where:** `ios/Shared/Alerts.swift:124-136`, `ios/Shared/Alerts.swift:214-217`

ios/Shared/Alerts.swift ignores the MTA's `transit_realtime.mercury_alert.affected_stations`. Mercury (lines 214-217) does not decode it, and alerts(for:) (lines 124-136) matches only informed_entity. In today's feed, 105 of 182 alerts list affected upstream stations with route, stop and direction, e.g. the Manhattan-bound R skip of R32-R35 lists R36-R45 direction 0. Riders boarding upstream of skipped or suspended stops (e.g. Bay Ridge-95 St, R45, heading for Prospect Av) therefore get no alert in the app, the widget or the Nearby widget.

**Fix:** Add `let affected_stations: [Informed]?` to Mercury, with a CodingKey if needed. Carry it into Entry as `affected: [Informed]`, and in alerts(for:) treat a selection as matched when `informed` or `affected` matches, using the same route, stop and direction rules. Optionally mark such alerts so that only the app's alert list, not the widget banner, shows them, to avoid noisy banners.

### 43. The delay banner's direction text swallows words like 'Some' and matches 'Downtown Brooklyn'

**Low** · Alerts and elevator outages · AF17

**Where:** `ios/Shared/Alerts.swift:68-75`

In AlertBrief.init (ios/Shared/Alerts.swift:68-75), the `-bound` alternative `[A-Z0-9][\w./]*(?:[ -][A-Z0-9][\w./]*)*-bound` absorbs a sentence-initial capitalised quantifier. A live feed header today, "Some Coney Island-Stillwell Av-bound [N] trains will end at Kings Hwy…", gives the direction "Some Coney Island-Stillwell Av-bound", and "Some Manhattan-bound" and "Most Inwood-bound" behave the same way (verified by a Swift test). `[Dd]owntown` also matches the place name "Downtown Brooklyn". The widget's delay banner then shows the wrong direction text.

**Fix:** After the match, strip a leading quantifier, e.g. `words.replacing(#/^(?:Some|Most|All|Many|Several|A few)\s+/#, with: "")`, before capitalising. Change the alternative to `[Dd]owntown(?! Brooklyn)`. Add the live N header and "Some Manhattan-bound" cases to AlertBriefTests.

### 44. Compact Dynamic Island shows live vs timetable by colour only, even with Differentiate Without Color or Mark live/scheduled times

**Low** · Lock Screen countdown · G16

**Where:** `ios/Widget/TrainLiveActivity.swift:47-52`, `ios/Widget/TrainLiveActivity.swift:45-46`, `ios/Widget/TrainLiveActivity.swift:32-34`, `ios/Widget/TrainLiveActivity.swift:77-88`, `ios/Widget/TrainLiveActivity.swift:175-186`

ios/Widget/TrainLiveActivity.swift:47-52: the Dynamic Island's compactTrailing shows the countdown with only a colour difference (liveGreen vs white) for live vs timetable. It omits the LiveMark or ScheduledMark that the Lock Screen banner (lines 77-82) and the expanded island (markedCountdown, line 32) show when marksLive or marksScheduled is true (lines 177-186). That includes when Differentiate Without Color is on, which Settings (ios/App/SettingsView.swift:79-85) says forces the live mark on. compactLeading (45-46) and minimal (53-54) show only the line bullet.

**Fix:** In compactLeading, show the mark beside the bullet, since compactTrailing is capped at 52 pt: `HStack(spacing: 2) { LineBullet(route: trainRoute(context), size: 20); if marksLive(context) { LiveMark(size: 10) } else if marksScheduled(context) { ScheduledMark(size: 10) } }`. Give it the same foregroundStyle as the countdown so the mark carries the status colour too.

### 45. The quick-start countdown ignores an earlier rerouted train that the full fetch finds

**Low** · Lock Screen countdown · BF47

**Where:** `ios/App/TrainActivityController.swift:79-82`, `ios/App/TrainActivityController.swift:101-106`, `ios/App/TrainActivityController.swift:214`

In the quick-start path (ios/App/TrainActivityController.swift:79-82), the first train comes from the chosen lines' own feed group only. The follow-up full-board update (lines 101-106) keeps that trip as the target (line 209) and lists only trains after it (line 214). So an earlier catchable train from another feed group, e.g. a D rerouted onto the R's tracks, is never counted down to or listed. An N on the R is not affected, since it is in the same -nqrw feed. It applies only when no saved board yields a state.

**Fix:** For the follow-up update, choose between the tracked trip and the full board's first catchable train, whichever is sooner. For example: `let first = selection.catchable(board.trains.filter { $0.time > .now }, now: .now).first`, then pass `following: (first.map { $0.time < state.train } ?? false) ? nil : state.trip`. Simpler alternative: pass `following: nil` when the first state came from the quick board, since the user hasn't seen a different train yet.

### 46. The train page's countdown label keeps naming a departed train and never passes its fresh times to the countdown

**Low** · Lock Screen countdown · BF5

**Where:** `ios/App/TrainDetail.swift:166-203`, `ios/App/TrainDetail.swift:293`, `ios/App/TrainActivityController.swift:36-38`, `ios/Widget/TrainLiveActivity.swift:119-129`, `ios/App/RTrainApp.swift:12-16`, `ios/App/TrainActivityController.swift:30-33`, `ios/App/TrainActivityController.swift:35-38`, `ios/App/TrainDetail.swift:29`

ios/App/TrainDetail.swift:169/:293 shows `TrainActivityController.currentTrain(for:)` (ios/App/TrainActivityController.swift:36-38), which is the activity's raw `state.train`. The Lock Screen shows `state.movedOn(at: .now)` (ios/Widget/TrainLiveActivity.swift:119-136, widget target only). After the tracked train leaves, the page keeps naming the departed train while the Lock Screen shows the next one. This lasts until something calls `TrainActivityController.refresh()` (app activation, Settings, or ↻), because the page's 30 s `loadBoard` never updates the activity. Smaller issues: `countdownProblem` (:20) isn't cleared when the picker changes train (:98-107). A `start` that finishes after the train has changed sets `countdownTrain` (:198) for the old train on the new page until the next `loadBoard`. `static var currentTrain` (TrainActivityController.swift:31-33) is dead code.

**Fix:** Move the `movedOn(at:)` extension from ios/Widget/TrainLiveActivity.swift into ios/Shared/TrainActivity.swift. Have `currentTrain(for:)` return `...content.state.movedOn(at: .now).train`. Delete `static var currentTrain`. In the `chosenTrain` setter, set `countdownProblem = nil`. In `startCountdown`, capture `let id = selection.trainID` before the await and assign `countdownTrain` only if `selection.trainID == id`. Optionally, after a successful loadBoard while `countdownTrain != nil`, call `await TrainActivityController.refresh()`.

### 47. With no trains left, the countdown replaces the alert (e.g. 'Suspended') with 'No trains predicted'

**Low** · Lock Screen countdown · BF46

**Where:** `ios/App/TrainActivityController.swift:148-153`, `server/Sources/TrainCore/ActivityState.swift:48-54`

When a refresh finds no train to count down to (ios/App/TrainActivityController.swift:148-153, mirrored in server/Sources/TrainCore/ActivityState.swift:48-54), the countdown's notice is set to "No trains predicted". That discards the alert label the freshly fetched board carries, such as "Suspended", so the Lock Screen and the widgets for the same train give different explanations. Keeping the last train time is documented as intended.

**Fix:** In the else branch, keep the alert when there is one: `state.notice = board.notice(for: selection, settings: SharedStore.loadSettings())?.label ?? "No trains predicted"`. Alternatively, combine the two, e.g. "No trains · Suspended". Make the same change in ActivityState.noTrains, passing it the board and the registration's settings.

### 48. Deleting a saved widget can make an old-style widget fall back to its hidden original train

**Low** (uncertain) · Widgets · AF39

**Where:** `ios/Shared/TrainWidgetIntent.swift:42-49`, `ios/Shared/TrainWidgetIntent.swift:115-121`

In ios/Shared/TrainWidgetIntent.swift:45-48, savedWidget(in:) relies on the `widget` parameter staying non-nil after its saved widget is deleted. SavedWidgetQuery.entities(for:) at lines 116-121 returns nothing for a deleted id. If AppIntents resolves that unresolvable identifier to nil (likely, but not verified here), the following happens to a widget first set up with the hidden legacy station/line/direction/stop parameters and later switched to a saved widget that is then deleted:
- It falls back to earlierTrain(...), its old train, instead of the default widget.
- WidgetStore.countPlaced (ios/App/WidgetStore.swift:63-67) attributes it to no saved widget.

**Fix:** In SavedWidgetQuery.entities(for:), return a placeholder SavedWidgetEntity for a valid UUID that is no longer saved, for example id unchanged, title "Deleted widget", subtitle "Shows the default", routes []. That keeps `widget` non-nil, and savedWidget(in:) already maps an unknown id to saved.defaultWidget. Add an initializer for that on SavedWidgetEntity.

### 49. Lock Screen widgets never show live vs timetable, even with Mark live/scheduled times or Differentiate Without Color

**Low** · Widgets · G17

**Where:** `ios/Widget/RTrainWidget.swift:491-523`, `ios/Widget/RTrainWidget.swift:695-701`

The Lock Screen widget families never mark live or timetable times: accessoryInline (ios/Widget/RTrainWidget.swift:481-490), accessoryCircular (:491-504) and accessoryRectangular (:505-524), including its 'then 8:31, 8:39' list at :518. These families render in vibrant mode, so the green is lost too. Settings › Mark live times, Mark scheduled times and Differentiate Without Color have no effect there, even though the Live Activity on the same Lock Screen honours them (ios/Widget/TrainLiveActivity.swift:77-88, 175-186).

**Fix:** In accessoryRectangular's HStack (:509-514), add `statusMark(next, size: 12)` after `lockScreenCountdown`. For the 'then' list, build a Text that puts `Text(Image(systemName: "clock"))` before each `!isLive` time when `marksScheduled` is on, and the live glyph before live ones when `marksLive` is on. In accessoryCircular, optionally put a small statusMark above the countdown when there is room.

### 50. Not-running lines are counted in 'N more lines' once a station is trimmed for room

**Low** · Widgets · AF63

**Where:** `ios/Widget/NearbyWidget.swift:142-148`, `ios/Widget/NearbyWidget.swift:518-531`, `ios/Widget/NearbyWidget.swift:509-510`

ios/Widget/NearbyWidget.swift:142-148 merges lines left out for room into `folded`, which already holds idle lines, and sets foldedForRoom for the whole small row. foldedLabel (518-531) then counts idle lines in "N more lines ›" without a "Not running now" label. foldedRow (509-510) puts them first on the station page via `first: nearby.folded`.

**Fix:** Split `folded` into `notRunning: [String]` (set in init) and `leftOut: [String]` (appended to by leaveOutLastLine). Show "N more lines ›" with leftOut.count and pass `first: leftOut`. Show notRunning's bullets with "Not running now" after it on the same small row, or on its own row and counted in height. height still adds smallRow once when either list is non-empty.

### 51. Opening the alert on a tinted/clear Home Screen covers the whole widget with a solid block until the reload

**Low** · Widgets · G15

**Where:** `ios/Widget/RTrainWidget.swift:418-426`, `ios/Widget/RTrainWidget.swift:271-275`

ios/Widget/RTrainWidget.swift:421-425: right after a tap opens the alert, and until the timeline reloads, the alert layer draws the opened picture with an opaque `Color.boardBackground` background over the still-present times layer. That background has no non-full-colour branch. In `.accented` rendering (tinted or clear Home Screen) it is drawn as a solid fill in the default-group colour. The alert text, countdown, banner text and button icons are in that same colour and vanish, leaving only accentable parts (the banner's alert symbol and outlined line bullets) visible. The window is short when board() reuses the saved board (RTrainWidget.swift:270-275). It lasts a full network fetch when no train is left to catch, e.g. a suspended line. What happens in `.vibrant` (StandBy night) is unverified.

**Fix:** Draw the opening picture only in full colour. At :421 change `if open || alertOpen` to `if alertOpen || (open && renderingMode == .fullColor)`, and keep the background as `if open && !alertOpen { Color.boardBackground }`. On tinted or clear screens the banner's chevron then flips at once and the times stay visible until the reload brings the alert. An alternative is to erase what is below in non-full-colour modes: add `.compositingGroup()` on the body ZStack (:369) and use `Color.black.blendMode(.destinationOut)` as the background, as StopRail does. That is untested in accented rendering.

### 52. The cached clock formatter ignores time-zone and 12/24-hour changes

**Low** · Widgets · CF46

**Where:** `ios/Widget/RTrainWidget.swift:1502-1518`, `ios/Widget/TrainLiveActivity.swift:195-208`

`Date.clock` (ios/Widget/RTrainWidget.swift:1504-1518) caches one DateFormatter whose `dateFormat` is frozen at first use from the 'jmm' template, with the time zone it found then and no locale or time-zone change observers. Within a living widget-extension process, a 12/24-hour or time-zone change is not reflected in widget times. In the Live Activity summary (ios/Widget/TrainLiveActivity.swift:195-208), the first time (`Spoken.clock`, :198) updates but the later ones (`.clock`, :202) do not. The effect lasts only as long as that one extension process.

**Fix:** Don't cache a frozen pattern. Either compute `DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current)` per call (cheap) and strip a/b/B from it, or keep the cached formatter but set `timeZone = .autoupdatingCurrent` and `locale = .autoupdatingCurrent`, and recompute its stripped pattern in an observer for `NSLocale.currentLocaleDidChangeNotification` and `.NSSystemTimeZoneDidChange`.

### 53. TrainMarker ignores isLive on tinted/clear Home Screens: every train on the map is drawn as the timetable outline

**Low** · Widgets · G13

**Where:** `ios/Widget/StopList.swift:256-268`, `ios/Widget/StopList.swift:278-286`, `ios/Widget/StopList.swift:49`, `ios/Widget/TransferMap.swift:97`, `ios/Widget/TransferMap.swift:100`

TrainMarker's tinted/clear-mode branch (ios/Widget/StopList.swift:260-268) ignores isLive and always draws the outlined letter, which in full colour (278-290) means a timetable time. On tinted Home Screens, the large Transfers map's two markers (ios/Widget/TransferMap.swift:97, 100) and the medium StopList marker (StopList.swift:49) can't show whether a train is live. On the medium list a timetable train still shows its departs time at the first stop, so the real loss is on the Transfers map. The rest of the tinted widget already loses its colour-only live cue.

**Fix:** In the non-fullColor branch, branch on isLive. For a live train, draw a knocked-out disc that survives one-colour rendering:
`Circle().frame(width: size, height: size).overlay(label(style).blendMode(.destinationOut)).compositingGroup().widgetAccentable()`
For a timetable train, keep the current outline (optionally dashed: `Circle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))`). Keep `.accessibilityLabel("\(style.label) train")` on both. StopRail and TrackRails already erase room around the marker.

### 54. Trains near you alert row opens the other direction's alerts, and which alert it shows varies

**Low** · Widgets · AF61, BF22

**Where:** `ios/Widget/NearbyWidget.swift:194-196`, `ios/Widget/NearbyWidget.swift:486-488`, `ios/Shared/Alerts.swift:133`, `ios/App/AlertsSheet.swift:35-37`

ios/Widget/NearbyWidget.swift:195 picks the line's notice from both directions' alerts merged in Dictionary order, so ties between same-kind alerts from different directions resolve differently in each process. The notice row's link (486-488) always uses the first direction's selection. ios/Shared/Alerts.swift:133 (and the N/S stop_id filter at 132) excludes the other direction's alerts, so when both directions have no trains and the displayed alert is specific to the second direction, tapping the row opens a sheet without that alert, possibly reading "No alerts for this line here right now" (ios/App/AlertsSheet.swift:35-37).

**Fix:** In NearbyLine.init, iterate `order` (deterministic) instead of `ways.values`. Find the worst alert together with its direction's selection, e.g. `order.compactMap { d in ways[d].flatMap { w in w.alerts.first.map { ($0, w.selection) } } }.min { $0.0.kind < $1.0.kind }`. min keeps the first of equal kinds, so with `order` the earlier direction wins ties. Store that selection (e.g. `noticeSelection`) and have noticeRow use `line.noticeSelection?.alertsURL`.

Also reported as: BF22 (Nearby widget's alert row opens the alerts of the first direction, which may not include the alert it showed).

### 55. Trains near you dates its entries from before locating and fetching, so minutes run high

**Low** · Widgets · AF65

**Where:** `ios/Widget/NearbyWidget.swift:65-67`, `ios/Widget/NearbyWidget.swift:87`, `ios/Widget/NearbyWidget.swift:95-97`, `ios/Widget/RTrainWidget.swift:194-195`

ios/Widget/NearbyWidget.swift:65 takes `now` before finding you, geocoding and fetching (:69, :76, :87-90). It then uses that `now` for the entries' dates (:68, :95-97), the TrainService `time > now` filter (:87) and the reload time (:67). Entry 0 is first shown seconds to (rarely) ~40 s after its date, so trains that left in that gap can still show as "Now", and minute counts are overstated by the skew. This is unlike Next train, which takes `now` after the fetch (ios/Widget/RTrainWidget.swift:194-195). The impact is minor because entries are already a minute apart.

**Fix:** In `NearbyProvider.plan`, once the awaits are done (after line 90), add `let shownAt = Date.now`. Use `shownAt` for the `.stations` entries' dates (`shownAt.addingTimeInterval(Double(minute) * 60)`) and for `reload`. `NearbyDirection.next(at:)` already filters by entry date, so the fetch's own `now` filter can stay.

### 56. Trains near you shows 'Uptown - Queens' style labels instead of Uptown/Downtown in Manhattan

**Low** · Widgets · AF62

**Where:** `ios/Widget/NearbyWidget.swift:211-218`

ios/Widget/NearbyWidget.swift:211-218 leaves Manhattan direction names joined with " - " unreduced. Rows read "Uptown - Queens" for the A/C/E at 14 St, 23 St, 34 St-Penn, 42 St-PABT, 50 St, Spring St, Canal St and W 4 St, the B/D/F/M at W 4 St and the M/Q at Lexington Av/63 St. They read "Broad St (JZ) - Uptown (M)" for the J/Z/M southbound at Delancey St-Essex St. These labels truncate in the half-row and are not the Uptown/Downtown the README describes for Manhattan.

**Fix:** In `named`, after the " & " cut, if the name's first " - "-separated part is "Uptown" or "Downtown", return just that part. For names with per-line notes, split on " - " and pick the segment whose "(…)" contains the route's letter (e.g. "(M)" for M, "(JZ)" for J/Z), then strip the parenthetical. Leave other " - " names such as "34 St - Hudson Yards" unchanged.

### 57. 'Walking directions in Maps' goes to the platforms' midpoint rather than an entrance

**Low** · App screens · BF17

**Where:** `ios/App/TrainDetail.swift:273`

The 'Walking directions in Maps' link (ios/App/TrainDetail.swift:273) routes to Station.lat/lon. That is the average of the platform coordinates (ios/Shared/Stations.swift:97-98), not an entrance, and it has no name. It is typically about 30 m from the nearest entrance and up to about 160 m at long single-platform stations. At Atlantic Av-Barclays Ctr it is about 71 m from the nearest elevator entrance. The entrance list, with elevator flags, is already available but unused.

**Fix:** Pick a destination from station.entrances: skip exitOnly entrances, and prefer isElevator entrances when step-free matters or settings.stepFree is on. Choose the one nearest the user if their location is known, otherwise the one nearest the station's centre. Fall back to station.lat/lon when the list is empty. Open it named, either with MKMapItem(placemark:) whose name is station.name and openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]), or by adding the name to the URL.

### 58. A widget tap can open the train the page was switched to instead of the tapped train

**Low** · App screens · BF7

**Where:** `ios/App/LiveView.swift:136-142`, `ios/App/LiveView.swift:191-192`, `ios/App/TrainDetail.swift:98-106`

Open train A in the Live tab, either from a Nearby row or from a favorite with walk 0 and default alert flags. Change the page to train B with the picker (TrainDetail.swift:98-106). Then tap A's time on the Nearby widget. LiveView sets path = NavigationPath([A]) (LiveView.swift:191-192), equal to the existing path, and the destination's `.id(selection.trainID)` (LiveView.swift:141) is still A's. SwiftUI keeps the existing TrainDetail, whose @State still shows B, instead of opening A. The page's title shows B, so the user can tell it is the wrong train.

**Fix:** Add `@State private var openings = 0` to LiveView and bump it in the `.train`, `.station` and `.transfer` cases of the onChange(of: opening) handler. Change the destination to `.id("\(selection.trainID) \(openings)")`, so an opening from a widget always builds a fresh TrainDetail even when the path value is equal. Another option is an onChangeTrain callback from TrainDetail that replaces the last path element without animation.

### 59. Siri says no trains are predicted when trains exist but none can be caught, and reads notices as 'Heads up: notice.'

**Low** · App screens · AF42

**Where:** `ios/Shared/Spoken.swift:29-30`, `ios/Shared/Spoken.swift:32-35`, `ios/App/Intents.swift:19-21`

ios/App/Intents.swift:19-21 gives Spoken.nextTrain only the catchable trains and the notice's one-word kind label. When a walking time is set and every predicted train is due before you could reach it, Siri says "There are no <line> trains ... predicted at <station> right now" (ios/Shared/Spoken.swift:29-30), which is false. Any notice is read as "Heads up: <label>." (Spoken.swift:32-35), e.g. "Heads up: notice." or "Heads up: suspended.", and never the alert's headline (Notice.text).

**Fix:** Add a parameter to Spoken.nextTrain for the soonest uncatchable train (or all trains). When catchable is empty but board.trains isn't, say e.g. "You can't make the <clock> R in time at <station>; no later train is predicted yet." For the notice, map Notice.Kind to full phrases ("there's a station notice", "service is suspended", "there are delays", "an elevator is out"), or append brief/text for alerts.

### 60. Station search misses common spellings like '34th street' or 'times square'

**Low** · App screens · BF36

**Where:** `ios/App/TrainPicker.swift:106-114`, `ios/Shared/StopEntity.swift:84-92`

Station search in the picker (ios/App/TrainPicker.swift:106-114) and in the widget configuration's StopQuery (ios/Shared/StopEntity.swift:85-93) is the same naive substring match over the MTA's abbreviated names. Common spellings such as '34th street', 'lexington avenue', 'times square', '42nd' or 'parkway' return no stations, although '34 st', 'times sq' and 'pkwy' work. The duplicated code itself is small (about 5 lines).

**Fix:** Add one shared matcher, for example `extension Station { func matches(_ query: String) -> Bool }` in StopEntity.swift (compiled into both app and widget) or in Stations.swift. It normalizes both sides: lowercase, turn '-', '/' and parentheses into spaces, strip ordinal suffixes after digits (`(\d+)(st|nd|rd|th)\b` → `$1`), and map street→st, avenue→av, square→sq, boulevard→blvd, parkway→pkwy, road→rd, place→pl, plaza→plz. Then check that every query token is a prefix of some name token. Call it from StationStep.matches and StopQuery.entities(matching:).

### 61. Step-free mode treats partly accessible platforms as step-free in both directions and is ignored by the change picker

**Low** · App screens · BF32, AF29

**Where:** `ios/App/TrainPicker.swift:230-235`, `ios/App/TrainPicker.swift:293`, `ios/App/TrainPicker.swift:442-465`, `ios/App/ChangePicker.swift:237-275`, `ios/Shared/Stations.swift:28-42`, `ios/App/TrainPicker.swift:231`

In Step-free mode the train picker never flags the 9 partly accessible (ada==2) platforms. All 9 are single-platform stations (28 St 6, Court Sq-23 St E/F, Wilson Av L, Hoyt St 2/3, Spring St C/E, 50 St C/E, 49 St NRW, 86 St 4/5/6, 137 St 1). StationRow (ios/App/TrainPicker.swift:230-235) and LinesStep (ios/App/TrainPicker.swift:293) treat `ada != 0` as step-free. DirectionStep (ios/App/TrainPicker.swift:442-465) shows no accessibility note, so you can pick the inaccessible direction with no warning. The change picker (ios/App/ChangePicker.swift:121-160 rows, 237-275 cards) ignores Step-free mode entirely, so even ada==0 platforms to change to are not marked. The note appears only afterwards, in TrainDetail's accessibility section.

**Fix:** In StationRow, count only `ada == 1` as fully step-free, and say 'Partly step-free' when any platform has ada == 2. In LinesStep's card, and in a DirectionStep footer, show `platform.accessibility` (for example 'Accessible: Downtown only') for ada==2 platforms of `station.platforms(serving: routes)` when settings.stepFree is on. adaNotes is free text, so show it rather than mapping it to a Direction. In ChangeLinesStep, add `@Environment(SettingsStore.self) private var settings` and show the same 'No step-free access' label, or the accessibility text, for ada != 1 platforms when settings.settings.stepFree is on.

Also reported as: AF29 (Partly accessible platforms count as step-free whichever direction you choose).

### 62. The direction step offers the dead-end direction at terminals

**Low** · App screens · BF29

**Where:** `ios/App/TrainPicker.swift:442-465`, `ios/App/LiveView.swift:576-582`, `ios/Widget/NearbyWidget.swift:171-173`

ios/App/TrainPicker.swift:442: DirectionStep offers both directions at all 33 terminal platforms whose MTA name for one direction is empty (e.g. Bay Ridge-95 St south, Coney Island-Stillwell Av south, Flushing-Main St north). The unnamed one is labelled 'Northbound' or 'Southbound' and can be saved as a favorite or widget that shows only terminating arrivals, or none. The Live tab (ios/App/LiveView.swift:576-583) and the Nearby widget (ios/Widget/NearbyWidget.swift:171-173) each hide such directions with their own equivalent copy of the rule. StopEntity.choices (ios/Shared/StopEntity.swift:52-61) also offers them.

**Fix:** In ios/Shared/Stations.swift add `func directions(of routes: [String]) -> [Direction]`. It returns `let named = Direction.allCases.filter { d in platforms(serving: routes).contains { !$0.directionName(d).isEmpty } }`, or `Direction.allCases` when `named` is empty. Use it in DirectionStep's ForEach, LiveView.NearbyLineRow.directions and NearbyLine.init (with `[route]`), and optionally in StopEntity.choices.

### 63. Train page's leave and arrival timers count up for a few seconds after the time passes

**Low** · App screens · BF6

**Where:** `ios/App/TrainDetail.swift:343-353`, `ios/App/TrainDetail.swift:88-93`, `ios/Widget/RTrainWidget.swift:1382`

ios/App/TrainDetail.swift:345 and :349: `Text(date, style: .timer)` counts up once the leave or arrival time has passed. The row is removed only on the next `now` tick (every 10 s, :88-93), so for up to 10 s a train you can no longer catch shows 'leave in 0:01…0:09', counting up. The widgets use a count-down `timerInterval` that stops at 0:00 (ios/Widget/RTrainWidget.swift:1382).

**Fix:** Pass `now` into TrainRow. Use `Text(timerInterval: now...max(now, leave), countsDown: true)` for the leave timer and `Text(timerInterval: now...max(now, train.time), countsDown: true)` for the arrival timer, with the same font and monospacedDigit modifiers.

### 64. Widgets tab 'placed' counts go stale after Make Default, delete, reorder or a change edit

**Low** · App screens · BF30

**Where:** `ios/App/WidgetsView.swift:41`, `ios/App/WidgetsView.swift:94-97`, `ios/App/WidgetsView.swift:156-161`, `ios/App/WidgetStore.swift:53-83`

Placed counts in the Widgets list (ios/App/WidgetsView.swift:41) and the editor (WidgetsView.swift:156-161) are computed only by WidgetStore.countPlaced() (ios/App/WidgetStore.swift:53-75), on .task and when the scene becomes active (WidgetsView.swift:93-97). WidgetStore.change() (WidgetStore.swift:77-83) does not recount, even though the mapping from widget configurations to saved widgets depends on `saved`: the default for unconfigured Next train widgets, and the first widget with a change for unconfigured Transfers widgets. After Make Default, delete, reorder, or adding or removing a change, the counts stay wrong until the tab reappears or the app is foregrounded again. Example: three unconfigured widgets keep showing "3 placed" on A after B is made default.

**Fix:** Store the last WidgetInfo array from getCurrentConfigurations in WidgetStore. Factor the counting loop into a function of (infos, saved), call it from countPlaced(), and call it again at the end of change(_:) after saving, so no extra system call is needed.

### 65. Siri, Start my train countdown and Shortcut suggestions ignore the default widget's commuting hours

**Low** · Saved state · AF35

**Where:** `ios/Shared/SharedStore.swift:277-283`, `ios/App/Intents.swift:13-14`, `ios/App/Intents.swift:35-36`, `ios/Shared/StopEntity.swift:95-101`, `ios/Shared/TrainWidgetIntent.swift:54-59`, `ios/Shared/SavedWidgets.swift:33-43`

During the default widget's commuting hours, widgets that follow the default show commute.selection (ios/Shared/TrainWidgetIntent.swift:54-59, ios/Widget/RTrainWidget.swift:170). Siri's 'When's my next train?' (ios/App/Intents.swift:13-14), 'Start my train countdown' (ios/App/Intents.swift:35-36) and StopQuery.suggestedEntities (ios/Shared/StopEntity.swift:95-101) use selection.json, which saveWidgets (ios/Shared/SharedStore.swift:277-283) writes from the default widget's base selection. In the evening they answer for the morning train, as do the Live tab and the in-app countdown. The code's comments scope commuting hours to widgets, so this is a design inconsistency rather than an accidental bug. Siri does name the direction it is answering for.

**Fix:** Add `static func appChoice(at date: Date = .now) -> Selection { loadWidgets().defaultWidget.shown(at: date).selection }` and use it in NextTrainIntent, StartCountdownIntent and StopQuery.suggestedEntities (and, if wanted, the Live tab's initial train). Otherwise state in the CommutingHours footer and README that Siri and the countdown always use the base train.

### 66. Registering a new token returns 503 'full' even when dropping the key's own oldest registration would make room

**Low** · Push server · CF8

**Where:** `server/Sources/TrainCore/Registrations.swift:163-172`, `server/Sources/TrainCore/Registrations.swift:164-172`, `server/Sources/TrainCore/HTTP.swift:195-199`

server/Sources/TrainCore/Registrations.swift:163-172 Store.upsert returns .full whenever a new token arrives while `registrations.count >= maxTotal`, before it computes the per-owner eviction. A key already at maxPerOwner that registers a new token would drop its own oldest and leave the total unchanged, but it gets 503 from HTTP.swift:197-199. That contradicts server/README.md:45 ("registering one more drops that key's oldest") and the intent of the comment at lines 160-162. It only happens when the global cap is reached.

**Fix:** Compute `others`/`evicted` first, then check the cap only for net growth: `if registrations[registration.token] == nil && registrations.count - evicted.count >= maxTotal { return .full }`, keeping the ownedByOther check before it. Extend StoreTests.capsTotalsAndOwners: with maxTotal 2 and maxPerOwner 2, owner a with 2 tokens registering a third gives .saved(evicted: [oldest]).

### 67. The daily per-address key quota is charged before verification, so failed attempts use it up, and its 429 has no Retry-After

**Low** · Push server · CF18

**Where:** `server/Sources/TrainCore/HTTP.swift:139-154`, `server/Sources/TrainCore/Limits.swift:45-62`, `server/README.md:49`, `server/README.md:86`

In POST /attest (server/Sources/TrainCore/HTTP.swift:139-155), the MAX_KEYS_PER_IP_PER_DAY quota (DailyLimiter.take, server/Sources/TrainCore/Limits.swift:52-61) is charged before the attestation is verified and before the key is stored. Failed attestations (401) and already-known keys (409) therefore use up the quota. Limits.swift:44 says the counter is meant to count keys made. As a result, anyone sharing a client's public address can block new installs at that address for the rest of the UTC day with about 10 junk POSTs. A misconfigured development build's retries can do the same. This 429 also has no Retry-After header, unlike the per-minute rate-limit 429 (HTTP.swift:43, README:54-55). It is documented separately at server/README.md:86.

**Fix:** Split DailyLimiter into `hasRemaining(client)` and `record(client)`. In the /attest handler, refuse with 429 when `!hasRemaining`, and call `record` only after `store.addKey(key)` returns true. Accept that concurrent requests may overshoot by a few; the per-minute RateLimiter still bounds verification work. Optionally add `Retry-After` set to the seconds until the next UTC midnight, and add a test showing that a failed attestation doesn't use up the quota.

### 68. The deploy plist pins RATE_LIMIT_BURST, so the burst no longer follows RATE_LIMIT_PER_MINUTE as documented

**Low** · Push server · BF66

**Where:** `server/deploy/com.traintimes.server.plist:61-62`, `server/Sources/TrainCore/Config.swift:97-99`, `server/Sources/TrainCore/Config.swift:28-38`, `server/Sources/TrainCore/Poller.swift:20`, `server/README.md:44-45`

server/deploy/com.traintimes.server.plist:61-62 pins RATE_LIMIT_BURST=30, so the documented default of "same as per minute" (server/README.md:47, implemented at Config.swift:98) never applies to a deployed server. Raising RATE_LIMIT_PER_MINUTE alone leaves the burst at 30. Config.swift:97 also repeats the per-minute default as a literal 30 instead of using Limits().requestsPerMinute (Config.swift:33).

**Fix:** Remove the RATE_LIMIT_BURST key from the plist, or comment it out with a note that it defaults to RATE_LIMIT_PER_MINUTE. In Config.swift:97, use `default: Int(limits.requestsPerMinute)` (limits is already `Limits()` at line 92) instead of the literal 30.

### 69. The poller skips its totals log line on quiet passes and miscounts failed pushes

**Low** · Push server · CF12

**Where:** `server/Sources/TrainCore/Poller.swift:99`, `server/Sources/TrainCore/Poller.swift:151`, `server/Sources/TrainCore/Poller.swift:160-195`, `server/Sources/TrainCore/Poller.swift:201-202`

server/Sources/TrainCore/Poller.swift:99 and :151 return before the totals log at :201-202, so idle passes and passes with no jobs log nothing. server/README.md:50 and :216-217 say every pass logs its totals. In the error accounting, `errorLines` (Poller.swift:160) counts both end-failure lines (:165-167) and push-failure lines (:187-189), but :195 subtracts it from `stats.failed`, which counts only push failures. The "… and N more failed pushes" line therefore undercounts by the number of end-failure lines logged, and is skipped entirely when end failures used the 10-line budget. End failures never appear in `failed`, and `withoutFeeds` is not in the totals line (it is logged separately at :147-149).

**Fix:** Move the totals log into a `defer` at the top of pass (after creating stats) so every pass logs it, or change the README to say passes with nothing to do log nothing. Add `withoutFeeds` and a separate `endFailed` count to Stats and to the line. Use two counters, `endErrorLines` and `pushErrorLines` (each capped, or sharing the cap via their sum), and log `stats.failed - pushErrorLines` more failed pushes, plus a similar line for end failures.

### 70. The server refreshes alerts only every other poll because of the app's 30-second alerts cache

**Low** · Push server · CF6, BF64

**Where:** `server/Sources/TrainCore/Poller.swift:221`, `ios/Shared/TrainService.swift:214-219`, `ios/Shared/TrainService.swift:254-264`, `server/Sources/TrainCore/Shared/TrainService.swift:214-219`, `server/Sources/TrainCore/Shared/TrainService.swift:252-264`, `ios/Shared/TrainService.swift:252-264`, `server/Sources/TrainCore/Poller.swift:32-49`

With the default POLL_SECONDS=30, the server refetches the alerts feed only on every other pass, about every 60 s. Poller.liveBoards (server/Sources/TrainCore/Poller.swift:221) goes through TrainService.alertEntries() (ios/Shared/TrainService.swift:214-219), which reuses the decoded entries for 30 s, timed from when the previous fetch finished (TrainService.swift:252-264). The next pass starts 30 s after the previous one started, so the cached copy is still under 30 s old. Alert-driven notices on countdowns can therefore lag by up to about 30 s more than the poll interval suggests. Train feeds are fetched fresh on every pass.

**Fix:** In Poller.liveBoards, skip the app's 30 s cache: `async let alertData = unique.contains(where: \.serviceAlerts) ? fetch(AlertsFeed.url) : nil`, then `let entries = (await alertData).flatMap { try? AlertsFeed.entries(in: $0, now: now) }`. As an alternative, add a `reusingFor window: TimeInterval = 30` parameter to TrainService.alertEntries and pass 0 from the server; with a window of 0, InFlight stores nothing.

Also reported as: BF64 (The app's 30 s alerts cache makes the server re-read alerts only every other 30 s poll).

### 71. Station list is sorted as plain strings, so '2 Av' comes after '191 St'

**Low** · Tools, Scriptable and CI · BF61

**Where:** `tools/make_stations.py:114`, `ios/App/TrainPicker.swift:105-113`

tools/make_stations.py:114 sorts stations.json by lowercased name in plain string order. The shipped ios/Shared/stations.json (also served to the server through the symlink server/Sources/TrainResources/Resources/stations.json) therefore lists numbered stations in this order: 1 Av, 103 St ... 138 St, 14 St, 145 St ... 191 St, 2 Av, 20 Av, ... 3 Av, ... 5 Av. StationDirectory.all (ios/Shared/Stations.swift:145) keeps file order. The station picker's unfiltered or search-filtered list (ios/App/TrainPicker.swift:105-114, shown at lines 142-151) shows stations in that order, which its doc comment calls 'alphabetically'. So does the widget's StopQuery.entities(matching:) (ios/Shared/StopEntity.swift:84-92), whose prefix(60) cut follows that order. With a line filter set, the list is in line order (inLineOrder), so it is unaffected.

**Fix:** In tools/make_stations.py, import re and change line 114 to `stations.sort(key=lambda s: ([int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s["name"].lower())], s["borough"]))`. Then regenerate and commit ios/Shared/stations.json, the single file that the server symlink also points to. No Swift change is needed, since StationDirectory keeps file order.

### 72. make_lines.py skips one-direction stops, so Aqueduct Racetrack sorts after Far Rockaway in the A's list

**Low** · Tools, Scriptable and CI · BF56, AF27

**Where:** `tools/make_lines.py:22`, `tools/make_lines.py:52-65`, `ios/Shared/lines.json`, `ios/Shared/Stations.swift:162-172`, `ios/App/TrainPicker.swift:113`, `ios/Shared/Lines.swift:33-35`, `tools/make_lines.py:53-54`, `tools/make_lines.py:61-65` (+3 more)

tools/make_lines.py:52-54 builds line orders from southbound trips only, so a stop served in one direction only gets no position. Today that is only H01 Aqueduct Racetrack on the A. ios/Shared/lines.json "A" lacks H01, and StationDirectory.inLineOrder (ios/Shared/Stations.swift:164-172, called from ios/App/TrainPicker.swift:113) puts it after Far Rockaway-Mott Av at the end of the A's filtered station list. In the A's order, Rockaway Blvd (A61) is followed by the Lefferts branch and then Aqueduct-N Conduit Av (H02). The LABELS map at make_lines.py:22 does lack "5X" compared with Lines.normalized (ios/Shared/Lines.swift:33-35), but that changes nothing: a 5X key would be an empty, unused list.

**Fix:** In make_lines.py main, also read direction_id "0" trips, reverse each one's stop list, and merge those patterns after all the southbound ones, so they only add stops the southbound trips lack. With the existing merge(), H01 then lands right after A61 Rockaway Blvd. That is in line order, though ahead of the Lefferts branch. Optionally assert that every (station, label) pair in stations.json appears in lines.json. Adding "5X": "5" to LABELS is harmless tidying only.

Also reported as: AF27 (lines.json omits Aqueduct Racetrack (H01), so the A filter lists it after Far Rockaway).

## Duplicated code (21: 2 medium, 19 low)

### 73. The train-feed fetch-and-filter pipeline is written several times in TrainService and again in the server's poller, which also copies its private helpers

**Medium** · Trains and feeds · CF5, AF3, BF21, AF4

**Where:** `server/Sources/TrainCore/Poller.swift:214-267`, `ios/Shared/TrainService.swift:174-205`, `ios/Shared/TrainService.swift:72-92`, `server/Sources/TrainCore/Poller.swift:271-275`, `ios/Shared/TrainService.swift:162-167`, `server/Sources/TrainCore/Poller.swift:278-283`, `ios/Shared/TrainService.swift:235-244`, `server/Sources/TrainCore/Poller.swift:286-292` (+35 more)

server/Sources/TrainCore/Poller.swift:214-291 hand-copies four pieces of ios/Shared/TrainService.swift: the batched feed and filter pipeline of trains(for:) (174-205) combined with board(for:)'s alerts and outages (72-92), outages(for:if:) (162-167), data(from:) (235-244) and oncePerTrip (302-308). TrainService.swift is already compiled into TrainCore through server/Sources/TrainCore/Shared/TrainService.swift. The copies are about 50 lines with no semantic drift today. The only differences are the per-stop index, which changes cost but not results, and a non-HTTP-response branch that https URLs never reach. No test compares liveBoards with TrainService (every Poller test injects a board closure), so a future change to the app's filtering could leave the server's countdown showing different trains. The O(selections × arrivals) cost in the app's trains(for:) is negligible at app scale.

**Fix:** In ios/Shared/TrainService.swift, change `private` to internal for oncePerTrip, data(from:) and outages(for:if:), or add a non-private `static func outages(atComplex:in:)`-style helper. Move the per-stop indexed loop into one internal `TrainService.trains(byStop:for:now:)`-style helper used by both trains(for:) and Poller.liveBoards. Then delete Poller.fetch, Poller.outages(for:in:) and the private oncePerTrip extension. At minimum, add a test that runs liveBoards and trains(for:) on the same recorded feed data and checks that they agree.

Also reported as: AF3 (Server Poller re-implements TrainService's feed pipeline and copies its private helpers); BF21 (Poller.liveBoards duplicates TrainService.board/trains(for:) and copies three of TrainService's private helpers; this copy has no tests); AF4 (The "fetch feeds → decode → filter → sort → oncePerTrip" pipeline is written three times in TrainService, and the connection-catchable filter three times in the widget).

### 74. The countdown's content state, state-building logic and train id format are hand-copied into the server

**Medium** · Lock Screen countdown · CF4, BF45, AF34, AF5

**Where:** `server/Sources/TrainCore/ContentState.swift:1-32`, `ios/Shared/TrainActivity.swift:8-25`, `server/Sources/TrainCore/ActivityState.swift:20-44`, `ios/App/TrainActivityController.swift:202-226`, `server/Sources/TrainCore/ActivityState.swift:48-54`, `ios/App/TrainActivityController.swift:148-153`, `server/Sources/TrainCore/ActivityState.swift:7-13`, `ios/App/TrainActivityController.swift:23` (+46 more)

The countdown model and logic exist twice: once in ActivityKit-bound app files, once hand-copied in the server. The pairs are:
- ContentState: server/Sources/TrainCore/ContentState.swift:10-26 and ios/Shared/TrainActivity.swift:8-25
- the state builder: server/Sources/TrainCore/ActivityState.swift:20-44 and ios/App/TrainActivityController.swift:202-226
- noTrains: ActivityState.swift:48-54 and TrainActivityController.swift:149-153
- lifetime: ActivityState.swift:7 and TrainActivityController.swift:23
- staleDate: ActivityState.swift:11-13 and TrainActivityController.swift:190-192
- the trainID format: server/Sources/TrainCore/Shims.swift:24 and ios/Shared/StopEntity.swift:20,71

staleDate has already drifted. Commit 9be9058 changed the app to `staleDate: state.train`, but the server still sends train + 120 s, and three server tests pin that value. A Live Activity therefore goes stale (and redraws via `movedOn`) at a different time depending on who last updated it. Separately, Poller.liveBoards and its private helpers (Poller.swift:215-292) re-implement TrainService.trains(for:) and the private oncePerTrip, data(from:) and outages(for:if:) in the already-shared ios/Shared/TrainService.swift.

**Fix:** 1. Create an ActivityKit-free ios/Shared/CountdownState.swift and symlink it into server/Sources/TrainCore/Shared. Put the ContentState struct in it, plus `static func state(for:trains:notice:now:following:)`, `noTrains(from:now:)`, `staleDate(for:)` (returning `state.train`) and `lifetime`.
2. In TrainActivity.swift, declare `typealias ContentState = CountdownState`.
3. Have TrainActivityController and ActivityState call the shared code, and delete server/Sources/TrainCore/ContentState.swift.
4. Update the three tests that expect train + 120.
5. Move the trainID format into Selection.swift, have StopEntity.init build its id from it, and delete the Shims.swift copy.
6. Optionally make TrainService's oncePerTrip internal (or reuse TrainService.trains(for:)) so Poller.liveBoards stops copying it.

Also reported as: BF45 (ContentState and the countdown-building logic are copied into the server, and the copy has already drifted (stale date)); AF34 (Countdown ContentState and its state-building logic are copied by hand between app and server, and the stale date has already drifted); AF5 (Selection.trainID is defined twice: StopEntity in the app, a hand-copied mirror in the server Shims).

### 75. Nearby's every-line-both-ways logic is copied between widget and app, which now order and label directions differently

**Low** · Trains and feeds · BF10, AF68

**Where:** `ios/App/LiveView.swift:576-583`, `ios/App/LiveView.swift:596`, `ios/App/LiveView.swift:94-100`, `ios/App/LiveView.swift:439-443`, `ios/App/LiveView.swift:351`, `ios/App/LiveView.swift:458`, `ios/Widget/NearbyWidget.swift:82-86`, `ios/Widget/NearbyWidget.swift:168-197` (+12 more)

There are three copies of the 'every line, both ways' Selection builder: ios/App/LiveView.swift:94-100, ios/App/LiveView.swift:439-443 and ios/Widget/NearbyWidget.swift:82-86. 'Named directions, else both' is in two places: LiveView.swift:576-583 and NearbyWidget.swift:170-172. The own-line filter is in three: LiveView.swift:351, LiveView.swift:458 and NearbyWidget.swift:183. The widget lists the toward-Manhattan way first with short labels. The app's NearbyLineRow always lists north then south with the MTA's full direction label (LiveView.swift:596). After a tap on the widget, StationLive shows the same lines in a different order wherever the Manhattan way is southbound: Queens lines such as the 7 ('Manhattan | Queens' on the widget, 'Flushing' then 'Manhattan' in the app), and Bronx lines. Labels differ too (R in Brooklyn: 'Brooklyn' vs 'Bay Ridge - 95 St'). The label difference may be a deliberate choice for widget room. The order difference looks like drift.

**Fix:** In ios/Shared/Nearby.swift add `extension Station { var lineSelections: [Selection] }` and `func ways(of route: String) -> [Direction]`. The second returns the named directions, else both, ordered toward-Manhattan first, moved from NearbyLine.init. Use lineSelections in LiveView.everyTrain, StationLive.selections and NearbyProvider.plan. Use ways(of:) in both NearbyLineRow.directions and NearbyLine.init, so the order matches. The app can keep its fuller labels if that's intended.

Also reported as: AF68 (Nearby's every-line-both-ways logic is copied between the widget and the app, and they disagree).

### 76. The change picker re-implements Change's across-the-platform and express rules

**Low** · Transfers · BF35, AF24

**Where:** `ios/App/ChangePicker.swift:38-42`, `ios/App/ChangePicker.swift:101-105`, `ios/App/ChangePicker.swift:232-235`, `ios/Shared/Change.swift:29-60`, `ios/App/ChangePicker.swift:233-235`, `ios/Shared/Change.swift:46-60`

ios/App/ChangePicker.swift:38-42 (changeLines) and :101-105 (ChangeStationStep.isExpress) re-implement Change.isAcross and Change.isExpress (ios/Shared/Change.swift:30-31, 46-60). ChangePicker.swift:232-235 repeats Station.platforms(serving:) as a per-platform test. Today the results are identical. The empty-routes difference is unreachable, because the picker labels only non-empty across lists and Change.validated drops empty route lists. The real risk is only future drift if the 'across' rule changes in one place and not the other.

**Fix:** Add `static func lines(at station: Station, from selection: Selection) -> (across: [String], others: [String])` to Change, built from the same `platforms(serving:)` call that isAcross uses. In ChangeStationStep, replace the private isExpress with `Change(stationID: station.id, routes: lines.across).isExpress(for: selection)`, keeping the `!lines.across.isEmpty` guard at the call site. ChangeLinesStep.isAcross(platform) can become `selection` platforms membership via `station.platforms(serving: selection.routes).contains(platform)`.

Also reported as: AF24 (ChangePicker re-implements Change's across and express logic, and the two have drifted).

### 77. Alert and elevator-notice handling is duplicated across Board.notice, the Nearby widget, AlertsSheet and TrainDetail

**Low** · Alerts and elevator outages · BF11, AF79

**Where:** `ios/App/AlertsSheet.swift:20-23`, `ios/Shared/TrainService.swift:24`, `ios/App/TrainDetail.swift:205-222`, `ios/App/AlertsSheet.swift:35-51`, `ios/App/TrainDetail.swift:358-382`, `ios/App/AlertsSheet.swift:89-112`, `ios/App/TrainDetail.swift:384-427`, `ios/App/AlertsSheet.swift:115-137` (+4 more)

The 'elevators out now' filter is duplicated at ios/App/AlertsSheet.swift:20-23 and ios/Shared/TrainService.swift:24. The two copies are identical and gated the same way today. Three status strings are copied between ios/App/TrainDetail.swift:205-222/249 and AlertsSheet.swift:36/43/50. AlertRow (TrainDetail.swift:358-382) and AlertDetail (AlertsSheet.swift:89-112) are intentionally collapsed and expanded versions of one alert. OutageRow (TrainDetail.swift:384-427) and ElevatorDetail (AlertsSheet.swift:115-137) cover intentionally different outages, though ElevatorDetail omits the start time and reason. The count drift is hypothetical for elevators. An existing difference is that the sheet ignores settings.alertKinds and selection.serviceAlerts, which the widget's notice applies.

**Fix:** Add `var elevatorsOut: [Outage] { (outages ?? []).filter { !$0.isPlanned && $0.isAccessibilityElevator } }` to Board, and use it in notice(...) and in AlertsSheet.elevatorsOut. Optionally move the outage date text into one helper (e.g. `Outage.whenText`) used by both views. Keep the separate collapsed and expanded alert views.

Also reported as: AF79 (Alert/notice handling duplicated; the Live Activity ignores the notice kind; Nearby's "worst alert" depends on dictionary order).

### 78. Countdown-width placeholder logic exists three times, and the Live Activity copy has lost the one-second margin

**Low** · Widgets · CF44, AF51

**Where:** `ios/Widget/RTrainWidget.swift:717-725`, `ios/Widget/RTrainWidget.swift:1401-1403`, `ios/Widget/TrainLiveActivity.swift:157-158`, `ios/Widget/RTrainWidget.swift:717`, `ios/Widget/RTrainWidget.swift:1401`, `ios/Widget/TrainLiveActivity.swift:157`, `ios/Widget/RTrainWidget.swift:717-724`, `ios/Widget/RTrainWidget.swift:718-724`

The timer placeholder ternary is repeated at ios/Widget/RTrainWidget.swift:720, ios/Widget/RTrainWidget.swift:1403 and ios/Widget/TrainLiveActivity.swift:158. The two widget copies switch a second early (>=3599 / >=599) in case the timer rounds up. The Live Activity copy uses >=3600 / >=600, so if a render happens with between 599 and 600 s left and the timer shows '10:00', the 5-character timer overflows the hidden '0:00' leftward toward the live/scheduled mark. This lasts under a second, until it reads '9:59', and only if the timer rounds up.

**Fix:** Add one helper in the Widget target, e.g. `func timerPlaceholder(seconds: TimeInterval) -> String { seconds >= 3599 ? "0:00:00" : seconds >= 599 ? "00:00" : "0:00" }`, and use it at RTrainWidget.swift:720, RTrainWidget.swift:1403 and TrainLiveActivity.swift:158 (passing `remaining`).

Also reported as: AF51 (Countdown-width placeholder logic exists three times, and the Live Activity copy has drifted).

### 79. StopList and TransferMap repeat styling and rail drawing, and place the train differently

**Low** · Widgets · AF67

**Where:** `ios/Widget/StopList.swift:112-162`, `ios/Widget/TransferMap.swift:203-271`, `ios/Widget/StopList.swift:64-83`, `ios/Widget/TransferMap.swift:125-146`, `ios/Widget/StopList.swift:168-246`, `ios/Widget/TransferMap.swift:294-375`

StopList and TransferMap duplicate small pieces:
- the stop-name styling (ios/Widget/StopList.swift:69-71 vs ios/Widget/TransferMap.swift:130-132)
- the dashed rail next to folded rows (StopList.swift:199-210 vs TransferMap.swift:320-331)
- the tinted-mode `destinationOut` eraser pattern (StopList.swift:212-243 vs TransferMap.swift:346-373)

The two maps place your train differently. StopLayout puts a moving train exactly halfway between the feed's stops (StopList.swift:147-152). TransferMapLayout interpolates by stop times and ignores the vehicle position (TransferMap.swift:245, 261-271). So the medium and large Transfers maps can show your train at different points at the same moment.

The folding logic differs on purpose. The "no singular" claim is wrong: folded groups always hold at least 2 stops.

**Fix:** Extract a small shared helper for the name style (weight, italic and colour from yours/trainStop/passed/folded), used by StopList.stopRow and TransferTrack.stopName. Optionally share a `railSegment` helper (solid or dashed) and a `clearBehind(path)` helper for the tinted eraser. To make the maps agree and match README.md:15-19, interpolate StopLayout.trainRow by the approach's stop times as TransferMapLayout.row(at:) does, and leave the folding algorithms separate.

### 80. Widget kind strings are repeated as literals, so reloads can't target only the train widgets

**Low** · Widgets · AF76

**Where:** `ios/Widget/RTrainWidget.swift:7`, `ios/Widget/RTrainWidget.swift:27`, `ios/Widget/RTrainWidget.swift:153`, `ios/App/WidgetStore.swift:60`, `ios/App/WidgetStore.swift:64`, `ios/App/WidgetStore.swift:82`, `ios/App/SettingsView.swift:13`, `ios/App/TrainActivityController.swift:184` (+1 more)

Widget kind strings are duplicated as literals at ios/Widget/RTrainWidget.swift:7, :27 and :153, and the app's `countPlaced` (ios/App/WidgetStore.swift:60, :64) depends on them matching. Only Nearby has a shared constant (ios/Shared/Nearby.swift:57).

`reloadAllTimelines()` also reloads the Nearby widget in cases where it doesn't need it, which costs a location fix (up to 10 s) and feed refetches:
- WidgetStore edits (WidgetStore.swift:82)
- countdown changes (TrainActivityController.swift:184)
- Settings changes that only touch `stepFree` (or `largerWidgetText`) (SettingsView.swift:13); `stepFree` affects no widget at all.

Nearby does depend on `alertKinds`, `marksLiveTimes` and `marksScheduledTimes`, so it must still reload when those change. The alerts decode is shared through a 30 s cache, so it is not an extra cost.

**Fix:** Add shared constants, for example `enum WidgetKind { static let train = "RTrainWidget"; static let transfers = "TransfersWidget" }` beside `Nearby.widgetKind`, and use them in RTrainWidget.swift:7/27/153 and WidgetStore.swift:60/64. In WidgetStore.change and TrainActivityController.tellWidgets, call `reloadTimelines(ofKind:)` for the two train kinds only. In SettingsStore.didSet, skip the reload when only `stepFree` changed, and reload Nearby only when `alertKinds`, `marksLiveTimes` or `marksScheduledTimes` changed.

### 81. App screen pieces are copied rather than shared (walk stepper, train button, rows, cards)

**Low** · App screens · AF80, BF13

**Where:** `ios/App/TrainDetail.swift:42-44`, `ios/App/WidgetsView.swift:253-262`, `ios/App/TrainDetail.swift:115-131`, `ios/App/WidgetsView.swift:497-520`, `ios/App/TrainDetail.swift:314-356`, `ios/App/Intents.swift:64-87`, `ios/App/TrainPicker.swift:302-315`, `ios/App/TrainPicker.swift:329-368` (+8 more)

Several app views are copied rather than shared. Exact or near-exact copies: the walk Stepper (TrainDetail.swift:42-44 = WidgetsView.swift:253-262), the train button label (TrainDetail.swift:115-131 ≈ WidgetsView.swift:497-520) and the StationLive/TransferLive loaders (LiveView.swift:426-494 and 498-561; LiveView's own load at 362-372 is similar but uses a loadState enum). The station search is duplicated in TrainPicker.swift:106-111 and StopEntity.swift:85-90. The "Lines.list(routes) heading" caption is repeated in 8 places. TrainDetail.TrainRow and NextTrainSnippet (Intents.swift:64-87), and the two platform cards (TrainPicker.swift:329-368, ChangePicker.swift:237-275), share only a common shell: their trailing or inner content is intentionally different (timer vs spoken leave time; Select all/step-free vs across-platform/own-train). The 20 vs 18 bullet sizes may be deliberate.

**Fix:** Make WalkStepper and the WidgetsView TrainRow internal, with a fallback-title parameter, and use them in TrainDetail. Add `extension Selection { var caption: String }` in Shared. Add `StationDirectory.matching(_ search:)` in Shared and use it from TrainPicker and StopQuery. Factor StationLive and TransferLive's load and timer loops into a small @Observable `LiveTrains(selections:)` or a view modifier. Leave the platform cards and the snippet row alone, or extract only the header and bottom-bar shell.

Also reported as: BF13 (Walking-time stepper duplicated between TrainDetail and WidgetsView).

### 82. Polling and refresh code is copy-pasted across the Live tab, station, transfer and train pages

**Low** · App screens · BF9

**Where:** `ios/App/LiveView.swift:213-229`, `ios/App/LiveView.swift:362-372`, `ios/App/LiveView.swift:471-493`, `ios/App/LiveView.swift:524-560`, `ios/App/TrainDetail.swift:80-93`, `ios/App/LiveView.swift:245`, `ios/App/LiveView.swift:448`, `ios/App/LiveView.swift:513`

ios/App/LiveView.swift has three near-copies of the polling code: LiveView 213-235 + 362-372, StationLive 471-485 + 487-493, and TransferLive 524-538 + 554-560. The StationLive and TransferLive load() bodies are identical, and the failure Label is copied at 245, 448 and 513. They have drifted. Only LiveView refreshes on scenePhase. LiveView tracks a LoadState whose `.loading` case is never shown, while the others use `failed: Bool`. TrainDetail (ios/App/TrainDetail.swift:80-93, 290-311) repeats the loop and ticker around a different fetch, and its success path lacks the cancellation guard the list screens have. A fix to the shared load logic has to be made in three places.

**Fix:** Extract a small `@MainActor @Observable final class LiveTrains { var trains: [String: [Arrival]]; var failed: Bool; var now: Date; func load(_ selections: [Selection]) async }`, or a `.pollingTrains(selections, every: 60, trains: $trains, failed: $failed, now: $now)` ViewModifier that owns the refreshable, the task loop, the 10 s ticker and the scenePhase refresh. Add a shared `MTAUnreachableRow` view. Use them in LiveView, StationLive and TransferLive. TrainDetail can reuse the ticker and add `guard !Task.isCancelled` before `board = fetched`.

### 83. The platform-by-platform line chooser is written twice, and the change version ignores Step-free mode

**Low** · App screens · BF34

**Where:** `ios/App/TrainPicker.swift:281`, `ios/App/TrainPicker.swift:291-293`, `ios/App/TrainPicker.swift:302-315`, `ios/App/TrainPicker.swift:329-368`, `ios/App/ChangePicker.swift:183`, `ios/App/ChangePicker.swift:212-225`, `ios/App/ChangePicker.swift:237-275`, `ios/Shared/StopEntity.swift:55`

LinesStep (ios/App/TrainPicker.swift:268-393) and ChangeLinesStep (ios/App/ChangePicker.swift:166-276) duplicate the platform-card scaffolding: `ordered` (TrainPicker.swift:281 / ChangePicker.swift:183), the platform header text (333 / 241), the LineToggle toggle closure (355-361 / 261-267), the card chrome (365-367 / 272-274) and the bottom button bar (302-315 / 212-225). The per-platform route ordering also appears in StopEntity.choices (ios/Shared/StopEntity.swift:55). Most differences between the copies are intentional (locked own-train lines, across/walk note, Done vs Next, no Select all). The genuine drift is that ChangeLinesStep ignores Step-free mode. Consolidation is practical, but the payoff is modest.

**Fix:** Add `extension Station { func routes(on platform: Platform) -> [String] { routes.filter(platform.routes.contains) } }` and use it at TrainPicker.swift:292, ChangePicker.swift:238 and StopEntity.swift:55. Put it in an app/widget file such as StopEntity.swift rather than Stations.swift, which the server also compiles. Extract a `PlatformCard<Accessory, Note>` view (header text, optional note, trailing accessory, toggles with a `locked: Set<String>`), with the step-free label inside, and a `ChosenLinesBar(title:disabled:action:)`, and use both from the two steps.

### 84. Three different rules decide whether a saved train is still valid

**Low** · Saved state · AF9

**Where:** `ios/Shared/Selection.swift:116-122`, `ios/Shared/Selection.swift:196`, `ios/Shared/StopEntity.swift:28`, `ios/Shared/TrainWidgetIntent.swift:77-78`

There are three validity rules for a saved train. Selection.validated() (ios/Shared/Selection.swift:116-122) drops lost lines. Selection.init?(link:) (ios/Shared/Selection.swift:196) needs any one line still at the station. StopEntity.init?(id:) (ios/Shared/StopEntity.swift:29) and TrainWidgetIntent.earlierTrain (ios/Shared/TrainWidgetIntent.swift:79-80) need every line still there. After a stations.json refresh in which a station loses one daytime line, a widget set up before saved widgets (Station/Line/Direction or the old `stop` parameter) gets nil and falls back to the default widget instead of keeping its train minus that line. A Shortcuts action holding that StopEntity likewise falls back to the app's train. This is rare, a leftover from the old Edit menu.

**Fix:** In StopEntity.init?(id:), replace `routes.allSatisfy(station.routes.contains)` with `routes.contains(where: station.routes.contains)` and keep the saved routes, so the id round-trips; selection(basedOn:) already calls validated(), which drops lost lines. In earlierTrain, make the same change; it already ends in .validated().

### 85. Small repeats inside the server: token DELETE SQL, hex formatting, App Attest nonce

**Low** · Push server · BF65

**Where:** `server/Sources/TrainCore/Registrations.swift:175`, `server/Sources/TrainCore/Registrations.swift:190`, `server/Sources/TrainCore/Registrations.swift:224`, `server/Sources/TrainCore/Registrations.swift:45-51`, `server/Sources/TrainCore/Limits.swift:118-132`, `server/Sources/TrainCore/HTTP.swift:76`, `server/Sources/TrainCore/Limits.swift:142`, `server/Sources/TrainCore/AppAttest.swift:144-146` (+4 more)

These are minor repetitions in the server with no drift. The token DELETE SQL appears three times (server/Sources/TrainCore/Registrations.swift:175, 190, 224). The App Attest nonce is built twice (AppAttest.swift:146, 184). Bytes are hex-formatted twice (HTTP.swift:76, Limits.swift:142). The hex-digit checks differ on purpose, the repeated SHA256(appID) is a negligible cost, and the double keyIDBytes check is a deliberate early rejection.

**Fix:** Optionally add `private func deleteRows(_ tokens: [String]) throws` in Store that only runs the DELETE, and keep unindex after the transaction commits. Add `static func nonce(authData: [UInt8], clientData: [UInt8]) -> [UInt8]` to AppAttest and use it at lines 146 and 184. Leave the hex checks, the rpIDHash computation and the route's keyIDBytes pre-check as they are.

### 86. Line labels and colours are re-coded in the Python tools and the Scriptable script

**Low** · Tools, Scriptable and CI · BF57

**Where:** `tools/make_lines.py:22`, `ios/Shared/Lines.swift:33-35`, `ios/Shared/Lines.swift:13-28`, `tools/make_stations.py:27-37`, `tools/make_app_icons.py:29-42`, `scriptable/Next R Train.js:19`, `ios/Shared/LineBullet.swift:33-62`, `tools/make_app_icons.py:23-42` (+5 more)

Line colors are copied by hand from ios/Shared/Lines.swift:13-28 into tools/make_app_icons.py:30-42, and all values match today. The route-to-label mapping is re-coded in tools/make_lines.py:22 (no 5X, which is harmless). The bullet label ratio 0.62/0.45 is repeated in ios/Shared/LineBullet.swift:35, ios/Widget/StopList.swift (TrainMarker.label), ios/Shared/WidgetChoices.swift (UIKit image renderer) and make_app_icons.py:24. ios/App/TrainPicker.swift LineToggle's 0.56/0.42 is an intentional off-state style. No copy currently gives wrong output. The risk is that a future color change in Lines.swift won't reach the generated icons.

**Fix:** Within Swift, add `static func fontSize(label: String, size: CGFloat) -> CGFloat` on LineBullet and use it in TrainMarker and WidgetChoices. For the Python copy, add a small check (or a test) that parses the `case ...: LineStyle(label:..., color: 0x..., usesDarkText: ...)` lines from Lines.swift and asserts they equal make_app_icons.BULLETS. Optionally add "5X": "5" to make_lines.LABELS. Leave the Scriptable script alone.

### 87. Line colour conversions, text-on-line colour and status colours are repeated

**Low** · Cross-cutting · AF78

**Where:** `ios/Shared/LineBullet.swift:6-23`, `ios/Shared/WidgetChoices.swift:33-38`, `ios/Shared/WidgetChoices.swift:43`, `ios/Widget/Pills.swift:40`, `ios/Widget/StopList.swift:281`, `ios/Widget/RTrainWidget.swift:1476`, `ios/Widget/RTrainWidget.swift:1481`, `ios/Widget/RTrainWidget.swift:1497-1500` (+6 more)

Several small colour definitions are copied rather than shared. liveGreen (ios/Shared/LineBullet.swift:15) duplicates liveText's dark value (LineBullet.swift:21), and boardBlack (ios/Widget/RTrainWidget.swift:1476) duplicates boardBackground's dark value (RTrainWidget.swift:1481). The text-on-line colour is repeated 4 times (LineBullet.swift:41, WidgetChoices.swift:43, Pills.swift:40, StopList.swift:281). The live/timetable status colour exists as Arrival.statusColor in the widget only (RTrainWidget.swift:1499), and is re-implemented 3 times in the app (LiveView.swift:725, TrainDetail.swift:330, Intents.swift:69) and 3 times in the Live Activity (TrainLiveActivity.swift:34, 52, 88). BulletImage re-derives the hex RGB (WidgetChoices.swift:33-38). The `Color(hex: LineStyle.of(x).color)` pattern appears at 5 call sites, not 9.

**Fix:** In ios/Shared, add `extension LineStyle { var swiftUIColor: Color; var uiColor: UIColor; var textColor: Color }` and use it at the 4 text-colour sites and the 5 inline Color(hex: LineStyle.of(..).color) sites. Define private shared UIColor constants for the live green and the board black, and build both liveGreen/liveText and boardBlack/boardBackground from them, so the Dynamic Island can keep a static dark colour. Optionally, move Arrival.statusColor into Shared, with the app passing .primary and the Live Activity applying .dark to the Dynamic Island regions.

### 88. Line-bullet drawing is written four times

**Low** · Cross-cutting · AF40

**Where:** `ios/Shared/LineBullet.swift:31-62`, `ios/Shared/WidgetChoices.swift:11-54`, `ios/Widget/StopList.swift:255-289`, `ios/App/TrainPicker.swift:405-414`, `ios/Shared/LineBullet.swift:33-54`, `ios/Widget/StopList.swift:256-276`, `ios/Shared/WidgetChoices.swift:28-47`, `ios/App/TrainPicker.swift:409-415` (+2 more)

The bullet drawing rules are duplicated in three places: LineBullet (ios/Shared/LineBullet.swift:33-54), TrainMarker in the stop rail (ios/Widget/StopList.swift:250-291; font rule at :272, tinted branch at :262-266 copying LineBullet.swift:48-52, text colour at :281) and BulletImage (ios/Shared/WidgetChoices.swift:28-48; font rule at :40, hex-to-RGB at :33-38, text colour at :43). LineToggle's off state (ios/App/TrainPicker.swift:409) uses its own 0.42/0.56 ratios, and it's undocumented whether that's intentional. The multi-bullet grid drift between BulletImage and LineBullets is the separate bug AF32.

**Fix:** Add `static func fontSize(for style: LineStyle, size: CGFloat) -> CGFloat` and a `LineStyle.textUIColor` and use them in LineBullet, TrainMarker and BulletImage. Extract the tinted-mode treatment into a `.tintedBullet(size:label:)` ViewModifier, or have TrainMarker's non-fullColor branch return `LineBullet(route:size:)`. Share the grid computation between LineBullets and BulletImage, as in AF32, rather than switching BulletImage to ImageRenderer, which is @MainActor and is called from a nonisolated getter.

### 89. Minutes-to-go and other small widget helpers are re-implemented in several places

**Low** · Cross-cutting · CF45, AF77, AF53

**Where:** `ios/Widget/RTrainWidget.swift:824-830`, `ios/Widget/RTrainWidget.swift:1007-1009`, `ios/Widget/NearbyWidget.swift:461-467`, `ios/App/LiveView.swift:703-711`, `ios/App/LiveView.swift:733-736`, `ios/Shared/Spoken.swift:61-68`, `ios/Shared/Change.swift:114-120`, `ios/Widget/RTrainWidget.swift:823-830` (+12 more)

Floor-and-clamp minutes-to-go is reimplemented at ios/Widget/RTrainWidget.swift:828-830, ios/Widget/RTrainWidget.swift:1007-1009, ios/Widget/NearbyWidget.swift:461, ios/App/LiveView.swift:707 and ios/App/LiveView.swift:734, although ios/Shared/Spoken.swift:61-63 already provides `Spoken.minutes(until:from:)` to both targets. The zero case has drifted: the medium widget's LATER column (RTrainWidget.swift:810) and the large Transfers 'THEN IN' column (RTrainWidget.swift:992) show '0 min' where Nearby and the app show 'Now'. This is reachable only without a walking time, with a later train under a minute away. Connection.waitMinutes (ios/Shared/Change.swift:114) deliberately rounds a train-to-train wait to the nearest minute and is not part of this duplication.

**Fix:** Have the five floor-minute sites call `Spoken.minutes(until:from:)`, or move it to a `Date.minutes(until:)` extension in ios/Shared. Add one shared short label (`minutes == 0 ? "Now" : "\(minutes) min"`) for the widget LATER and THEN IN columns if 'Now' is the intended wording. Leave Connection.waitMinutes as it is.

Also reported as: AF77 ("Whole minutes until" and "Now/N min/minutes" text implemented 6+ times); AF53 (Small helpers copied between widget files (minutes until, short station name, text-middle guide, colours)).

### 90. Small Station helpers are written twice (direction availability, stop-to-station lookup, terminal name, search)

**Low** · Cross-cutting · AF25

**Where:** `ios/App/LiveView.swift:576-583`, `ios/Widget/NearbyWidget.swift:171-173`, `ios/Shared/TrainService.swift:144`, `ios/Widget/TransferMap.swift:230`, `ios/Shared/Stations.swift:201-209`, `ios/Shared/Stations.swift:216-218`, `ios/App/TrainPicker.swift:107-112`, `ios/Shared/StopEntity.swift:87-92`

Four small helpers are written twice. (1) 'directions the MTA names for this line here, else both' at ios/App/LiveView.swift:576-583 and ios/Widget/NearbyWidget.swift:171-173. (2) Feed stop id to Station via `StationDirectory.station(id: String(stop.dropLast()))` at ios/Shared/TrainService.swift:144 and ios/Widget/TransferMap.swift:230, while ios/Shared/Stations.swift:216-218 has a private lookup that handles both id forms. (3) `terminalName(forStop:)` (Stations.swift:201-204) is a pure alias of `shortName(forStop:)`, used only at SubwayFeed.swift:25. (4) Station text search at ios/App/TrainPicker.swift:107-112 and ios/Shared/StopEntity.swift:86-92. All copies agree today, so this is maintenance risk only.

**Fix:** Add `Station.directions(of route: String) -> [Direction]` in Stations.swift and use it in both Nearby views. Add `StationDirectory.station(forStop:)` (platform(forStop:) then byID) and use it in TrainService.stations(after:) and TransferMap. Delete `terminalName(forStop:)` and have `Arrival.terminal` call `shortName(forStop:)`. Add `Station.matches(search words: [Substring]) -> Bool` and use it in TrainPicker.matches and StopQuery.entities(matching:).

### 91. Small shared-logic duplicates (line-list joining, Northbound/Southbound fallback, deep-link parsing)

**Low** · Cross-cutting · AF41

**Where:** `ios/Shared/Lines.swift:111-115`, `ios/Shared/Spoken.swift:40-43`, `ios/Shared/Alerts.swift:162-170`, `ios/Shared/Selection.swift:60`, `ios/Shared/StopEntity.swift:37`, `ios/Shared/Stations.swift:127`, `ios/Widget/NearbyWidget.swift:213`, `ios/Shared/TrainWidgetIntent.swift:205` (+20 more)

There are several small duplicates in shared logic, all low severity.
- Spoken.either (ios/Shared/Spoken.swift:40-43) duplicates Lines.list(_, joinedBy: "or") (ios/Shared/Lines.swift:111-115) and has drifted: for a single shuttle selection Siri says "There are no S trains to …" instead of "42 St Shuttle" (Spoken.swift:9,30). AlertsFeed.readable (ios/Shared/Alerts.swift:162-170) has a third joiner.
- StopEntity.displayRepresentation (ios/Shared/StopEntity.swift:37) repeats Selection.linesLabel (ios/Shared/Selection.swift:60).
- The direction fallback "Northbound"/"Southbound" is written at ios/Shared/Stations.swift:127 and ios/Widget/NearbyWidget.swift:213. The same compass names appear at ios/Shared/TrainWidgetIntent.swift:205 and ios/App/TrainPicker.swift:454. Spoken.isNamed (Spoken.swift:57-59) depends on the exact fallback text.
- Deep-link parsing (the value closure, comma split and "traintimes" scheme) is repeated at Selection.swift:155-157,165,187-192 and Nearby.swift:72,84-89.
- ChangePicker re-derives across and express (ios/App/ChangePicker.swift:38-42, 102-105) instead of using Change.isAcross/isExpress (ios/Shared/Change.swift:46-60). Its per-platform isAcross (233-235) is related but not identical.
- Stop-to-station lookup via station(id: dropLast) is at ios/Shared/TrainService.swift:144 and ios/Widget/TransferMap.swift:230. terminalName(forStop:) (Stations.swift:202-204) is an alias of shortName(forStop:).
- TrainWidgetIntent.earlierTrain (TrainWidgetIntent.swift:79-80) rebuilds StopEntity.selection(basedOn:). SavedWidgetOptions.results() and SavedWidgetQuery.suggestedEntities() are identical.
- The server mirrors Selection.trainID at server/Sources/TrainCore/Shims.swift:21-25 on purpose, since AppIntents isn't available there.

**Fix:** - In Spoken.nextTrain, use Lines.list(selection.routes, joinedBy: "or") and delete either().
- Have StopEntity.displayRepresentation use Selection(stationID:routes:direction:).linesLabel, or a static Lines.label(of:) helper.
- Add Direction.compassName ("Northbound"/"Southbound") and use it at the 4 sites. Have Spoken.isNamed compare against Direction.allCases.map(\.compassName), or make Station.directionLabel report whether the name is real.
- Add a small DeepLink helper (scheme constant, query value lookup, comma list).
- In ChangePicker, use Change(stationID: station.id, routes: lines).isAcross / isExpress.
- Add a public StationDirectory.station(forStop:) and use it at the two sites. Replace terminalName with shortName.
- In earlierTrain, return StopEntity(stationID:direction:routes:).selection(basedOn: base). Have SavedWidgetOptions.results() call SavedWidgetQuery().suggestedEntities().
- Optionally move the id format into Selection.swift (shared), so StopEntity.id and the server shim both use it.

### 92. Spoken line names are built separately in 5+ places and have drifted: shuttles are all "S train", and "A train" may be read as the article

**Low** · Cross-cutting · G30

**Where:** `ios/Shared/LineBullet.swift:44`, `ios/Shared/LineBullet.swift:52`, `ios/Widget/StopList.swift:267`, `ios/Widget/StopList.swift:289`, `ios/Widget/RTrainWidget.swift:1310`, `ios/App/TrainPicker.swift:427`, `ios/App/ChangePicker.swift:259`, `ios/Shared/Lines.swift:95-102`

Spoken line names are built in two ways that have drifted apart. The first is inline `"\(LineStyle.of(route).label) train"`, which says "S" for all three shuttles:
- ios/Shared/LineBullet.swift:44 and :52
- ios/Widget/StopList.swift:267 and :289
- ios/Widget/RTrainWidget.swift:1310
- the bare labels in ios/Shared/Spoken.swift:9

The second is `Lines.name(of:)` (ios/Shared/Lines.swift:95-102), used at:
- ios/App/TrainPicker.swift:427
- ios/App/ChangePicker.swift:259
- ios/App/LiveView.swift:608

As a result, VoiceOver on the widgets, the Live Activity, Nearby rows and the alert banner reads GS, FS and H all as "S train". The app's picker reads "42 St Shuttle train" and so on for the same lines. Whether VoiceOver voices a bare "A train" as the article "a" is unverified.

**Fix:** Add `static func spokenName(of route: String) -> String { "\(name(of: route)) train" }` to Lines, avoiding "Shuttle train" if wanted. Use it at LineBullet.swift:44/52, StopList.swift:267/289, RTrainWidget.swift:1310, TrainPicker.swift:427 and ChangePicker.swift:259. Optionally, for single-letter labels, give the label as `Text(label).speechSpellsOutCharacters()` + " train", so "A" is read as the letter.

### 93. The live/scheduled mark rule and mark views are written separately on every surface

**Low** · Cross-cutting · AF52, BF12

**Where:** `ios/App/SettingsView.swift:24-26`, `ios/Widget/RTrainWidget.swift:337-339`, `ios/Widget/RTrainWidget.swift:695-701`, `ios/Widget/RTrainWidget.swift:763-773`, `ios/Widget/RTrainWidget.swift:799`, `ios/Widget/NearbyWidget.swift:307-309`, `ios/Widget/NearbyWidget.swift:462-466`, `ios/App/LiveView.swift:718-722` (+18 more)

The live/scheduled mark rule is written separately on each surface. `withoutColor || marksLiveTimes` appears at ios/App/SettingsView.swift:24-26, ios/Widget/RTrainWidget.swift:337, ios/Widget/NearbyWidget.swift:307, ios/App/Intents.swift:50 and ios/Widget/TrainLiveActivity.swift:177-180. The LiveMark/ScheduledMark choice appears at RTrainWidget.swift:695-701, 761-773 and 799, NearbyWidget.swift:462-466, ios/App/LiveView.swift:718-722, ios/App/TrainDetail.swift:331-335, Intents.swift:70-74 and TrainLiveActivity.swift:78-82 and 160-164. All copies agree today. The colour and accessibility-source differences are intentional, per surface or forced by the DynamicIsland closures. The Live Activity reads settings.json about once per rendered view, which costs nothing that matters. The risk is that a future rule change misses one surface.

**Fix:** In ios/Shared/LineBullet.swift add `extension AppSettings { func marksLive(withoutColor: Bool) -> Bool { withoutColor || marksLiveTimes } }` and a `StatusMark(isLive:marksLive:marksScheduled:size:)` view that returns LiveMark, ScheduledMark or EmptyView. Each caller keeps its own `.foregroundStyle`. Replace SettingsStore.marksLive and the four other copies with the extension, and use StatusMark at the plain if/else sites. Leave RTrainWidget's ZStack slot variant as is. In TrainLiveActivity, optionally read `SharedStore.loadSettings()` once in CountdownBanner and markedCountdown and pass it down.

Also reported as: BF12 (Train row, live/scheduled marks and the marksLive rule copied in several places).

## Optimizations (6: 6 low)

### 94. A Transfers widget with no change still fetches every feed and builds an hour of entries for a fixed message

**Low** · Transfers · AF50

**Where:** `ios/Widget/RTrainWidget.swift:179`, `ios/Widget/RTrainWidget.swift:221`, `ios/Widget/RTrainWidget.swift:864`, `ios/Widget/RTrainWidget.swift:357`, `ios/Widget/RTrainWidget.swift:1233`

A Transfers widget whose shown saved widget has no change (ios/Widget/RTrainWidget.swift:163-172) still fetches the full board in `plan` (179-232): every connected train feed plus alerts. It also builds up to 60 minute entries plus leave-time entries (221-230), only to show the fixed 'Add a change of trains…' message (864-871). Those trains only feed `fullAlert`'s countdown when an alert is open. With that alert open, `fullAlert` → `buttons(style)` (1374, 1233-1240) draws a dimmed map pill on its own, because `hasButtons` is false (357) and the ↻/walk layer is never drawn.

**Fix:** In `plan`, when `transfers && change == nil`, skip the train feeds and return a single entry. Fetch `TrainService.notices(for:includingOutages:)` only if the selection wants alerts or outages. Use `reloadInterval(at:)` or longer, since the app already calls `reloadAllTimelines` when saved widgets change (WidgetStore.swift:82). In `buttons(_:)`, or in `fullAlert`, skip the row (or at least the map pill) when `!hasButtons`.

### 95. Elevator status is fetched for stations with no elevators

**Low** · Alerts and elevator outages · BF19

**Where:** `ios/Shared/TrainService.swift:162-167`, `ios/App/TrainDetail.swift:245`, `ios/App/AlertsSheet.swift:25-28`

`TrainService.outages(for:if:)` (ios/Shared/TrainService.swift:162-167) fetches and decodes the ENE feed for every station, including the 294 of 496 whose complex has no equipment in equipment.json. TrainDetail.swift:245 then ignores the result. If the ENE fetch fails at such a station, `outages` is nil, so TrainDetail.swift:299-301 never sets `noticesFetched`, and every 30-second reload re-fetches the alerts and ENE feeds. With elevatorAlerts turned on for such a station (WidgetsView.swift:244 allows this anywhere), AlertsSheet.swift:25-28/42-44 shows 'Couldn't load elevator status from the MTA' at a station that has no elevators. Widgets with elevatorAlerts on at such stations also fetch ENE for nothing.

**Fix:** In ios/Shared/TrainService.swift:164, write `guard let complex = selection.station?.complex, EquipmentDirectory.hasEquipment(atComplex: complex) else { return [] }` before the fetch. Optionally mirror this in server/Sources/TrainCore/Poller.swift:271-275 (`Poller.outages(for:in:)`) so the two stay alike.

### 96. The ~1 MB alerts feed is downloaded and decoded even when nothing will show alerts

**Low** · Alerts and elevator outages · CF53, AF49

**Where:** `ios/Shared/TrainService.swift:74`, `ios/Shared/TrainService.swift:78`, `ios/Widget/RTrainWidget.swift:279`, `ios/Widget/RTrainWidget.swift:281`, `ios/App/TrainActivityController.swift:112`, `ios/App/TrainActivityController.swift:144`, `ios/App/Intents.swift:16`, `ios/Shared/TrainService.swift:72` (+1 more)

When a selection has serviceAlerts == false, or Settings has no alert kinds, the widget (RTrainWidget.swift:279,281), countdown (TrainActivityController.swift:112,144) and Siri (Intents.swift:16) still fetch the alerts feed and decode it in full with JSONDecoder (TrainService.swift:78/103 -> alertEntries -> AlertsFeed.entries). The result only feeds Board.notice(for:settings:), which ignores it. The waste can't be avoided today because TrainService.swift:74 makes includingOutages depend on includingAlerts, and the change overload always fetches alerts. This happens only in non-default configurations and costs time and widget memory, not correctness.

**Fix:** Remove line 74, so `outages(for:if: includingOutages)` is independent of alerts, and add `includingAlerts` to the change overload, passing it to `alertEntries(if:)`. In the widget, countdown and Siri callers, pass `includingAlerts: selection.serviceAlerts && !SharedStore.loadSettings().alertKinds.isEmpty, includingOutages: selection.elevatorAlerts`. Leave TrainDetail and AlertsSheet as they are. Check that TrainActivityController's quick board (line 79), which passes includingAlerts: false, still gets the outages it expects.

Also reported as: AF49 (Widgets download and decode the ~1 MB alerts feed even when the widget mentions no alerts).

### 97. Every widget edit, down to each keystroke, rewrites two files and reloads every widget including Trains near you

**Low** · Widgets · BF27, AF75

**Where:** `ios/App/TrainActivityController.swift:99-101`, `ios/App/TrainActivityController.swift:183-185`, `ios/App/WidgetStore.swift:77-83`, `ios/Shared/TrainActivity.swift:56`, `ios/App/SettingsView.swift:67-72`, `ios/App/WidgetsView.swift:154-158`, `ios/App/WidgetsView.swift:233`, `ios/App/WidgetsView.swift:236` (+5 more)

Three calls to WidgetCenter.shared.reloadAllTimelines() also reload the Nearby widget, which uses none of the data they changed: WidgetStore.change (ios/App/WidgetStore.swift:82), TrainActivityController.tellWidgets (ios/App/TrainActivityController.swift:184) and RefreshIntent from the countdown (ios/Shared/TrainActivity.swift:56). Nearby (ios/Widget/NearbyWidget.swift:63-98) reads only settings and location, and each reload costs a location fix and several feed fetches. The widget editor's bindings call update → change on every keystroke or stepper tick (WidgetsView.swift:154, 233-236), so each one does two file writes and a full reload. The elevator button (SettingsView.swift:67-72) does this once per widget. In startNow, tellWidgets (line 99) runs before fetchAll saves the fresh board (103), so after an app-started countdown, widgets showing the same train can re-fetch feeds the app is already fetching.

**Fix:** In WidgetStore.change, tellWidgets and RefreshIntent, replace reloadAllTimelines with `for kind in ["RTrainWidget", "TransfersWidget"] { WidgetCenter.shared.reloadTimelines(ofKind: kind) }`, and move those kind strings into shared constants next to Nearby.widgetKind. Keep reloadAll in SettingsStore. Debounce the editor's saves, for example by committing the name field on submit or by coalescing change() through a short Task delay. Add a batch method such as `WidgetStore.update(_ widgets: [SavedWidget])` for the elevator button. In startNow, save the quick or saved board before tellWidgets, or call tellWidgets after fetchAll.

Also reported as: AF75 (Every saved-widget edit, down to each keystroke in the Name field, rewrites two App Group files and reloads every widget, including Trains near you).

### 98. Trains near you waits for the place-name lookup before fetching trains

**Low** · Widgets · CF49, AF64

**Where:** `ios/Widget/NearbyWidget.swift:76-90`, `ios/Widget/NearbyLocator.swift:41-48`, `ios/Widget/NearbyWidget.swift:76`, `ios/Widget/NearbyWidget.swift:87`, `ios/Widget/NearbyLocator.swift:68-78`

In ios/Widget/NearbyWidget.swift:76, plan awaits NearbyLocator.placeName(for:) (ios/Widget/NearbyLocator.swift:68-78), which reverse-geocodes over the network after a move of more than 250 m or a failed earlier lookup. Only then does it start the independent feed and alert fetches (:87-88), so on those reloads the geocode latency adds to the feed latency inside the time-limited widget extension. Separately, the 10 s timeout Task in requestLocation (NearbyLocator.swift:44-47) is never cancelled after an early fix. That is harmless (finish is idempotent) but keeps the locator alive for up to 10 s.

**Fix:** Compute `near` first and start the place lookup together with the fetches: `async let place = NearbyLocator.placeName(for: location)` next to `async let fetched` / `async let alertEntries`, and await `place` in both the noStations branch and the stations branch. Optionally store the timeout task (`private var timeout: Task<Void, Never>?`) and call `timeout?.cancel()` in `finish(_:)`.

Also reported as: AF64 (Nearby provider looks up the place name before fetching trains instead of alongside).

### 99. Station page and Live tab Nearby rows fetch other lines' feeds and throw those trains away

**Low** · App screens · BF4, CF54

**Where:** `ios/App/LiveView.swift:487-488`, `ios/App/LiveView.swift:458`, `ios/App/LiveView.swift:362-366`, `ios/App/LiveView.swift:351`, `ios/Shared/TrainService.swift:174-179`, `ios/Shared/Lines.swift:47-48`, `ios/Widget/NearbyWidget.swift:87`, `ios/App/LiveView.swift:488` (+2 more)

StationLive (LiveView.swift:488) and the Live tab's load (LiveView.swift:366) fetch with includingOtherLines: true. For a lettered station other than the L, Lines.feedURLs (Lines.swift:42-51) adds the other connected lettered feeds. Rows that keep only their own line's trains (LiveView.swift:351, :458) then throw all of those trains away, because each MTA feed contains only its own lines. StationLive for Prospect Av (R) downloads about 346 KB of -ace/-bdfm/-g/-jz each minute on top of the 133 KB -nqrw it needs, and decodes four extra feeds. The Live tab wastes the same only when no favorite is on a connected lettered line, because favorites legitimately need the other feeds for rerouted trains (Selection.shows, Selection.swift:70-74). This drifts from the documented intent (TrainService.swift:169-173) and from the Nearby widget (NearbyWidget.swift:87).

**Fix:** StationLive.load: `await TrainService.trains(for: selections, includingOtherLines: false)`. LiveView.load: favorites and nearby rows share keys (trainID ignores walkMinutes), so keep the favorites' fuller result. `let favIDs = Set(favorites.favorites.map(\.trainID)); let nearbyOnly = selections.filter { !favIDs.contains($0.trainID) }; async let a = TrainService.trains(for: favorites.favorites); async let b = TrainService.trains(for: nearbyOnly, includingOtherLines: false); let fetched = await a.merging(await b) { fav, _ in fav }`. InFlight already shares feeds both calls need.

Also reported as: CF54 (Station page and Live tab nearby rows fetch other lines' feeds and then throw those trains away).

## Robustness (26: 2 medium, 24 low)

### 100. Any widgets.json decode failure silently wipes every saved widget

**Medium** · Saved state · AF33

**Where:** `ios/Shared/SharedStore.swift:269-275`, `ios/App/WidgetStore.swift:13-17`, `ios/Shared/SavedWidgets.swift:5-14`, `ios/Shared/SavedWidgets.swift:66-70`, `ios/Shared/SavedWidgets.swift:129-139`, `ios/Shared/Change.swift:6-14`, `ios/Shared/SharedStore.swift:309-317`

Any decode failure of widgets.json wipes every saved widget. SharedStore.loadWidgets (ios/Shared/SharedStore.swift:269-275) silently turns it into a one-widget fallback built from selection.json. WidgetStore.init (ios/App/WidgetStore.swift:13-17) writes that fallback back unconditionally, so all saved widgets, names, changes and commuting hours are lost for good. Decoding is all-or-nothing (SavedWidgets.init(from:) decodes [SavedWidget], ios/Shared/SavedWidgets.swift:66-70). SavedWidget, Change and CommutingHours use synthesized Decodable, which ignores property defaults: verified that a missing `weekdays`, `name` or `quickMinutes` throws. Nothing triggers this today, since the past additions were Optional. It becomes data loss the first time a non-optional or default-valued field is added without a tolerant decoder. AppSettings (ios/Shared/SharedStore.swift:309-317) resets to defaults only in memory, and only after a downgrade.

**Fix:** In loadWidgets, return whether the file was missing or present but undecodable. In WidgetStore.init, call saveWidgets only when the file was missing, and when it is undecodable, first copy it to widgets.json.bad. Add hand-written init(from:) to SavedWidget (name: decodeIfPresent ?? ""), Change (quickMinutes/walkMinutes: decodeIfPresent ?? the defaults) and CommutingHours (start/end/weekdays: decodeIfPresent ?? the defaults), like Selection. Optionally decode the widgets array element by element, skipping failures.

### 101. One undecodable registration row stops the server starting, and launchd restarts it into the same failure

**Medium** · Push server · CF3

**Where:** `server/Sources/TrainCore/Registrations.swift:252-272`, `server/Sources/TrainCore/Registrations.swift:101-104`, `server/Sources/TrainCore/Registrations.swift:304`, `server/Sources/TrainCore/ServerMain.swift:43`, `server/deploy/com.traintimes.server.plist:82-86`, `server/Sources/TrainCore/Registrations.swift:257`, `server/Sources/TrainCore/Registrations.swift:264`, `server/Sources/TrainCore/Registrations.swift:268` (+3 more)

server/Sources/TrainCore/Registrations.swift:252-272 loadRegistrations decodes selection (line 264), alert_kinds (266) and last_state (268) with `try` inside a rethrowing compactMap. One blob that fails to decode makes Store.init (line 101) throw, then ServerMain.serve (ServerMain.swift:43). The process exits 1, and launchd's KeepAlive with ThrottleInterval 30 (deploy/com.traintimes.server.plist) keeps restarting it into the same failure. The most plausible cause is a non-optional field added to ContentState (whose header says to mirror the app's properties) or a ServiceAlert.Kind case removed or renumbered, followed by a deploy while countdowns are stored. migrateLegacyFile (line 304) likewise decodes the whole legacy array in one call, so one bad entry fails it all.

**Fix:** In loadRegistrations, decode per row without throwing. If `try? decoder.decode(Selection.self, ...)` fails, skip the row and collect its token to DELETE afterwards. For alert_kinds and last_state use `row[6].blob.flatMap { try? decoder.decode(...) }`, so a bad blob loads as nil and the next pass pushes fresh. Log how many rows were dropped or reset. Decode legacy entries one by one in the same way. Add a StoreTests case that writes a last_state blob missing a key and checks that Store(directory:) still opens with that registration's lastState == nil.

### 102. Skipped stops and cancelled trips in the feed are not recognised

**Low** (uncertain) · Trains and feeds · AF8

**Where:** `ios/Shared/SubwayFeed.swift:159-172`, `ios/Shared/SubwayFeed.swift:177-193`

`SubwayFeed.tripUpdate` (ios/Shared/SubwayFeed.swift:159-172 and 177-193; compiled into app, widget and server) ignores StopTimeUpdate.schedule_relationship (field 5) and TripDescriptor.schedule_relationship (field 4). A stop flagged SKIPPED (1) that still has an arrival or departure time would be returned as an arrival there. A trip flagged CANCELED (3) or DELETED (7) that still has timed stop updates would be shown. `tripStops` (L119-141) likewise counts skipped stops when choosing where to change. Of the captured feeds, only the L feed sends these fields, and every value is SCHEDULED (0).

**Fix:** In the stop_time_update handler, add `case 5: relationship = try reader.varint()`. After `lastStop = stop`, `guard relationship != 1 else { return true }`, so a SKIPPED stop is neither matched nor added to `stops` but can still be the last stop. In the TripDescriptor handler, add `case 4: tripRelationship = try reader.varint()`, and return [] when it is 3 (CANCELED) or 7 (DELETED). Optionally apply the same SKIPPED check in `tripStops`.

### 103. Elevator outage rows omit dates when the MTA leaves a start or end blank

**Low** (uncertain) · Alerts and elevator outages · BF15

**Where:** `ios/App/TrainDetail.swift:392-401`

OutageRow.when at ios/App/TrainDetail.swift:392-401 returns "" (no date line) for three cases: planned work with a start but no estimated return, planned work with only an end, and a current outage with only an estimated return. AlertsSheet's ElevatorDetail (ios/App/AlertsSheet.swift:129-133) does handle the last of these. In today's live ENE feed every row has both dates, so the gap is latent. It matters only if the MTA leaves outagedate or estimatedreturntoservice blank.

**Fix:** Add cases before `default`: `case (true, let start?, nil): return "From \(start)"`, `case (true, nil, let end?): return "Until \(end)"`, `case (false, nil, let end?): return "Back \(end) (estimate)"`.

### 104. One malformed entry fails the whole alerts or outages feed

**Low** · Alerts and elevator outages · CF57

**Where:** `ios/Shared/Alerts.swift:105`, `ios/Shared/Alerts.swift:181`, `ios/Shared/Alerts.swift:207`, `ios/Shared/Outages.swift:51`

Both MTA JSON decoders are all-or-nothing. In `ios/Shared/Alerts.swift:105` the whole feed fails if any entity lacks `id` (line 181), has a header/description/period object without a `translation` array (207) or a translation without `text` (211), or writes a period time that isn't a number (197-198). `TrainService.alertEntries` then returns nil and every board, widget, countdown and server push loses all alerts. Likewise, `ios/Shared/Outages.swift:51` fails the whole outage list if any row lacks `equipment` (73). The live feeds checked on 2026-10-19 all conform, so this is a hardening issue against a single bad MTA row, not a current failure.

**Fix:** Decode the arrays element by element and drop the ones that fail, for example `struct Lossy<T: Decodable>: Decodable { let value: T? ; init(from d: Decoder) { value = try? T(from: d) } }` with `let entity: [Lossy<Entity>]`, then `compactMap(\.value)`. Do the same for `[Lossy<Row>]` in OutagesFeed. Make `Translated.translation` optional (default `[]`). Optionally accept numeric strings for `Period.start`/`end`.

### 105. Changing the live/scheduled mark settings redraws the countdown only after a successful network refresh

**Low** · Lock Screen countdown · BF48

**Where:** `ios/App/SettingsView.swift:14-18`, `ios/App/TrainActivityController.swift:141-145`

Toggling Mark live times or Mark scheduled times (ios/App/SettingsView.swift:14-18) redraws the Lock Screen countdown only by way of a full network refresh (ios/App/TrainActivityController.swift:138-155). If TrainService.board fails or times out after 15 s, line 144 `continue`s without calling activity.update. The countdown keeps its old mark until a later successful refresh, or until iOS redraws it at the stale date, because TrainLiveActivity.swift:177-186 reads the marks from SharedStore only when it renders.

**Fix:** In refreshNow, when the fetch fails, re-post the current state anyway: `guard let board = ... else { await activity.update(content(activity.content.state)); continue }`. For marks-only changes, skip the fetch and just re-post. iOS may not redraw an identical state, so to be sure, carry the marks in ContentState as optional `marksLive`/`marksScheduled` fields with defaults, mirrored in server/Sources/TrainCore/ContentState.swift. Set them when building the state, so a marks change posts content that actually differs.

### 106. Live Activity ContentState and attributes must stay decodable across app updates and an independently deployed server, but nothing enforces or tests that

**Low** · Lock Screen countdown · G24

**Where:** `ios/Shared/TrainActivity.swift:7-29`, `server/Sources/TrainCore/ContentState.swift:3-9`, `server/Tests/TrainCoreTests/ContentStateEncodingTests.swift:51-64`, `ios/App/TrainActivityController.swift:26-28`, `ios/App/TrainActivityController.swift:167-171`

Nothing enforces or tests that `TrainActivityAttributes.ContentState` (ios/Shared/TrainActivity.swift:8-25) and its attributes (selection, stationName, heading; :27-29) stay compatible. The rule they need is that new fields are Optional. Their Codable is synthesized, so a non-Optional field added later, even with a default, makes older JSON fail to decode (verified for the pattern).

The only pinned-format test (server/Tests/TrainCoreTests/ContentStateEncodingTests.swift:51-64) decodes the server's hand-kept copy (server/Sources/TrainCore/ContentState.swift), not the app's type. That copy's comment (line 9) does not state the Optional-only rule.

Today the app does not register push tokens at all: there is no pushType or pushTokenUpdates in ios/. So the danger of server payloads that the app cannot decode is only for the future, once push is wired up. If the app added a required field before the separately deployed server, every push would be undecodable. How ActivityKit handles running activities whose stored content no longer decodes after an app update is unverified.

**Fix:** Document the rule in both structs' doc comments: new ContentState or attribute fields must be Optional, or decoded with `decodeIfPresent` in a hand-written `init(from:)`. Move ContentState into an ActivityKit-free shared file that the server symlinks, and alias it with `typealias ContentState = TrainContentState` inside TrainActivityAttributes. That lets the pinned-payload tests decode with the app's real type. State in server/README.md that the server must be deployed before an app release that changes ContentState.

### 107. Dimmed-screen countdown handling exists only for Lock Screen accessories, not the small widget in StandBy or the Live Activity on the Always-On Lock Screen

**Low** (uncertain) · Widgets · G19

**Where:** `ios/Widget/RTrainWidget.swift:1381-1386`, `ios/Widget/RTrainWidget.swift:1388-1399`, `ios/Widget/RTrainWidget.swift:552`, `ios/Widget/TrainLiveActivity.swift:83`, `ios/Widget/TrainLiveActivity.swift:148-151`

The dimmed-display handling in lockScreenCountdown (ios/Widget/RTrainWidget.swift:1388-1414) is used only by accessoryCircular and accessoryRectangular (:497, :512). Two other countdowns read no `isLuminanceReduced` and have no fallback:
- the home-screen `countdown(to:)` (:1381-1386), which the small widget shows in StandBy (:552), held only to a measured `maxWidth` (:686);
- the Live Activity banner (ios/Widget/TrainLiveActivity.swift:83, :148-151).
Whether they actually show '3:--' or a clipped first digit under StandBy dimming or the Always-On Lock Screen is undocumented and unverified.

**Fix:** Verify on an Always-On iPhone first: StandBy with the small widget, and the Live Activity on the dimmed Lock Screen. If the issue reproduces:
- In countdownLabel, when `luminanceReduced`, show `Text(entry.selection.leaveTime(for: train).clock)` in place of `countdown(to:)`, as lockScreenCountdown does.
- In CountdownBanner, read `@Environment(\.isLuminanceReduced)` and show `Spoken.clock(state.train)` or `.clock` when it is true. Otherwise hold the timer to a hidden '0:00'/'00:00' stand-in, as markedCountdown already does (TrainLiveActivity.swift:156-173).

### 108. Map and alert buttons flip stored state rather than set it, so twin widgets fall out of step

**Low** · Widgets · AF54

**Where:** `ios/Shared/TrainActivity.swift:109`, `ios/Shared/TrainActivity.swift:137`, `ios/Shared/SharedStore.swift:121`, `ios/Widget/RTrainWidget.swift:152`, `ios/Widget/RTrainWidget.swift:399`, `ios/Widget/RTrainWidget.swift:415`

ToggleMapIntent and ToggleAlertIntent (ios/Shared/TrainActivity.swift:109-113, 137-141) flip the stored flag via SharedStore.toggleMap/toggleAlert (ios/Shared/SharedStore.swift:95-97, 106-108, 121-128). They do not store the toggle's new state. Twin widgets share a widgetID (ios/Widget/RTrainWidget.swift:152-158), and per the code's own note iOS reloads only the tapped one. A twin still showing the old state therefore inverts the stored value against what its tap asked for. Its map or alert button appears to do nothing, and the other twin is left wrong until its next scheduled reload.

**Fix:** Make both intents conform to `SetValueIntent` with `@Parameter(title: "On") var value: Bool`; `Toggle(isOn:intent:)` then passes the toggle's new state. Replace `toggle` with `set(_ key: String, to on: Bool, in file:)`, which inserts or removes under the same NSFileCoordinator. Optionally call `WidgetCenter.shared.reloadTimelines(ofKind:)` after storing so twins redraw.

### 109. Trains near you silently falls back to a location up to an hour old

**Low** · Widgets · AF66

**Where:** `ios/Widget/NearbyLocator.swift:27-34`

When a fresh fix can't be had (requestLocation fails, it times out after 10 s, or isAuthorizedForWidgetUpdates is false), NearbyLocator.locate() at ios/Widget/NearbyLocator.swift:27-34 falls back to manager.location if it is up to 60 minutes old. The Nearby widget (ios/Widget/NearbyWidget.swift:75-98) then shows that location's stations, distances and walk times as current. The only hint is that the header shows the old place's name. This contradicts README.md:74-75 ("finds where you are each time it refreshes").
The further case is not authorized for widget updates with no recent fix. There the widget shows "Couldn't find where you are. Tap ↻ to try again." (NearbyWidget.swift:348), which a retry may not fix. How often iOS reports that state is unverified.

**Fix:** In NearbyLocator.swift:31, cut the fallback window from 60*60 to about 10*60. Better, return the fix's timestamp along with it (for example `.found(location, stale: Bool)`) and show "as of h:mm" in the header when the fix is older than a few minutes. Optionally return `.notAllowed(asked: true)` when `!manager.isAuthorizedForWidgetUpdates` and there is no usable fix, so the widget points to the permission setting rather than ↻.

### 110. A crafted traintimes:// link with a huge walk value crashes the app

**Low** · App screens · CF55

**Where:** `ios/Shared/Selection.swift:159`, `ios/Shared/Selection.swift:64`, `ios/App/LiveView.swift:545`

A traintimes://transfer deep link with an out-of-range `walk` (e.g. `walk=999999999999999999`) is parsed without a bound at `ios/Shared/Selection.swift:159`. Once the Transfer page (`ios/App/LiveView.swift:545`) has any train, `catchable` → `leaveTime` (`ios/Shared/Selection.swift:64`) computes `walkMinutes * 60`, which overflows Int and traps in release builds. The app crashes. It isn't persistent, and the app's own Transfers widget links always carry 0...60.

**Fix:** Clamp at parse time: `selection.walkMinutes = min(max(value("walk").flatMap(Int.init) ?? 0, 0), 60)`, matching the app's stepper range. Also make `leaveTime` overflow-proof with `train.time.addingTimeInterval(-TimeInterval(walkMinutes) * 60)`, and do the same in `Change.walk(to:from:)`, which also multiplies `walkMinutes * 60`.

### 111. Live tab's loading state is never shown, and its failure banner can stick with nothing to load

**Low** · App screens · BF18

**Where:** `ios/App/LiveView.swift:60`, `ios/App/LiveView.swift:75`, `ios/App/LiveView.swift:244`, `ios/App/LiveView.swift:363-365`, `ios/App/LiveView.swift:371`

ios/App/LiveView.swift: `.loading` (set at :60 and :365) is never read, because only `== .failed` is checked (:244). `load()` returns before updating loadState when `everyTrain` is empty (:363-364). So after a failed load, removing the last favorite while there are no nearby stations (location off, or no pin) leaves the 'Couldn't reach the MTA. Pull down to try again.' banner up, and pulling down does nothing.

**Fix:** Replace LoadState with `@State private var failed = false` (as StationLive does), and in load() write `guard !selections.isEmpty else { failed = false; return }` and `failed = fetched.isEmpty`. Alternatively keep the enum and set `loadState = .loaded` before the early return.

### 112. A new line or direction is saved twice, first with the old change still attached

**Low** · Saved state · BF28

**Where:** `ios/App/TrainPicker.swift:41-46`, `ios/App/WidgetsView.swift:301-312`

Choosing a new line or direction for a saved widget (or for its commuting hours) updates the store twice. First TrainPicker's single selection write (ios/App/TrainPicker.swift:41-46) goes through WidgetStore.binding (ios/App/WidgetStore.swift:43-50) with the old `change` still attached. Then TripSections' `.onChange(of: selection)` (ios/App/WidgetsView.swift:301-308) clears or validates `change` in a second update. Each update writes two files and calls `reloadAllTimelines`. The half-changed state lasts only milliseconds and the second reload replaces it, so no realistic user-visible failure follows. The weakness is that the 'new line or direction drops the change' rule lives in a view modifier rather than the model, so a future writer (such as the currently unused `WidgetStore.defaultSelection`) would skip it.

**Fix:** Put the rule in the model and apply it in one mutation. Add `mutating func setSelection(_ new: Selection)` to SavedWidget and CommutingHours: if routes or direction change, set `change = nil`, otherwise `change = change?.validated(for: new)`. Then assign `selection`. Have TripSections bind selection through it, for example a Binding whose setter calls `widget.setSelection($0)`, and remove the `.onChange(of: selection)`.

### 113. Alert kinds are stored as Int raw values: reordering them (the obvious fix for AF20) silently remaps Settings, and an unknown value resets every setting

**Low** · Saved state · G21

**Where:** `ios/Shared/Alerts.swift:6-9`, `ios/Shared/SharedStore.swift:291`, `ios/Shared/SharedStore.swift:309-317`, `ios/Shared/SharedStore.swift:255-259`, `ios/App/SettingsView.swift:9-12`, `ios/Shared/SharedStore.swift:229-233`, `ios/Shared/TrainService.swift:47-50`, `server/Sources/TrainCore/Registrations.swift:70-71` (+1 more)

ServiceAlert.Kind (ios/Shared/Alerts.swift:6-9) uses its Int raw values (delays=0, suspended=1, serviceChange=2, notice=3) both for priority ordering and as the stored format, in four places: settings.json alertKinds (ios/Shared/SharedStore.swift:291, 309-317), boards.json Notice.kind (ios/Shared/TrainService.swift:47-50), boardKey (ios/Shared/SharedStore.swift:229-233), and the server's POST /activities body and SQLite alert_kinds column (server/Sources/TrainCore/Registrations.swift:70-71, 245, 266). Reordering the cases, the natural fix for AF20, would silently remap users' saved alert choices and the server's stored registrations. A removed or unknown raw value makes AppSettings decoding throw, so loadSettings (SharedStore.swift:255-259) returns defaults and the next toggle writes them, resetting all five settings. Because the full enabled set is stored, a kind added later starts off for anyone who has ever changed a setting. None of this happens with the current four cases.

**Fix:** Give Kind explicit, permanent raw values (`case delays = 0, suspended = 1, serviceChange = 2, notice = 3`) and add a separate `priority: Int` used by `<`, so the AF20 fix changes only priority. Decode alertKinds leniently: decode `[Int]` and `compactMap(ServiceAlert.Kind.init(rawValue:))`, both in AppSettings.init(from:) and in the server's RegistrationRequest and SQLite load. Optionally store `hiddenAlertKinds` instead, so new kinds default to on.

### 114. Defaults on synthesized-Codable persisted types do not apply when decoding: the next field added the same way breaks saved data, store by store

**Low** · Saved state · G23

**Where:** `ios/Shared/SavedWidgets.swift:8`, `ios/Shared/SavedWidgets.swift:135-139`, `ios/Shared/Change.swift:11-14`, `ios/Shared/Change.swift:102-108`, `ios/Shared/SubwayFeed.swift:17`, `ios/Shared/SubwayFeed.swift:21`, `ios/Shared/SharedStore.swift:56-75`, `ios/Shared/SharedStore.swift:181-195` (+3 more)

Synthesized `init(from:)` treats every non-Optional stored property as required, even a `var` with an initial value. A test confirmed keyNotFound for Arrival without `trip` or `approach`, and for Change without `quickMinutes`.

Two persisted types look like they tolerate missing keys but do not:
- CommutingHours (ios/Shared/SavedWidgets.swift:136-139: start, end, weekdays)
- Arrival (ios/Shared/SubwayFeed.swift:17 trip, :21 approach), which is persisted through SavedBoard and Connection in boards.json

Selection and AppSettings (ios/Shared/SharedStore.swift:309-317) do have hand-written lenient decoders. All fields shipped so far are compatible, so nothing breaks today.

A future non-Optional field written this way would make the silent `try?` loads fail:
- widgets.json: `loadWidgets` (SharedStore.swift:269-275) falls back to one widget built from selection.json, and the user's other saved widgets are lost on the next save.
- countdown.json: `loadCountdown` (72-75) returns nil, so a widget's walk button starts a new countdown instead of stopping the running one (TrainActivityController.swift:121).
- boards.json: only a refetch is lost.

map.json and alert.json are `[String]` arrays and are not affected. No decode failure is logged anywhere.

**Fix:** Give CommutingHours and Arrival, and any persisted type that later gains a defaulted field, a hand-written `init(from:)` that uses `decodeIfPresent(...) ?? default`, as AppSettings does. Or add a small default-value property wrapper. Add pinned-JSON decode tests for today's widgets.json, countdown.json and boards.json formats. Replace the bare `try?` in loadWidgets, loadCountdown and savedBoards with do/catch that logs through os.Logger.

### 115. FavoritesStore replaces every favorite with the default widget's train, and saves that, whenever the saved list fails to decode

**Low** · Saved state · G22

**Where:** `ios/App/FavoritesStore.swift:20-38`, `ios/Shared/Selection.swift:35-44`

In ios/App/FavoritesStore.swift:20-38, `init` treats "no saved data" and "saved data that fails to decode" the same way. If decoding `[Selection]` fails because of any single element, the whole ordered favorites list (each entry with its own walking time) is replaced by the default widget's train and written to UserDefaults.standard right away (lines 35-37), so the original data is lost for good. This can't happen with the current Selection format (Selection.swift:35-54 has been stable since e4007e6, when FavoritesStore was added). It becomes reachable only after a future change to Selection or Direction decoding, or a downgrade to a build that uses a different format.

**Fix:** In FavoritesStore.init, branch on `UserDefaults.standard.data(forKey: Self.key)` first. Seed and save the default train only when it is nil. When data exists, decode it element by element (decode `[AnyDecodable]`/`[JSONValue]`, or use a lossy wrapper with `try?` per element) and keep the elements that decode. If any element fails, copy the raw data to a backup key such as "favorites.unreadable" and don't write until the user edits the list. Add a test that decodes a pinned favorites JSON in today's format.

### 116. Map and alert toggle entries are never pruned, and replaced App Group files are left behind

**Low** · Saved state · AF43

**Where:** `ios/Shared/SharedStore.swift:91-128`, `ios/Shared/SharedStore.swift:28-36`

Map entries in map.json (SharedStore.swift:95-97) are removed only by tapping the map button again on the same widgetID, and widgetID is "<kind> <family> <config>" (ios/Widget/RTrainWidget.swift:152-158). So a medium or large widget removed while showing its map leaves its entry behind, and a new widget with the same kind, size and Edit-menu choices opens on the map. Alert entries are pruned once a reload sees no notice (RTrainWidget.swift:190-193), but never for removed widgets. Pre-9be9058 bare-id entries in map.json and alert.json (old alert ids look like "R34:N:R true true") can never match or be removed. refreshed.json and toggled.json (replaced by taps.json, SharedStore.swift:32) are left in the App Group container. All of this is tiny and cosmetic.

**Fix:** Do a one-time cleanup, e.g. when SharedStore is first used in the app. Delete refreshed.json and toggled.json. Drop map/alert entries that don't start with "RTrainWidget " or "TransfersWidget "; don't use the no-space test, because old alert ids contain spaces. For removed widgets, either prune map.json in the app against WidgetCenter.shared.getCurrentConfigurations (rebuilding each widgetID from kind, family and intent), or store a toggle date with each entry and drop entries older than a day in toggle(_:in:).

### 117. An out-of-range time in the feed crashes the server on every pass

**Low** · Push server · CF52

**Where:** `server/Sources/TrainCore/Pusher.swift:78`, `server/Sources/TrainCore/Pusher.swift:88`, `server/Sources/TrainCore/Log.swift:16`, `ios/Shared/SubwayFeed.swift:243`, `ios/Shared/SubwayFeed.swift:193`

ios/Shared/SubwayFeed.swift:240-247 reads StopTimeEvent.time as a UInt64, and line 193 accepts any non-zero value as `Date(timeIntervalSince1970:)`. A negative int64 time therefore becomes a date about 1.8e19 s after 1970, which passes every filter (Poller.swift:247 and ActivityState.swift:22 only check `> now`). If that arrival becomes a countdown's target, three conversions overflow and trap: `Int(...timeIntervalSince1970)` at server/Sources/TrainCore/Pusher.swift:78-81 (expiration) and :88 (stale-date), and, with LOG_PUSHES=1, `Int(date.timeIntervalSince(now).rounded())` at Log.swift:16. The trap crashes the server on every pass for as long as the feed keeps the value. The trigger needs a malformed feed (a negative time on the followed or only trip), so the risk is low.

**Reproduced:** SubwayFeed.eventTime reads StopTimeEvent.time as UInt64 and tripUpdate accepts any non-zero value (ios/Shared/SubwayFeed.swift:188-193, 239-246); Pusher.notification converts with Int(...timeIntervalSince1970) (server/Sources/TrainCore/Pusher.swift:78-88), which traps above Int.max (a negative int64 encodes as ~1.8e19). Needs a malformed MTA stop time on a tracked/only train, so unlikely, but the result is a crash loop under launchd.

**Fix:** In SubwayFeed.tripUpdate, after `let due = ...`, treat implausible times as missing: `guard due != 0, due < 4_102_444_800 else { return true }` (year 2100). That one check protects the app, the widget and the server. As a second guard, in Pusher.notification and Log.relative convert with a clamping helper, e.g. `Int(exactly: x.rounded(.down)) ?? Int.max`, or clamp the Double to ±9e18 before calling Int().

### 118. Expressions within reach of the type-checker limit on Swift 6.2, including one in server code that install.sh builds

**Low** · Push server · G2

**Where:** `server/Sources/TrainCore/Poller.swift:245-249`, `server/Tests/TrainCoreTests/AttestTestSupport.swift:17`, `ios/Shared/TrainService.swift:198-202`

On Swift 6.2.1, server/Sources/TrainCore/Poller.swift:245-249 (the `(feeds.own + feeds.others).flatMap{...}.filter{...}.sorted{...}.oncePerTrip()` chain in liveBoards) takes about 2.4 s to type-check and needs 200k-300k solver scopes. One plausible edit, such as an extra Date-arithmetic condition in the filter or a tie-break in the sort closure, pushes it past the limit, and the release build that server/deploy/install.sh:27 runs then fails. The same pattern in ios/Shared/TrainService.swift:198-202 (about 300 ms; it compiles into the app, the widget and the server) also fails with those two edits. server/Tests/TrainCoreTests/AttestTestSupport.swift:17 (CBOR head default branch) takes about 2 s. It also only ever writes 4 bytes, so a value of 2^32 or more would be truncated, though none is used. No code fails today.

**Fix:** In Poller.swift:245, give the intermediates explicit types: `let feedURLs: [URL] = feeds.own + feeds.others; let found: [Arrival] = feedURLs.flatMap { (url: URL) -> [Arrival] in guard let byStop = arrivals[url] else { return [] }; return stopIDs.flatMap { (stop: String) -> [Arrival] in byStop[stop] ?? [] } }; let trains = found.filter { ... }.sorted { ... }.oncePerTrip()`. Use a name other than `urls` so it doesn't shadow the outer `urls`. I verified this is under 50 ms even with extra conditions. Make the same change at TrainService.swift:198 (`let merged: [Arrival] = (feeds.own + feeds.others).flatMap { (url: URL) -> [Arrival] in arrivals[url] ?? [] }`). In the CBOR helper, write the bytes out directly: `[major << 5 | 26, UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]`, and add a 27 (8-byte) case if 64-bit values are ever needed.

### 119. In-memory limiter and challenge structures can grow without bound under floods

**Low** · Push server · CF19

**Where:** `server/Sources/TrainCore/Limits.swift:45-62`, `server/Sources/TrainCore/Limits.swift:69-72`, `server/Sources/TrainCore/Limits.swift:87`, `server/Sources/TrainCore/Limits.swift:100-108`

DailyLimiter.counts (server/Sources/TrainCore/Limits.swift:48, 52-61) has no size cap: every distinct client address that consumes a challenge in POST /attest (HTTP.swift:139-142) adds an entry that lives until UTC midnight. ChallengeStore.queue (Limits.swift:71, 87) keeps consumed challenges until they expire, because consume() (Limits.swift:93-96) removes them only from `expiries`, and MAX_CHALLENGES bounds outstanding challenges (expiries.count), not the queue. Under issue-and-consume floods from rotating addresses (IPv6 per-/128 keys), memory grows with request rate x 300 s for the queue and with distinct addresses per day for DailyLimiter, not with configured limits.

**Fix:** Give DailyLimiter a maxTracked (for example 200_000). When a new client would exceed it, refuse with false, which answers 429. Otherwise counts is already cleared daily. In ChallengeStore.issue, also refuse when `queue.count - head >= 2 * limit`. Alternatively, have consume() mark the entry so purge() can compact, or keep issued challenges in one ordered dictionary that consume() removes from.

### 120. Package.swift understates what the package needs: toolchain floor, swift-certificates minimum, Darwin-only SQLite3

**Low** · Push server · G3

**Where:** `server/Package.swift:1`, `server/Package.swift:17`, `server/Sources/TrainCore/AppAttest.swift:4`, `server/Sources/TrainCore/AppAttest.swift:136`, `server/Sources/TrainCore/SQLite.swift:2`

server/Package.swift understates its requirements in two ways:
- Line 1 says swift-tools-version 6.0, but its own minimum dependency (hummingbird from 2.28.0, tools 6.2) and the pinned graph need Swift 6.2 or later, so a 6.0 or 6.1 toolchain fails resolution.
- Line 17 allows swift-certificates from 1.0.0, but AppAttest.swift:4 and :136 use the FixedExpiryValidationTime SPI and RFC5280Policy(fixedExpiryValidationTime:), which first exist in 1.15.0. This is masked by the committed Package.resolved pin of 1.21.0.

Separately, `import SQLite3` (SQLite.swift:2) makes the package Darwin-only. That matches its stated macOS LaunchDaemon deployment (`platforms: [.macOS(.v14)]`, server/README.md:16) and is undocumented rather than a bug.

**Fix:** Set `// swift-tools-version:6.2` and change line 17 to `.package(url: "https://github.com/apple/swift-certificates.git", from: "1.15.0")`. Add one line to server/README.md saying it builds on macOS with Swift 6.2+ (and on Linux only with an added SQLite3 systemLibrary target). Only add the Linux systemLibrary target if a Linux CI job is actually introduced.

### 121. SQLite connection is closed twice when opening the database fails

**Low** · Push server · CF9

**Where:** `server/Sources/TrainCore/SQLite.swift:24-41`

server/Sources/TrainCore/SQLite.swift:28-41 has a use-after-free. When sqlite3_open_v2 fails, init calls `sqlite3_close(handle)` (line 32) and throws without setting `handle = nil`. Because `self` is already fully initialized (both stored properties have defaults), Swift runs deinit, and deinit calls `sqlite3_close(handle)` again on the freed connection (line 40). In testing, SQLite's misuse check makes the second call a no-op returning SQLITE_MISUSE, and the error is still thrown and logged normally. It is undefined behavior on the open-failure path, not an observed crash.

**Fix:** In the failure branch, set `handle = nil` after `sqlite3_close(handle)`. sqlite3_close(NULL) is a harmless no-op. Alternatively, drop the explicit close and let deinit release the handle.

### 122. server.log is never rotated, and every refused request writes a line

**Low** · Push server · CF23

**Where:** `server/deploy/com.traintimes.server.plist:158-161`, `server/Sources/TrainCore/HTTP.swift:277-284`, `server/deploy/install.sh:51`

server.log (server/deploy/com.traintimes.server.plist:72-75, created at server/deploy/install.sh:51) is never rotated. Every refused auth request logs a line (server/Sources/TrainCore/HTTP.swift:246-284), limited only per client IP by the 30/min rate limit. Each poll pass logs a line every 30 s while countdowns are registered. The file grows without bound, slowly in normal use and quickly under distributed junk traffic, on the disk that also holds the SQLite database.

**Fix:** Have install.sh install /etc/newsyslog.d/traintimes.conf, e.g. `/usr/local/traintimes/server.log traintimes:staff 600 7 10240 * NJ` (size-based, compressed; launchd reopens stdout on restart, or use the N flag and rely on append). Optionally aggregate auth refusals into a per-minute summary line.

### 123. make_altstore_source.py can miss a bundle's entitlements if a stray '<?xml' appears in the binary

**Low** · Tools, Scriptable and CI · BF58

**Where:** `tools/make_altstore_source.py:37-47`, `tools/make_altstore_source.py:62-63`

tools/make_altstore_source.py:40 uses `re.findall(rb"<\?xml.*?</plist>", executable, re.S)`. A `<?xml` byte sequence earlier in a Mach-O with no `</plist>` after it (for example an XML/GPX/SVG string literal in __TEXT) makes the match start there and swallow the code-signature entitlements plist. plistlib then fails at :42 and the exception is silently skipped at :43-44, so that bundle's entitlements are missing from source.json (:62). Nothing triggers it today: no such string exists in the code, and the app and widget have identical entitlements and usage strings. It would bite only if an app-only entitlement were added together with such a string. Separately, :63 merges privacy strings last-wins across bundles, which is harmless while the strings are identical.

**Fix:** Minimal: stop a match from crossing another XML header, with `re.findall(rb"<\?xml(?:(?!<\?xml).)*?</plist>", executable, re.S)`. More robust: since CI runs on macOS and already uses codesign, read each bundle's entitlements with `codesign -d --entitlements - --xml <bundle>`, or parse the 0xfade7171 blob by its length. Also exit non-zero when a bundle yields no entitlements. For privacy, keep the app's value when keys collide (`privacy.setdefault`).

### 124. A duplicate platform id in stations.json would crash the app, widget and server

**Low** · Cross-cutting · CF58, AF28

**Where:** `ios/Shared/Stations.swift:148`, `ios/Shared/Stations.swift:151`, `tools/make_stations.py:88`, `ios/Shared/Stations.swift:148-151`, `tools/make_stations.py:88-110`

ios/Shared/Stations.swift:148-151: `byID` and `platformsByID` use `Dictionary(uniqueKeysWithValues:)`. A duplicate platform id in stations.json would trap the first time either lazy static is touched. That is the first `StationDirectory.station(id:)`, `shortName`, `terminalName` or `borough` call, including `Selection.stopIDs`, in the app, the widget and the server alike. tools/make_stations.py:88-105 doesn't check uniqueness, and no CI step runs code that touches these dictionaries. The server's start-up check (ServerMain.swift:37) reads only `platforms`, so the server traps on its first lookup, not at start-up. The current data has no duplicates.

**Fix:** In Stations.swift use `Dictionary(all.flatMap { s in s.platforms.map { ($0.id, s) } }, uniquingKeysWith: { first, _ in first })`, and the same for platformsByID. In make_stations.py, after building `stations`, do: `dupes = [k for k, n in collections.Counter(s['id'] for s in stations).items() if n > 1]; sys.exit(f'duplicate GTFS Stop IDs: {dupes}') if dupes else None`.

Also reported as: AF28 (Duplicate platform ids would crash the app, widget and server at static init).

### 125. Saved-board and fetch timestamps from the future (clock set back) count as fresh indefinitely

**Low** · Cross-cutting · CF47

**Where:** `ios/Widget/RTrainWidget.swift:268-270`, `ios/Widget/RTrainWidget.swift:106-115`, `ios/Shared/SharedStore.swift:212`, `ios/Shared/TrainService.swift:256`

Freshness checks treat a timestamp in the future as fresh: ios/Widget/RTrainWidget.swift:268-269 (30-second board reuse, which also defeats ↻ because `refreshed` < `fetched`), :110 (reload = fetched + interval), ios/Shared/SharedStore.swift:212 (boards prune), and ios/Shared/TrainService.swift:256 (InFlight `recent`, which matters in the app and for the 30 s alerts cache). After the device clock moves back by X, a widget keeps redrawing its saved board, ends up showing no trains once those depart, and doesn't fetch or reload for about X. The app's feed cache likewise returns stale data for about X.

**Fix:** Treat `fetched > now` as stale everywhere: in board() use `(0..<30).contains(now.timeIntervalSince(saved.fetched))`; in timeline() use `reload = min(fetched, now) + interval` (or clamp reload to at most now + interval); in saveBoard filter `(0..<3600).contains(fetched.timeIntervalSince($0.value.fetched))`; in InFlight filter `(0..<window).contains(now.timeIntervalSince($0.value.fetched))`.

## Accessibility (13: 1 medium, 12 low)

### 126. Next train medium: fixed 130/150-pt column and 14.5/19-pt rows don't grow with Dynamic Type, so minutes run off the widget, rows overlap, and on SE/mini with a banner the layout shifts and the map button drops below ↻/walk

**Medium** · Widgets · G7

**Where:** `ios/Widget/BoardStyle.swift:27-39`, `ios/Widget/RTrainWidget.swift:583-620`, `ios/Widget/RTrainWidget.swift:626-644`, `ios/Widget/RTrainWidget.swift:795-821`, `ios/Widget/StopList.swift:25-29`, `ios/Widget/StopList.swift:64-83`

The medium Next train widget's right-hand column has a fixed width: 130 pt compact, 150 large (ios/Widget/BoardStyle.swift:33). Its rows have a fixed pitch: 14.5 or 19 pt (BoardStyle.swift:36; RTrainWidget.swift:818). The time and minutes text in it follows Dynamic Type, and the rows are rigid HStacks of fixedSize pieces (RTrainWidget.swift:795-821).

When the mark slot and bullet are present (a multi-line selection plus Mark live/scheduled times or Differentiate Without Color), a row needs:
- compact: ~150 pt at xxxLarge
- large: ~170 pt at xxxLarge (e.g. iPhone 15)

The `.topLeading` column frame (RTrainWidget.swift:643) pushes the excess right, past the 16-pt margin, so "12 min" is clipped at the widget edge. At accessibility sizes the fixedSize rows overflow their fixed row heights and the digits overlap. StopList rows (StopList.swift:25-29, 64-83) have a minimum of the same pitch and behave alike.

ViewThatFits (RTrainWidget.swift:630-640) only measures height, and row height doesn't track text size. It never responds to width overflow.

On an SE medium with a banner, the left side needs more than the ~102 pt available:
- with Larger widget text, from about the default size on
- without it, at larger text sizes

`.frame(width:height:)` (577) then centres the overflow, so the times layer's map pill can sit below the ↻ and walk pills, which the controls layer pins to the bottom. Unverified: how much the header's minimumScaleFactor absorbs, and whether WidgetKit uses AX sizes on the Home Screen.

**Fix:** In laterTrains, measure the needed row width: mark slot + 3 + timeWidth + 3 + bullet + minutesGap + minutesWidth.
- When it exceeds `style.columnWidth`, drop the minutes column, then the mark slot, or widen the column at the expense of `textRoom`, which mediumLayout already computes.
- Derive the row height from `style.timeUIFont.lineHeight`, with the current constant as a floor, so ViewThatFits drops rows as the text grows.

On the left, if the header + countdown + buttons (+ banner) exceed `size.height`, use one heading line or a smaller countdown rather than letting the fixed frame centre the overflow.

As a stopgap, cap the widget with `.dynamicTypeSize(...DynamicTypeSize.xxLarge)`, together with the measurement fix in G9.

### 127. Live Activity: VoiceOver reads the buttons before the countdown and gets a bare timer, and the Dynamic Island never shows the notice

**Low** · Lock Screen countdown · G29

**Where:** `ios/Widget/TrainLiveActivity.swift:65-109`, `ios/Widget/TrainLiveActivity.swift:20-44`, `ios/Widget/TrainLiveActivity.swift:45-55`, `ios/Widget/TrainLiveActivity.swift:93-98`

ios/Widget/TrainLiveActivity.swift:65-109: CountdownBanner has no accessibility grouping or sort priority, so VoiceOver reads Refresh and Stop the countdown (header row, line 74) before the countdown (77-88). The countdown is a lone Text(timerInterval:) whose live or scheduled status is spoken only when a mark is drawn. The notice (94-98) is read as a bare kind label ('Delays', 'Suspended', 'Elevator out'). In the Dynamic Island, compactLeading and compactTrailing (45-52) are two unrelated elements, and minimal (53-54) speaks only the line. The expanded region (20-44) shows neither the notice nor the following trains, so a suspension or elevator notice is never shown or spoken in the island.

**Fix:** In CountdownBanner:
- Wrap the mark and countdown HStack in `.accessibilityElement(children: .combine)` with an `.accessibilityLabel` that always includes the status ("Live" or "Scheduled") and the line, plus `.accessibilitySortPriority(1)` so it is read first.
- Combine the header VStack into one element.
- Give the notice `.accessibilityLabel("Alert: \(notice)")`.

In the island:
- Give minimal's bullet `.accessibilityLabel` with the line and the countdown time.
- When shownState(context).notice is non-nil, add a one-line `Label(notice, systemImage: "exclamationmark.triangle.fill")` to DynamicIslandExpandedRegion(.bottom).

### 128. Column widths are measured with the process-wide content size category, not the widget's environment; labelUIFont is cached for the process lifetime, and a .dynamicTypeSize cap would not reach these measurements

**Low** · Widgets · G9

**Where:** `ios/Widget/BoardStyle.swift:60-62`, `ios/Widget/RTrainWidget.swift:1101-1102`, `ios/Widget/RTrainWidget.swift:1438-1442`, `ios/Widget/StopList.swift:27`, `ios/Widget/RTrainWidget.swift:1320`

The widget measures text widths and heights with `UIFont.preferredFont(forTextStyle:)` and no trait collection, which uses the process-wide content size category. The SwiftUI Text drawn beside it follows the view's `dynamicTypeSize` environment instead. The measurement sites are:
- ios/Widget/BoardStyle.swift:22, :60-62
- ios/Widget/RTrainWidget.swift:1320, :1440
- ios/Widget/StopList.swift:27

The two agree today, but any environment override would split them. In particular, a `.dynamicTypeSize(...)` cap added to fix G7 would leave the columns sized for the uncapped text.

Separately, `labelUIFont` (ios/Widget/RTrainWidget.swift:1101-1102) is a `static let`, fixed for the process's lifetime. It sizes the Transfers "THEN IN" column (RTrainWidget.swift:947, inside `max(lead, ...)`). If WidgetKit re-renders in the same process after a text-size change, that column keeps its stale width (runtime-dependent, unverified).

**Fix:** Read `@Environment(\.dynamicTypeSize)` in TrainWidgetView and pass a trait collection into BoardStyle, TransferColumns, StopList and alertText:
`UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))`
Then measure with `UIFont.preferredFont(forTextStyle:compatibleWith:)`. Make `labelUIFont` a function of that trait collection instead of a `static let`. Or replace the UIKit measuring with SwiftUI layout: a Grid, or hidden placeholder Text that sizes the columns.

### 129. Decorative SF Symbols are read inside combined labels, and the Settings text names the Live mark by an unlabeled inline image

**Low** · Widgets · G31

**Where:** `ios/Widget/RTrainWidget.swift:1255-1259`, `ios/Widget/RTrainWidget.swift:1269-1271`, `ios/Widget/NearbyWidget.swift:492-494`, `ios/Widget/NearbyWidget.swift:526-527`, `ios/Widget/NearbyWidget.swift:362-363`, `ios/App/SettingsView.swift:82`

Decorative SF Symbols without labels are spoken inside combined or linked elements:
- The alert banner's kind symbol and chevron, ios/Widget/RTrainWidget.swift:1255-1259 and 1269-1271, inside the `.combine` Button at 427-432.
- Nearby noticeRow's symbol, ios/Widget/NearbyWidget.swift:492-494, which is redundant with bannerText's bold kind.
- The folded row's chevron.right (NearbyWidget.swift:526-527) and the header's location icon (362-363).
Separately, the Settings footnote at ios/App/SettingsView.swift:82 describes the Live mark with an unlabelled inline image, so VoiceOver reads the symbol's own description and not "Live", the word LiveMark speaks on the widgets (ios/Shared/LineBullet.swift:118). This is accessibility polish only.

**Fix:** Add `.accessibilityHidden(true)` to the banner's notice symbol and chevron (RTrainWidget.swift:1255, 1269), to the Nearby noticeRow symbol (NearbyWidget.swift:492) and to the chevron.right (526). Give the header icon `.accessibilityLabel(located ? "Your location" : "Location unknown")` or hide it. In SettingsView.swift:80-82, keep the inline image but label the subtitle Text, since `Image(...).accessibilityLabel` is no longer an Image and can't be interpolated into Text: `Text("Live predictions get \(Image(systemName: "dot.radiowaves.up.forward")) as well as their green.").accessibilityLabel("Live predictions are marked Live as well as green.")`. Do the same for the clock symbol in the Mark scheduled times subtitle ("marked Scheduled").

### 130. Fixed-height containers around Dynamic Type text: Transfers map positions, wait pill, button pills

**Low** · Widgets · G10

**Where:** `ios/Widget/TransferMap.swift:19-21`, `ios/Widget/TransferMap.swift:90-93`, `ios/Widget/TransferMap.swift:139-145`, `ios/Widget/RTrainWidget.swift:1175-1197`, `ios/Widget/Pills.swift:18-21`

Several widget views put scalable text inside fixed geometry, with no Dynamic Type cap anywhere in ios/:
- ios/Widget/TransferMap.swift:19-21, 87-101, 138-146: TransferTrack's stop names, times and train markers sit at fixed y offsets (7, 28, 44, 64 or 50) in a fixed-height frame. Stop times are `.fixedSize()` caption text centred on stops about 62 pt apart (5 stops on a 6.1" large widget), so neighbouring times overlap from about AX2.
- ios/Widget/RTrainWidget.swift:1175-1197: waitCell is a 20 pt capsule around footnote text. On a quick pill the text is drawn in boardBackground, so glyph parts outside the pill disappear. This is marginal at AX3 and clear at AX4 and AX5.
- ios/Widget/Pills.swift:18-21: Pill is a fixed 24/26 pt frame around a scaling symbol.

The ViewThatFits fallbacks (RTrainWidget.swift:957-963) react only to vertical fit, which does vary with text size through the labels row and the card, but never to horizontal collisions.

**Fix:** - In TransferTrack, read `@Environment(\.dynamicTypeSize)`. Drop showsTimes when the widest stop time, measured with the caption font (e.g. String.width(in:), already used in RTrainWidget), exceeds `track.spacing - 4`, and derive the y offsets from the font's line height.
- Alternatively, cap the map with `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`.
- For waitCell, use `.frame(minHeight: 20)` with `.padding(.vertical, 2)` instead of a fixed height.
- For Pill, use `.frame(minHeight:)`, or cap the symbol with `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`.

### 131. Glyphs in visible text are read literally: "Tap ↻", lone "–" placeholders, "→" in titles

**Low** · Widgets · G28

**Where:** `ios/Widget/NearbyWidget.swift:328`, `ios/Widget/NearbyWidget.swift:348`, `ios/Widget/RTrainWidget.swift:499-501`, `ios/Widget/RTrainWidget.swift:1211-1216`, `ios/Widget/RTrainWidget.swift:1012-1014`, `ios/Widget/RTrainWidget.swift:1113`, `ios/App/TrainDetail.swift:190`

Several visible strings use a glyph as a word, with no accessibility label:
- "Tap ↻ to try again" in ios/Widget/NearbyWidget.swift:328 and :348, and "Tap ↻ on it" in ios/App/TrainDetail.swift:190. VoiceOver names the glyph, while the control is labelled "Refresh" (ios/Widget/Pills.swift:100,103).
- Lone "–" placeholders in ios/Widget/RTrainWidget.swift:499-501 (accessoryCircular, used for both no trains and a failed fetch) and :1211-1216 (Transfers nextCell, read after waitCell's "No train to change to").
- "→" in transferTitle (:1012-1014) and transferLabels (:1113), read as "right arrow".

**Fix:** Add accessibility labels:
- On the Label at NearbyWidget.swift:328: `.accessibilityLabel("Couldn't reach the MTA. Tap Refresh to try again.")`. Likewise for the :348 detail text, and reword the TrainDetail.swift:190 footer to say "Refresh".
- On Text("–") at RTrainWidget.swift:500: `.accessibilityLabel(entry.problem ?? "No trains")`.
- On Text("–") at :1212: `.accessibilityHidden(true)`.
- On transferTitle's Text: `.accessibilityLabel("\(entry.stationName) to \(change.station?.name ?? "")")`.
- On the transferLabels trip Text: `.accessibilityLabel("\(lines) to \(station)")`.

### 132. Nearby widget rows: links omit the line, read minutes as "12, min", and the app's own Nearby rows already solved this

**Low** · Widgets · G27

**Where:** `ios/Widget/NearbyWidget.swift:408-419`, `ios/Widget/NearbyWidget.swift:428-454`, `ios/Widget/NearbyWidget.swift:458-483`, `ios/App/LiveView.swift:608-610`, `ios/App/LiveView.swift:694-695`

In the Trains near you widget, each direction Link (ios/Widget/NearbyWidget.swift:430-448) combines its children into labels like "Manhattan, 12, min" or "Manhattan, Live, 12, min", and "Manhattan, –" when there's no train or the feed failed (476). The line is named only by the separate LineBullet element before the links (413, labelled "R train"). A VoiceOver user who touches or jumps straight to a link doesn't hear which line it is. The app's equivalent row (ios/App/LiveView.swift:608-610) names the line in the label and puts spoken minutes in the value (Minutes.spoken, 703-711). The widget never got that treatment. This is inconsistent accessibility, not duplicated code.

**Fix:** Move `Minutes.spoken` out of the private struct in ios/App/LiveView.swift into a Shared or Widget extension (for example `extension Arrival { static func spoken(_:now:) }`) and add a live/scheduled word. In NearbyWidget.swift way(_:), replace `.accessibilityElement(children: .combine)` with `.accessibilityElement(children: .ignore)` plus `.accessibilityLabel("\(Lines.name(of: direction.selection.firstRoute)) \(direction.label)")` and `.accessibilityValue(next.map { spoken } ?? (direction.trains == nil ? "Couldn't load" : "No trains"))`, with the alert's label appended when present.

### 133. The "where the train is" maps (StopList, TransferTrack) say nothing to VoiceOver about where the trains are

**Low** · Widgets · G26

**Where:** `ios/Widget/StopList.swift:31-62`, `ios/Widget/StopList.swift:64-83`, `ios/Widget/StopList.swift:168-246`, `ios/Widget/TransferMap.swift:51-65`, `ios/Widget/TransferMap.swift:78-121`, `ios/Widget/TransferMap.swift:125-146`, `ios/Widget/TransferMap.swift:294-382`

The "where the train is" maps give VoiceOver no description of position.

StopList (ios/Widget/StopList.swift:31-83):
- It speaks its "N STOPS AWAY" label and the stop names. It never says which stop the train is at or between, or which row is your stop (shown only by weight and colour, 69-71).
- A not-yet-departed train's departs time (74-80) is a bare clock.

TransferTrack (ios/Widget/TransferMap.swift:51-146):
- It has no stops-away summary.
- Its track legend words are spoken without their hidden swatches (75).
- Stop names and times come in declaration order from the change backwards (87).
- The two markers are just "D train" and "R train". The rails, your stop and the shared platforms are in Canvases (StopRail 168-246, TrackRails 294-382) and invisible to accessibility.
- Note that the D's marker shows a time-equivalent position on your train's route (228-232), not its real location.

**Fix:** Make each map one accessibility element: `.accessibilityElement(children: .ignore).accessibilityLabel(layout.spoken)`. Add pure, unit-testable `spoken` properties:
- StopLayout: "R train, live, between 36 St and 25 St, 7 stops from Prospect Av, your stop", built from trainRow, rows and isTrainStop. For .starting: "scheduled to leave 95 St at 8:12".
- TransferMapLayout: "Your R is between 4 Av-9 St and Union St, 2 stops from Atlantic Av." Then nextNote when the D is off the map ("D at 9 Av"); otherwise describe the D by time ("the D gets to Atlantic Av N min after you"), not by nextRow's stop. Add "you share a platform at …" for rows with `shared`.
Keep the existing `.accessibilityHidden(true)` swatches, and fold the LOCAL/EXPRESS legend into that sentence or label it "Local track: R" / "Express track: D".

### 134. VoiceOver on the widgets never says whether a time is live unless the visual marks are turned on

**Low** · Widgets · G18

**Where:** `ios/Widget/RTrainWidget.swift:762-773`, `ios/Widget/RTrainWidget.swift:695-701`, `ios/Widget/RTrainWidget.swift:1381-1386`, `ios/Widget/NearbyWidget.swift:447`, `ios/Widget/NearbyWidget.swift:462-469`

On the Next train, Transfers and Trains near you widgets, VoiceOver says 'Live' or 'Scheduled' only when the visual marks are on (Settings › Mark live/scheduled times, or Differentiate Without Color):
- ios/Widget/RTrainWidget.swift:763-772 hides the marks from accessibility by the visibility flags.
- statusMark (:695-701) and NearbyWidget.time (ios/Widget/NearbyWidget.swift:462-466) draw nothing when the marks are off.
- The countdowns (:1381-1386) and clock Texts carry no live or scheduled value.
With default settings, a timetable time sounds the same as a live prediction.

**Fix:** Make accessibility independent of the visual marks:
- In timeAndBullet, use `.accessibilityHidden(!train.isLive)` for LiveMark and `.accessibilityHidden(train.isLive)` for ScheduledMark.
- In `countdown(to:)` and laterTrain's clock Text, add `.accessibilityValue(train.isLive ? "live" : "scheduled")` (passing `train` through where needed).
- In NearbyWidget.time(), add the same `.accessibilityValue` to the minutes Text, so the combined Link reads e.g. 'Manhattan, 12 min, live'.

### 135. Widget rows read as loose fragments: later trains, small widget, and Transfers rows and card

**Low** · Widgets · G25

**Where:** `ios/Widget/RTrainWidget.swift:806-818`, `ios/Widget/RTrainWidget.swift:548-560`, `ios/Widget/RTrainWidget.swift:1134-1172`, `ios/Widget/RTrainWidget.swift:1046-1093`, `ios/Widget/RTrainWidget.swift:1105-1129`, `ios/Widget/RTrainWidget.swift:1196`

In ios/Widget/RTrainWidget.swift, no train row is combined into one accessibility element, so VoiceOver reads each part as a separate stop with nothing saying what it is:
- laterTrains rows (:806-818);
- the small widget's countdown, bullet and LATER cell (:548-560, :730-753);
- transferRow (:1134-1172), in both the medium and large lists;
- transferCard (:1046-1093).
The large widget's column headers (:1105-1129) are separate elements unconnected to the values; the medium list has none. waitCell's label (:1196) says '0 minute wait' for waits under 30 s, where the pill shows '<1 min' (ios/Shared/Change.swift:114-120), and never says a wait is a quick change.

**Fix:** Give each row `.accessibilityElement(children: .ignore)` and a composed label:
- laterTrains: `"\(train.lineLabel) train at \(train.time.clock), in \(minutes(until: train)) minutes, \(train.isLive ? "live" : "scheduled")"`.
- transferRow: "Leave in N minutes: R at 8:12, at Atlantic Av 8:18, 2 minute wait, quick change, D at 8:20", with minutes from `minutesToLeave` against `entry.date`. Entries are per-minute on medium and large.
- transferCard: one label for the whole card.
- Small widget: `.accessibilityElement(children: .combine)` on the countdown HStack (:549-555).
- waitCell: use `waitMinutes == 0 ? "under a minute's wait" : "\(m) minute wait"`, and append ", quick change" when `quick`.

### 136. Line bullets and their letters never scale with Dynamic Type (app station rows, direction step, widgets)

**Low** · App screens · G11

**Where:** `ios/App/TrainPicker.swift:243`, `ios/App/TrainPicker.swift:405-419`, `ios/App/TrainPicker.swift:446-450`, `ios/Shared/LineBullet.swift:33-38`

Line bullets and their letters have fixed sizes and never follow Dynamic Type. LineBullet (ios/Shared/LineBullet.swift:33-38) sizes its label from a constant `size`, and every caller passes a literal: 16 pt in StationRow (ios/App/TrainPicker.swift:243), 32 in the filter grid (126), 46 in LineToggle (405-419), 14-28 in the widgets. At accessibility text sizes, station names and boroughs grow while the line letters stay around 10 pt. DirectionStep's `.subheadline` bold arrow sits in a fixed 32×32 circle (ios/App/TrainPicker.swift:446-450) and outgrows it at large accessibility sizes. The repo uses no @ScaledMetric or UIFontMetrics anywhere.

**Fix:** In the app, add `@ScaledMetric(relativeTo: .caption) private var bulletSize: CGFloat = 16` to StationRow and pass it to LineBullet, capped with `min(bulletSize, 32)`. Do the same for the 32-pt direction circle (`@ScaledMetric(relativeTo: .subheadline)`) and the 46-pt LineToggle, each with a sensible cap. In widgets, scale bullets that sit beside text-style text with `@ScaledMetric(relativeTo:)` too; it works in widget views. Re-check the widget rows' fixed heights.

### 137. Pickers mark the current choice only with a checkmark, weight or dimming, and "Select all"/"Clear" don't say which platform

**Low** · App screens · G32

**Where:** `ios/App/TrainPicker.swift:121-131`, `ios/App/TrainPicker.swift:257-259`, `ios/App/TrainPicker.swift:342-351`, `ios/App/TrainPicker.swift:459-461`, `ios/App/ChangePicker.swift:131-133`, `ios/App/ChangePicker.swift:142-144`, `ios/App/AlertsSheet.swift:93-111`

Several app pickers show the current choice to VoiceOver only through a trailing checkmark image, with no Selected trait: StationRow (ios/App/TrainPicker.swift:257-259), DirectionStep (ios/App/TrainPicker.swift:459-461) and ChangeStationRow (ios/App/ChangePicker.swift:142-144). LineToggle, everyLine and the filter grid already add `.isSelected`. Every platform card's "Select all"/"Clear" button (ios/App/TrainPicker.swift:342-351) has the same label, so rotor and button-list navigation can't tell them apart (in swipe order the platform header gives context). The filter grid buttons are labeled only "R train" (they do carry .isSelected). Each alert or elevator outage in AlertsSheet (ios/App/AlertsSheet.swift:93-130) is read as 3-4 separate elements.

**Fix:** Add `.accessibilityAddTraits(station.id == chosenID ? .isSelected : [])` to the StationRow and ChangeStationRow buttons and `.accessibilityAddTraits(direction == current ? .isSelected : [])` to the DirectionStep button, and mark the checkmark images `.accessibilityHidden(true)`. Give the platform button `.accessibilityLabel("\(allChosen ? "Clear" : "Select all") on the \(labels) platform")`. Optionally add `.accessibilityHint("Shows only stations on this line")` to the filter buttons. Add `.accessibilityElement(children: .combine)` to AlertDetail and ElevatorDetail.

### 138. VoiceOver can't tell live from timetable times in the Live tab, and map entrances are unlabeled

**Low** · App screens · BF14

**Where:** `ios/App/LiveView.swift:694-695`, `ios/App/LiveView.swift:703-711`, `ios/App/LiveView.swift:610`, `ios/App/TrainDetail.swift:443-445`, `ios/App/TrainDetail.swift:454-476`

ios/App/LiveView.swift:694-695 collapses Minutes into a single accessibility label from `spoken()` (LiveView.swift:703-711), and NearbyLineRow reuses that string as its value (LiveView.swift:610). Neither includes whether each time is live or timetable, so VoiceOver users in the Live tab (favorites, Nearby, StationLive) can't tell live predictions from scheduled (isLive=false) trips, even when the Live/Scheduled marks are visible. On the station map, entrances that aren't elevators get an empty Annotation title (ios/App/TrainDetail.swift:443-445), and EntranceMark (TrainDetail.swift:454-476) has no accessibility label, so exit-only and ordinary entrances aren't named.

**Fix:** In `Minutes.spoken`, append ', live' or ', scheduled' per train, from train.isLive. This could apply always, or when marksLive/marksScheduled is on, with the flags passed in. In StationMap use `Annotation(entrance.isElevator ? "Elevator" : entrance.exitOnly == true ? "Exit only" : "Entrance", …)`, or add `.accessibilityLabel(...)` with the same text to EntranceMark.

## Tests, CI and release (22: 4 medium, 18 low)

### 139. No tests for the protobuf decoder, alert and outage parsing, or transfer matching

**Medium** · Trains and feeds · CF27, AF6, AF30

**Where:** `ios/Shared/SubwayFeed.swift:291`, `ios/Shared/SubwayFeed.swift:474`, `ios/Shared/Alerts.swift:104`, `ios/Shared/Outages.swift:50`, `ios/Shared/Change.swift:83`, `server/Sources/TrainCore/Poller.swift:215`, `server/Tests/TrainCoreTests/Fixtures.swift:1`, `server/Sources/TrainCore/Shared/SubwayFeed.swift:72-98` (+13 more)

Nothing tests the shared feed-decoding and filtering code that every target depends on: SubwayFeed.arrivals/stops(after:)/tripUpdate/vehiclePosition and the private ProtobufReader (ios/Shared/SubwayFeed.swift:72-311), Arrival.place (:55-63), AlertsFeed.entries/alerts(for:) with their period, direction and stop_id matching (ios/Shared/Alerts.swift:104-150), OutagesFeed, Change.connections, Selection.shows, TrainService.board, and Poller.liveBoards (server/Sources/TrainCore/Poller.swift:215-266). PollerTests inject a BoardSource and StateBuildingTests build Boards by hand. No CI workflow runs the server tests either.

**Fix:** Add TrainCoreTests suites, for example SubwayFeedTests, with a tiny protobuf builder in the test target. Cover arrival vs departure fallback, is_assigned (1001/2), several matched stops per trip, joining vehicle positions, truncated varints, lengths past the end, and an unknown wire type throwing FeedError.malformed. Add AlertsFeedTests on a small JSON fixture (direction_id 0 = north, stop_id with and without N/S, end == 0 open-ended), OutagesFeed fixture tests, and Change.connections cases. Add a liveBoards test that compares liveBoards' trains to TrainService.trains(for:) on the same canned feeds, made testable by injecting a fetch function. Optionally add a `swift test` job to CI.

Also reported as: AF6 (No tests for the hand-written protobuf decoder, feed selection, Selection.shows or legacy Selection decoding); AF30 (No tests for transfer matching, alert filtering or outage parsing).

### 140. CI has no concurrency control, so an older or re-run build can replace the newer 'latest' release

**Medium** · Tools, Scriptable and CI · BF51, CF48

**Where:** `.github/workflows/build-ios.yml:3-6`, `.github/workflows/build-ios.yml:13-14`, `.github/workflows/build-ios.yml:91-100`

.github/workflows/build-ios.yml has no concurrency group, and its publish step (lines 96-100) does not check that $GITHUB_SHA is still the head of main. When two runs overlap, the one that finishes last becomes `latest` even if it built the older commit. A manual re-run of an old run (run_number is kept on re-runs, lines 13-14) also republishes old code as latest. AltStore treats any version that differs from the installed one as an update, so users already on the newer build are prompted to 'update' back to the older build, and new installs get the older code. If two publish steps overlap, one fails with 'release already exists'. The claim that a run_number reset would stop AltStore offering builds is wrong, because AltStore compares with != and not <.

**Fix:** Add a workflow-level `concurrency: { group: publish-latest, cancel-in-progress: false }`. At the start of the publish step, add `[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$GITHUB_SHA" ] || { echo 'main has moved on; not publishing'; exit 0; }`. The run_number scheme can stay.

Also reported as: CF48 (CI has no concurrency group: an older run can replace the newer 'latest' release).

### 141. CI never builds or tests the server, which compiles shared app files in Swift 6 mode, and nothing runs before merge

**Medium** · Tools, Scriptable and CI · BF54, CF25

**Where:** `.github/workflows/build-ios.yml:3-6`, `.github/workflows/build-ios.yml:20-44`, `server/Sources/TrainCore/Shared`, `server/Tests/TrainCoreTests`, `tools/make_lines.py:25-45`, `.github/workflows/build-ios.yml:17-100`, `server/Sources/TrainCore/Shims.swift`, `.github/workflows/build-ios.yml:17-36` (+4 more)

CI (.github/workflows/build-ios.yml, the only workflow, push-to-main and manual triggers only) never builds or tests server/. server/ compiles 8 ios/Shared files (symlinked into server/Sources/TrainCore/Shared) in Swift 6 mode against Shims.swift, while CI compiles them only in the iOS target's Swift 5 mode (ios/project.yml:9). An ios/Shared edit can therefore break the server unnoticed until the next deploy/install.sh run on the server Mac. The 9 test files in server/Tests/TrainCoreTests never run. There is no pull_request trigger, so even the iOS build first runs after the merge and publishes straight to users. tools/make_lines.py and tools/make_stations.py parsers (merge, route_ids, short_name, entrances_by_stop, equipment) have no tests.

**Fix:** Add a `pull_request:` trigger. The publish step is already gated on refs/heads/main, and the artifact upload is harmless. Add a second job, `server: runs-on: macos-latest; steps: checkout; swift build --package-path server; swift test --package-path server` (or ubuntu with a swift:6.0 container if the package builds on Linux). Optionally, add a paths filter so server-only pushes don't publish a new iOS build, plus a small pytest file for the tools/ parsers using synthetic rows.

Also reported as: CF25 (CI never builds or tests the server, though 8 ios/Shared files compile in Swift 6 mode only there).

### 142. Server tests don't compile on Swift 6.2: the authData '+' chain in AttestTestSupport.swift is too complex to type-check

**Medium** · Tools, Scriptable and CI · G1

**Where:** `server/Tests/TrainCoreTests/AttestTestSupport.swift:84-88`, `server/README.md:246`, `server/Package.swift:1`, `server/Package.resolved`

In server/Tests/TrainCoreTests/AttestTestSupport.swift:84-88, the single `let authData = Array(SHA256.hash(...)) + [0x40] + withUnsafeBytes(of: counter.bigEndian, Array.init) + environment.aaguid + [...] + credential + [0xa0]` expression goes over the constraint solver's limit on Swift 6.2.x. I verified this on 6.2.1 (Linux) with the committed files: it is the only error, and the whole TrainCoreTests module (85 tests) fails to compile. The pinned dependencies (Package.resolved) need tools-version 6.2, so 6.2.x is the oldest toolchain that can build the server, and on it `swift test` (server/README.md:246) cannot work. Package.swift:1 (tools-version 6.0) and the README do not say so. The finder reports that 6.3+ compiles it; I could not test that here.

**Fix:** Split the chain into typed statements (this matches the scratch copy, which passes all 85 tests on 6.2.1): `var authData: [UInt8] = Array(SHA256.hash(data: Data(appID.utf8))); authData.append(0x40); authData += withUnsafeBytes(of: counter.bigEndian) { [UInt8]($0) }; authData += environment.aaguid; authData += [UInt8(credential.count >> 8), UInt8(credential.count & 0xff)]; authData += credential; authData.append(0xa0)`. Optionally give the line 120-121 chain the same treatment. Raise `// swift-tools-version` to 6.2, which the dependencies already require. If a server CI job is added, pin its toolchain.

### 143. No tests for the widgets' layout and labelling logic, and the iOS project has no test target

**Low** · Widgets · AF72

**Where:** `ios/Widget/NearbyWidget.swift:209-231`, `ios/Widget/NearbyWidget.swift:275-297`, `ios/Widget/StopList.swift:112-162`, `ios/Widget/TransferMap.swift:203-288`, `ios/Widget/TrainLiveActivity.swift:119-129`, `ios/project.yml`

There is no unit test coverage for the widget's pure layout and labelling logic. Untested are NearbyLayout.fit and NearbyLine.labels (ios/Widget/NearbyWidget.swift:209-231, 275-297), StopLayout.init (ios/Widget/StopList.swift:113-161), TransferMapLayout.init/row(at:) (ios/Widget/TransferMap.swift:203-271) and ContentState.movedOn (ios/Widget/TrainLiveActivity.swift:119-129). ios/project.yml has no test target, and the server's tests compile only 8 ios/Shared files.

**Fix:** Add a `bundle.unit-test` target to ios/project.yml, compiling Widget/StopList.swift, TransferMap.swift and NearbyWidget.swift's non-view types plus Shared (or hosted by the app), and run it in the CI build. Alternatively, move StopLayout, TransferMapLayout and movedOn, which need only Foundation, Arrival, Connection and StationDirectory, into ios/Shared files symlinked into server/Sources/TrainCore/Shared, and test them there. Use table-driven cases: maxRows 3 vs 4, a train before the first stop, the end of a line, movedOn with and without following trains.

### 144. Widget timeline planning has no tests and lives where it can't be tested

**Low** · Widgets · AF58

**Where:** `ios/Widget/RTrainWidget.swift:179`, `ios/Widget/RTrainWidget.swift:98`, `ios/Widget/RTrainWidget.swift:265`

The widget's timeline planning has no tests and can't be tested where it lives. This covers entry dates (leave times of the first 10 trains or connections, minute marks capped at an hour), `runsOut`, the reload policy (min 60 s, capped by `runsOut` and commute switches), board reuse (30 s, toggled with something still to catch, never older than ↻), stripping stops, and clearing positions after 60 s (ios/Widget/RTrainWidget.swift:98-118, 179-283). It is private to the widget target, which has no test target; iOS is only built in CI (build-ios.yml) and never tested. A real bug already slipped through this way: connections never have their stale positions cleared (RTrainWidget.swift:236-247). Server tests could cover an extracted version, but no CI workflow runs them either.

**Fix:** Move the pure core into a new ios/Shared file (e.g. `TimelinePlan.dates(leaveTimes:now:hasMap:)`, `TimelinePlan.trains(_:at:fetched:hasMap:)`, `TimelinePlan.connections(_:at:fetched:keepsStops:)` and `TimelinePlan.reload(now:fetched:runsOut:switches:interval:)`). Symlink it into server/Sources/TrainCore/Shared and keep only the TrainEntry building in the widget. Add server tests for: the first train of every entry has `leaveTime > date`; positions are nil after 60 s for trains and connections; at most 70 entries; reload is ≥ now+60 s and ≤ runsOut. Add a workflow step that runs `swift test` in server/.

### 145. No tests for change validation, saved-widget logic or commuting hours

**Low** · Saved state · BF40, AF44, CF51

**Where:** `ios/Shared/Change.swift:46-75`, `ios/App/ChangePicker.swift:38-42`, `ios/Shared/SavedWidgets.swift:95-101`, `server/Tests/TrainCoreTests`, `ios/Shared/SavedWidgets.swift:129-167`, `ios/Shared/SavedWidgets.swift:46-124`, `ios/Shared/Spoken.swift:1-73`, `ios/Shared/SavedWidgets.swift:143-167` (+3 more)

ios/Shared/Change.swift compiles into TrainCore through a symlink but has no tests: validated(for:) at :69-75, isAcross/isAllAcross/isExpress at :46-60, and connections at :83-97. The BF24 regression (a change behind the new station is kept) would have been caught by one. ios/Shared/SavedWidgets.swift (SavedWidgets.move at :95-101, CommutingHours.isActive at :143-153 and nextSwitch at :156-167) and ChangePicker's private changeLines (ios/App/ChangePicker.swift:38-42) are also untested. Neither compiles into any test target: SavedWidgets.swift is not symlinked into TrainCore, and the iOS project has no test target.

**Fix:** Add server/Tests/TrainCoreTests/ChangeTests.swift covering Change.validated (own station, dropped routes, station past the change), isAcross and isExpress (for example R at Atlantic Av, and 7 local to express at Queensboro Plaza or Court Sq), and connections (trip matching, arrival before the train, and walk added for another platform). Symlink ios/Shared/SavedWidgets.swift into server/Sources/TrainCore/Shared to test move, isActive (including ranges past midnight) and nextSwitch. Move changeLines into Change as a static helper so it can be tested too.

Also reported as: AF44 (No tests for commuting hours, saved-widget migration or Siri text, though these files could run in the server's test target); CF51 (No tests for the riskiest time logic).

### 146. A wall-clock timing check in the Poller tests flakes under parallel runs

**Low** · Push server · CF33

**Where:** `server/Tests/TrainCoreTests/PollerTests.swift:130-146`, `server/Tests/TrainCoreTests/PollerTests.swift:148-164`, `server/Tests/TrainCoreTests/HTTPTests.swift:310-319`

The assertion `#expect(elapsed < .milliseconds(600))` at server/Tests/TrainCoreTests/PollerTests.swift:144 (in pushesConcurrentlyWithinTheBound, lines 130-146) flakes under CPU contention. Swift Testing runs it in parallel with tenThousandCountdownsInOnePass (lines 148-164) in the same non-serialized PollerTests suite, and the 10k test's long synchronous pass and actor hops hold the cooperative pool. That delays the wake-ups after the 20 ms sleeps. Measured failure rates: 0/6 runs on 4 cores, 1/3 on 2 cores, 2/3 on 1 core. The `maxInFlight >= 4` and 10k `< 10 s` checks did not flake. The UTC-midnight sensitivity of capsKeysPerAddressPerDay (HTTPTests.swift:310-319, via DailyLimiter.take's `.now` default at Limits.swift:51) is real but negligible.

**Fix:** Use `@Suite(.serialized) struct PollerTests`, which stops the 10k test overlapping the concurrency test. Also either drop the elapsed check (bounding maxInFlight is enough to prove concurrency) or make it deterministic: FakePusher waits on a gate until `limit` sends are in flight, then the test asserts `maxInFlight == 8`. Optionally pass a `now` closure into DailyLimiter through HTTPServices for the midnight case.

### 147. App Attest authenticator-data parsing has no tests for malformed input, and the test authority can't produce any

**Low** · Push server · G4

**Where:** `server/Sources/TrainCore/AppAttest.swift:43-56`, `server/Sources/TrainCore/AppAttest.swift:160-163`, `server/Tests/TrainCoreTests/AttestTestSupport.swift:78-115`, `server/Tests/TrainCoreTests/AppAttestTests.swift:125-154`

No test covers AuthenticatorData.init's malformed-input refusals (server/Sources/TrainCore/AppAttest.swift:43-56: <37 bytes, AT flag clear, <55 bytes, credential ID truncated) or the unknown-aaguid refusal (160-163). The test helpers (server/Tests/TrainCoreTests/AttestTestSupport.swift:78-88, 118-121) cannot produce such input.

The exposure is narrower than claimed:
- The withCredential:true guards run only after Apple-root chain validation and the nonce check over authData (AppAttest.swift:133-145), so they are not attacker-reachable in production.
- Only the 37-byte guard is reached before signature verification, via verifyAssertion (line 180). Even that requires a registered key id (HTTP.swift:243-256).

**Fix:** - Add a unit test that calls `AuthenticatorData(_:withCredential:)` directly with: 36 bytes; 55 bytes with flags 0x00; 54 bytes with flags 0x40; 58 bytes with length 0xffff. Expect the four `.malformed` messages, and check that a valid 3-byte ID parses.
- Add a verifyAssertion case whose authenticatorData is 36 bytes, expecting `.malformed("authenticator data too short")`.
- Add `flags: UInt8 = 0x40` and `aaguid: [UInt8]? = nil` parameters to TestAuthority.attestation, and an eachCheckRefuses case expecting `.malformed("aaguid")`.

### 148. No tests for the x5c length guard, the /attest size limit or trusting CF-Connecting-IP

**Low** · Push server · CF24

**Where:** `server/Tests/TrainCoreTests/AppAttestTests.swift:180-264`, `server/Tests/TrainCoreTests/HTTPTests.swift:321-348`, `server/Tests/TrainCoreTests/LimitsTests.swift:56-66`

Three edge paths have no tests. (a) AppAttest.verifyAttestation's x5c count guard (AppAttest.swift:117, `x5c.count >= 2`): nothing tests a 1-certificate x5c, and nothing pins whether longer chains are accepted (today 3 entries are accepted). SyntheticAppAttestTests is at AppAttestTests.swift:106-190. (b) The 16 KB limit on POST /attest (HTTP.swift:133): it returns 413 correctly, but HTTPTests.swift:133-136 tests the 413 only for /activities. (c) RateLimit honoring CF-Connecting-IP from a loopback peer (HTTP.swift:41): HTTPTests run in `.router` mode with no loopback peer, so only the ignored-header case (HTTPTests.swift:341-345) and the ClientIP.resolve unit test (LimitsTests.swift:56-66) run. If the middleware stopped passing the header, every client behind cloudflared would share one 127.0.0.1 bucket, and no test would fail. The original's "per-client challenge cap" part is not a test gap: no such cap exists (MAX_CHALLENGES is global by spec, Limits.swift:77-79, server/README.md:48), and per-client throttling of /attest/challenge comes from RateLimit, which is tested.

**Fix:** Add to SyntheticAppAttestTests: re-encode an attestation with x5c = [leaf] and expect malformed("attestation object"). If exactly 2 certificates should be required, change AppAttest.swift:117 to `x5c.count == 2` and also test that 3 are refused. Otherwise test that 3 are accepted. In AttestModeHTTPTests, POST /attest with AppContext.attestBodyLimit + 1 bytes and expect .contentTooLarge. Add a `.test(.live)` test with requestBurst = 1: GET /health returns 200, the same request with CF-Connecting-IP: 203.0.113.9 returns 200, and a third without the header returns 429. Drop the per-client-challenge test, or raise a per-client issuance cap as a separate design change.

### 149. POST /activities validation and 'started' clamping are untested

**Low** · Push server · CF26

**Where:** `server/Sources/TrainCore/HTTP.swift:175-182`, `server/Sources/TrainCore/HTTP.swift:191`, `server/Tests/TrainCoreTests/HTTPTests.swift:92-118`, `server/Tests/TrainCoreTests/HTTPTests.swift:120-142`, `server/Tests/TrainCoreTests/Fixtures.swift:7`

Tests for POST /activities (server/Tests/TrainCoreTests/HTTPTests.swift:92-142) exercise only the token clause of the validation guard at server/Sources/TrainCore/HTTP.swift:175-182. Unknown station, a route the station doesn't serve, empty routes, walkMinutes outside 0...180 and a trip over 256 bytes are untested, even though server/README.md:130 promises 400 for "a station or line that doesn't exist". The `started` clamp at HTTP.swift:191 is never asserted. registersAndDeletes passes the fixture date (Fixtures.swift:7, about 2026-05-09), which the server silently clamps to Date.now - 8h, and the test never checks saved.started. A regression such as dropping the outer `min(..., now)` would let a future `started` through, so Registration.ends (Registrations.swift:36) would never arrive and per-key eviction (Registrations.swift:171) would never pick that entry. That regression, or dropping the route check, would pass all current tests.

**Fix:** In SecretModeHTTPTests add a table-driven case expecting 400 for: stationID "XXX"; R34 with routes ["Q"]; routes []; walkMinutes -1 and 181; a 257-byte trip. registrationBody needs a parameter to override the selection and trip. Assert store.count == 0 afterwards. Add clamp cases that post `started` omitted, Date.now - 9h and Date.now + 3600, and assert saved.started lies in [Date.now - ActivityState.lifetime - 1, Date.now]. In registersAndDeletes pass Date.now - 60 and assert saved.started is within 1 s of it.

### 150. Poller pass branches are untested, and the 'keeps the last state' test has no last state

**Low** · Push server · CF34

**Where:** `server/Sources/TrainCore/Poller.swift:103-112`, `server/Sources/TrainCore/Poller.swift:133-137`, `server/Sources/TrainCore/Poller.swift:164-170`, `server/Tests/TrainCoreTests/PollerTests.swift:77-85`

No test covers these Poller.pass branches: the no-trains fallback at server/Sources/TrainCore/Poller.swift:133-134 (it pushes "No trains predicted" once at priority 10, then nothing, then a priority-5 refresh at +300 s); skipping when there is no last state (135-137); ending a registration that was never pushed (106-112 produce push == nil, the (.end, nil) arm at 164-170 still drops it); and dropping a registration whose end push fails (164-170). keepsTheLastStateWithoutFeeds (server/Tests/TrainCoreTests/PollerTests.swift:77-85) has no last state, so it doesn't show that one is kept. Temporary tests confirm the current behavior is correct. Today a change to Poller's wiring, such as `continue` in place of noTrains or no longer dropping an (.end, nil) job, would go unnoticed. ActivityState's isMeaningful/updated logic and noTrains' fields are already unit-tested elsewhere.

**Fix:** Add to PollerTests.swift (each passes today): (1) pass at `now` with fixtureBoard(), then a poller whose board has `trains = []`: at now+30 expect 2 pushes, the last with notice "No trains predicted" and priority 10; at now+60 still 2; at now+330 expect 3, the last at priority 5. (2) Upsert testRegistration(started: now - ActivityState.lifetime - 1) and pass: expect stats.ended == 1, pusher.pushes.isEmpty, store.count == 0. (3) Register with started = now - lifetime + 10, pass at now with a .sent pusher, then pass at now+10 with FakePusher(result: .failed("APNs 500")): expect ended == 1, one push sent, store.count == 0. (4) Push once, then pass with board: nil at now+400: expect withoutFeeds == 1, no pushes, and lastState and lastPush unchanged.

### 151. Server config parsing, including the security-relevant defaults, is untested

**Low** · Push server · CF35

**Where:** `server/Sources/TrainCore/Config.swift:61-105`

Config(environment:) (server/Sources/TrainCore/Config.swift:61-105) has no tests. That covers the ATTEST_MODE default of "on", the API_SECRET presence and length rules for ATTEST_MODE=off, ATTEST_ENVIRONMENT parsing, the RATE_LIMIT_BURST default and the integer ranges. A regression in the security-relevant default would not be caught. README.md:213-214 notes that older plists still contain API_SECRET.

**Fix:** Add server/Tests/TrainCoreTests/ConfigTests.swift. Start from a base environment with APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID and DATA_DIR, which should give `.attest([.production])` even when API_SECRET is present. Check that ATTEST_MODE=off throws with no API_SECRET and with a 15-character one, and gives `.secret` with 16 characters. Check that ATTEST_ENVIRONMENT=both gives both environments and "staging" throws. Check that RATE_LIMIT_PER_MINUTE=60 alone gives requestBurst 60, and that PORT=0 throws.

### 152. Server's liveBoards, APNs error handling and run loop have no tests

**Low** · Push server · CF14, CF31

**Where:** `server/Tests/TrainCoreTests/PollerTests.swift:45-49`, `server/Sources/TrainCore/Poller.swift:214-267`, `server/Sources/TrainCore/Pusher.swift:92-113`, `server/Sources/TrainCore/Poller.swift:32-54`, `server/Sources/TrainCore/Pusher.swift:75-90`

Several server paths have no tests. Poller.liveBoards (Poller.swift:214-267), the server's copy of the app's feed aggregation, is never run because every test injects `boards` (PollerTests.swift:45-49). APNSPusher.send's error classification (Pusher.swift:103-111), which decides whether a token is dropped, is untested. Poller.run (Poller.swift:32-54) is untested apart from `schedule()` and a direct `purge(now:)` call (StoreTests.swift:112). In addition, StateBuildingTests.swift:95-97 and PollerTests.swift:65 pin a stale date of train + 2 min (ActivityState.swift:11-13), which differs from the app's `staleDate: state.train` (ios/App/TrainActivityController.swift:191).

**Fix:** Give liveBoards an injectable `fetch: @Sendable (URL) async -> Data?` (default: the URLSession fetch) and a matching alert-entries source. It currently calls the shared `TrainService.alertEntries()`, which fetches internally. Test it with recorded GTFS-rt, alerts and outages bytes, including a failed own-line feed (selection left out), a failed other-line feed (selection kept), and a failed outages feed (outages nil). Move the APNs classification into a pure `static func classify(status: Int, reason: APNSError.ErrorReason?) -> PushResult` and unit-test it. When the stale-date drift is fixed, change both test expectations to `state.train`.

Also reported as: CF31 (How APNs errors decide which tokens are dropped is untested, as is the push expiration).

### 153. The 'replaced during a pass' test never runs a pass

**Low** · Push server · CF28

**Where:** `server/Tests/TrainCoreTests/PollerTests.swift:119-128`, `server/Sources/TrainCore/Poller.swift:161-194`, `server/Sources/TrainCore/Registrations.swift:197-229`

`aRegistrationReplacedDuringAPassIsntOverwritten` (PollerTests.swift:119-128) never runs `Poller.pass`. It checks only Store.apply's revision guard (Registrations.swift:197-211), which StoreTests could own. Nothing checks that Poller.pass records outcomes against the revision from its `store.all` snapshot (Poller.swift:161-194). If a refactor used a re-read or current revision, a push computed for the old registration would overwrite a same-token re-registration made mid-pass, or an invalidToken result would delete it, and the suite would still pass.

**Fix:** Replace or extend the test with an end-to-end version (verified passing on current code). For each of FakePusher(.sent) and FakePusher(.invalidToken("410 Unregistered")): upsert testRegistration(), record its revision, then build `Poller(store:pusher:interval: 30) { selections, _ in _ = try? await store.upsert(testRegistration(), maxTotal: 10, maxPerOwner: 5); return Dictionary(selections.map { ($0, fixtureBoard()) }, uniquingKeysWith: { a, _ in a }) }`. Run `pass(at: now)` and assert `store.count == 1`, the revision changed, and `lastState == nil`.

### 154. The /health 'no Server header' test can't fail

**Low** · Push server · CF32

**Where:** `server/Tests/TrainCoreTests/HTTPTests.swift:46-54`, `server/Sources/TrainCore/ServerMain.swift:186-195`

HTTPTests.swift:46-54 (`healthNeedsNoAuthAndSaysOnlyOk`) asserts `response.headers[.server] == nil` in `.test(.router)` mode. Hummingbird adds the Server header only in Application.run (Hummingbird Application.swift:130-131), and the router test framework skips that path. The assertion therefore passes even with serverName set. It also never uses the production configuration, which is built inline at ServerMain.swift:63 (`configuration: .init(address: ..., serverName: nil)`). Changing that to a non-nil serverName would put a Server header on production responses, and no test would fail.

**Fix:** Pull the configuration into a function, e.g. `static func applicationConfiguration(for config: Config) -> ApplicationConfiguration` in ServerMain, and test that `serverName == nil`. Alternatively, build the test Application with that configuration and run this check with `.test(.live)`, where the header logic actually runs.

### 155. The legacy-migration test can't detect a second migration overwriting rows

**Low** · Push server · CF29

**Where:** `server/Tests/TrainCoreTests/StoreTests.swift:39-70`, `server/Tests/TrainCoreTests/StoreTests.swift:48`, `server/Sources/TrainCore/Registrations.swift:301-316`

server/Tests/TrainCoreTests/StoreTests.swift:65-69 writes the byte-identical legacy file (built at lines 44-51) a second time over an untouched row. Its assertions therefore cannot tell 'skips tokens already in the database' (the filter at server/Sources/TrainCore/Registrations.swift:305) from 'overwrites them with the legacy data'. Removing the filter keeps the test green. In production that would let a leftover registrations.json (for example, if removeItem at line 313 failed after the commit) roll lastState, lastPush, trip and revision back to stale values on every start.

**Fix:** Before writing the file the second time, change either the database row or the legacy content. For example, `try await store.apply([.pushed(token: sampleToken, revision: migrated.revision, state: state(train: 9, trip: "q"), at: now + 60)])`, then assert that `again.registration(for: sampleToken)?.lastState == state(train: 9, trip: "q")`, `.trip == "q"` and `.lastPush == now + 60`. Or write a second legacy array with a different lastState and trip, and assert that `again.registration(for:) == migrated`.

### 156. The purge test can't tell the right deletions from wrong ones, and nothing checks deletions in the database

**Low** · Push server · CF30

**Where:** `server/Tests/TrainCoreTests/StoreTests.swift:105-116`, `server/Sources/TrainCore/Registrations.swift:358-372`, `server/Sources/TrainCore/Registrations.swift:173-179`, `server/Sources/TrainCore/Registrations.swift:187-193`, `server/Sources/TrainCore/Registrations.swift:223-228`

No test checks a registration DELETE against the database. The purge test (server/Tests/TrainCoreTests/StoreTests.swift:105-116) uses an in-memory Store and checks only the in-memory count. It also has no registration of a surviving key. The SQL DELETEs at server/Sources/TrainCore/Registrations.swift:175 (eviction), :190 (remove), :224 (apply .drop) and :364 (purge) could delete the wrong rows, or none, while every test stays green. The divergence would only show after a restart: countdowns that should survive would be lost, or evicted and removed ones would come back and be pushed again.

**Fix:** Add a file-backed test. Create `Store(directory: dir)`. Add keys "old" (91 days unused) and "recent", with registrations owned by each. Upsert past maxPerOwner to evict one, `remove` one, `apply([.drop(...)])` one, and run `Poller.purge(now:)`. Then open `let reloaded = try Store(directory: dir)` and assert that `reloaded.count`, `reloaded.count(ownedBy:)` and `reloaded.registration(for:)` match the original store for every token: the recent key's registration exists and the deleted ones are nil.

### 157. AltStore source points at the moving 'latest' download, so a cached source and the .ipa can disagree

**Low** · Tools, Scriptable and CI · BF53

**Where:** `.github/workflows/build-ios.yml:15`, `.github/workflows/build-ios.yml:78`, `tools/make_altstore_source.py:65-72`, `tools/make_altstore_source.py:98-99`

source.json's downloadURL (build-ios.yml:15,78; tools/make_altstore_source.py:70,98) always points at releases/download/latest/TrainTimes.ipa, which every push replaces, while version/buildVersion describe one build. AltStore checks the downloaded .ipa's version and build against the cached source entry (VerifyAppOperation.verifyDownloadedVersion). An install or update started from a source fetched before a push therefore fails with a version-mismatch error until the user refreshes sources.

**Fix:** Create a release per build (`gh release create v$VERSION ios/TrainTimes.ipa --target $GITHUB_SHA`) and pass `--download-url https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION/TrainTimes.ipa`. Keep only source.json and icon.png in the moving `latest` release. Optionally, also emit `"sha256"` for the .ipa in the version entry.

### 158. CI checks only one alternate app icon, and icon-change failures are silent

**Low** · Tools, Scriptable and CI · BF49

**Where:** `.github/workflows/build-ios.yml:68-69`, `ios/App/AppIcon.swift:15`, `ios/App/AppIcon.swift:25`, `tools/make_app_icons.py:30-43`

The CI icon check (.github/workflows/build-ios.yml:68-69) promises "every line's icon" but only checks AppIcon-SI. AppIcon.swift:15 can request 23 alternate icons (every Lines.filterRoutes label except R). All 23 exist in the asset catalog today. AppIcon.swift:25 drops the setAlternateIconName error. If a future edit removes or renames an icon set, or adds a line to filterRoutes without running tools/make_app_icons.py, the build still passes, and users whose default line is affected keep the old icon with no error anywhere. tools/make_app_icons.py:30-42 is a hand copy of the colours in ios/Shared/Lines.swift:13-28. They agree today.

**Fix:** In the Package step, replace the single PlistBuddy line with `for l in 1 2 3 4 5 6 7 A C E B D F M G J Z L N Q W S SI; do /usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundleAlternateIcons:AppIcon-$l" Payload/NextRTrain.app/Info.plist >/dev/null || exit 1; done`. In AppIcon.show, pass a completion handler that logs the error (e.g. `{ error in if let error { print("App icon \(name ?? "R"): \(error)") } }`). Optionally, have make_app_icons.py assert that its BULLETS keys equal the filterRoutes labels.

### 159. Every push to main publishes a new app version, even for docs- or server-only changes

**Low** · Tools, Scriptable and CI · BF62

**Where:** `.github/workflows/build-ios.yml:3-6`, `.github/workflows/build-ios.yml:13-14`

In .github/workflows/build-ios.yml:3-6 the `on: push: branches: [main]` trigger has no `paths` filter, and lines 13-14 number each run 1.0.<run_number>. A commit that touches only README.md, server/** (not the symlinked shared files) or tools/make_lines.py still rebuilds the app and republishes the `latest` release and source.json under a new version. AltStore then offers users an update that has no app changes. The original's claim that this uses up the weekly App ID signings is wrong, because an update reuses the existing App IDs. The cost is an unneeded update and reinstall for users, plus CI time.

**Fix:** Add a paths filter to the push trigger: `paths: ['ios/**', 'tools/make_altstore_source.py', '.github/workflows/build-ios.yml']`, and keep `workflow_dispatch` for manual rebuilds. ios/** already covers the files the server symlinks.

### 160. Release publishing deletes then recreates 'latest', so a failed create leaves no release and errors are hidden

**Low** · Tools, Scriptable and CI · BF52

**Where:** `.github/workflows/build-ios.yml:96-100`, `README.md:140-145`

Publishing at .github/workflows/build-ios.yml:96-100 deletes the `latest` release and its tag and then recreates them. That is not atomic. Every publish briefly makes the AltStore source URL from README.md:140-145 and the .ipa return 404. If `gh release create` fails (gh deletes its draft when an asset upload fails), no `latest` release exists until a re-run or a new push. `|| true` hides delete failures. A leftover `latest` tag makes GitHub ignore `--target`, so the release points at a stale commit.

**Fix:** Update the release in place. If `gh release view latest` succeeds, run `git push -f origin "$GITHUB_SHA:refs/tags/latest"`, then `gh release upload latest ios/TrainTimes.ipa ios/source.json ios/icon.png --clobber`, then `gh release edit latest --title "Train Times $VERSION" --notes ...`. Otherwise run the existing `gh release create`. Better still, also publish each build as its own `v$VERSION` release (see BF53), so the moving release only carries source.json and icon.png.

## Documentation drift (10: 3 medium, 7 low)

### 161. README describes a Station/Line/Direction Edit menu that no longer exists

**Medium** · Widgets · AF31

**Where:** `README.md:65-72`, `ios/Shared/TrainWidgetIntent.swift:13-37`, `ios/Shared/TrainWidgetIntent.swift:137-213`

The "More than one widget" paragraph in README.md:65-72 describes an Edit Widget menu with Station, Line and Direction choices and line/station narrowing. That menu no longer exists: ios/Shared/TrainWidgetIntent.swift:33-37 exposes only the saved-widget picker, and the old parameters are kept hidden, without suggestions, only so old configurations still load (:16-31, :137-213). The paragraph also contradicts README.md:33-38 and :114, which describe the Widgets tab and picking a saved widget in the Edit menu. It also says a widget follows "the app's choice", whereas an empty choice now follows the default saved widget.

**Fix:** Rewrite README.md:65-72. Set up widgets in the app's Widgets tab (train, change, commuting hours), then touch and hold a widget, tap Edit Widget and pick one of them. Left empty, a widget shows the default saved widget, which you can change in the Widgets tab. Widgets set up earlier with a Station, Line and Direction (or a single Train) keep that train until a saved widget is picked.

### 162. README's Siri phrases no longer work because the App Shortcuts provider was removed

**Medium** · App screens · BF42

**Where:** `ios/App/Intents.swift:5`, `ios/App/Intents.swift:27`, `README.md:91-106`

Commit e4007e6 removed the only AppShortcutsProvider (TrainShortcuts) from ios/App/Intents.swift, and nothing replaced it. NextTrainIntent (Intents.swift:5) and StartCountdownIntent (Intents.swift:27) are still Shortcuts actions, but the spoken phrases that README.md:92 and README.md:99-101 promise aren't registered. Siri won't recognise 'When's my next train in Train Times?' or 'Start my train countdown in Train Times' unless the user builds a personal shortcut, and the Shortcuts app shows no App Shortcuts tile for Train Times.

**Fix:** Restore the provider in ios/App/Intents.swift (app target): `struct TrainShortcuts: AppShortcutsProvider { static var appShortcuts: [AppShortcut] { AppShortcut(intent: NextTrainIntent(), phrases: ["When's my next train in \(.applicationName)", "When is my next train in \(.applicationName)", "Next train in \(.applicationName)", "Check \(.applicationName)"], shortTitle: "Next train", systemImageName: "tram.fill"); AppShortcut(intent: StartCountdownIntent(), phrases: ["Start my train countdown in \(.applicationName)", "I'm on my way in \(.applicationName)"], shortTitle: "Count down to my train", systemImageName: "timer") } }`. If dropping it was deliberate, remove the phrase claims from README.md:91-93 and 99-101 instead.

### 163. The server README describes push registration the app doesn't do, and the server's fixed identity can't serve AltStore installs

**Medium** · Push server · BF41, CF13, AF38

**Where:** `ios/App/TrainActivityController.swift:97`, `ios/project.yml:43-47`, `ios/project.yml:35-36`, `server/README.md:3-6`, `server/README.md:147-170`, `README.md:93-97`, server/Sources/TrainCore/Config.swift:10,55, `server/deploy/com.traintimes.server.plist` (+18 more)

server/README.md (lines 3-6 and 147-169) describes an app-side flow that does not exist. The app never asks for a push token: ios/App/TrainActivityController.swift:97 has no `pushType: .token`. It never runs App Attest, never sends POST or DELETE to /activities, and has no aps-environment or App Attest entitlement and no NSSupportsLiveActivitiesFrequentUpdates (ios/project.yml:35-47, 75-79). README.md:93-97 and TrainActivityController.swift:7-9 say no push server is used. A deployed server will have no registrations. The server's APP_ID, APNS_TOPIC and team default to XUU899AG4D's signed build (server/Sources/TrainCore/Config.swift:10,55). They can be overridden, but only for a single team, so builds sideloaded with AltStore and a free Apple ID (README.md:128-170) cannot use the server.

**Fix:** For now, change the opening of server/README.md to say the app does not register countdowns yet, so the server has no effect until it does. Note in both READMEs that the server works only with builds signed by the configured team (Xcode with a paid team, TestFlight or App Store), not with AltStore/free-Apple-ID installs. To make it work, implement the documented client flow in TrainActivityController: `Activity.request(..., pushType: .token)`, observe `pushTokenUpdates`, POST to /activities with an App Attest assertion, and DELETE when the countdown ends. Then add `aps-environment`, `com.apple.developer.devicecheck.appattest-environment` and `NSSupportsLiveActivitiesFrequentUpdates` to project.yml.

Also reported as: CF13 (Docs: server README says the app registers push tokens, but the app has no registration code and the main README says no push server is used); AF38 (The app never asks for a Live Activity push token or registers with the push server).

### 164. README is out of date about what the widgets show

**Low** · Widgets · AF55

**Where:** `README.md:9`, `README.md:10`, `README.md:56`, `README.md:95`, `ios/Widget/RTrainWidget.swift:545`, `ios/Widget/RTrainWidget.swift:1251`, `ios/Widget/RTrainWidget.swift:443`

Three parts of README.md no longer match the widget code. (1) README.md:9 says the small widget shows the next two trains' times. It shows one later train, and none with Larger text (ios/Widget/RTrainWidget.swift:544-545), and has done since afb692b. (2) README.md:10 and :55-57 describe the alert as an icon after the direction, with only the medium widget giving the headline above the countdown. Since 9be9058, every home screen size has a coloured banner across the top (RTrainWidget.swift:1251-1280); a delay shows there in short form (bullets and direction). Tapping the banner expands the full alert, with "+N more" and "More ›" (L1346-1374), and a tap on the open alert opens the app's alerts (`tapURL`, L389-393). (3) README.md:95-96 says ↻ on any widget refreshes the countdown. ↻ goes through the app (`RefreshIntent`, which refreshes the Live Activity) only when `entry.countingDown` is true (RTrainWidget.swift:442-443). That means the same train, with the countdown started in the app or on that same widget (SharedStore.swift:67-68). Any other widget's ↻ sends `RefreshWidgetsIntent`, which reloads only that widget (TrainActivity.swift:65-84).

**Fix:** Edit README.md. Line 9: "The small widget shows the countdown with the train after it beside it (with larger text, the countdown alone)." Lines 10 and 55-57: describe the coloured alert banner across the top of every home screen widget. It gives a delay's lines and direction in short form, a tap shows the whole alert, and "More ›" opens the app's alert details. Lines 95-96: "tap ↻ on the countdown, on the widget it was started from (or, if you started it in the app, any widget showing that train), or open the app."

### 165. README says a tap anywhere opens the Nearby list; the widget opens three other places

**Low** · Widgets · AF71

**Where:** README.md (Trains near you paragraph), `ios/Widget/NearbyWidget.swift:383-384`, `ios/Widget/NearbyWidget.swift:486-488`, `ios/Widget/NearbyWidget.swift:509-510`

The README's Trains near you paragraph (README.md:82-84) says a time opens that train and a tap anywhere else opens the Live tab's Nearby list. In ios/Widget/NearbyWidget.swift, a station's name and distance row opens that station's page (`Nearby.stationURL`, L383-384). A suspended line's alert row opens that line's alerts (`alertsURL`, L486-488). The "N more lines ›" or "Not running now" row opens the station page, with the folded lines first (L509-510). Each direction's link covers its label and alert icon as well as the time (L428-451). Only the header and the empty space open `Nearby.url` (L311-315, L356).

**Fix:** Replace the README sentence: "Tap a line's way (its name or time) to open that train in the app, a station's name or its 'more lines' row for all of that station's lines, a suspended line's alert for its details, or anywhere else for the Live tab's Nearby list."

### 166. README says walk and map buttons stay lit while on; they no longer do

**Low** · Widgets · AF47

**Where:** `ios/Widget/Pills.swift:61`, `ios/Widget/Pills.swift:109`, `ios/Widget/Pills.swift:138`, `ios/Widget/RTrainWidget.swift:447`, `ios/Widget/RTrainWidget.swift:1235`, `README.md:120`

README.md:120-121 says the walk and map buttons stay lit in the line's colour while they're on. Since commit 9be9058 every widget button only flashes from a tap until the redraw (ios/Widget/Pills.swift:52-83, 117-120, 136-139), which the code comments say is intended. So the README is out of date, and the medium/large widget no longer shows when its countdown is running: `running` (ios/Widget/RTrainWidget.swift:448) changes only WalkButton's VoiceOver label.

**Fix:** If flash-only is intended, change README.md:120-121 to say each button flashes in the line's colour when tapped. If a running cue is wanted, give `FlashToggleStyle` a `steady: Bool` and draw `Pill(lit: (configuration.isOn || steady) ? LineStyle.of(route) : nil)`, with a lighter fill or outline for `steady` so the tap flash still shows. Pass `steady: running` from WalkButton.

### 167. Misleading comments and messages in WidgetsView

**Low** · App screens · BF39

**Where:** `ios/App/WidgetsView.swift:20-21`, `ios/App/WidgetsView.swift:189`, `ios/App/WidgetsView.swift:183`

Several comments and texts in ios/App/WidgetsView.swift no longer match the code. The newTrain doc at :20-21 says the picker sets the fields one after another, but TrainPicker.swift:41-46 sets them all at once. The AddWidget doc at :189 implies it opens before the train is chosen, but it opens only with a chosen train (:85-91), taking just the walk time and alerts from the default. The delete confirmation at :183 says widgets will show the default, which is wrong for Transfers widgets: TrainWidgetIntent.swift:65-68 falls back to the first widget with a change. Separately, Create New starts the TrainPicker from the default widget's selection (:24), so the default's station, lines and direction show as already chosen.

**Fix:** Rewrite the newTrain doc as: 'Starts from the default widget, for its walking time and alerts; the picker sets the station, lines and direction together.' Rewrite the AddWidget doc as: 'Naming and setting up a new widget whose train has been chosen.' Change the delete message to: 'Next train widgets showing it will show the default; Transfers widgets the first widget with a change.' For Create New, optionally pass a selection without a station to the picker (or a chosenID of nil), keeping only walkMinutes and the alert flags from the default.

### 168. Two server test comments are wrong (the fixture alert isn't a delay; a pinned date is off)

**Low** · Push server · CF36

**Where:** `server/Tests/TrainCoreTests/Fixtures.swift:16`, `server/Tests/TrainCoreTests/ContentStateEncodingTests.swift:8`

Two test comments are wrong. Fixtures.swift:16 describes fixtureBoard()'s alert as "a delay alert", but it is a `.serviceChange` "Reroute" alert (Fixtures.swift:27), and StateBuildingTests.swift:70-72 relies on it not being a delay. ContentStateEncodingTests.swift:8 says Date(timeIntervalSinceReferenceDate: 800_000_000) is "2026-05-07 21:46:40 UTC". It is 2026-05-09 06:13:20 UTC (Unix 1_778_307_200).

**Fix:** Fixtures.swift:16: "Five trains, one already gone, with a service-change alert and an elevator out." ContentStateEncodingTests.swift:8: "// 2026-05-09 06:13:20 UTC, as seconds since 2001 and since 1970".

### 169. Changing the Scriptable widget's settings as the README invites leaves the line colour and terminals wrong

**Low** · Tools, Scriptable and CI · BF60

**Where:** `scriptable/Next R Train.js:10-16`, `scriptable/Next R Train.js:19`, `scriptable/Next R Train.js:278-287`, `README.md:124-125`, `scriptable/Next R Train.js:9-19`, `README.md:124-126`

The Scriptable script works for any R stop, but its settings do not fully cover other routes. Following the in-file hint at scriptable/Next R Train.js:11 and adding "N" leaves N trains without a destination, because TERMINALS (line 16) lacks R01N. Switching to a non-NQRW line keeps the yellow bullet with black text, because YELLOW (line 19) and bullet() (lines 278-287) sit outside the Settings block, and it shows no destinations unless TERMINALS is rewritten. README.md:124-126 only says "another stop" and does not say which other fields must change.

**Fix:** Add `R01N: "Astoria"` (and, for completeness, `D43S: "Coney Island"`) to TERMINALS. Move the bullet colours into the Settings block (`const BULLET = new Color("#FCCC0A"); const BULLET_TEXT = Color.black();`) and use them in bullet(). Reword the README to say "another R stop, or another line by changing STOP_ID, ROUTES, FEED_URL, TERMINALS and the bullet colours".

### 170. README's data-refresh steps omit lines.json and make_lines.py

**Low** · Tools, Scriptable and CI · BF55

**Where:** `README.md:183-194`, `tools/make_lines.py:1-16`, `ios/Shared/Stations.swift:153-160`

README.md:183-194 documents refreshing only stations.json and equipment.json (via tools/make_stations.py). The bundled ios/Shared/lines.json is built by tools/make_lines.py from the GTFS schedule zip and filtered by stations.json's routes (make_lines.py:48-51, 63), and it drives the picker's line order (Stations.swift:153-170, TrainPicker.swift:113). The README never mentions it. Refreshing stations.json alone leaves lines.json stale, so a newly added or newly served station sorts after the line's last stop when the picker is filtered by that line.

**Fix:** In README.md's 'Built into the app' list, add a bullet: `ios/Shared/lines.json`: each line's stops in order, from the MTA's GTFS schedule (google_transit.zip). Change 'To refresh both' to cover all three files, and add the step: 'then follow the download steps at the top of tools/make_lines.py and run `python3 tools/make_lines.py gtfs ios/Shared/stations.json ios/Shared` (after make_stations.py, since it reads the new stations.json)'.

## Dead code (4: 4 low)

### 171. BoardStyle.headingUIFont is never used

**Low** · Widgets · AF73

**Where:** `ios/Widget/BoardStyle.swift:22`

The computed property BoardStyle.headingUIFont at ios/Widget/BoardStyle.swift:22 is never referenced anywhere in the repository. It is dead code.

**Fix:** Delete line 22 of ios/Widget/BoardStyle.swift (`var headingUIFont: UIFont { ... }`).

### 172. WidgetStore.defaultSelection is unused and would skip change validation if used

**Low** · App screens · BF38

**Where:** `ios/App/WidgetStore.swift:30-39`

`WidgetStore.defaultSelection` (ios/App/WidgetStore.swift:30-39) is dead code with a stale doc comment. If it were ever used, it would set the default widget's selection without clearing or validating its `change`, which TripSections does in WidgetsView.swift:305-311.

**Fix:** Delete `defaultSelection` (ios/App/WidgetStore.swift:30-39).

### 173. AppContext.maxUploadSize is unused and looser than the per-route limits

**Low** · Push server · CF22

**Where:** `server/Sources/TrainCore/HTTP.swift:20-23`

`AppContext.maxUploadSize` (server/Sources/TrainCore/HTTP.swift:23) returns the 16 KB /attest limit but currently does nothing. In Hummingbird 2.28.0 it is read only by `request.decode(as:context:)` (the JSON and form request decoders), and every route here calls `collectBody(upTo:)` with an explicit limit (HTTP.swift:133, 164). If POST /activities were ever refactored to `request.decode(as:context:)`, its limit would rise silently from 4 KB to 16 KB.

**Fix:** Change line 23 to `var maxUploadSize: Int { Self.bodyLimit }`, so any implicit body read gets the strictest limit, and keep the explicit `collectBody(upTo: AppContext.attestBodyLimit)` on /attest. Don't simply delete the override: Hummingbird's default is 2 MB.

### 174. Lines.trunks is never used

**Low** · Cross-cutting · AF26

**Where:** `ios/Shared/Lines.swift:77-91`

`Lines.trunks` (ios/Shared/Lines.swift:77-91) is never referenced anywhere in the repo. It compiles into the app, the widget and the server (through the Shared symlink) and can drift from filterRoutes/LineStyle. No runtime effect.

**Fix:** Delete `static let trunks` and its doc comment (ios/Shared/Lines.swift:77-91).

## Appendix: claims checked and refuted

Reviewers raised these, and verification showed they don't hold. They're listed so nobody spends time on them again.

- **Each decode copies the whole feed into a new byte array** (AF10). The copy is real (`bytes = [UInt8](data)`, SubwayFeed.swift:259), but it is not meaningful. Today's feeds are 189 KB (numbered), 184 KB (bdfm), 137 KB (nqrw), 116 KB (ace), 29 KB (jz), 25 KB (L), 20 KB (G) and 7 KB (SI). Copying all 8 together for the Nearby widget adds about 0.7 MB for the length of a decode, around 2% of a ~30 MB widget budget. It is a sub-millisecond memcpy, far below the 1 MB alerts JSON…
- **The quick-change highlight can't fire for another-platform lines at default settings** (AF19). The arithmetic is right. Change.swift:93 requires next >= arrival + walk, `wait` (Change.swift:111) is next minus arrival, and `isQuick` (Change.swift:123-126) compares the rounded wait with quickMinutes. With the defaults (2 and 3), another-platform connections are never highlighted. But this is the documented design. README.md:27-28 says waits of 2 minutes or less are highlighted, and README.md:35-37 says a…
- **Every selection re-runs the alert text regexes (headline, marked text, brief, full details) for the same alerts** (AF22). The repeated work is real but costs very little. `AlertsFeed.alerts(for:in:now:)` (ios/Shared/Alerts.swift:129-148) does run `readable(header)`, `readable(details)`, `marked(header)` and `AlertBrief(header:)` for every alert that matches, on every call. `details` is read only by the app (AlertsSheet.swift:100, TrainDetail.swift:367). I timed it with the live MTA feed from today (182 entities, 9 active within the…
- **The outage feed is re-decoded for each complex, and hasEquipment scans every machine** (AF23). I measured it with a scratch test in the debug build, which overstates release cost. OutagesFeed.outages(atComplex:in:) on the live 62 KB nyct_ene.json takes about 1.5 ms per call. hasEquipment(atComplex:) over 708 machines takes about 23 µs per call. On the server, Poller.liveBoards already caches per complex (Poller.swift:250-257) and decodes only for selections with elevatorAlerts, which is opt-in and off by…
- **boards.json is fully decoded twice per widget reload, and settings.json 3-5 times, inside the widget's memory and time budget** (AF36). The redundant work is real but small. I measured it with live MTA feeds (Mon 14:26 ET), building boards exactly as TrainService does and encoding them like SavedBoard. R34 N R: 4.4 KB. R34 S R: 17.8 KB. R31 N D/N/R (33 trains): 17.6 KB. 127 N 1/2/3: 16.1 KB. A41 N A/C/F (42 trains): 25.8 KB. R->D/N transfers board: 20.2 KB. Six boards total 102 KB, not 'hundreds of KB'. Decoding them takes about 8.5 ms (x86…
- **With a walking time, 'minutes' mean time to the train in some places and time to leave in others** (AF56). The mixed meanings exist, but each one is documented and works as described. README.md:11 says the medium widget 'lists the trains after it with their minutes to go'. The code comments at RTrainWidget.swift:794 ('with their minutes to go') and BoardStyle ('minutes to go') agree. The 'N min' in the LATER column (RTrainWidget.swift:824-830) sits next to that train's arrival clock time, and the two agree. Countdowns…
- **Live Activity rebuilds its moved-on state about 10 times per render and reads Settings from disk twice** (AF69). The cost is negligible. `movedOn(at:)` (ios/Widget/TrainLiveActivity.swift:119-129) copies a small struct and a few short arrays. Running it about 10 times per render costs microseconds, and Live Activity views re-render only when the app updates the activity or at the stale date. The "two settings reads per render" claim is wrong. In CountdownBanner (:78-82) and markedCountdown (:160-164), `marksScheduled` runs…
- **Cancelled feed fetches keep running and are still awaited, so a board fails only after its slowest other fetch** (AF7). The mechanism is real. InFlight.value starts an unstructured `Task { try await fetch() }` (ios/Shared/TrainService.swift:259). Waiters `try await task.value` (L258, L262), which does not pass cancellation on, so the URLSession request keeps running. When `trainData` throws, the un-awaited `async let`s (L77-79) and the remaining task-group children (L270-279) are cancelled and implicitly awaited, and those fetches…
- **Transfer map draws a shared platform at any station both trains pass, even on different platforms** (AF70). The station-level match is real. StationDirectory merges platforms with the same name and complex (Stations.swift:180-193), and stations.json puts R23, Q01, M20 and 639 into one 'Canal St' station. So `station("R23")?.id == station("Q01")?.id`, and a Q approaching via Q01 marks the R's Canal St row as shared (TransferMap.swift:230-231, 241). The outline does not claim the two trains share a platform, though: -…
- **Per-render object churn: `@State NearbyLocation()` and TrainDetail.init's ActivityKit query run on each parent rebuild** (BF20). The churn happens, but it costs almost nothing and the part that could matter is already handled. `@State private var location = NearbyLocation()` (LiveView.swift:56) and `@State private var store = WidgetStore()` (AppTabs.swift:10) are evaluated each time the struct is initialised, which is standard Swift/SwiftUI behaviour. Each throwaway NearbyLocation only allocates a CLLocationManager and reads…
- **Favorites show arrival minutes, not when to leave, for trains with a walking time** (BF23). The README and the code do not disagree. README.md:87-89 says that "the app shows a leave time for each train". TrainDetail does exactly that: TrainRow shows 'leave in' plus a timer for every train when walkMinutes > 0 (TrainDetail.swift:152, 343-347). The README never describes the Favorites list. Favorites showing arrival minutes is a documented design choice. FavoriteRow's doc is "when its next trains come"…
- **Station step recomputes nearby and matching stations several times per render and makes a CLLocationManager per init** (BF37). The cost is negligible. In a -O Swift benchmark over the real 464 stations, the `matches` filter takes about 0.29 ms per call and `nearby` about 0.06 ms. `matches` runs twice only when no line filter is set: at line 151, `filter.map{...} ?? "\(matches.count)..."` evaluates the count lazily. `nearby` is computed only when the search is empty and a location exists. NearbyLocation uses one-shot `requestLocation()`,…
- **The widget decodes app-only data: equipment.json's 'alternative' text (188 of 302 KB) and stations.json's entrances (129 of 253 KB)** (BF59). The sizes are roughly right: the alternative text is about 200 KB across only 708 machines, and the entrances about 128 KB (2,198 entries). The cost is small, though. Both are decoded once per process into `static let` caches (EquipmentDirectory.all at Outages.swift:29, StationDirectory.platforms at Stations.swift:138), not on every timeline. Equipment is decoded only when the selection has elevatorAlerts on…
- **Redundant Live tab loads: on foreground, on clearing a pin, and on every reorder** (BF8). The duplicate load() calls do happen, but the costly part, the network, is already handled. Every feed fetch goes through InFlight (TrainService.swift:207, 235-266). It shares a fetch already under way and, in the app, reuses a result for 15 s (TrainService.swift:221-228). That comment names exactly this case: "coming back to the app, a refresh and the countdown can all ask for the same feeds within moments". On…
- **APNs DeviceTokenNotForTopic is not treated as an invalid token, so it's retried every pass for 8 hours, and the classification is untested** (CF10). The code does treat a 400 DeviceTokenNotForTopic as `.failed` (Pusher.swift:103-109), and Poller then retries every pass until the 8-hour end (Poller.swift:139-145, 185-190). But neither failure scenario can happen in normal use. Only the genuine attested app can register: AppAttest.swift:158/191 check that rpIdHash equals SHA256 of APP_ID "XUU899AG4D.com.rtrainwidget.app", and the default APNS_TOPIC is that…
- **The first push after every registration goes at priority 10 even though the app just showed that state** (CF11). The mechanics are right. HTTP.swift:184-194 builds each POST /activities registration with lastState nil, so ActivityState.push (ActivityState.swift:74) returns .update and Poller.swift:143 sends at priority 10. The saving is not meaningful, though. It is one push per countdown start, while the same countdown already gets a priority-10 push on every ≥30 s train move, every ≥60 s following-train move, and every…
- **POST /activities stores selections it doesn't canonicalize (duplicate or reordered routes, platform IDs), partly re-implementing Selection.validated()** (CF21). The facts are accurate: duplicate routes, out-of-order routes and platform stationIDs all pass the checks at server/Sources/TrainCore/HTTP.swift:175-180 and are stored as sent. But the claimed consequences don't matter. - No wrong data. Every function the server applies is order- and duplicate-insensitive: stopIDs/platforms(serving:) is a filter over station.platforms (Stations.swift:105-107), and shows,…
- **Redundant App Group reads on every widget reload and Live Activity render** (CF50). The counts are roughly right. settings.json can be read up to 5 times per reload: hasRoom (RTrainWidget.swift:146, only for medium widgets under 158 pt, thanks to `||` short-circuiting), plan (:186), boardKey in loadBoard, then notice and boardKey in saveBoard. boards.json is decoded twice, but only on the fetch path. The 30 s reuse path decodes it once. The cost still isn't meaningful. AppSettings is a tiny JSON…
- **SubwayFeed copies a stop list for every matched stop (quadratic in stops per trip), and the server and Nearby paths never read it** (CF56). The code fact is right: ios/Shared/SubwayFeed.swift:208 copies `Array(stops[...at])` for each matched stop, and the server, the Live tab and the Nearby widget never read `approach`. A search shows it is used only in ios/Widget/StopList.swift, TransferMap.swift and RTrainWidget.swift. The cost is not meaningful in practice, though. The quadratic term only appears when many stops of the same trip are registered at…
- **Line-label tables have drifted: make_lines.py lacks the 5X mapping that Lines.normalized has** (CF59). The two tables do differ: tools/make_lines.py:22 has no "5X", while ios/Shared/Lines.swift:34 maps it. But the claimed effect cannot happen. In make_lines.py a trip's stops are kept only if `(stop, label) in serves` (line 64), and `serves` is built from stations.json routes. Those are the MTA's daytime bullets, with no X variants: the route counts in stations.json show no 5X, 6X, 7X or FX. An unmapped 5X trip…
- **Per-pass work that could be done once: outages decoded per complex, unused alerts computed, and per-registration state building** (CF7). The redundant work exists, but I measured it in a temporary test in the scratch package (debug build, Linux) and the cost is far below what could lengthen a 30 s pass. Decoding the live 61,641-byte outages feed (150 rows) for all 153 complexes that have equipment took 0.22 s total, about 1.5 ms each. Even the worst case, all 445 complexes in stations.json each with an elevatorAlerts registration, is about 0.65 s…
