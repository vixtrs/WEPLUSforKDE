#!/bin/sh
# Wallpaper Engine KDE – Workshop install shim.
#
# The plugin calls this as:
#     we-trigger.sh <steam_library_path_or_file_url> <workshop_id> [appid] [reinstall]
#
# The real work lives in wek-download.py (next to this file): it normalizes
# file:// URLs, checks that the library/manifest exist, makes sure the Steam
# client is running and logged in, asks the client for the item, verifies that
# the files landed on disk and reports progress/failures instead of swallowing
# them.  Keeping both scripts inside the plugin makes the package portable.

LIB="$1"
ID="$2"
APPID="${3:-431960}"
REINSTALL="${4:-0}"

if [ -z "$LIB" ] || [ -z "$ID" ]; then
    echo "ERROR uso: we-trigger.sh <librería> <id> [appid] [reinstall]" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$REINSTALL" = "1" ]; then
    exec /usr/bin/python3 "$SCRIPT_DIR/wek-download.py" \
        --library "$LIB" --item "$ID" --appid "$APPID" --force
fi

exec /usr/bin/python3 "$SCRIPT_DIR/wek-download.py" \
    --library "$LIB" --item "$ID" --appid "$APPID"
