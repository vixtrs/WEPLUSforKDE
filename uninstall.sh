#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="com.github.catsout.wallpaperEngineKde"
DEST_DIR="${HOME}/.local/share/plasma/wallpapers/${PLUGIN_ID}"
PURGE=0
ASSUME_YES=0
NO_RESTART=0

say() { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

for arg in "$@"; do
    case "$arg" in
        --purge-cache) PURGE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --no-restart) NO_RESTART=1 ;;
        -h|--help)
            say "Usage: ./uninstall.sh [--purge-cache] [--yes] [--no-restart]"
            exit 0
            ;;
        *) warn "Unknown option: $arg" ;;
    esac
done

if [ "${ASSUME_YES}" -eq 0 ]; then
    read -r -p "Remove ${PLUGIN_ID}? [y/N]: " ans || ans="n"
    case "${ans}" in
        [yY]*) ;;
        *) say "Cancelled."; exit 0 ;;
    esac
fi

removed=0
if command -v kpackagetool6 >/dev/null 2>&1; then
    if kpackagetool6 -t Plasma/Wallpaper -r "${PLUGIN_ID}" 2>/dev/null; then removed=1; fi
fi
if [ "${removed}" -eq 0 ] && [ -d "${DEST_DIR}" ]; then
    rm -rf "${DEST_DIR}"
    say "Removed ${DEST_DIR}"
fi

if [ "${PURGE}" -eq 1 ]; then
    rm -rf "${HOME}/.local/share/wallpaperEngineKde/translated"
    rm -rf "${HOME}/.config/wekde"
    say "Removed translation cache and wekde configuration."
fi

if [ "${NO_RESTART}" -eq 0 ]; then
    if systemctl --user list-unit-files 2>/dev/null | grep -q '^plasma-plasmashell.service'; then
        systemctl --user restart plasma-plasmashell.service || true
    elif command -v kquitapp6 >/dev/null 2>&1; then
        kquitapp6 plasmashell >/dev/null 2>&1 || true
        sleep 1
        kstart plasmashell >/dev/null 2>&1 &
    fi
fi

say "Uninstalled. Your Steam Workshop wallpapers were not touched."
