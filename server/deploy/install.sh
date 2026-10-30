#!/bin/bash
# Builds TrainTimesServer and installs it as a LaunchDaemon running as the
# hidden, unprivileged user "traintimes". Safe to run again to update it.
#
#   sudo ./deploy/install.sh
set -euo pipefail

LABEL=com.traintimes.server
SERVICE_USER=traintimes
# Can read the log and the plist, for the admin app (mac/): admins could
# with sudo anyway. The key and the database stay the service's alone.
ADMIN_GROUP=admin
PREFIX=/usr/local/traintimes
PLIST=/Library/LaunchDaemons/$LABEL.plist
BUNDLE=TrainTimesServer_TrainResources.bundle
LOG=$PREFIX/server.log
NEWSYSLOG=/etc/newsyslog.d/$LABEL.conf

DEPLOY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACKAGE_DIR=$(dirname "$DEPLOY_DIR")

step() { echo "==> $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Run this with sudo: sudo $0" >&2
    exit 1
fi

if [[ -n ${PREBUILT_BIN_DIR:-} ]]; then
    # Built already, as by the admin app (mac/), which runs a copy of this
    # script from outside ~/Documents: root can't read there
    step "Using the release build in $PREBUILT_BIN_DIR"
    BIN_DIR=$PREBUILT_BIN_DIR
else
    # Build as whoever ran sudo, so .build isn't left owned by root
    BUILD_USER=${SUDO_USER:-root}
    step "Building a release build as $BUILD_USER"
    sudo -H -u "$BUILD_USER" swift build -c release --package-path "$PACKAGE_DIR"
    BIN_DIR=$(sudo -H -u "$BUILD_USER" swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)
fi
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

# $PREFIX and the program are root's, so the service can't put links where
# this script works. What's the service's (data/, the log and the .p8 key) is
# never recursed into, nor followed if it's a link.
step "Installing into $PREFIX (root's; data/, the log and the key $SERVICE_USER's, the log readable by $ADMIN_GROUP)"
install -d -o root -g wheel -m 755 "$PREFIX"
# newsyslog, as root, chowns and chmods the log's old copies as it moves them
# down. While $PREFIX was the service's it could have put links by those
# names, so all but plain files with one name go.
find "$PREFIX" -maxdepth 1 -name 'server.log.*' ! \( -type f -links 1 \) -exec rm -rf {} +
if [[ ! -e $PREFIX/data && ! -L $PREFIX/data ]]; then
    install -d -o "$SERVICE_USER" -m 700 "$PREFIX/data"
fi
# Copied in beside the old ones, then swapped in
rm -rf "$PREFIX/TrainTimesServer.new" "$PREFIX/$BUNDLE.new"
install -o root -g wheel -m 755 "$BIN_DIR/TrainTimesServer" "$PREFIX/TrainTimesServer.new"
cp -R "$BIN_DIR/$BUNDLE" "$PREFIX/$BUNDLE.new"
chmod -R u=rwX,go=rX "$PREFIX/$BUNDLE.new"
# A link or a directory left where the program goes (from when $PREFIX was
# the service's) would take the new one somewhere else
[[ -f $PREFIX/TrainTimesServer && ! -L $PREFIX/TrainTimesServer ]] || rm -rf "$PREFIX/TrainTimesServer"
mv -f "$PREFIX/TrainTimesServer.new" "$PREFIX/TrainTimesServer"
rm -rf "$PREFIX/$BUNDLE"
mv "$PREFIX/$BUNDLE.new" "$PREFIX/$BUNDLE"
# The log only as a plain file with no other name, made afresh otherwise
if [[ -L $LOG ]] || [[ ! -f $LOG ]] || [[ $(stat -f %l "$LOG") != 1 ]]; then
    rm -rf "$LOG"
    (umask 077 && : > "$LOG")
fi
chown "$SERVICE_USER:$ADMIN_GROUP" "$LOG"
chmod 640 "$LOG"
find "$PREFIX" -maxdepth 1 -type f -links 1 -name '*.p8' -exec chown "$SERVICE_USER" {} + -exec chmod 600 {} +

step "Rotating the log at 10 MB, keeping 7 ($NEWSYSLOG)"
mkdir -p "$(dirname "$NEWSYSLOG")"
cat > "$NEWSYSLOG" <<EOF
# Installed by TrainTimes' deploy/install.sh. The server moves to the new file
# itself (LOG_FILE), so N: there's nothing to signal.
# logfile                           owner:group      mode count size(KB) when flags
$LOG    $SERVICE_USER:$ADMIN_GROUP    640  7     10240    *    N
EOF
chown root:wheel "$NEWSYSLOG"
chmod 644 "$NEWSYSLOG"

if [[ -f "$PLIST" ]]; then
    step "Keeping the existing $PLIST (root:$ADMIN_GROUP, mode 640)"
    chown "root:$ADMIN_GROUP" "$PLIST"
    chmod 640 "$PLIST"
else
    step "Installing $PLIST (root:$ADMIN_GROUP, mode 640)"
    install -o root -g "$ADMIN_GROUP" -m 640 "$DEPLOY_DIR/$LABEL.plist" "$PLIST"
fi

# Placeholders in values, not the comment that mentions them
if grep -q '<string>[^<]*XXXX' "$PLIST"; then
    step "Not starting yet: $PLIST still has XXXX placeholders"
    echo "    1. sudo install -o $SERVICE_USER -m 600 AuthKey_<KEYID>.p8 $PREFIX/"
    echo "    2. sudo nano $PLIST   (APNS_KEY_PATH and APNS_KEY_ID)"
    echo "    3. sudo $0"
    exit 0
fi

# Unloaded and loaded again, not kickstarted: launchd holds a loaded job to
# the code hash of the program it was loaded with, so a kickstarted new build
# fails to spawn (EX_CONFIG). Loading again also picks up changes to $PLIST.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    step "Stopping the running daemon (launchctl bootout)"
    launchctl bootout "system/$LABEL" || true
    # bootout returns before the job's gone, and bootstrap fails until it is
    for _ in {1..50}; do
        launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 0.1
    done
fi
step "Starting the daemon (launchctl bootstrap)"
launchctl bootstrap system "$PLIST"

if grep -q '<key>ATTEST_MODE</key>' "$PLIST" && grep -A1 '<key>ATTEST_MODE</key>' "$PLIST" | grep -q '>off<'; then
    echo "    Warning: ATTEST_MODE is off: anyone with API_SECRET can register. For development only."
fi
if ! grep -q '<key>LOG_FILE</key>' "$PLIST"; then
    echo "    Note: $PLIST has no LOG_FILE, so after newsyslog rotates the log the server writes to"
    echo "    the old one until it restarts. Add LOG_FILE as deploy/$LABEL.plist has it."
fi
step "Done. Log: tail -f $PREFIX/server.log"
