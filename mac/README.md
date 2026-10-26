# Train Times Server (Mac app)

Manages the push server (`../server`) on the Mac mini it runs on, from an admin
account:

- **Overview:** whether the LaunchDaemon is running, `/health` and cloudflared,
  the APNs key and App Attest mode, the last pass's totals and the attest key
  count, pushes per pass over the last hour, and the push timing.
- **Logs:** `server.log` as it's written, filtered by kind or text.
- **Configuration:** the plist's settings. Save & Restart writes the plist and
  loads it again, since launchd only reads the environment as it loads it.
  Saving drops the plist's comments.
- **Rebuild:** builds and tests the server from the files on disk (it never
  pulls), runs `deploy/install.sh`, then checks `/health`. Root can't read
  `~/Documents`, so it runs a copy of `deploy/` with the build beside it, from
  your temporary folder (`PREBUILT_BIN_DIR`). Cancel stops the build, the
  tests or the health check; once `install.sh` has started, it runs to the end.

Stop, Start, Restart, Save and Rebuild ask for your password: they run as root
through `osascript`. Reading needs none: `launchctl print` gives the status and
environment, and `install.sh` makes the log and the plist readable by the admin
group. Until it has run once, the log and the plist can't be read; Rebuild
fixes that.

## Build

    ~/.local/xcodegen/xcodegen/bin/xcodegen generate
    xcodebuild -project TrainTimesAdmin.xcodeproj -scheme TrainTimesAdmin -derivedDataPath build
    open "build/Build/Products/Debug/Train Times Server.app"

It's signed to run on this Mac only and isn't sandboxed. Tests: add `test` to
the `xcodebuild` line.
