#!/usr/bin/env python3
import argparse
import asyncio
import base64
import colorsys
import fcntl
import io
import json
import math
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

try:
    from websockets.asyncio.server import serve
except Exception:
    from websockets.server import serve

HOST = "127.0.0.1"
PORT = 38765
RATE = 48000
CHANNELS = 2
HOP = 1600
WINDOW = 2048
BANDS = 64
FMIN = 40.0
FMAX = 16000.0
DB_FLOOR = -60.0
DECAY = 0.72
IDLE_SECONDS = 75.0
MEDIA_INTERVAL = 1.0
EMPTY_THUMB = (
    "data:image/png;base64,"
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def runtime_dir():
    d = Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/wek-web-bridge-{os.getuid()}"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def run_cmd_sync(args, timeout=4.0):
    try:
        p = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
        return p.stdout.decode("utf-8", "replace").strip()
    except Exception:
        return ""


def default_monitor():
    sink = run_cmd_sync(["pactl", "get-default-sink"], timeout=2.0).splitlines()
    sink = sink[0].strip() if sink else ""
    sources = run_cmd_sync(["pactl", "list", "short", "sources"], timeout=2.0)
    monitors = []
    for line in sources.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2 and fields[1].endswith(".monitor"):
            monitors.append(fields[1])
    if sink and sink + ".monitor" in monitors:
        return sink + ".monitor"
    if sink:
        return sink + ".monitor"
    return monitors[0] if monitors else ""


def build_bands():
    freqs = np.fft.rfftfreq(WINDOW, 1.0 / RATE)
    edges = np.logspace(math.log10(FMIN), math.log10(FMAX), BANDS + 1)
    bins = []
    for i in range(BANDS):
        lo = int(np.searchsorted(freqs, edges[i], side="left"))
        hi = int(np.searchsorted(freqs, edges[i + 1], side="left"))
        if hi <= lo:
            hi = min(lo + 1, len(freqs))
        bins.append((lo, hi))
    return np.hanning(WINDOW).astype(np.float32), bins


HANN, BAND_BINS = build_bands()


def audio_frame(samples, state):
    out = []
    for ch in range(CHANNELS):
        spec = np.fft.rfft(samples[:, ch] * HANN)
        mag = np.abs(spec) / (WINDOW / 2.0)
        vals = np.zeros(BANDS, dtype=np.float32)
        for i, (lo, hi) in enumerate(BAND_BINS):
            rms = float(np.sqrt(np.mean(mag[lo:hi] ** 2) + 1e-12))
            db = 20.0 * math.log10(rms + 1e-9)
            vals[i] = min(1.0, max(0.0, (db - DB_FLOOR) / (-DB_FLOOR)))
        prev = state.get(ch)
        if prev is None:
            prev = vals
        else:
            vals = np.maximum(vals, prev * DECAY)
        state[ch] = vals
        out.extend(float(round(v, 4)) for v in vals)
    return out


def fetch_bytes(url):
    if not url:
        return None
    try:
        if url.startswith("data:"):
            header, _, payload = url.partition(",")
            if ";base64" in header:
                return base64.b64decode(payload)
            return urllib.parse.unquote_to_bytes(payload)
        if url.startswith("file://"):
            from urllib.parse import unquote
            return Path(unquote(url[7:])).read_bytes()
        if url.startswith("http://") or url.startswith("https://"):
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) WEKWebBridge/1.0",
                    "Accept": "image/avif,image/webp,image/png,image/jpeg,*/*",
                },
            )
            with urllib.request.urlopen(req, timeout=6.0) as resp:
                return resp.read(8 * 1024 * 1024)
    except Exception:
        return None
    return None


def hex_rgb(rgb):
    return "#%02x%02x%02x" % tuple(max(0, min(255, int(v))) for v in rgb)


