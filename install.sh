#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="com.github.catsout.wallpaperEngineKde"
BRAND="WEPLUSforKDE"
VERSION="1.0.0"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/${PLUGIN_ID}"
DEST_DIR="${HOME}/.local/share/plasma/wallpapers/${PLUGIN_ID}"

NO_DEPS=0
ASSUME_YES=0
NO_RESTART=0

say() { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --no-deps) NO_DEPS=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --no-restart) NO_RESTART=1 ;;
        -h|--help)
            say "Usage: ./install.sh [--no-deps] [--yes] [--no-restart]"
            exit 0
            ;;
        *) die "Unknown option: $arg" ;;
    esac
done

if [ ! -f "${SRC_DIR}/metadata.json" ]; then
    if [ -f "${SCRIPT_DIR}/metadata.json" ] && [ -d "${SCRIPT_DIR}/contents" ]; then
        SRC_DIR="${SCRIPT_DIR}"
    else
        die "Plugin directory not found. Run this script from the extracted release root."
    fi
fi

say "============================================================"
say "  ${BRAND} v${VERSION} — Easy Setup"
say "============================================================"

if command -v plasmashell >/dev/null 2>&1; then
    PLASMA_VERSION="$(plasmashell --version 2>/dev/null || true)"
    case "${PLASMA_VERSION}" in
        *" 6."*|*" 6"*) ;;
        *) warn "KDE Plasma 6 is recommended. Detected: ${PLASMA_VERSION:-unknown}" ;;
    esac
fi

install_deps() {
    say "[1/4] Checking system dependencies..."
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm python python-pillow python-numpy python-websockets playerctl ffmpeg curl mpv
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3 python3-pillow python3-numpy python3-websockets playerctl ffmpeg curl mpv
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y python3 python3-pil python3-numpy python3-websockets playerctl ffmpeg curl mpv
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y python3 python3-Pillow python3-numpy python3-websockets playerctl ffmpeg curl mpv
    else
        warn "Unrecognized package manager. Install manually: python3, Pillow, numpy, websockets, playerctl, ffmpeg, curl, mpv."
    fi
}

if [ "${NO_DEPS}" -eq 0 ]; then
    if [ "${ASSUME_YES}" -eq 1 ]; then
        install_deps
    else
        read -r -p "Install/verify system dependencies now? [S/n]: " ans || ans="s"
        case "${ans}" in
            [nN]*) say "[INFO] Skipping system package installation." ;;
            *) install_deps ;;
        esac
    fi
fi

say "[2/4] Installing plugin files to ${DEST_DIR}..."
if [ -d "${DEST_DIR}" ]; then
    BACKUP="${DEST_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
    mv "${DEST_DIR}" "${BACKUP}"
    say "  Backup: ${BACKUP}"
fi

installed=0
if command -v kpackagetool6 >/dev/null 2>&1; then
    if kpackagetool6 -t Plasma/Wallpaper -l 2>/dev/null | grep -qx "${PLUGIN_ID}"; then
        if kpackagetool6 -t Plasma/Wallpaper -u "${SRC_DIR}"; then installed=1; fi
    else
        if kpackagetool6 -t Plasma/Wallpaper -i "${SRC_DIR}"; then installed=1; fi
    fi
fi
if [ "${installed}" -eq 0 ]; then
    mkdir -p "$(dirname "${DEST_DIR}")"
    rm -rf "${DEST_DIR}"
    cp -r "${SRC_DIR}" "${DEST_DIR}"
    say "  Installed by direct copy."
fi

say "[3/4] Creating cache directories..."
mkdir -p "${HOME}/.local/share/wallpaperEngineKde/translated"
mkdir -p "${HOME}/.config/wekde/wallpaper"

say "[4/4] Checking native backend..."
if ldconfig -p 2>/dev/null | grep -q libWallpaperEngineKde; then
    say "  [OK] libWallpaperEngineKde.so detected."
elif [ -n "$(find /usr/lib /usr/lib64 /usr/local/lib "${HOME}/.local/lib" -name 'libWallpaperEngineKde.so' 2>/dev/null)" ]; then
    say "  [OK] libWallpaperEngineKde.so detected."
else
    warn "libWallpaperEngineKde.so was not found."
    say "  Scene and video wallpapers require the native backend."
    say "  Arch/CachyOS: yay -S wallpaper-engine-kde-plugin-git"
    say "  Other distributions: build the upstream C++/Vulkan backend."
fi

if [ "${NO_RESTART}" -eq 0 ]; then
    if [ "${ASSUME_YES}" -eq 0 ]; then
        read -r -p "Restart plasmashell now? [S/n]: " r_ans || r_ans="s"
    else
        r_ans="s"
    fi
    case "${r_ans}" in
        [nN]*) say "[INFO] Restart Plasma manually to activate the plugin." ;;
        *)
            if systemctl --user list-unit-files 2>/dev/null | grep -q '^plasma-plasmashell.service'; then
                systemctl --user restart plasma-plasmashell.service || warn "Could not restart plasma-plasmashell.service."
            elif command -v kquitapp6 >/dev/null 2>&1; then
                kquitapp6 plasmashell >/dev/null 2>&1 || true
                sleep 1
                kstart plasmashell >/dev/null 2>&1 &
            else
                warn "Restart Plasma manually."
            fi
            ;;
    esac
fi

say "[OK] ${BRAND} v${VERSION} installed."
say "     Select the Steam library that contains steamapps/workshop/content/431960."
