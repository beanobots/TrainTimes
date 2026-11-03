# Leeway: App Store assets

The new icon, Close-up Tonal, and the artwork and text for the App Store listing. The icon is the yellow strip at a subway platform's edge: tonal domes in a true stagger, a concrete seam, the yellow edge line, then the track in deeper concrete.

## What's here

| Path | What | Size | Where it goes |
| --- | --- | --- | --- |
| `icon/AppIcon-1024.png` | The app icon, default appearance | 1024×1024, RGB, no alpha | Already in `ios/App/Assets.xcassets/AppIcon.appiconset/icon.png`; App Store Connect takes the icon from the build |
| `icon/AppIcon-1024-dark.png` | Dark appearance: the track goes near-black | 1024×1024 | `icon-dark.png` in the same icon set |
| `icon/AppIcon-1024-tinted.png` | Tinted appearance: greyscale, which iOS tints | 1024×1024 | `icon-tinted.png` in the same icon set |
| `icon/*.svg` | Sources for the three PNGs | 1024 artboard | Edit these, then re-export |
| `banners/leeway-banner-5244x2950.png` | Icon, LEEWAY and "For the New Yorker without a car" over the platform's edge | 5244×2950 | The banner |
| `banners/leeway-search-results-5244x2950.png` | The banner's layout: icon, LEEWAY and the subhead over the platform's edge | 5244×2950 | Search results, landscape |
| `banners/leeway-search-results-2950x5244.png` | The same, upright: icon, LEEWAY and the subhead stacked, the platform's edge below | 2950×5244 | Search results, portrait |
| `banners/leeway-banner-1200x630.png` | The same, for link previews | 1200×630 | A website's Open Graph image |
| `banners/leeway-banner-1500x500.png` | The same, wide | 1500×500 | A social header |
| `screenshots/iphone-6.9-drafts/` | Six framed screenshots of first-run setup | 1320×2868 | **Drafts**: see below |
| `metadata.md` | Name, subtitle, promotional text, keywords, description, What's New, categories | — | App Store Connect, field by field |
| `tools/make_assets.py` | Draws the banners and frames screenshots | — | Run it to remake either |

The icon is full-bleed and square, as Apple asks: iOS and the App Store draw the rounded corners.

## Screenshots

App Store Connect needs **6.9-inch iPhone** screenshots (1320×2868 or 1290×2796); it scales them down for smaller iPhones. `ios/project.yml` doesn't set `TARGETED_DEVICE_FAMILY`, and XcodeGen's iOS default is iPhone and iPad, so check the built target: if it includes iPad, App Store Connect also asks for **13-inch iPad** screenshots (2064×2752 or 2048×2732). To ship on iPhone only, set `TARGETED_DEVICE_FAMILY: "1"` on the Leeway target.

The six in `iphone-6.9-drafts/` are drawn from the design system's setup mockups, not captured from the app, and their SF Symbols are stand-ins. Use them to judge the layout and headlines, then replace them with real captures. App Review expects screenshots of the app itself. Lead with the widgets, which setup can't show:

1. Capture from a 6.9-inch simulator (such as iPhone 16 Pro Max) or a device: the Home Screen with a Next train widget, the Lock Screen countdown, the Transfers widget, Trains near you, an alert, and a setup screen.
2. Put the captures in one folder and list them with their headlines, in order, as `screenshots/captions.example.json` does.
3. Frame them:

```bash
pip3 install pillow
python3 design/app-store/tools/make_assets.py screenshots path/to/captures design/app-store/screenshots/captions.example.json design/app-store/screenshots/iphone-6.9
```

For iPad, add `--size 2064x2752`.

Headlines follow the app's voice: sentence case, no full stop, at most two lines.

## Remaking the banners

```bash
python3 design/app-store/tools/make_assets.py banners
```

## Colours and type

| | Hex | Use |
| --- | --- | --- |
| Strip yellow | `#fbcb0a` | The strip and its edge line |
| Dome | `#e6b500` | The domes, only on the strip |
| Deeper concrete | `#6e6961` | The seam and the track |
| Platform concrete | `#8b867d` | Behind the strip in the banners and screenshots |
| Rail black | `#161514` | Text on concrete (5:1) and on the strip (11:1) |

LEEWAY and the headlines are set in **Archivo**, Expanded ExtraBold (width 125, weight 800). It's in `tools/fonts/` under the SIL Open Font License (`OFL.txt`); keep the licence with the font.
