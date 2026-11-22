#!/bin/zsh
set -eu
set -o pipefail

source_app="${0:A:h:h}/dist/Still.app"
destination="${STILL_APPLICATIONS_DIR:-/Applications}"
target="$destination/Still.app"

codesign --verify --deep --strict "$source_app"
if [[ -d "$target" ]] && diff -qr "$source_app" "$target" >/dev/null && codesign --verify --deep --strict "$target"; then
    echo "Already current: $target"
    exit 0
fi
if [[ -e "$target" || -L "$target" ]]; then
    if [[ -L "$target" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null)" != app.still.chat ]]; then
        echo "Expected the installed Still app at $target. Leaving this item in place." >&2
        exit 1
    fi
fi

# Stage on the destination volume so a failed copy cannot damage the installed app.
stage=$(mktemp -d "$destination/.still-install.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
ditto --norsrc --noextattr "$source_app" "$stage/Still.app"
codesign --verify --deep --strict "$stage/Still.app"
diff -qr "$source_app" "$stage/Still.app"

/usr/bin/python3 - "$stage/Still.app" "$target" <<'PY'
import ctypes
import os
import sys

staged, installed = sys.argv[1:]
if os.path.lexists(installed):
    # macOS RENAME_SWAP exchanges both directory entries atomically.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renamex_np(os.fsencode(staged), os.fsencode(installed), 2):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), installed)
else:
    os.rename(staged, installed)
PY
codesign --verify --deep --strict "$target"
diff -qr "$source_app" "$target"
echo "Installed and verified: $target"
