# Next R train widget: Prospect Av, Manhattan-bound

An iPhone widget with a live countdown to the next Manhattan-bound R train at
Prospect Av (Brooklyn), its arrival time, and the trains after it. Live
predictions are green; timetable times the MTA hasn't assigned a train to yet are
white. It reads the MTA's free real-time feed (no API key).

There are two versions:

- `scriptable/`: a script for the free Scriptable app. No computer needed.
- `ios/`: a native widget app. It moves on to the next train by itself and has a
  refresh button. It's built on GitHub's Mac servers, so you don't need a Mac.

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
4. **Add the widget.** Touch and hold the Home Screen, tap **Edit → Add Widget**,
   and choose **Next R train**.

A free Apple ID signs apps for 7 days. AltStore renews the signature on its own
when AltServer is running on your computer and your iPhone is on the same Wi-Fi.
If it lapses, the app stops opening until you refresh it in AltStore.

## Changing it

The settings are in `Settings` at the top of `ios/Widget/SubwayFeed.swift` (and at
the top of `scriptable/Next R Train.js`): the stop (`R34N` is Manhattan-bound,
`R34S` is toward Bay Ridge), which routes to show, and the labels. Push to `main`
and the build runs again.

## How it stays fresh

iOS decides when widgets fetch new data, usually every 5 to 15 minutes. The
countdown ticks every second in between. The native version steps to the next
train when one arrives and has a refresh button (↻); the Scriptable one counts
back up from 0:00 until iOS next refreshes it.
