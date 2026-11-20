#!/usr/bin/env bash
# Build the AutowakeBar menu bar app.
#
#   ./menubar/build.sh            build menubar/build/AutowakeBar.app
#   ./menubar/build.sh --install  build, copy to ~/Applications, start at login, launch it
#   ./menubar/build.sh --uninstall  stop it and remove the app + login agent
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="AutowakeBar"
BUILD_DIR="$DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_APP="$HOME/Applications/$APP_NAME.app"
LOGIN_LABEL="com.autowake.menubar"
LOGIN_PLIST="$HOME/Library/LaunchAgents/$LOGIN_LABEL.plist"

uninstall() {
    launchctl bootout "gui/$(id -u)/$LOGIN_LABEL" 2>/dev/null || true
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -f "$LOGIN_PLIST"
    rm -rf "$INSTALL_APP"
    echo "Removed $APP_NAME."
}

if [ "${1:-}" = "--uninstall" ]; then
    uninstall
    exit 0
fi

echo "Compiling $APP_NAME..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    "$DIR/AutowakeBar.swift"

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$LOGIN_LABEL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS is happy running it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [ "${1:-}" != "--install" ]; then
    echo "Run it with: open \"$APP\"   (or pass --install to start it at login)"
    exit 0
fi

uninstall >/dev/null
mkdir -p "$HOME/Applications"
cp -R "$APP" "$INSTALL_APP"

cat > "$LOGIN_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LOGIN_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$INSTALL_APP/Contents/MacOS/$APP_NAME</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$LOGIN_PLIST"
echo "Installed to $INSTALL_APP and started. It will launch at login."