def luminance(rgb):
    r, g, b = [v / 255.0 for v in rgb]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def extract_colors(img):
    small = img.convert("RGB").resize((64, 64), Image.Resampling.BILINEAR)
    q = small.quantize(colors=10, method=Image.Quantize.MEDIANCUT)
    palette = q.getpalette() or []
    entries = sorted(q.getcolors(64 * 64) or [], reverse=True)
    chosen = []
    for _, idx in entries:
        base = idx * 3
        if base + 2 >= len(palette):
            continue
        rgb = tuple(palette[base:base + 3])
        h, s, v = colorsys.rgb_to_hsv(*(c / 255.0 for c in rgb))
        if v < 0.10 or v > 0.94:
            continue
        if s < 0.08 and 0.20 < v < 0.85:
            continue
        if any(sum((a - b) ** 2 for a, b in zip(rgb, old)) < 42 ** 2 for old in chosen):
            continue
        chosen.append(rgb)
        if len(chosen) >= 5:
            break
    if not chosen:
        chosen = [(28, 28, 32), (78, 78, 88), (180, 180, 190)]
    while len(chosen) < 5:
        chosen.append(tuple(min(255, c + 32) for c in chosen[-1]))
    primary, secondary, tertiary = chosen[0], chosen[1], chosen[2]
    text = (255, 255, 255) if luminance(primary) < 0.52 else (0, 0, 0)
    high = (255, 255, 255) if luminance(primary) < 0.55 else (0, 0, 0)
    return {
        "primaryColor": hex_rgb(primary),
        "secondaryColor": hex_rgb(secondary),
        "tertiaryColor": hex_rgb(tertiary),
        "textColor": hex_rgb(text),
        "highContrastColor": hex_rgb(high),
    }


def make_thumb(url, cache):
    if not url:
        return None, None
    cached = cache.get(url)
    if cached is not None:
        return cached
    raw = fetch_bytes(url)
    if not raw:
        return None, None
    try:
        img = Image.open(io.BytesIO(raw))
        img.load()
        img = img.convert("RGB")
        img.thumbnail((320, 320), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=88, optimize=True)
        uri = "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode("ascii")
        colors = extract_colors(img)
        cache[url] = (uri, colors)
        if len(cache) > 10:
            cache.pop(next(iter(cache)))
        return uri, colors
    except Exception:
        return None, None


def player_kind(name):
    n = name.lower()
    return any(x in n for x in ("firefox", "chrom", "brave", "vivaldi", "edge", "opera", "zen"))


