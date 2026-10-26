#!/usr/bin/env python3
"""WEK Workshop downloader, auditor & unsubscriber (WEPLUSforKDE v3)."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

APPID_DEFAULT = "431960"
STEAM_ROOT = Path.home() / ".local/share/Steam"
if not (STEAM_ROOT / "logs").is_dir():
    _alt = Path.home() / ".steam/steam"
    if (_alt / "logs").is_dir():
        STEAM_ROOT = _alt
STEAM_LOGS = STEAM_ROOT / "logs"
STEAM_PIPE = Path.home() / ".steam/steam.pipe"
STEAM_WRAPPER = Path.home() / ".local/bin/steam"
DATA_DIR = Path.home() / ".local/share/wallpaperEngineKde/wek-download"
LOG_FILE = DATA_DIR / "wek-download.log"
STATUS_DIR = DATA_DIR / "status"
LOCK_FILE = DATA_DIR / ".lock"
WORKSHOP_LOG = STEAM_LOGS / "workshop_log.txt"


def now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(message: str) -> None:
    line = f"[{now()}] {message}"
    print(line, flush=True)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def write_status(item: str, state: str, message: str = "", **extra) -> None:
    try:
        STATUS_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "item": item,
            "state": state,
            "message": message,
            "updated": datetime.now(timezone.utc).isoformat(),
            **extra,
        }
        target = STATUS_DIR / f"{item}.json"
        tmp = target.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, target)
    except OSError:
        pass


def normalize_library(value: str) -> Path:
    value = (value or "").strip().strip("'\"")
    if value.startswith("file://"):
        value = urllib.parse.unquote(value[7:])
    elif value.startswith("file:"):
        value = urllib.parse.unquote(value[5:])
    value = os.path.expanduser(value)
    path = Path(os.path.normpath(value))
    for _ in range(5):
        if (path / "steamapps" / "workshop").is_dir():
            break
        if path.name.lower() in {"steamapps", "workshop", "content", "431960"} or path.name.isdigit():
            path = path.parent
            continue
        break
    return path


def manifest_path(lib: Path, appid: str) -> Path:
    return lib / "steamapps" / "workshop" / f"appworkshop_{appid}.acf"


def content_dir(lib: Path, appid: str, item: str) -> Path:
    return lib / "steamapps" / "workshop" / "content" / appid / item


def download_dir(lib: Path, appid: str, item: str) -> Path:
    return lib / "steamapps" / "workshop" / "downloads" / appid / item


def content_ready(content: Path) -> bool:
    proj = content / "project.json"
    if not proj.is_file():
        return False
    try:
        data = json.loads(proj.read_text(encoding="utf-8-sig", errors="replace"))
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    wtype = str(data.get("type") or "").strip().lower()
    wfile = data.get("file")
    if not wtype or not wfile:
        return True
    target = content / str(wfile).replace("\\", "/")
    if target.is_file():
        return True
    if wtype == "scene":
        if target.with_suffix(".pkg").is_file() or (content / "scene.pkg").is_file():
            return True
    return False


def is_installed(lib: Path, appid: str, item: str) -> bool:
    return content_ready(content_dir(lib, appid, item))


def dir_size(path: Path) -> int:
    total = 0
    try:
        for root, _dirs, files in os.walk(path):
            for name in files:
                try:
                    total += os.path.getsize(os.path.join(root, name))
                except OSError:
                    pass
    except OSError:
        pass
    return total


def mark_manifest_for_redownload(lib: Path, appid: str, item: str) -> None:
    acf = manifest_path(lib, appid)
    if not acf.is_file():
        return
    try:
        text = acf.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    pattern = re.compile(r'("' + re.escape(item) + r'"\s*\{)(.*?)(\n\s*\})', re.S)
    changed = False

    def replace_block(match: re.Match[str]) -> str:
        nonlocal changed
        body = match.group(2)
        new_body = re.sub(r'("size"\s*)"[^"]*"', r'\1"0"', body)
        new_body = re.sub(r'("timeupdated"\s*)"[^"]*"', r'\1"1"', body)
        if new_body != body:
            changed = True
        return match.group(1) + new_body + match.group(3)

    new_text = pattern.sub(replace_block, text)
    if changed:
        try:
            acf.write_text(new_text, encoding="utf-8")
        except OSError:
            pass


def steam_launcher() -> str | None:
    if STEAM_WRAPPER.is_file():
        return str(STEAM_WRAPPER)
    return shutil.which("steam")


def steam_pids() -> list[int]:
    try:
        res = subprocess.run(["pgrep", "-x", "steam"], capture_output=True, text=True, timeout=5)
        return [int(p) for p in res.stdout.split() if p.strip().isdigit()]
    except Exception:
        return []


def login_state() -> str | None:
    lg = STEAM_LOGS / "steamui_login.txt"
    try:
        lines = lg.read_text(encoding="utf-8", errors="replace").splitlines()[-500:]
        st = None
        for ln in lines:
            m = re.search(r"SetLoginState:\s*([A-Za-z]+)", ln)
            if m:
                st = m.group(1)
        if st is not None:
            return "on" if st == "Success" else st.lower()
    except OSError:
        pass
    clog = STEAM_LOGS / "connection_log.txt"
    if clog.is_file():
        try:
            with clog.open("rb") as fh:
                fh.seek(0, os.SEEK_END)
                sz = fh.tell()
                fh.seek(max(0, sz - 300_000))
                txt = fh.read().decode("utf-8", "replace")
            st = None
            for ln in txt.splitlines():
                if "Logged On" in ln:
                    st = "on"
                elif "Logged Off" in ln or "LogOff" in ln:
                    st = "off"
            return st
        except OSError:
            pass
    return None


def _get_steam_windows_kwin() -> set[str]:
    if not shutil.which("kdotool"):
        return set()
    try:
        res = subprocess.run(["kdotool", "search", "--name", "Steam"], capture_output=True, text=True, timeout=2)
        return {w.strip() for w in res.stdout.splitlines() if w.strip()}
    except Exception:
        return set()


def _suppress_steam_window_popup(before_wins: set[str]) -> None:
    env = {**os.environ, "STEAM_FRAME_FORCE_CLOSE": "1"}
    if shutil.which("kdotool"):
        for _ in range(8):
            time.sleep(0.25)
            try:
                cur = _get_steam_windows_kwin()
                for wid in cur:
                    if wid not in before_wins:
                        subprocess.run(["kdotool", "windowminimize", wid], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
            except Exception:
                pass


def send_steam_pipe_cmd(cmd_str: str) -> bool:
    for pipe_cand in [STEAM_PIPE, STEAM_ROOT / "steam.pipe"]:
        if pipe_cand.exists():
            try:
                fd = os.open(str(pipe_cand), os.O_WRONLY | os.O_NONBLOCK)
                try:
                    payload = (cmd_str.strip() + "\n").encode("utf-8")
                    os.write(fd, payload)
                    log(f"steam.pipe IPC enviado en silencio: {cmd_str}")
                    return True
                finally:
                    os.close(fd)
            except OSError:
                pass
    return False


def ensure_steam(item: str, timeout: int) -> tuple[bool, str]:
    started = False
    env = {**os.environ, "STEAM_FRAME_FORCE_CLOSE": "1", "SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS": "1"}
    if not steam_pids():
        log("Steam no está corriendo; iniciándolo en modo silencioso (-silent)…")
        write_status(item, "starting", "Iniciando Steam en segundo plano")
        launcher = steam_launcher()
        if not launcher:
            return False, "No se encontró el comando steam"
        try:
            subprocess.Popen(
                [launcher, "-silent", "-nochatui", "-nofriendsui"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                env=env,
                start_new_session=True,
            )
            started = True
        except OSError as exc:
            return False, f"No se pudo iniciar Steam: {exc}"
        deadline = time.time() + min(timeout, 60)
        while time.time() < deadline:
            if steam_pids():
                break
            time.sleep(1)
        else:
            return False, "Steam no terminó de arrancar"

    deadline = time.time() + min(timeout, 90 if started else 20)
    while time.time() < deadline:
        if login_state() == "on":
            return True, "Steam logueado"
        time.sleep(2)
    return False, "Steam está abierto pero sin sesión activa."


def _steam_download_seen(item: str, offset: int) -> bool:
    text = read_log_since(offset)
    return (f"Download item {item} requested" in text) or (f"requested item {item}" in text and "Workshop download job" in text)


def trigger_steam(item: str, appid: str) -> None:
    before_wins = _get_steam_windows_kwin()
    offset = log_size()
    launcher = steam_launcher()
    if not launcher:
        return
    env = {**os.environ, "STEAM_FRAME_FORCE_CLOSE": "1"}
    cmd = [launcher, "-silent", "+workshop_download_item", appid, item]
    log("disparando fallback silencioso: " + " ".join(cmd))
    try:
        subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            env=env,
        )
        _suppress_steam_window_popup(before_wins)
        deadline = time.time() + 6.0
        while time.time() < deadline:
            if _steam_download_seen(item, offset):
                log(f"workshop_log confirmó inicio de descarga para {item}")
                break
            time.sleep(0.4)
    except OSError as exc:
        log(f"steam error: {exc}")


def log_size() -> int:
    try:
        return WORKSHOP_LOG.stat().st_size
    except OSError:
        return 0


def read_log_since(offset: int) -> str:
    try:
        size = WORKSHOP_LOG.stat().st_size
        if offset > size:
            offset = 0
        with WORKSHOP_LOG.open("r", encoding="utf-8", errors="replace") as fh:
            if offset > 0:
                fh.seek(offset)
            return fh.read()
    except OSError:
        return ""


def verify_subscription(lib: Path, appid: str, item: str) -> bool:
    acf = manifest_path(lib, appid)
    try:
        text = acf.read_text(encoding="utf-8", errors="replace")
        return re.search(r'"' + re.escape(item) + r'"\s*\{', text) is not None
    except OSError:
        return False


def delete_all_for_item(lib: Path, appid: str, item: str) -> int:
    send_steam_pipe_cmd(f"workshop_unsubscribe_item {appid} {item}")
    targets = [
        content_dir(lib, appid, item),
        download_dir(lib, appid, item),
        Path.home() / ".local/share/wallpaperEngineKde/translated" / item,
        Path.home() / ".cache/wescene-renderer" / item,
        Path.home() / ".config/wekde/wallpaper" / f"{item}.json",
        Path.home() / ".config/wekde/wallpaper" / f"{item}_bindings.json",
        STATUS_DIR / f"{item}.json",
    ]
    for t in targets:
        try:
            if t.is_dir():
                shutil.rmtree(t, ignore_errors=True)
            elif t.is_file():
                t.unlink(missing_ok=True)
        except OSError:
            pass

    acf = manifest_path(lib, appid)
    if acf.is_file():
        try:
            txt = acf.read_text(encoding="utf-8", errors="replace")
            pat = re.compile(r'\s*"' + re.escape(item) + r'"\s*\{[^{}]*\}', re.S)
            new_txt = pat.sub("", txt)
            if new_txt != txt:
                acf.write_text(new_txt, encoding="utf-8")
        except OSError:
            pass

    log(f"Eliminado por completo y desuscrito: {item}")
    print(f"OK deleted {item}", flush=True)
    return 0


def check_audit(lib: Path, appid: str, clean_orphans: bool = False, remove_unsubscribed: bool = False) -> int:
    acf = manifest_path(lib, appid)
    subscribed: set[str] = set()
    if acf.is_file():
        txt = acf.read_text(encoding="utf-8", errors="replace")
        for im in re.finditer(r'"(\d{7,12})"\s*\{', txt):
            subscribed.add(im.group(1))

    cdir = lib / "steamapps/workshop/content" / appid
    downloaded_valid: set[str] = set()
    corrupted_dirs: list[str] = []
    if cdir.is_dir():
        for entry in sorted(cdir.iterdir()):
            if not entry.is_dir():
                continue
            name = entry.name
            if ".wek-old-" in name or ".wek-partial-" in name:
                corrupted_dirs.append(str(entry))
                continue
            if name.isdigit():
                if content_ready(entry):
                    downloaded_valid.add(name)
                else:
                    corrupted_dirs.append(str(entry))

    trans_root = Path.home() / ".local/share/wallpaperEngineKde/translated"
    orphan_translated: list[str] = []
    if trans_root.is_dir():
        for entry in sorted(trans_root.iterdir()):
            if entry.is_dir() and entry.name.isdigit() and entry.name not in downloaded_valid:
                orphan_translated.append(str(entry))

    missing_download = sorted(subscribed - downloaded_valid)
    unsubscribed_local = sorted(downloaded_valid - subscribed)

    if remove_unsubscribed:
        for uid in unsubscribed_local:
            delete_all_for_item(lib, appid, uid)
        unsubscribed_local = []

    if clean_orphans:
        for p_str in corrupted_dirs + orphan_translated:
            shutil.rmtree(p_str, ignore_errors=True)
        corrupted_dirs.clear()
        orphan_translated.clear()

    report = {
        "subscribed_count": len(subscribed),
        "downloaded_count": len(downloaded_valid),
        "missing_download": missing_download,
        "unsubscribed_local": unsubscribed_local,
        "orphans": corrupted_dirs + orphan_translated,
    }
    print("CHECK_JSON " + json.dumps(report, ensure_ascii=False), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="WEK Workshop downloader & auditor")
    parser.add_argument("--library", default="", help="Steam library path or file:// URL")
    parser.add_argument("--detect-library", action="store_true", help="Auto-detect Steam library path")
    parser.add_argument("--item", default="0", help="Workshop item id")
    parser.add_argument("--appid", default=APPID_DEFAULT, help="Workshop app id (431960)")
    parser.add_argument("--timeout", type=int, default=600, help="Seconds to wait for the item")
    parser.add_argument("--force", action="store_true", help="Re-download even if installed")
    parser.add_argument("--delete-all", action="store_true", help="Delete workshop + translated + config + unsubscribe")
    parser.add_argument("--check", action="store_true", help="Audit subscribed vs downloaded vs orphans")
    parser.add_argument("--clean-orphans", action="store_true", help="Remove orphan/corrupted dirs during --check")
    parser.add_argument("--remove-unsubscribed", action="store_true", help="Remove local items no longer in manifest")
    args = parser.parse_args()

    item = args.item.strip()
    appid = args.appid.strip()
    if getattr(args, 'detect_library', False):
        return detect_best_steam_library(appid)
    if not args.library:
        print('ERROR --library is required', flush=True)
        return 4
    lib = normalize_library(args.library)

    if args.check:
        return check_audit(
            lib,
            appid,
            clean_orphans=args.clean_orphans,
            remove_unsubscribed=args.remove_unsubscribed,
        )

    if not item.isdigit() or item == "0":
        print(f"ERROR ID de Workshop inválido: {item!r}", flush=True)
        return 4

    if args.delete_all:
        return delete_all_for_item(lib, appid, item)

    acf = manifest_path(lib, appid)
    if not (lib / "steamapps" / "workshop").is_dir() or not acf.is_file():
        msg = f"Librería o manifiesto de Steam inválido: {lib}"
        write_status(item, "error", msg, library=str(lib))
        print(f"ERROR {msg}", flush=True)
        return 4

    if is_installed(lib, appid, item) and not args.force:
        content = content_dir(lib, appid, item)
        write_status(item, "done", "Ya estaba instalado", library=str(lib), content=str(content))
        print(f"OK {content}", flush=True)
        return 0

    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        lock_fh = LOCK_FILE.open("a", encoding="utf-8")
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError):
        msg = "Ya hay una descarga de Workshop en curso"
        print(f"ERROR {msg}", flush=True)
        return 2

    try:
        write_status(item, "starting", "Verificando Steam", library=str(lib), pid=os.getpid())
        ok, message = ensure_steam(item, args.timeout)
        if not ok:
            write_status(item, "error", message, library=str(lib))
            print(f"ERROR {message}", flush=True)
            return 3

        content = content_dir(lib, appid, item)
        backup = None
        force_backup = False
        if content.exists():
            is_partial = not (content / "project.json").is_file()
            if args.force or is_partial:
                suffix = ".wek-old-" if args.force else ".wek-partial-"
                backup = content.with_name(content.name + suffix + str(int(time.time())))
                try:
                    os.replace(content, backup)
                    force_backup = args.force
                except OSError:
                    backup = None

        def restore_backup() -> None:
            if backup is None or not force_backup:
                return
            if content.exists():
                shutil.rmtree(content, ignore_errors=True)
            try:
                os.replace(backup, content)
            except OSError:
                pass

        mark_manifest_for_redownload(lib, appid, item)
        offset = log_size()
        trigger_steam(item, appid)
        last_trigger = time.time()
        triggers = 1
        started_at = time.time()
        last_report = 0.0
        seen_request = False

        while time.time() - started_at < args.timeout:
            content = content_dir(lib, appid, item)
            if content_ready(content):
                subscribed = verify_subscription(lib, appid, item)
                if backup is not None and force_backup:
                    shutil.rmtree(backup, ignore_errors=True)
                write_status(item, "done", "Instalado", library=str(lib), content=str(content), subscribed=subscribed)
                print(f"OK {content} subscribed={'yes' if subscribed else 'no'}", flush=True)
                return 0

            tail = read_log_since(offset)
            if item in tail:
                seen_request = True
            if "Wrong AppID" in tail or "result : No match" in tail:
                msg = "Steam rechazó el ítem (no pertenece a 431960 o no existe)."
                restore_backup()
                write_status(item, "error", msg, library=str(lib))
                print(f"ERROR {msg}", flush=True)
                return 1

            if time.time() - last_report >= 4:
                last_report = time.time()
                dl_dir = download_dir(lib, appid, item)
                downloaded = dir_size(dl_dir)
                state = "downloading" if downloaded else "queued"
                write_status(item, state, f"Descargando {item}", library=str(lib), downloaded_bytes=downloaded)
                print(f"STATUS {state} {downloaded}", flush=True)

            if not seen_request and triggers < 3 and time.time() - last_trigger > 18:
                trigger_steam(item, appid)
                triggers += 1
                last_trigger = time.time()

            time.sleep(1.5)

        restore_backup()
        write_status(item, "error", f"Tiempo agotado para {item}", library=str(lib))
        print(f"ERROR Tiempo de espera agotado para {item}", flush=True)
        return 1
    finally:
        try:
            fcntl.flock(lock_fh, fcntl.LOCK_UN)
            lock_fh.close()
        except OSError:
            pass


def detect_best_steam_library(appid: str = APPID_DEFAULT) -> int:
    """Scan libraryfolders.vdf and mounted volumes to locate the Workshop library."""
    candidates: list[Path] = []
    seen: set[str] = set()

    def add_cand(p: Path) -> None:
        try:
            rp = str(p.resolve())
        except OSError:
            rp = str(p)
        if rp not in seen:
            seen.add(rp)
            candidates.append(Path(rp))

    home = Path.home()
    roots = [
        home / ".local/share/Steam",
        home / ".steam/steam",
        home / ".steam/root",
        home / ".var/app/com.valvesoftware.Steam/.local/share/Steam",
    ]
    for r in roots:
        add_cand(r)
        vdf = r / "steamapps/libraryfolders.vdf"
        if vdf.is_file():
            try:
                vtxt = vdf.read_text(encoding="utf-8", errors="replace")
                for m in re.finditer(r'"path"\s+"([^"]+)"', vtxt):
                    add_cand(Path(m.group(1).replace("\\\\", "/")))
            except OSError:
                pass

    user_name = os.environ.get("USER") or home.name
    for mb in (Path("/run/media") / user_name, Path("/media") / user_name, Path("/mnt")):
        if not mb.is_dir():
            continue
        try:
            for vol in sorted(mb.iterdir()):
                if not vol.is_dir():
                    continue
                add_cand(vol)
                for sp in ("Steam", "SteamLibrary", "Program Files (x86)/Steam", "Program Files/Steam"):
                    add_cand(vol / sp)
        except OSError:
            pass

    best_lib: Path | None = None
    best_count = -1
    for cand in candidates:
        wdir = cand / "steamapps/workshop/content" / appid
        if wdir.is_dir():
            try:
                cnt = sum(1 for x in wdir.iterdir() if x.is_dir() and x.name.isdigit())
            except OSError:
                cnt = 0
            if cnt > best_count:
                best_count = cnt
                best_lib = cand

    if best_lib is not None and best_count >= 0:
        print(f"DETECTED_LIBRARY {best_lib}", flush=True)
        return 0
    print("ERROR No Steam library with Wallpaper Engine Workshop folder found", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
