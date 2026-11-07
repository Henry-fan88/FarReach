#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/farreach-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/farreach-swift-cache"
./scripts/build-network.sh
swift package resolve
SPARKLE_ROOT="$PWD/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$SPARKLE_FRAMEWORK"
cp "$SPARKLE_ROOT/LICENSE" Resources/ThirdParty/Sparkle-LICENSE
# Universal output runs on both Apple silicon and Intel Macs.
for ARCH in arm64 x86_64; do
    swift build --disable-sandbox --scratch-path ".build/release-$ARCH" -c release --arch "$ARCH" \
        -Xswiftc -file-prefix-map -Xswiftc "$PWD=/FarReach" \
        -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/FarReach" -Xswiftc -gnone
done
ARM_BIN="$(swift build --disable-sandbox --scratch-path .build/release-arm64 -c release --arch arm64 --show-bin-path)/FarReach"
INTEL_BIN="$(swift build --disable-sandbox --scratch-path .build/release-x86_64 -c release --arch x86_64 --show-bin-path)/FarReach"
OUTPUT_DIR="${FARREACH_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUTPUT_DIR"
APP_PATH="$OUTPUT_DIR/FarReach.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Frameworks"
/usr/bin/lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP_PATH/Contents/MacOS/FarReach"
# Remove linker debug records that can retain absolute object/module paths.
/usr/bin/strip -S "$APP_PATH/Contents/MacOS/FarReach"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
python3 scripts/configure-update-bundle.py Resources/UpdateConfiguration.json "$APP_PATH/Contents/Info.plist"
cp Networking/bin/FarReachNetwork "$APP_PATH/Contents/Helpers/FarReachNetwork"
/usr/bin/ditto --norsrc --noextattr "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d Resources/ThirdParty ]]; then
    /usr/bin/ditto Resources/ThirdParty "$APP_PATH/Contents/Resources/ThirdParty"
fi
SIGN_ARGS=(--force --sign "${FARREACH_SIGN_IDENTITY:--}")
if [[ "${FARREACH_SIGN_IDENTITY:--}" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
SPARKLE_BUNDLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
# Sign nested code inside-out, keeping the vendor's required XPC entitlements.
for NESTED in "XPCServices/Downloader.xpc" "XPCServices/Installer.xpc" "Autoupdate" "Updater.app"; do
    /usr/bin/codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE_BUNDLE/Versions/B/$NESTED"
done
/usr/bin/codesign "${SIGN_ARGS[@]}" "$SPARKLE_BUNDLE"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_PATH/Contents/Helpers/FarReachNetwork"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
# Package without local owner IDs, timestamps, or Finder metadata.
python3 scripts/package-app.py "$APP_PATH" "$OUTPUT_DIR/FarReach-macOS.zip"
printf 'Built %s\n' "$APP_PATH"