async def run_cmd(args, timeout=3.0):
    try:
        p = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
        )
        try:
            out, _ = await asyncio.wait_for(p.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            p.kill()
            await p.wait()
            return ""
        return out.decode("utf-8", "replace").strip()
    except Exception:
        return ""


async def media_snapshot(cache):
    players = []
    raw = await run_cmd(["playerctl", "-l"])
    for name in dict.fromkeys(x.strip() for x in raw.splitlines()):
        if not name:
            continue
        status = await run_cmd(["playerctl", "-p", name, "status"])
        meta = await run_cmd([
            "playerctl", "-p", name, "metadata", "--format",
            "{{title}}\x1f{{artist}}\x1f{{album}}\x1f{{mpris:length}}\x1f{{mpris:artUrl}}\x1f{{position}}",
        ])
        fields = meta.split("\x1f")
        while len(fields) < 6:
            fields.append("")
        players.append({
            "player": name,
            "status": status,
            "title": fields[0].strip(),
            "artist": fields[1].strip(),
            "album": fields[2].strip(),
            "length": fields[3].strip(),
            "art": fields[4].strip(),
            "position": fields[5].strip(),
        })
    if not players:
        return {
            "enabled": True,
            "title": "",
            "artist": "",
            "albumTitle": "",
            "albumArtist": "",
            "genres": "",
            "contentType": "music",
            "position": 0.0,
            "duration": 0.0,
            "state": 0,
            "thumbKey": "",
            "thumb": None,
        }
    rank = {"Playing": 3, "Paused": 2, "Stopped": 1}
    players.sort(key=lambda p: (rank.get(p["status"], 0), 0 if player_kind(p["player"]) else 1), reverse=True)
    p = players[0]
    state = {"Playing": 1, "Paused": 2, "Stopped": 0}.get(p["status"], 0)
    title = p["title"] if state != 0 else ""
    artist = p["artist"] if state != 0 else ""
    album = p["album"] if state != 0 else ""
    art = p["art"] if state != 0 else ""
    try:
        length = float(p["length"])
        length = length / 1e6 if length > 100000 else length
    except Exception:
        length = 0.0
    try:
        pos = float(p["position"])
        pos = pos / 1e6 if pos > 100000 else pos
    except Exception:
        pos = 0.0
    thumb = None
    colors = None
    if art:
        thumb, colors = await asyncio.to_thread(make_thumb, art, cache)
    if colors is None:
        colors = {
            "primaryColor": "#1e1e24",
            "secondaryColor": "#50505c",
            "tertiaryColor": "#b4b4be",
            "textColor": "#ffffff",
            "highContrastColor": "#ffffff",
        }
    return {
        "enabled": True,
        "title": title,
        "artist": artist,
        "albumTitle": album,
        "albumArtist": artist,
        "genres": "",
        "contentType": "music",
        "position": max(0.0, pos),
        "duration": max(0.0, length),
        "state": state,
        "thumbKey": art,
        "thumb": thumb,
        **colors,
    }


class Client:
    def __init__(self, ws):
        self.ws = ws
        self.queue = asyncio.Queue(maxsize=240)
        self.task = asyncio.create_task(self._writer())

    async def _writer(self):
        try:
            while True:
                msg = await self.queue.get()
                await self.ws.send(msg)
        except Exception:
            pass

    def push(self, msg, audio=False):
        if self.queue.full():
            if audio:
                return
            try:
                self.queue.get_nowait()
            except Exception:
                pass
        try:
            self.queue.put_nowait(msg)
        except Exception:
            pass

    async def close(self):
        self.task.cancel()
        try:
            await self.ws.close()
        except Exception:
            pass


class Bridge:
    def __init__(self):
        self.clients = set()
        self.stop_event = asyncio.Event()
        self.audio_task = None
        self.media_task = None
        self.last_media = None
        self.last_thumb = None
        self.art_cache = {}

    def ensure_workers(self):
        if self.audio_task is None or self.audio_task.done():
            self.audio_task = asyncio.create_task(self.audio_loop())
        if self.media_task is None or self.media_task.done():
            self.media_task = asyncio.create_task(self.media_loop())

    def broadcast(self, msg, audio=False):
        for client in list(self.clients):
            client.push(msg, audio=audio)

    async def audio_loop(self):
        state = {}
        while not self.stop_event.is_set():
            monitor = await asyncio.to_thread(default_monitor)
            if not monitor:
                await asyncio.sleep(2.0)
                continue
            proc = None
            try:
                proc = await asyncio.create_subprocess_exec(
                    "parec",
                    "--format=s16le",
                    "--rate=%d" % RATE,
                    "--channels=%d" % CHANNELS,
                    "--latency-msec=20",
                    "--device=" + monitor,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                buf = np.zeros((WINDOW, CHANNELS), dtype=np.float32)
                frames = 0
                while not self.stop_event.is_set():
                    raw = await proc.stdout.readexactly(HOP * CHANNELS * 2)
                    block = np.frombuffer(raw, dtype="<i2").reshape(-1, CHANNELS).astype(np.float32)
                    block /= 32768.0
                    buf = np.concatenate((buf[HOP:], block), axis=0)
                    frames += 1
                    if not self.clients:
                        continue
                    vals = audio_frame(buf, state)
                    self.broadcast("A" + json.dumps(vals, separators=(",", ":")), audio=True)
                    if frames % 150 == 0:
                        now_monitor = await asyncio.to_thread(default_monitor)
                        if now_monitor and now_monitor != monitor:
                            break
            except (asyncio.IncompleteReadError, BrokenPipeError, ConnectionResetError):
                pass
            except asyncio.CancelledError:
                raise
            except Exception:
                await asyncio.sleep(0.5)
            finally:
                if proc is not None and proc.returncode is None:
                    try:
                        proc.kill()
                        await proc.wait()
                    except Exception:
                        pass
            await asyncio.sleep(0.5)

    async def media_loop(self):
        last_thumb_key = None
        while not self.stop_event.is_set():
            try:
                snap = await media_snapshot(self.art_cache)
                thumb_key = snap.get("thumbKey", "")
                if thumb_key != last_thumb_key:
                    if not snap.get("thumb"):
                        snap["thumb"] = EMPTY_THUMB
                    self.last_thumb = None if snap["thumb"] == EMPTY_THUMB else snap["thumb"]
                    last_thumb_key = thumb_key
                else:
                    snap["thumb"] = None
                self.last_media = dict(snap)
                msg = "M" + json.dumps(snap, separators=(",", ":"))
                self.broadcast(msg)
            except asyncio.CancelledError:
                raise
            except Exception:
                pass
            await asyncio.sleep(MEDIA_INTERVAL)

    async def handler(self, ws):
        client = Client(ws)
        if self.last_media is not None:
            snap = dict(self.last_media)
            snap["thumb"] = self.last_thumb or snap.get("thumb")
            client.push("M" + json.dumps(snap, separators=(",", ":")))
        self.clients.add(client)
        self.ensure_workers()
        try:
            async for _ in ws:
                pass
        except Exception:
            pass
        finally:
            self.clients.discard(client)
            await client.close()

    async def idle_watch(self):
        idle_since = time.monotonic()
        while not self.stop_event.is_set():
            await asyncio.sleep(5.0)
            if self.clients:
                idle_since = time.monotonic()
            elif time.monotonic() - idle_since > IDLE_SECONDS:
                self.stop_event.set()

    async def run(self):
        idle = asyncio.create_task(self.idle_watch())
        async with serve(self.handler, HOST, PORT, max_size=4 * 1024 * 1024, ping_interval=20, ping_timeout=20):
            print("WEKBRIDGE_READY %s:%d" % (HOST, PORT), flush=True)
            await self.stop_event.wait()
        idle.cancel()
        for task in (self.audio_task, self.media_task):
            if task is not None:
                task.cancel()
        await asyncio.gather(idle, *(t for t in (self.audio_task, self.media_task) if t is not None), return_exceptions=True)


def port_open():
    try:
        with socket.create_connection((HOST, PORT), timeout=0.25):
            return True
    except Exception:
        return False


def ensure_daemon():
    base = runtime_dir()
    lock_path = base / "wek-web-bridge-start.lock"
    with open(lock_path, "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if port_open():
            print("WEKBRIDGE_RUNNING", flush=True)
            return 0
        log = open(base / "wek-web-bridge.log", "ab", buffering=0)
        subprocess.Popen(
            [sys.executable, "-u", os.path.abspath(__file__), "--serve"],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            close_fds=True,
            start_new_session=True,
        )
        for _ in range(20):
            time.sleep(0.1)
            if port_open():
                print("WEKBRIDGE_STARTED", flush=True)
                return 0
        print("WEKBRIDGE_START_FAILED", flush=True)
        return 1


def selftest():
    t = np.arange(WINDOW) / RATE
    samples = np.zeros((WINDOW, CHANNELS), dtype=np.float32)
    samples[:, 0] = 0.12 * np.sin(2 * math.pi * 440 * t)
    samples[:, 1] = 0.08 * np.sin(2 * math.pi * 1800 * t)
    vals = audio_frame(samples, {})
    print(json.dumps({"len": len(vals), "maxL": max(vals[:64]), "maxR": max(vals[64:])}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--ensure", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    if args.ensure:
        return ensure_daemon()
    bridge = Bridge()

    def stop(_signum, _frame):
        bridge.stop_event.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    asyncio.run(bridge.run())
    return 0


if __name__ == "__main__":
    sys.exit(main())
