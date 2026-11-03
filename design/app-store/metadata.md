# App Store listing: Leeway

Text for App Store Connect, each field within its limit (counts checked). Paste as is, or edit and recount.

## Name · 24/30

Leeway: NYC Subway Times

The Home Screen keeps showing **Leeway** (`CFBundleDisplayName`); this is only the store's name. If it's taken, try *Leeway: Next Train NYC* (22).

## Subtitle · 29/30

Next train, and when to leave

## Promotional text · 135/170

A live countdown to your next subway train on your Home Screen, with your walk to the station counted in, so you know when to head out.

Promotional text can change at any time without a new build.

## Keywords · 95/100

```
subway,mta,nyc,train,times,widget,countdown,transit,commute,metro,station,brooklyn,queens,bronx
```

Commas, no spaces. The app's name and its category are already searched, so they're left out.

## Description · 1589/4000

```
Leeway puts a live countdown to your next NYC subway train on your Home Screen, with the trains after it and the moment you need to leave.

YOUR NEXT TRAIN
• A Home Screen widget counting down to your train, with the next few after it
• Live predictions in green; timetable times the MTA hasn't assigned a train to yet in white
• Every subway line and the Staten Island Railway, from the MTA's own real-time feeds

WHEN TO LEAVE
• Set how long your walk to the station takes, and Leeway counts down to when to head out
• Trains you can't reach in time are left out
• Tap the walk button, or say "Start my train countdown in Leeway", for a countdown on your Lock Screen and in the Dynamic Island

CHANGING TRAINS
• The Transfers widget times a change on the way, like the R to the D or N at Atlantic Av-Barclays Ctr
• Give it a destination and every way there is timed, fastest first, with the walk between platforms counted in

AROUND YOU
• The Trains near you widget lists the closest stations, how far each is, and each line's next train both ways
• Service alerts for your line, station and direction, right on the widget
• Step-free access: which elevators and escalators are out, and the MTA's advice for getting around them

YOUR WAY
• As many widgets as you like, for home, work and anywhere else, each with its own train
• Commuting hours: show your train home in the evening
• Ask Siri "When's my next train in Leeway?", or use its actions in Shortcuts
• Follows light and dark mode; on tinted Home Screens every line's bullet stays readable

Leeway isn't affiliated with the MTA.
```

## What's New · 67/4000

A new icon: the yellow strip at the platform's edge, domes and all.

## Categories

- Primary: **Navigation**
- Secondary: **Travel**

## Still to fill in App Store Connect

These need answers only you can give, so nothing is guessed here:

- **Support URL** and **Privacy Policy URL** (both required).
- **App Privacy**: the app asks for Location (trips from where you are, the Trains near you widget, walking turns), and Settings has a **Share Diagnostics** switch; declare what each collects and whether it's linked to the person.
- **Age rating** questionnaire.
- **Copyright** line, for example "2026 Your Name".
- **App Review notes**: there's no sign-in to give a reviewer. Live countdowns get new times from the push server (`server/`) once App Attest succeeds, which it can't in the simulator.
- **"Leeway isn't affiliated with the MTA."** closes the description; keep it, since the app names the MTA and shows its line colours.
