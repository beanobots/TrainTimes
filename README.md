# Train Times: a next-train widget for the NYC subway

An iPhone widget with a live countdown to the next train and the times of the
trains after it. You choose the station, lines and direction in the app. Live
predictions are green; timetable times the MTA hasn't assigned a train to yet are
white. It reads the MTA's free real-time feeds (no API key) and covers every
subway line and the Staten Island Railway.

The small widget shows the countdown with the next two trains' times beside it.
The medium one shows the countdown on its own, with any delay written above it,
and lists the trains after it with their minutes to go. Beside a short station
name the list starts at the top and has room for one more. On an iPhone 12 or
later, apart from the minis, the medium widget's text is larger.

**Where the train is.** The medium widget's map button swaps that list for the
stops between the next train and your station: the one it's at or heading for,
the next, how many more, and yours. It starts from the MTA's live train position
at the widget's last refresh, then moves the train along by when it's due at each
stop. Tap the button again for the times.

**Choosing a train.** In the app, tap the train at the top and choose in three
steps, each leading to the next: the station (search, or show only one line's),
its lines, and the direction. The lines are laid out platform by platform: tap
as many as you like, say the N and the R at Atlantic Av, from one platform or
several (the 2 and the Q work too), or all of a platform's at once, and their
trains show up together, each with its bullet. A station with one line skips
straight to the direction.

Trains of another line running on yours show up too, with their own bullet: an N
or D running local on the R, say, or an E running local in Queens. Lines that
always stop at your platform stay out unless you choose them.

The app also shows, for the station and line you choose:

- **Service alerts**: delays, suspensions, skipped stops and other changes in
  effect now for that line at that station and direction. The widget marks the
  most important one with an icon after the direction, and the medium widget
  gives its headline.
- **Accessibility**: whether the station is step-free, which elevators and
  escalators are out or have planned work, and the MTA's advice for getting
  around a broken elevator. Turn on "Show elevator outages on the widget" to
  see them there too.
- **A map** of the station and its entrances, with elevator entrances marked,
  and walking directions in Maps.

**More than one widget.** Every widget follows the app's choice until you give
it its own, for example one widget for home and one for work: touch and hold the
widget, tap **Edit Widget**, and choose a **Station**, a **Line** and a
**Direction**, in any order. Choose the line first and the stations are only the
ones it stops at; choose the station first and its lines are listed platform by
platform: each line, a platform's lines together, or every line. Until all three
are chosen, the widget shows the app's train. Widgets set up with a train before
there were three choices keep it.

**Walking time.** Set how long it takes you to walk to the station in the app.
Trains you can't reach in time are left out, the widgets count down to when to
leave, and the app shows a leave time for each train.

**On your way.** Tap a widget's walk button, or **I'm on my way** in the app (or
say "Start my train countdown in Train Times"), to count down to your train on the
Lock Screen and in the Dynamic Island. It stays up until you tap the walk button
again, on the widget or the countdown, or for 8 hours, when iOS ends it. It can
only get new times while the app runs, which needs no push server: tap ↻ on the
countdown or a widget, or open the app. In between it keeps ticking, and once your
train has gone a refresh moves it to the next one.

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
readable. The Lock Screen countdown is always dark.

There are two versions:

- `ios/`: a native app and widget. You pick any station and line in the app, and
  the widget moves on to the next train by itself and has refresh and walk
  buttons (and, on the medium widget, the map button). Each lights up in the
  line's colour: ↻ as new times come in, the others while they're on. It's built
  on GitHub's Mac servers, so you don't need a Mac.
- `scriptable/`: a script for the free Scriptable app, fixed to the R train at
  Prospect Av (change the settings at the top to use another stop). No computer
  needed.

## Install the native version (Windows/Mac computer, free Apple ID)

Every push to `main` builds the app on a GitHub Mac (see the Actions tab; about
two minutes) and publishes it as the [latest release](../../releases/tag/latest):
`TrainTimes.ipa`, plus `source.json`, an AltStore source that describes it. Each
build gets its own version number (1.0.N, where N is the build number), so
AltStore can tell when there's a new one.

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
4. **Choose your train.** Open **Train Times** and tap the train at the top.
   Search for your station (or show only one line's), tap one or more of its
   lines, then the direction. The widget updates right away.
5. **Add the widget.** Touch and hold the Home Screen, tap **Edit → Add Widget**,
   and choose **Train Times**. Until you choose, it shows the R at Prospect Av,
   toward Manhattan.

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
  ties each one to its station.

To refresh both, follow the download steps at the top of `tools/make_stations.py`,
then run `python3 tools/make_stations.py Stations.csv entrances.json equipment.json ios/Shared`
and push.

## How it stays fresh

iOS decides when widgets fetch new data, usually every 5 to 15 minutes. The
countdown ticks every second in between. The native version steps to the next
train when one arrives and has a refresh button (↻); the Scriptable one counts
back up from 0:00 until iOS next refreshes it.
