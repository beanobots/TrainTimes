# Train Times: a next-train widget for the NYC subway

An iPhone widget with a live countdown to the next train and the times of the
trains after it. You choose the station, lines and direction in the app. Live
predictions are green; timetable times the MTA hasn't assigned a train to yet are
white. It reads the MTA's free real-time feeds (no API key) and covers every
subway line and the Staten Island Railway.

The small widget shows the countdown with the train after it beside it, while
there's room (a time past 10:00 can leave too little); with **Larger widget
text** on in the app's Settings, it shows a bigger countdown on its own. The
medium one shows the countdown on its own and, down its right side, the trains
after it with their minutes to go, as many as fit. On an iPhone 12 or later,
apart from the minis, or with Larger widget text on, the medium widget's text is
larger, and fewer of those trains fit.

**Where the train is.** The medium widget's map button swaps that list for the
stops between the next train and your station: the one it's at or heading for,
the next, how many more, and yours. It starts from the MTA's live train position
at the widget's last refresh, then moves the train along by when it's due at each
stop. Tap the button again for the times.

**Changing trains.** A widget can also change trains on the way, say from the R
at Prospect Av to the D or N express at Atlantic Av-Barclays Ctr. The
**Transfers** widget shows it, beside the Next train widget. The medium one has
your next two changes, each with the countdown to leaving, when your R leaves
Prospect Av and gets to Atlantic, the wait there, and the express it meets. The
large one shows the next change big: the countdown, then your R leaving, the
ride to Atlantic, the wait and the express. Under it are three more. Where times
past 10:00 leave too little room, as on smaller phones, when your R gets to
Atlantic is left out. Waits short enough for a quick change (2 minutes or less,
unless you choose otherwise) are highlighted. The large one's map button keeps
the next change at the top and swaps the three below it for the tracks to
Atlantic: your R on the local track and the express below it on its own, each
where it would be by how long it has to go to Atlantic, so a quick change shows
as the two side by side. The medium
one's shows where your R is. To set one up, edit a widget in the app's Widgets tab and tap **Add
a Change**: pick the station from the stops after yours, then the lines there
(those across the platform are chosen to start with). A line on another
platform, like the 2 or 3 at Atlantic Av, counts the walk to it in the wait; set
how long that walk is on the widget. A Transfers widget shows the widget picked
in its Edit menu, or with none picked the first one that changes trains.

