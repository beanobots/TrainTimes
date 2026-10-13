# Train Times: a next-train widget for the NYC subway

An iPhone widget with a live countdown to the next train, its arrival time, and
the trains after it. You choose the station, line and direction in the app. Live
predictions are green; timetable times the MTA hasn't assigned a train to yet are
white. It reads the MTA's free real-time feeds (no API key) and covers every
subway line and the Staten Island Railway.

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

## Changing the data

The station list (`ios/Shared/stations.json`) comes from the MTA's
[station list](http://web.mta.info/developers/data/nyct/subway/Stations.csv). To
refresh it, download the CSV and run
`python3 tools/make_stations.py Stations.csv ios/Shared/stations.json`, then push.

## How it stays fresh

iOS decides when widgets fetch new data, usually every 5 to 15 minutes. The
countdown ticks every second in between. The native version steps to the next
train when one arrives and has a refresh button (↻); the Scriptable one counts
back up from 0:00 until iOS next refreshes it.
