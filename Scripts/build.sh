#!/bin/zsh
set -eu
STILL_SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$STILL_SOURCE"
install_app=false
if [[ ${1:-} == --install ]]; then
    install_app=true
    shift
fi
swift build -c release --sdk "$(xcrun --sdk macosx --show-sdk-path)" "$@"
STILL_BIN="$(swift build -c release --sdk "$(xcrun --sdk macosx --show-sdk-path)" "$@" --show-bin-path)"
# The deployment target is macOS 15, but native glass requires linking against SDK 26+.
if ! xcrun vtool -show-build "$STILL_BIN/Still" | awk '$1 == "sdk" { seen = 1; if ($2 + 0 < 26) old = 1 } END { exit (!seen || old) }'; then
    echo "Still requires a macOS 26 or newer linked SDK. Check the selected Xcode and rebuild." >&2
    exit 1
fi
STILL_APP="$STILL_SOURCE/dist/Still.app"
mkdir -p "$STILL_APP/Contents/MacOS" "$STILL_APP/Contents/Resources"
cp "$STILL_BIN/Still" "$STILL_APP/Contents/MacOS/Still"
cp Resources/local_server.py Resources/model_engines.py Resources/generation.py Resources/inkling_protocol.py Resources/gemma_protocol.py "$STILL_APP/Contents/Resources/"
mkdir -p "$STILL_APP/Contents/Resources/still_gemma"
cp Resources/still_gemma/*.py Resources/still_gemma/LICENSE* Resources/still_gemma/PROVENANCE.md "$STILL_APP/Contents/Resources/still_gemma/"
rm -f "$STILL_APP/Contents/Resources/managed_server.py" "$STILL_APP/Contents/Resources/gemma_server.py"
cp Resources/Info.plist "$STILL_APP/Contents/Info.plist"
cp Resources/Still.icns "$STILL_APP/Contents/Resources/"
xattr -cr "$STILL_APP"
codesign --force --deep --sign - "$STILL_APP"
codesign --verify --deep --strict "$STILL_APP"
ditto -c -k --norsrc --noextattr --keepParent "$STILL_APP" "$STILL_SOURCE/.build/Still.zip"
mv -f "$STILL_SOURCE/.build/Still.zip" "$STILL_SOURCE/dist/Still.zip"
echo "Built $STILL_APP"
if [[ $install_app == true ]]; then
    exec Scripts/install-app.sh
fi