**Choosing a train.** In the app's **Widgets** tab, tap a widget and then its
train (or, in the Live tab, the train at the top of a train's page), and choose
in three steps, each leading to the next: the station (search, or show only one
line's), its lines, and the direction. The lines are laid out platform by platform: tap
as many as you like, say the N and the R at Atlantic Av, from one platform or
several (the 2 and the Q work too), or all of a platform's at once, and their
trains show up together, each with its bullet. A station with one line skips
straight to the direction.

Trains of another line running on yours show up too, with their own bullet: an N
or D running local on the R, say, or an E running local in Queens. Lines that
always stop at your platform stay out unless you choose them. A train whose trip
ends at your station isn't listed, as it doesn't leave from there, and one held
at the platform stays listed until it leaves.

The app also shows, for the station and line you choose:

- **Service alerts**: delays, suspensions, skipped stops and other changes in
  effect now for that line at that station and direction. A Home Screen widget
  shows the most important one in a band of its colour across the top (a delay
  as just the lines it holds up and which way). Tap the band for the whole
  alert, and again for the times; with it open, tap **More ›** for every
  alert's details in the app. On the Lock Screen, the inline and rectangular
  widgets say what kind it is.
- **Accessibility**: whether the station is step-free, which elevators and
  escalators are out or have planned work, and the MTA's advice for getting
  around a broken elevator. Turn on **Elevator outages** for a widget in the
  Widgets tab to see them there too.
- **A map** of the station and its entrances, with elevator entrances marked,
  and walking directions in Maps.

**More than one widget.** Set up as many as you like in the app's **Widgets**
tab, for example one for home and one for work. Each has its own train, any
change of trains, walking time and the alerts it mentions, and can show another
train at certain times of day (**Commuting hours**), say your train home in the
evening. Then touch and hold a widget, tap **Edit Widget**, and pick one of
them. A Next train widget with none picked shows the default one, starred in the
Widgets tab, where you can make another the default. Changes in the Widgets tab
update every widget showing that one. Widgets set up before the Widgets tab keep
the train they were given (a station, a line and a direction, or before those a
single train) until you pick one.

**Trains near you.** The large **Trains near you** widget finds where you are
each time it refreshes and lists the closest stations, with how far each is and
about how long it takes to walk there. Each line gets a row: its bullet, then the
way toward Manhattan and its next train ("Now", "1 min", "12 min"), then the
other way and its next train. In Manhattan the two ways are Uptown and Downtown;
elsewhere the other way is the borough its trains are headed for, so the G from
Brooklyn reads Queens and Brooklyn. A line that ends at the station has only the
way it goes from there. Lines with no trains just now share a small row under
the others, and a suspended line shows its alert instead of times. A station
with more lines than fit shows its first four and "4 more lines ›". Tap a way
(its name or its next train) to open that train in the app, a station's name or
its row of other lines for all of that station's lines, a suspended line's alert
for its details, or anywhere else for the Live tab's Nearby list. The widget
uses the app's location permission: choose **While Using the App or Widgets**
when the app asks.

**Walking time.** Set how long it takes you to walk to the station in the app.
Trains you can't reach in time are left out, the widgets count down to when to
leave, and the app shows a leave time for each train.

**On your way.** Tap a widget's walk button, or **I'm on my way** in the app (or
say "Start my train countdown in Train Times"), to count down to your train on the
Lock Screen and in the Dynamic Island. It stays up until you tap the walk button
again, on the widget or the countdown, or for 8 hours, when iOS ends it. It can
only get new times while the app runs, which needs no push server: tap ↻ on the
countdown or on the widget you started it from (any widget showing that train,
if you started it in the app), or open the app; another widget's ↻ refreshes
just that widget. In between it keeps ticking, and once your train has gone a
refresh moves it to the next one. The push server in `server/` is for updating
it with the app closed, but the app doesn't use it yet, and installs from
AltStore can't (see [its README](server/README.md)).

**Siri and Shortcuts.** Say "When's my next train in Train Times?" Siri answers
with the next train you can catch (and when to leave, and any delays) and shows
the next few. iOS needs the app's name in the phrase. Both actions are in the
Shortcuts app too, where you can pick a different train.

To ask without the app's name, make your own shortcut: in the Shortcuts app, tap
**+**, add Train Times' **When's my next train?** action, and name the shortcut
"When's the next train". Siri runs a shortcut when you say its name.

The app and the widgets follow your phone's light or dark setting: the widgets'
station-board look is black in dark mode and white in light. On tinted Home
Screens a widget's line bullet turns into an outline so the letter stays
readable. Where a widget is drawn in one colour (tinted and clear Home Screens,
StandBy at night), live times keep their mark, as their green doesn't show. The
Lock Screen countdown is always dark.

**The app's icon** is the bullet of your default widget's line (the first one,
if it has more than one). Make another widget the default in the Widgets tab, or
change the default's line, and the icon follows; iOS says so with an alert.

There are two versions:

- `ios/`: a native app and widget. You pick any station and line in the app, and
  the widget moves on to the next train by itself and has refresh and walk
  buttons (and, on the medium widget, the map button). Each flashes in the
  line's colour when you tap it. It's built
  on GitHub's Mac servers, so you don't need a Mac.
- `scriptable/`: a script for the free Scriptable app, set up for the R train at
  Prospect Av. For another stop or line, change the settings at the top: the
  stop, the lines, the station and direction names, and the line's feed, colour
  and terminals. No computer needed.

## Install the native version (Windows/Mac computer, free Apple ID)

Every push to `main` that changes the app (anything in `ios/`) or how it's
built builds it on a GitHub Mac (see the Actions tab; about two minutes) and
publishes it as the [latest release](../../releases/tag/latest):
`TrainTimes.ipa`, plus `source.json`, an AltStore source that describes it.
Each build gets its own version number (1.0.N, where N is the build number), so
AltStore can tell when there's a new one, and its own release, `v1.0.N`, which
the source downloads it from, so a source AltStore read before the next build
still gets the build it describes. A build that finishes after `main` has
changed the app again, or after a newer build, isn't published. To publish
without changing the app, run the workflow on `main` from the Actions tab
(**Run workflow**). Pull requests are built too, but not published. The push
server in `server/` has its own workflow, which builds and tests it for every
pull request and every push to `main` that changes it or the app's shared code.

1. **Install AltStore** on your iPhone by following the official guide at
   [altstore.io](https://altstore.io). It needs AltServer running on your
   computer, and your iPhone on the same Wi-Fi. Turn on **Developer Mode** on the
   iPhone if it asks (Settings → Privacy & Security).
2. **Add the Train Times source.** In AltStore, open **Sources**, tap **+**, and
   paste:

   ```
   https://github.com/beanobots/TrainTimes/releases/download/latest/source.json
   ```

3. **Install it.** Open the source, tap **Train Times**, and tap **Free** (or
   **Get**). Sign in with your Apple ID when it asks. The app and widget use two
   of the ten App IDs a free account gets. New builds then show up as updates in
   AltStore.

   Or, without the source: download `TrainTimes.ipa` from the
   [latest release](../../releases/tag/latest), put it on the iPhone (AirDrop,
   iCloud Drive or Files), and in AltStore go to **My Apps**, tap **+**, and pick
   it. You won't get update notices this way.
4. **Choose your train.** Open **Train Times**, go to the **Widgets** tab, tap
   your widget, then tap its train. Search for your station (or show only one
   line's), tap one or more of its lines, then the direction. The widget
   updates right away.
5. **Add the widget.** Touch and hold the Home Screen, tap **Edit → Add Widget**,
   and choose **Train Times**: Next train, Transfers for a widget that
   changes trains, or Trains near you for the stations closest to you. Until
   you choose, Next train shows the R at Prospect Av, toward Manhattan.

If the app shows an orange warning that the widget can't see your choice, the
shared storage the app and widget use wasn't set up when it was installed (it's an
App Group that AltStore creates while signing). Reinstalling with AltStore
should fix it.

A free Apple ID signs apps for 7 days. AltStore renews the signature on its own
when AltServer is running on your computer and your iPhone is on the same Wi-Fi.
If it lapses, the app stops opening until you refresh it in AltStore.

## Where the data comes from

Live, each time the widget or app refreshes (no API key needed):

- Train times: the MTA's GTFS-realtime subway feeds (one per group of lines).
  For a lettered line other than the L, the app reads all the connected lettered
  lines' feeds, since a train rerouted onto your line stays in its own line's feed.
- Service alerts: the MTA's subway alerts feed.
- Elevator and escalator outages: the MTA's elevator and escalator status feed.

Built into the app (refresh them now and then):

- `ios/Shared/stations.json`: the MTA's
  [station list](http://web.mta.info/developers/data/nyct/subway/Stations.csv)
  plus the [subway entrances](https://data.ny.gov/Transportation/MTA-Subway-Entrances-and-Exits-2024/i9wp-a4ja)
  from data.ny.gov.
- `ios/Shared/equipment.json`: the MTA's list of elevators and escalators, which
  ties each one to its station and the platforms it serves.
- `ios/Shared/lines.json`: the stations each line stops at, in order, from the
  MTA's [GTFS schedule](http://web.mta.info/developers/data/nyct/subway/google_transit.zip),
  for listing a line's stations as it runs.

To refresh them, follow the download steps at the top of `tools/make_stations.py`
(the GTFS schedule among them, which shows the lines that run the other way to a
station's direction names), then run
`python3 tools/make_stations.py Stations.csv entrances.json equipment.json gtfs ios/Shared`.
It also copies the first two into the push server's resources, which can't
link to them (`make_lines.py` does the same with `lines.json`). `lines.json`
keeps only the stops `stations.json` lists, so then run
`python3 tools/make_lines.py gtfs ios/Shared/stations.json ios/Shared`. Push all
six files: the three in `ios/Shared` and the server's copies of them in
`server/Sources/TrainResources/Resources`, which the server's CI checks match.

## How it stays fresh

iOS decides when widgets fetch new data, usually every 5 to 15 minutes. The
countdown ticks every second in between. The native version steps to the next
train when one leaves (a train held at the platform waits at 0:00) and has a
refresh button (↻); the Scriptable one counts back up from 0:00 until iOS next
refreshes it.

When the MTA can't be reached, or its feed has stopped updating (3 minutes
behind the other lines' feeds read with it; for a line read from its own feed
alone, such as the 1 to 7, the L and the SIR, or when every feed has stopped,
10 minutes by the phone's clock, which may be fast), a Next train or Transfers
widget keeps the times it has while one of its trains is
still to catch, with no signal in place of ↻, and the Lock Screen's rectangular
widget says "Not updated since 8:12". Only with none left does it say it
couldn't reach the MTA. Trains near you keeps no old times: a line whose times
it couldn't get shows "–", and with none at all it says "Couldn't reach the MTA"
along its bottom. In the app, a line whose times didn't come says "Couldn't
load".
