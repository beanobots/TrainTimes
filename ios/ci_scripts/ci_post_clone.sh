#!/bin/sh
# Xcode Cloud runs this right after cloning. Leeway.xcodeproj isn't in git (XcodeGen makes it
# from project.yml), so make it here, with the same XcodeGen as locally
set -euo pipefail

XCODEGEN_VERSION=2.46.0
TOOLS="${TMPDIR:-/tmp}/xcodegen-$XCODEGEN_VERSION"

if [ ! -x "$TOOLS/xcodegen/bin/xcodegen" ]; then
    mkdir -p "$TOOLS"
    curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" -o "$TOOLS/xcodegen.zip"
    unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
"$TOOLS/xcodegen/bin/xcodegen" generate
