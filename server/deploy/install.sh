#!/bin/bash
# Builds TrainTimesServer and installs it as a LaunchDaemon running as the
# hidden, unprivileged user "traintimes". Safe to run again to update it.
#
#   sudo ./deploy/install.sh
set -euo pipefail

LABEL=com.traintimes.server
SERVICE_USER=traintimes
PREFIX=/usr/local/traintimes
PLIST=/Library/LaunchDaemons/$LABEL.plist
BUNDLE=TrainTimesServer_TrainResources.bundle

DEPLOY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACKAGE_DIR=$(dirname "$DEPLOY_DIR")

step() { echo "==> $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Run this with sudo: sudo $0" >&2
    exit 1
fi

# Build as whoever ran sudo, so .build isn't left owned by root
BUILD_USER=${SUDO_USER:-root}
step "Building a release build as $BUILD_USER"
sudo -H -u "$BUILD_USER" swift build -c release --package-path "$PACKAGE_DIR"
BIN_DIR=$(sudo -H -u "$BUILD_USER" swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)
[[ -x "$BIN_DIR/TrainTimesServer" && -d "$BIN_DIR/$BUNDLE" ]] || { echo "Build output not found in $BIN_DIR" >&2; exit 1; }

if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    step "User $SERVICE_USER already exists"
else
    step "Creating the hidden, non-admin user $SERVICE_USER"
    # A random password nobody keeps: the account is only for running the daemon
    sysadminctl -addUser "$SERVICE_USER" -fullName "Train Times Server" \
        -password "$(openssl rand -base64 32)" -home /var/empty -shell /usr/bin/false
    id -u "$SERVICE_USER" >/dev/null 2>&1 || { echo "Creating $SERVICE_USER failed" >&2; exit 1; }
fi
dscl . -create "/Users/$SERVICE_USER" IsHidden 1

step "Installing into $PREFIX"
install -d -m 700 "$PREFIX" "$PREFIX/data"
# Copied in beside the old ones, then swapped in
install -m 700 "$BIN_DIR/TrainTimesServer" "$PREFIX/TrainTimesServer.new"
rm -rf "$PREFIX/$BUNDLE.new"
cp -R "$BIN_DIR/$BUNDLE" "$PREFIX/$BUNDLE.new"
mv -f "$PREFIX/TrainTimesServer.new" "$PREFIX/TrainTimesServer"
rm -rf "$PREFIX/$BUNDLE"
mv "$PREFIX/$BUNDLE.new" "$PREFIX/$BUNDLE"
touch "$PREFIX/server.log"

step "Setting owner $SERVICE_USER, mode 700"
chown -R "$SERVICE_USER" "$PREFIX"
chmod 700 "$PREFIX" "$PREFIX/data" "$PREFIX/TrainTimesServer"
chmod -R go-rwx "$PREFIX"
find "$PREFIX" -maxdepth 1 -name '*.p8' -exec chmod 600 {} +

if [[ -f "$PLIST" ]]; then
    step "Keeping the existing $PLIST"
else
    step "Installing $PLIST (root:wheel, mode 600)"
    install -o root -g wheel -m 600 "$DEPLOY_DIR/$LABEL.plist" "$PLIST"
fi

# Placeholders in values, not the comment that mentions them
if grep -q '<string>[^<]*XXXX' "$PLIST"; then
    step "Not starting yet: $PLIST still has XXXX placeholders"
    echo "    1. sudo install -o $SERVICE_USER -m 600 AuthKey_<KEYID>.p8 $PREFIX/"
    echo "    2. sudo nano $PLIST   (APNS_KEY_PATH and APNS_KEY_ID)"
    echo "    3. sudo $0"
    exit 0
fi

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    step "Restarting the running daemon (launchctl kickstart -k)"
    launchctl kickstart -k "system/$LABEL"
else
    step "Starting the daemon (launchctl bootstrap)"
    launchctl bootstrap system "$PLIST"
fi

if grep -q '<key>ATTEST_MODE</key>' "$PLIST" && grep -A1 '<key>ATTEST_MODE</key>' "$PLIST" | grep -q '>off<'; then
    echo "    Warning: ATTEST_MODE is off: anyone with API_SECRET can register. For development only."
fi
step "Done. Log: sudo tail -f $PREFIX/server.log"
