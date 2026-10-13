# Train Times: a next-train widget for the NYC subway

An iPhone widget with a live countdown to the next train, its arrival time, and
the trains after it. You choose the station, line and direction in the app. Live
predictions are green; timetable times the MTA hasn't assigned a train to yet are
white. It reads the MTA's free real-time feeds (no API key) and covers every
subway line and the Staten Island Railway.

The app also shows, for the station and line you choose:

- **Service alerts**: delays, suspensions, skipped stops and other changes in
  effect now for that line at that station and direction. The widget mentions
  the most important one.
- **Accessibility**: whether the station is step-free, which elevators and
  escalators are out or have planned work, and the MTA's advice for getting
  around a broken elevator. Turn on "Show elevator outages on the widget" to
  see them there too.
- **A map** of the station and its entrances, with elevator entrances marked,
  and walking directions in Maps.

**More than one widget.** Every widget follows the app's choice until you give
it its own: touch and hold the widget, tap **Edit Widget**, and pick a **Train**
(search by station, then choose the line and direction), for example one widget
for home and one for work. Each widget can also have its own walking time.

**Walking time.** Set how long it takes you to walk to the station (in the app,
or per widget). Trains you can't reach in time are left out, the widget counts
down to when to leave, and the app shows a leave time for each train.

**On your way.** Tap **I'm on my way** in the app (or say "Start my train
countdown in Train Times") to count down to your train on the Lock Screen and in
the Dynamic Island. It can only get new times while the app runs, which needs no
push server: tap the countdown's refresh button, or open the app. In between it
keeps ticking, and once your train has gone a refresh moves it to the next one.

**Siri and Shortcuts.** Say "When's my next train in Train Times?" Siri answers
with the next train you can catch (and when to leave, and any delays) and shows
the next few. iOS needs the app's name in the phrase. Both actions are in the
Shortcuts app too, where you can pick a different train.

The app follows your phone's light or dark setting. The widget always uses its
dark station-board look, and on tinted Home Screens its line bullet turns into an
outline so the letter stays readable.

There are two versions:

- `ios/`: a native app and widget. You pick any station and line in the app, and
  the widget moves on to the next train by itself and has a refresh button. It's
  built on GitHub's Mac servers, so you don't need a Mac.
- `scriptable/`: a script for the free Scriptable app, fixed to the R train at
  Prospect Av (change the settings at the top to use another stop). No computer
  needed.

## Install the native version (Windows/Mac/Linux computer, free Apple ID)

1. **Get the build.** Every push to `main` builds the app on a GitHub Mac
   (see the Actions tab, about 5 to 10 minutes). When it's green, download
   `NextRTrain.ipa` from the [latest release](../../releases/tag/latest).
2. **Install AltStore** on your iPhone by following the official guide at
   [altstore.io](https://altstore.io). It needs AltServer running on your
   computer, and your iPhone on the same Wi-Fi. Turn on **Developer Mode** on the
   iPhone if it asks (Settings → Privacy & Security).
3. **Put the `.ipa` on the iPhone** (AirDrop, iCloud Drive or Files), open AltStore,
   go to **My Apps**, tap **+**, and pick `NextRTrain.ipa`. Sign in with your Apple
   ID when it asks. The app and widget use two of the ten App IDs a free account
   gets.
4. **Choose your train.** Open **Train Times**. Tap **Station** to search for one
   (or filter by line first), then pick the line and direction. The widget
   updates right away.
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
