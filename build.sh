#!/bin/bash
# Build, test and install Knob without Xcode or SwiftPM (only Command Line Tools needed).
#   ./build.sh          build build/Knob.app
#   ./build.sh test     run the parser tests
#   ./build.sh install  build, install to ~/Applications and launch
#   ./build.sh dmg      build build/Knob-<version>.dmg, the file people download
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Knob"
BUNDLE_ID="dev.yusifabasov.knob"
VERSION="0.1.0"
MIN_MACOS="14.0"
ICON_CONCEPT="screen"   # which drawing in Tools/Icon.swift becomes the app icon (dial | screen | sun)
BUILD=build
APP="$BUILD/$APP_NAME.app"

mkdir -p "$BUILD"

run_tests() {
    swiftc -O -o "$BUILD/tests" Sources/MonitorCore/*.swift Tests/*.swift
    "$BUILD/tests"
}

# Render the app icon with Tools/Icon.swift and pack every size macOS uses into an .icns.
# Skipped when the drawing code hasn't changed since the last render.
build_icon() {
    ICNS="$BUILD/AppIcon-$ICON_CONCEPT.icns"
    if [ -f "$ICNS" ] && [ "$ICNS" -nt Tools/Icon.swift ]; then return; fi
    swiftc -O -parse-as-library Tools/Icon.swift -o "$BUILD/icon"
    local set="$BUILD/AppIcon.iconset"
    rm -rf "$set"; mkdir -p "$set"
    "$BUILD/icon" "$ICON_CONCEPT" "$BUILD/AppIcon-1024.png" 1024
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$BUILD/AppIcon-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
        sips -z "$((s * 2))" "$((s * 2))" "$BUILD/AppIcon-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o "$ICNS"
}

build_app() {
    build_icon
    clang -O2 -arch arm64 -mmacosx-version-min="$MIN_MACOS" -I Sources/CDDC/include \
        -c Sources/CDDC/ddc.c -o "$BUILD/ddc.o"
    swiftc -O -target "arm64-apple-macosx$MIN_MACOS" -parse-as-library \
        -I Sources/CDDC/include \
        -framework IOKit -framework CoreFoundation -framework ServiceManagement \
        Sources/MonitorCore/*.swift Sources/App/*.swift "$BUILD/ddc.o" \
        -o "$BUILD/Knob"

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BUILD/Knob" "$APP/Contents/MacOS/Knob"
    cp "$BUILD/AppIcon-$ICON_CONCEPT.icns" "$APP/Contents/Resources/AppIcon.icns"
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Knob</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    codesign --force --sign - "$APP" >/dev/null
    echo "Built $APP"
}

# Disk image for distribution: Knob.app plus an Applications shortcut to drag it onto, with
# the app icon as the disk's icon. Built read-write first so the icon flag can be set, then
# compressed.
make_dmg() {
    build_app
    local dmg="$BUILD/$APP_NAME-$VERSION.dmg" rw="$BUILD/dmg-rw.dmg" stage="$BUILD/dmg"
    rm -rf "$stage" "$dmg" "$rw"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    cp "$BUILD/AppIcon-$ICON_CONCEPT.icns" "$stage/.VolumeIcon.icns"
    hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$rw" >/dev/null
    local mnt
    mnt=$(hdiutil attach -nobrowse -noverify -noautoopen "$rw" | awk -F'\t' '/\/Volumes\//{print $NF}')
    SetFile -a C "$mnt" # use .VolumeIcon.icns as the disk icon
    hdiutil detach "$mnt" >/dev/null
    hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
    rm -rf "$rw" "$stage"
    echo "Built $dmg ($(du -h "$dmg" | cut -f1))"
}

case "${1:-build}" in
    test) run_tests ;;
    build) build_app ;;
    install)
        run_tests
        build_app
        pkill -x Knob 2>/dev/null || true
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/$APP_NAME.app"
        cp -R "$APP" "$HOME/Applications/"
        touch "$HOME/Applications/$APP_NAME.app" # nudge Finder/Launch Services to pick up icon changes
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -f "$HOME/Applications/$APP_NAME.app" 2>/dev/null || true
        open "$HOME/Applications/$APP_NAME.app"
        echo "Installed and launched ~/Applications/$APP_NAME.app"
        ;;
    dmg)
        run_tests
        make_dmg
        ;;
    *) echo "usage: $0 [build|test|install|dmg]"; exit 1 ;;
esac
