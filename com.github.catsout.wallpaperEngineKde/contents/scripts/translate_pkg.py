#!/usr/bin/env python3
"""WE-for-KDE scene.pkg translator (v17 — Paridad Completa con Wallpaper Engine).

Extrae contenedores Wallpaper Engine scene.pkg (PKGV0023/24/18) en un directorio
traducido (~/.local/share/wallpaperEngineKde/translated/<id>/) y aplica:

1. Transpilador y Polyfill Universal JS (__wekTick):
   - Despacha automáticamente mediaPlaybackChanged, mediaPropertiesChanged,
     mediaTimelineChanged y mediaThumbnailChanged desde update() leyendo
     engine.userProperties (u_playstate, u_title, u_artist, u_album,
     u_albumartist, u_position, u_duration).
   - Repara llaves desbalanceadas de traductores antiguos y limpia restos de debug.
   - Añade fallback automático u_albumartist || u_artist.
   - Enlaza cursorDown -> cursorClick con debounce de 250ms para que todos los
     botones interactivos respondan aunque SceneViewer no emita cursorClick.
   - Desactiva handlers de arrastre en capas "Drag and Drop" que secuestran clics.
   - Valida cada script JS modificado con `node --check` antes de guardarlo.

2. Escáner Profundo de Audio Reactivo y Bindings:
   - Inspecciona scene.json, scripts .js, shaders (.frag/.vert), materiales y
     partículas dentro del .pkg y en el directorio del workshop.
   - Detecta g_AudioSpectrum16/32/64Left/Right, registerAudioBuffers,
     Simple_Audio_Bars, AUDIOPROCESSING y audioprocessingmode, escribiendo la
     resolución real (16/32/64) y la lista de shaders en audio_visualizer.json.

3. Gestión Segura de Portadas ($mediaThumbnail -> media_cover.tex) y Materiales:
   - Redirige $mediaThumbnail a materials/media_cover.tex (TEXV0005 con cadena
     completa de mips) usando escritura atómica, sin sobrescribir portadas reales
     ya descargadas.
   - Elimina combos vacíos ("" o None) en materials/*.json que provocan el error
     nativo `combo '%s' can't be empty`.

4. Extracción Real de Texturas de Trails (.tex -> .png) y Parallax Inteligente:
   - Extrae el PNG embebido dentro de contenedores TEXV/TEXB para NativeTrail.qml.
   - Inyecta parallaxDepth solo en capas visuales sin scripts ni parallax nativo.

5. Protección Anti-Retraducción Destructiva:
   - Respeta directorios sellados (translator_version.json >= 99) salvo que se
     invoque con `--force`, e incluye modo `--upgrade-existing` para actualizar
     directorios ya traducidos sin pisar parches manuales desde el .pkg.
"""

import base64
import html
import io
import json
import logging
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

TRANSLATOR_VERSION = 17

# Cross-platform TRANS_ROOT support
if os.name == "nt":
    TRANS_ROOT = os.path.join(os.environ.get("APPDATA", ""), "wallpaperEngineKde", "translated")
else:
    TRANS_ROOT = os.path.expanduser("~/.local/share/wallpaperEngineKde/translated")

VISUAL_KEYS = ("image", "particles", "particle", "sound", "instance", "color", "model")
DEPTH_HINTS = ("g_ParallaxPosition", "depthparallax")

# User properties that gate a wallpaper's own cursor trail.
TRAIL_USER_PROPS = {"mousecursor", "interactive_particles", "cursortrail"}
TRAIL_NAME_RE = re.compile(r"cursor|mouse|trail", re.I)
ATTRACT_OPS = {"controlpointattract", "controlpointforce"}

try:
    from PIL import Image, ImageDraw
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# Tiny 1x1 transparent PNG encoded as base64 (fallback when PIL missing)
_TRANSPARENT_PNG_B64 = (
    b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMA"
    b"ASsJTYQAAAAASUVORK5CYII="
)

MEDIA_THUMB_TEX = "media_cover"
MEDIA_THUMB_FILE = MEDIA_THUMB_TEX + ".tex"

_USERVAR_PAT = re.compile(r"\bu_[a-z0-9_]+\b", re.I)
_AUDIO_PAT = re.compile(
    r"wallpaperRegisterAudioListener|registerAudioListener|getSpectrum|sigAudio"
    r"|registerAnalyser|wallpaperRegisterAnalyser|getAudio|applyAudio"
    r"|registerAudioBuffers|\bg_AudioSpectrum(?:16|32|64)?(?:Left|Right)?\b"
    r"|Simple_Audio_Bars|audio_frequency|audio_response|audio_bars"
    r"|audio_oscilloscope|audioSpectrum|AudioSpectrum"
    r'|"AUDIOPROCESSING"|"audioprocessingmode"',
    re.I,
)
_SPECTRUM_RES_PAT = re.compile(r"g_AudioSpectrum(16|32|64)", re.I)
_JS_REF_PAT = re.compile(r'["\']([^"\']+?\.js)["\']', re.I)

_SHORTCUT_RULES = [
    ("bnext", ("next", "skip", "forward")),
    ("bprev", ("prev", "back", "rewind")),
    ("bplaypause", ("play", "pause", "start", "toggle")),
]

WEK_POLYFILL_MARKER = "// [WEK_UNIVERSAL_SHIM_V17]"

WEK_MEDIA_SHIM_HEADER = """// [WEK_UNIVERSAL_SHIM_V17]
if (typeof MediaPlaybackEvent === 'undefined') {
    globalThis.MediaPlaybackEvent = { PLAYBACK_STOPPED: 0, PLAYBACK_PAUSED: 1, PLAYBACK_PLAYING: 2 };
}
var __wekState = { st: -1, title: null, artist: null, pos: -1, dur: -1, lastClickTs: 0 };
function __wekTick() {
    try {
        if (typeof engine === 'undefined' || !engine.userProperties) return;
        var up = engine.userProperties;
        var st = (up.u_playstate !== undefined) ? Number(up.u_playstate) : 0;
        var title = String(up.u_title || '');
        var artist = String(up.u_artist || '');
        var album = String(up.u_album || '');
        var albumArtist = String(up.u_albumartist || artist || '');
        var pos = (up.u_position !== undefined) ? Number(up.u_position) : 0;
        var dur = (up.u_duration !== undefined) ? Number(up.u_duration) : 0;
        if (st === 0 && title.length > 0) st = 2;

        if (st !== __wekState.st) {
            __wekState.st = st;
            if (typeof mediaPlaybackChanged === 'function') {
                mediaPlaybackChanged({ state: st, duration: dur, position: pos });
            }
        }
        if (title !== __wekState.title || artist !== __wekState.artist) {
            __wekState.title = title;
            __wekState.artist = artist;
            var hasT = title.length > 0;
            if (typeof mediaPropertiesChanged === 'function') {
                mediaPropertiesChanged({
                    title: title, artist: artist, album: album,
                    albumTitle: album, albumArtist: albumArtist,
                    genres: '', duration: dur
                });
            }
            if (typeof mediaThumbnailChanged === 'function') {
                mediaThumbnailChanged({
                    hasThumbnail: hasT,
                    primaryColor: { x: 1, y: 1, z: 1 },
                    secondaryColor: { x: 0.8, y: 0.8, z: 0.8 },
                    tertiaryColor: { x: 0.5, y: 0.5, z: 0.5 },
                    textColor: { x: 1, y: 1, z: 1 },
                    highContrastColor: { x: 0, y: 0, z: 0 }
                });
            }
        }
        if ((dur > 0 && dur !== __wekState.dur) || (pos >= 0 && Math.abs(pos - __wekState.pos) >= 0.5)) {
            __wekState.dur = dur;
            __wekState.pos = pos;
            if (typeof mediaTimelineChanged === 'function') {
                mediaTimelineChanged({ position: pos, duration: dur });
            }
        }
    } catch (e) {}
}
"""


def atomic_write_bytes(dest_path, data_bytes):
    """Write bytes atomically using a temporary file in the same directory."""
    dest_dir = os.path.dirname(os.path.abspath(dest_path))
    os.makedirs(dest_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".wek_tmp_", dir=dest_dir)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data_bytes)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, dest_path)
    except Exception:
        if os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        raise


def atomic_write_text(dest_path, text):
    """Write UTF-8 text atomically."""
    atomic_write_bytes(dest_path, text.encode("utf-8"))


def atomic_write_json(dest_path, obj, indent=2):
    """Write JSON atomically."""
    text = json.dumps(obj, indent=indent, ensure_ascii=False)
    atomic_write_text(dest_path, text)


def u32(data, pos):
    return struct.unpack_from("<I", data, pos)[0]


def parse_entries(data):
    """Parse the PKG directory, return (entries, dir_end)."""
    count = u32(data, 0x0C)
    entries = []
    pos = 0x10
    for _ in range(count):
        ln = u32(data, pos)
        name = data[pos + 4 : pos + 4 + ln].decode("utf-8", "replace")
        off = u32(data, pos + 4 + ln)
        size = u32(data, pos + 4 + ln + 4)
        entries.append({"name": name, "off": off, "size": size})
        pos += 4 + ln + 8
    return entries, pos


def walk_nodes(node, max_depth=64):
    """Iterate scene object nodes (children and nested objects) with a depth guard."""
    stack = [(node, 0)]
    visited = set()
    while stack:
        current, depth = stack.pop()
        if depth > max_depth or id(current) in visited:
            continue
        visited.add(id(current))
        if isinstance(current, dict):
            yield current
            for key in ("children", "objects"):
                children = current.get(key)
                if isinstance(children, list):
                    for child in reversed(children):
                        stack.append((child, depth + 1))
        elif isinstance(current, list):
            for item in reversed(current):
                stack.append((item, depth + 1))


def parse_depth(value):
    """Normalize a WE parallaxDepth value ('0.00000 0.00000', [a, b] or number)."""
    if isinstance(value, (list, tuple)):
        if value:
            try:
                return float(value[0])
            except (TypeError, ValueError):
                return None
        return None
    if isinstance(value, str):
        parts = value.split()
        if parts:
            try:
                return float(parts[0])
            except ValueError:
                return None
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def has_real_parallax(scene):
    """True when the scene ships functional parallax."""
    general = scene.get("general") or {}
    if general.get("cameraparallax") is True:
        return True
    for node in walk_nodes(scene):
        depth = parse_depth(node.get("parallaxDepth"))
        if depth not in (None, 0.0):
            return True
    return False


def visual_objects(scene):
    """Yield the parallax-capable layer objects of a scene JSON."""
    root = scene.get("root") or scene.get("objects") or scene
    for node in walk_nodes(root):
        if not isinstance(node, dict):
            continue
        if any(k in node for k in VISUAL_KEYS):
            yield node


def depth_from_position(node):
    pos = node.get("position") or node.get("origin") or [0.0, 0.0, 0.0]
    if isinstance(pos, str):
        pos = pos.split()
    try:
        z = float(pos[2]) if len(pos) > 2 else 0.0
    except (TypeError, ValueError):
        z = 0.0
    depth = max(0.03, min(abs(z) * 0.0006, 0.12))
    if z < 0:
        depth = -depth
    return depth


def check_js_syntax(js_code):
    """Validate JS syntax with `node --check` when Node.js is available on PATH."""
    if shutil.which("node") is None:
        return True, ""
    with tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False, encoding="utf-8") as tf:
        tf.write(js_code)
        tpath = tf.name
    try:
        res = subprocess.run(
            ["node", "--check", tpath],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return res.returncode == 0, res.stderr.strip()
    except Exception as e:
        return True, str(e)
    finally:
        if os.path.exists(tpath):
            try:
                os.unlink(tpath)
            except OSError:
                pass


def transpile_we_script(script_text, obj_name="", obj_id=None, prop_name="", sid=""):
    """Repair legacy syntax bugs and inject WE media/click compatibility polyfills."""
    if not isinstance(script_text, str) or not script_text.strip():
        return script_text

    # Remove debug leftovers if present
    if "[COVERDBG]" in script_text:
        return """'use strict';
export let __workshopId = '3629186919';
export function update(value) {
    var es = (typeof engine !== 'undefined' && engine.userProperties) ? engine.userProperties : {};
    var st = Number(es.u_playstate) || 0;
    var vis = (st === 1 || st === 2) || (!!es.u_title);
    thisLayer.visible = vis;
    return (value !== undefined) ? value : 1.0;
}
"""

    # High-precision fixes for Media Info Collection buttons (Media Info Collection asset pack)
    if obj_name == "Buttons" and prop_name == "visible" and "PlayerPlayBold" in script_text:
        return """'use strict';
export let __workshopId = '3629186919';
export function update(value) {
    var es = (typeof engine !== 'undefined' && engine.userProperties) ? engine.userProperties : {};
    var st = Number(es.u_playstate) || 0;
    var isPlaying = (st === 2);
    try {
        thisScene.getLayer('PlayerPlayBold41').visible = !isPlaying;
        thisScene.getLayer('PlayerPauseBold41').visible = isPlaying;
    } catch (e) {}
    return true;
}
"""

    if obj_name in ("PlayerPlayBold41", "PlayerPauseBold41") and prop_name == "visible":
        return """'use strict';
export let __workshopId = '3629186919';
var _lastTs = 0;
function _fire(event) {
    if (!thisLayer.visible) return;
    var now = Date.now();
    if (now - _lastTs < 250) return;
    if (typeof input !== 'undefined' && input.cursorWorldPosition) {
        var cx = input.cursorWorldPosition.x;
        if (cx < 791.0 || cx > 821.0) return;
    }
    _lastTs = now;
    engine.openUserShortcut("newproperty12");
}
export function cursorDown(event) { _fire(event); }
export function cursorClick(event) { _fire(event); }
"""

    if obj_name == "Previous song" and prop_name == "visible" and "newproperty13" in script_text:
        return """'use strict';
export let __workshopId = '3629186919';
var _lastTs = 0;
function _fire(event) {
    var now = Date.now();
    if (now - _lastTs < 250) return;
    if (typeof input !== 'undefined' && input.cursorWorldPosition && input.cursorWorldPosition.x > 791.0) return;
    _lastTs = now;
    engine.openUserShortcut("newproperty13");
}
export function cursorDown(event) { _fire(event); }
export function cursorClick(event) { _fire(event); }
"""

    if obj_name == "Next song" and prop_name == "visible" and "newproperty14" in script_text:
        return """'use strict';
export let __workshopId = '3629186919';
var _lastTs = 0;
function _fire(event) {
    var now = Date.now();
    if (now - _lastTs < 250) return;
    if (typeof input !== 'undefined' && input.cursorWorldPosition && input.cursorWorldPosition.x < 821.0) return;
    _lastTs = now;
    engine.openUserShortcut("newproperty14");
}
export function cursorDown(event) { _fire(event); }
export function cursorClick(event) { _fire(event); }
"""

    # 1. Repair extra '{' injected by older translator in mediaPropertiesChanged
    patched = re.sub(
        r'(export\s+function\s+mediaPropertiesChanged\s*\(event\)\s*\{\s*if\s*\(typeof\s+event===\"string\".*?else\s+if\s*\(!event\)\s*\{\s*event=\{\};\s*\})\s*\{',
        r"\1",
        script_text,
    )

    # 2. Disable Drag and Drop layer mouse capture that blocks button clicks
    if "drag and drop" in (obj_name or "").lower():
        patched = re.sub(
            r"\bexport\s+function\s+(cursorDown|cursorUp|cursorMove)\b",
            r"function _off_\1",
            patched,
        )
        return patched

    if WEK_POLYFILL_MARKER in patched:
        return patched

    # 3. Artist fallback: u_albumartist -> (u_albumartist || u_artist)
    patched = patched.replace(
        "engine.userProperties.u_albumartist",
        "(engine.userProperties.u_albumartist || engine.userProperties.u_artist)",
    )

    needs_media = any(
        fn in patched
        for fn in (
            "mediaPlaybackChanged",
            "mediaPropertiesChanged",
            "mediaTimelineChanged",
            "mediaThumbnailChanged",
        )
    )
    has_click = re.search(r"\bexport\s+function\s+cursorClick\s*\(", patched) is not None
    has_down = re.search(r"\bexport\s+function\s+cursorDown\s*\(", patched) is not None

    if needs_media:
        if re.search(r"\bexport\s+function\s+update\s*\(", patched):
            patched = re.sub(
                r"(\bexport\s+function\s+update\s*\([^)]*\)\s*\{)",
                r"\1\n\t__wekTick();",
                patched,
                count=1,
            )
        else:
            patched += "\nexport function update(value) { __wekTick(); return value; }\n"

        if "'use strict';" in patched:
            patched = patched.replace("'use strict';", "'use strict';\n" + WEK_MEDIA_SHIM_HEADER, 1)
        else:
            patched = WEK_MEDIA_SHIM_HEADER + "\n" + patched

    if has_click and not has_down:
        patched += """
export function cursorDown(event) {
    var now = Date.now();
    if (typeof __wekState !== 'undefined') {
        if (now - __wekState.lastClickTs < 250) return;
        __wekState.lastClickTs = now;
    }
    if (typeof cursorClick === 'function') cursorClick(event);
}
"""

    if prop_name == "text" and "__wekTextBridge" not in patched and re.search(r"\bexport\s+function\s+update\s*\(", patched):
        patched = re.sub(
            r"\bexport\s+function\s+update\s*\(",
            "function __wekOrigTextUpdate(",
            patched,
            count=1,
        )
        patched += """
// __wekTextBridge
var __wekLastSyncText = null;
export function update(value) {
    if (typeof __wekTick === 'function') __wekTick();
    var __r = __wekOrigTextUpdate(value);
    if (__r !== undefined && __r !== null) {
        var __s = String(__r);
        if (__s !== __wekLastSyncText) {
            __wekLastSyncText = __s;
            try { thisLayer.text = __s; } catch (e) {}
        }
    }
    return __r;
}
"""

    ok, err = check_js_syntax(patched)
    if not ok:
        logger.warning(f"  JS syntax check failed on id={obj_id} ({obj_name}.{prop_name}): {err}")
        return script_text
    return patched


def walk_and_transpile_scene_scripts(node, sid=""):
    """Recursively transpile all inline property/effect scripts in scene_doc."""
    changed = 0
    if isinstance(node, dict):
        obj_name = str(node.get("name") or "")
        obj_id = node.get("id")
        # Hide $mediaPreviousThumbnail transition effect that obscures Current cover
        if obj_name == "Previous" and isinstance(node.get("passes"), list):
            for pas in node["passes"]:
                ut = pas.get("usertextures") if isinstance(pas, dict) else None
                if isinstance(ut, list) and any(
                    isinstance(t, dict) and "mediapreviousthumbnail" in str(t.get("name", "")).lower()
                    for t in ut
                ):
                    node["visible"] = False
                    changed += 1
        for k, v in list(node.items()):
            if isinstance(v, dict) and isinstance(v.get("script"), str):
                new_s = transpile_we_script(
                    v["script"], obj_name=obj_name, obj_id=obj_id, prop_name=k, sid=sid
                )
                if new_s != v["script"]:
                    v["script"] = new_s
                    changed += 1
            elif isinstance(v, (dict, list)):
                changed += walk_and_transpile_scene_scripts(v, sid=sid)
    elif isinstance(node, list):
        for item in node:
            changed += walk_and_transpile_scene_scripts(item, sid=sid)
    return changed


def inject_parallax_on_doc(scene_doc, raw_scene_text="", skip_ids=None):
    """Inject parallaxDepth into eligible visual objects of scene_doc in-place."""
    if any(h in raw_scene_text for h in DEPTH_HINTS):
        return 0
    if not isinstance(scene_doc, dict) or has_real_parallax(scene_doc):
        return 0
    changed = 0
    for node in visual_objects(scene_doc):
        if skip_ids and node.get("id") in skip_ids:
            continue
        name = str(node.get("name") or "")
        if "parallax" in name.lower():
            continue
        if "script" in node or "scriptproperties" in node or "mouseTarget" in node:
            continue
        # Skip if any property of this node has an inline script
        if any(isinstance(v, dict) and "script" in v for v in node.values()):
            continue
        depth = depth_from_position(node)
        node["parallaxDepth"] = f"{depth:.5f} {depth:.5f}"
        changed += 1
    return changed


def load_json_entry(data, entries, dir_end, name):
    """Load a JSON file stored inside the pkg by (case-insensitive) name."""
    want = name.replace("\\", "/").lower()
    for e in entries:
        if e["name"].replace("\\", "/").lower() != want:
            continue
        blob = data[dir_end + e["off"] : dir_end + e["off"] + e["size"]]
        try:
            return json.loads(blob.decode("utf-8", "replace"))
        except Exception:
            return None
    return None


def load_entry_raw(data, entries, dir_end, name):
    """Return raw text of an entry (case-insensitive match), or None."""
    want = name.replace("\\", "/").lower()
    for e in entries:
        if e["name"].replace("\\", "/").lower() != want:
            continue
        blob = data[dir_end + e["off"] : dir_end + e["off"] + e["size"]]
        try:
            return blob.decode("utf-8", "replace")
        except Exception:
            try:
                return blob.decode("latin-1", "replace")
            except Exception:
                return None
    return None


def extract_bindings_and_audio(scene_text, data, entries, dir_end, pkg_dir=None):
    """
    Deep scan of scene.json, scripts (.js), shaders (.frag/.vert), materials,
    and particles inside the pkg (and optional pkg_dir) for u_* vars and audio hooks.
    Returns (sorted_bindings, audio_hooks_bool, suggested_resolution, audio_shaders_list).
    """
    bindings = set()
    audio_hooks = False
    detected_res = 32
    audio_shaders = []

    def scan_text_blob(txt, entry_name=""):
        nonlocal audio_hooks, detected_res
        if not txt:
            return
        for m in _USERVAR_PAT.finditer(txt):
            bindings.add(m.group(0))
        if _AUDIO_PAT.search(txt):
            audio_hooks = True
            if entry_name.lower().endswith((".frag", ".vert")):
                sh_base = re.sub(r"^shaders/|(\.frag|\.vert)$", "", entry_name.replace("\\", "/"))
                if sh_base not in audio_shaders:
                    audio_shaders.append(sh_base)
        for rm in _SPECTRUM_RES_PAT.finditer(txt):
            audio_hooks = True
            rval = int(rm.group(1))
            if rval > detected_res:
                detected_res = rval

    scan_text_blob(scene_text, "scene.json")

    # Scan inline escaped scripts inside scene_text
    for m in re.finditer(r'"script"\s*:\s*"([^"]{10,15000})"', scene_text, re.I | re.S):
        s = html.unescape(m.group(1))
        scan_text_blob(s, "inline_script.js")

    # Scan all text-like entries inside the PKG
    for e in entries:
        ename = e["name"].replace("\\", "/")
        elower = ename.lower()
        if elower.endswith((".frag", ".vert", ".js", ".json")) and e["size"] < 3_000_000:
            raw = load_entry_raw(data, entries, dir_end, ename)
            if raw:
                scan_text_blob(raw, ename)

    # Also check project.json in pkg_dir if present
    if pkg_dir and os.path.isdir(pkg_dir):
        pj_file = os.path.join(pkg_dir, "project.json")
        if os.path.isfile(pj_file):
            try:
                with open(pj_file, "r", encoding="utf-8", errors="replace") as fh:
                    ptxt = fh.read()
                scan_text_blob(ptxt, "project.json")
                if re.search(r'"supportsaudioprocessing"\s*:\s*true', ptxt, re.I):
                    audio_hooks = True
            except Exception:
                pass

    return sorted(bindings), bool(audio_hooks), detected_res, audio_shaders


def write_bindings_file(out_dir, sid, bindings, audio_hooks, suggested_res=32, shaders=None):
    """Write bindings.json, <sid>_bindings.json, audio_manifest.json, and audio_visualizer.json."""
    shaders = shaders or []
    try:
        os.makedirs(out_dir, exist_ok=True)
        atomic_write_json(os.path.join(out_dir, "bindings.json"), bindings, indent=2)
    except Exception as e:
        logger.debug(f"failed to write {out_dir}/bindings.json: {e}")

    try:
        cfgdir = os.path.expanduser("~/.config/wekde/wallpaper")
        os.makedirs(cfgdir, exist_ok=True)
        cfgpath = os.path.join(cfgdir, f"{sid}_bindings.json")
        atomic_write_json(cfgpath, bindings, indent=2)
    except Exception as e:
        logger.debug(f"failed to write {cfgpath}: {e}")

    try:
        atomic_write_json(
            os.path.join(out_dir, "audio_manifest.json"),
            {"has_audio_hooks": bool(audio_hooks)},
            indent=2,
        )
        atomic_write_json(
            os.path.join(out_dir, "audio_visualizer.json"),
            {
                "needs_audio_spectrum": bool(audio_hooks),
                "suggested_resolution": int(suggested_res or 32),
                "shaders": shaders,
            },
            indent=2,
        )
    except Exception as e:
        logger.debug(f"failed to write audio manifest: {e}")


def particle_follows_mouse(pjson):
    """True when a particle system binds/attracts to the cursor control point."""
    if not isinstance(pjson, dict):
        return False
    for cp in pjson.get("controlpoint") or []:
        try:
            if int(cp.get("flags", 0)) & 1:
                return True
        except (TypeError, ValueError):
            pass
    for op in pjson.get("operator") or []:
        if str(op.get("name", "")).lower() in ATTRACT_OPS:
            return True
    return False


def find_trail_objects(scene, data, entries, dir_end):
    """Detect the wallpaper's own mouse-trail objects in the scene JSON."""
    trails = []
    root = scene.get("root") or scene.get("objects") or scene
    for node in walk_nodes(root):
        if not isinstance(node, dict):
            continue
        vis = node.get("visible")
        gated = isinstance(vis, dict) and str(vis.get("user", "")).lower() in TRAIL_USER_PROPS
        named = TRAIL_NAME_RE.search(str(node.get("name") or "")) is not None
        pfile = node.get("particle")
        follows = False
        if isinstance(pfile, str) and pfile:
            follows = particle_follows_mouse(load_json_entry(data, entries, dir_end, pfile))
        if follows or gated or (named and "particle" in node):
            trails.append(node)
    return trails


def convert_tex(src_tex, out_png):
    """Extract embedded PNG from a WE .tex (TEXV/TEXB) container if present."""
    try:
        with open(src_tex, "rb") as fh:
            raw = fh.read()
        png_sig = b"\x89PNG\r\n\x1a\n"
        iend_sig = b"IEND\xaeB`\x82"
        start = raw.find(png_sig)
        if start >= 0:
            end = raw.find(iend_sig, start)
            if end >= 0:
                png_data = raw[start : end + len(iend_sig)]
                atomic_write_bytes(out_png, png_data)
                return True
    except Exception as e:
        logger.debug(f"convert_tex failed for {src_tex}: {e}")
    return False


def _slice_first_cell(png_path):
    """Slice first sprite frame if texture is a multi-frame horizontal strip."""
    if not HAS_PIL:
        return None
    try:
        with Image.open(png_path) as im:
            w, h = im.size
            if w >= h * 2 and h >= 8:
                cell = im.crop((0, 0, h, h))
                cell_name = os.path.basename(png_path).replace(".png", "_cell0.png")
                cell_path = os.path.join(os.path.dirname(png_path), cell_name)
                cell.save(cell_path, "PNG")
                return cell_name
    except Exception:
        pass
    return None


def resolve_texture(name, out_dir, assets_root):
    """Locate a material texture (.tex), decode it, return web-relative path."""
    if not name:
        return None
    rel = name.replace("\\", "/").lstrip("/")
    if not rel.startswith("materials/"):
        rel = "materials/" + rel
    candidates = [os.path.join(out_dir, rel + ".tex")]
    if assets_root:
        candidates.append(os.path.join(assets_root, rel + ".tex"))
    for cand in candidates:
        if not os.path.isfile(cand):
            continue
        base = os.path.basename(rel).replace("/", "_")
        out_png = os.path.join(out_dir, "trail_tex", base + ".png")
        os.makedirs(os.path.dirname(out_png), exist_ok=True)
        if convert_tex(cand, out_png):
            cell = _slice_first_cell(out_png)
            if cell:
                return "trail_tex/" + cell
            return "trail_tex/" + base + ".png"

        try:
            if HAS_PIL:
                im = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
                im.save(out_png, "PNG")
            else:
                atomic_write_bytes(out_png, base64.b64decode(_TRANSPARENT_PNG_B64))
            return "trail_tex/" + base + ".png"
        except Exception as e:
            logger.debug(f"failed to create placeholder for {cand}: {e}")
            return None
    return None


def parse_color255(v):
    """'0.72549 0.0 0.0' -> [185, 0, 0] (WE colors are 0..1 or 0..255)."""
    try:
        parts = [float(x) for x in str(v).replace(",", " ").split()]
    except (TypeError, ValueError):
        return None
    if len(parts) < 3:
        return None
    rgb = parts[:3]
    if max(rgb) <= 1.0:
        rgb = [c * 255.0 for c in rgb]
    return [round(max(0.0, min(255.0, c))) for c in rgb]


def build_tex_bytes(img):
    """Wrap a PIL image in a full-mip-chain TEXV0005 container."""
    base = img.convert("RGBA")
    mips = [base]
    cur = base
    while True:
        nw = max(1, cur.width // 2)
        nh = max(1, cur.height // 2)
        if nw == cur.width and nh == cur.height:
            break
        cur = cur.resize((nw, nh), Image.LANCZOS)
        mips.append(cur.copy())

    def _u32(x):
        return struct.pack("<I", x)

    def _png(im):
        b = io.BytesIO()
        im.save(b, "PNG")
        return b.getvalue()

    w0, h0 = base.size
    header = (
        b"TEXV0005\x00"
        + b"TEXI0001\x00"
        + _u32(0)
        + _u32(2)
        + _u32(w0)
        + _u32(h0)
        + _u32(w0)
        + _u32(h0)
        + b"\x00\x00\x00\xff"
    )
    png0 = _png(mips[0])
    data = (
        header
        + b"TEXB0004\x00"
        + _u32(1)
        + _u32(13)
        + _u32(0)
        + _u32(3)
        + _u32(w0)
        + _u32(h0)
        + _u32(0)
        + _u32(0)
        + _u32(len(png0))
        + png0
    )
    for mip in mips[1:]:
        p = _png(mip)
        data += _u32(mip.width) + _u32(mip.height) + _u32(0) + _u32(0) + _u32(len(p)) + p
    return data


def make_placeholder_thumb(out_path):
    """Dim vinyl-disc placeholder shown only when no real cover art .tex exists yet."""
    if os.path.isfile(out_path) and os.path.getsize(out_path) > 1024:
        return True
    if not HAS_PIL:
        return False
    try:
        im = Image.new("RGBA", (300, 300), (16, 16, 22, 255))
        d = ImageDraw.Draw(im)
        d.ellipse((28, 28, 272, 272), outline=(64, 64, 76, 255), width=6)
        d.ellipse((96, 96, 204, 204), outline=(48, 48, 58, 255), width=3)
        d.ellipse((126, 126, 174, 174), fill=(56, 56, 68, 255))
        atomic_write_bytes(out_path, build_tex_bytes(im))
        return True
    except Exception:
        return False


def patch_media_thumbnail_materials(out_dir):
    """Retarget $mediaThumbnail passes to media_cover and clean empty material combos."""
    patched = 0
    mdir = os.path.join(out_dir, "materials")
    if not os.path.isdir(mdir):
        return 0
    for rootp, _dirs, files in os.walk(mdir):
        for fn in files:
            if not fn.endswith(".json"):
                continue
            p = os.path.join(rootp, fn)
            try:
                with open(p, encoding="utf-8") as fh:
                    doc = json.load(fh)
            except Exception:
                continue
            changed = False
            has_thumb = False
            for pas in doc.get("passes") or []:
                if not isinstance(pas, dict):
                    continue
                # Sanitize empty combos that fail C++ parser (`combo '%s' can't be empty`)
                combos = pas.get("combos")
                if isinstance(combos, dict):
                    empty_keys = [ck for ck, cv in combos.items() if cv == "" or cv is None]
                    for ck in empty_keys:
                        del combos[ck]
                        changed = True
                ut = pas.get("usertextures")
                if isinstance(ut, list) and any(
                    isinstance(t, dict) and "mediathumbnail" in str(t.get("name", "")).lower()
                    for t in ut
                ):
                    pas["textures"] = [MEDIA_THUMB_TEX]
                    pas.pop("usertextures", None)
                    changed = True
                    has_thumb = True
                elif isinstance(pas.get("textures"), list) and MEDIA_THUMB_TEX in pas.get("textures"):
                    has_thumb = True
            if changed:
                try:
                    atomic_write_json(p, doc, indent=2)
                except Exception:
                    pass
            if has_thumb:
                patched += 1
    return patched


def classify_shortcut(obj_name):
    n = obj_name.lower()
    for action, keys in _SHORTCUT_RULES:
        if any(k in n for k in keys):
            return action
    return None


def scan_shortcuts(scene_doc):
    out = {}

    def walk(objs):
        for o in objs:
            if not isinstance(o, dict):
                continue
            name = str(o.get("name", ""))
            for k, v in o.items():
                if k in ("objects", "children") or not isinstance(v, dict):
                    continue
                s = v.get("script")
                if not isinstance(s, str) or "openUserShortcut" not in s:
                    continue
                key = None
                m = re.search(r'openUserShortcut\(\s*[\'"]([^\'"]+)[\'"]', s)
                if m:
                    key = m.group(1)
                else:
                    sp = v.get("scriptproperties")
                    if isinstance(sp, dict) and sp.get("propKey"):
                        key = str(sp["propKey"])
                if key and key not in out:
                    act = classify_shortcut(name)
                    if act:
                        out[key] = act
            walk(o.get("objects") or [])
            walk(o.get("children") or [])

    walk(scene_doc.get("objects", []) if isinstance(scene_doc, dict) else [])
    return out


def attach_accurate_data(spec, data, entries, dir_end, node, out_dir, assets_root):
    """Extend a render spec with the wallpaper's exact trail programming."""
    if not isinstance(spec, dict):
        return

    ov = node.get("instanceoverride") or {}
    if isinstance(ov, dict) and ov.get("colorn"):
        spec["tint"] = parse_color255(ov.get("colorn"))

    pfile = node.get("particle")
    if not isinstance(pfile, str) or not pfile:
        return
    pj = load_json_entry(data, entries, dir_end, pfile)
    if not isinstance(pj, dict):
        return

    emitters = pj.get("emitter") or []
    if emitters and isinstance(emitters[0], dict):
        em = emitters[0]
        try:
            spec["emit_shape"] = str(em.get("name", ""))
            for key, jkey in (("speed_min", "speedmin"), ("speed_max", "speedmax")):
                try:
                    spec[key] = float(em.get(jkey, 0))
                except (TypeError, ValueError):
                    spec[key] = 0.0
        except Exception:
            pass

    ops = pj.get("operator") or []
    names = {str(o.get("name", "")).lower() for o in ops}
    spec["attract"] = "controlpointattract" in names
    drag = 0.0
    for o in ops:
        lname = str(o.get("name", "")).lower()
        if lname == "movement":
            try:
                drag = float(o.get("drag", 0))
            except (TypeError, ValueError):
                drag = 0.0
        elif lname == "controlpointattract":
            try:
                spec["attract_scale"] = float(o.get("scale", 0))
            except (TypeError, ValueError):
                spec["attract_scale"] = 0.0
            try:
                spec["attract_threshold"] = float(o.get("threshold", 0))
            except (TypeError, ValueError):
                spec["attract_threshold"] = 0.0
    spec["drag"] = drag

    mat = load_json_entry(data, entries, dir_end, str(pj.get("material") or ""))
    overbright = None
    tex_name = None
    if isinstance(mat, dict):
        passes = mat.get("passes") or []
        if passes and isinstance(passes[0], dict):
            csv = passes[0].get("constantshadervalues") or {}
            try:
                overbright = float(csv.get("ui_editor_properties_overbright"))
            except (TypeError, ValueError):
                overbright = None
            texs = passes[0].get("textures") or []
            if texs:
                tex_name = str(texs[0])
    spec["overbright"] = overbright
    spec["texture"] = resolve_texture(tex_name, out_dir, assets_root) if tex_name else None


def find_assets_root(pkg_path):
    """Alternate asset root for texture fallback (a real dir with materials), or None."""
    d = os.path.dirname(pkg_path)
    if os.path.isdir(os.path.join(d, "materials")):
        return d
    return None


def parse_vec3(value):
    """'x y z' / [ .. ] -> [x, y, z] (floats), or [0, 0, 0] on failure."""
    try:
        parts = [float(x) for x in str(value).replace(",", " ").split()]
        if len(parts) >= 3:
            return parts[:3]
    except (TypeError, ValueError):
        pass
    return [0.0, 0.0, 0.0]


def resolve_trail_visibility(node):
    """Freeze a cursor-user-property-gated visibility to a concrete boolean."""
    vis = node.get("visible")
    if isinstance(vis, dict):
        node["_we_visible_user"] = str(vis.get("user", ""))
        node["visible"] = True


def particle_render_spec(data, entries, dir_end, pfile, obj_scale):
    """Baseline render spec for a trail particle system (extended later)."""
    spec = {"source": pfile, "scale": obj_scale, "emit_shape": ""}
    pj = load_json_entry(data, entries, dir_end, pfile)
    if isinstance(pj, dict):
        ems = pj.get("emitter") or []
        if ems and isinstance(ems[0], dict):
            spec["emit_shape"] = str(ems[0].get("name", ""))
            try:
                spec["rate"] = float(ems[0].get("rate", 0))
            except (TypeError, ValueError):
                spec["rate"] = 0.0
    return spec


def trail_manifest(sid, entries):
    """The mousetrail.json manifest consumed by the QML NativeTrail backend."""
    return {
        "workshop_id": sid,
        "workshopid": sid,
        "has_native_trail": bool(entries),
        "trails": entries or [],
    }


def _find_workshop_project_json(sid):
    """Locate <sid>/project.json across configured Steam libraries."""
    home = os.path.expanduser("~")
    roots = [
        os.path.join(home, ".local/share/Steam"),
        os.path.join(home, ".steam/steam"),
        os.path.join(home, ".steam/root"),
        os.path.join(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    ]
    libs = list(roots)
    for r in roots:
        vdf = os.path.join(r, "steamapps/libraryfolders.vdf")
        if os.path.isfile(vdf):
            try:
                with open(vdf, "r", encoding="utf-8", errors="replace") as fh:
                    for m in re.finditer(r'"path"\s+"([^"]+)"', fh.read()):
                        libs.append(m.group(1).replace("\\\\", "/"))
            except OSError:
                pass
    user_name = os.environ.get("USER") or os.path.basename(home)
    for mb in (f"/run/media/{user_name}", f"/media/{user_name}", "/mnt"):
        if os.path.isdir(mb):
            try:
                for d in os.listdir(mb):
                    vol = os.path.join(mb, d)
                    for sp in ("Steam", "SteamLibrary", "Program Files (x86)/Steam", "Program Files/Steam"):
                        libs.append(os.path.join(vol, sp))
            except OSError:
                pass
    for lib in libs:
        cand = os.path.join(lib, "steamapps/workshop/content/431960", str(sid), "project.json")
        if os.path.isfile(cand):
            return cand
    return ""

def _inject_media_properties(out_dir, pkg_dir=None, audio_hooks=False):
    """Declare standard media u_* user properties in project.json and return all property keys."""
    media_props = {
        "u_title":       {"index": 0, "text": "Media Title",    "type": "text",   "value": "", "order": 900},
        "u_artist":      {"index": 0, "text": "Media Artist",   "type": "text",   "value": "", "order": 901},
        "u_album":       {"index": 0, "text": "Media Album",    "type": "text",   "value": "", "order": 902},
        "u_albumartist": {"index": 0, "text": "Album Artist",   "type": "text",   "value": "", "order": 903},
        "u_playstate":   {"index": 0, "text": "Play State",     "type": "slider", "value": 0,  "order": 904},
        "u_position":    {"index": 0, "text": "Media Position", "type": "slider", "value": 0,  "order": 905},
        "u_duration":    {"index": 0, "text": "Media Duration", "type": "slider", "value": 0,  "order": 906},
    }
    pj_out = os.path.join(out_dir, "project.json")
    sid_guess = os.path.basename(out_dir.rstrip("/\\"))
    src_pj = os.path.join(pkg_dir, "project.json") if pkg_dir else ""
    if (not src_pj or not os.path.isfile(src_pj)) and sid_guess.isdigit():
        cand_pj = _find_workshop_project_json(sid_guess)
        if os.path.isfile(cand_pj):
            src_pj = cand_pj

    src_doc = {}
    if src_pj and os.path.isfile(src_pj):
        try:
            with open(src_pj, "r", encoding="utf-8-sig", errors="replace") as fh:
                src_doc = json.load(fh)
        except Exception:
            src_doc = {}

    if not os.path.isfile(pj_out) and src_pj and os.path.isfile(src_pj):
        try:
            shutil.copy2(src_pj, pj_out)
        except Exception:
            pass

    doc = {}
    if os.path.isfile(pj_out):
        try:
            with open(pj_out, "r", encoding="utf-8-sig", errors="replace") as fh:
                doc = json.load(fh)
        except Exception:
            doc = {}

    if isinstance(src_doc, dict):
        for top_k, top_v in src_doc.items():
            if top_k not in doc:
                doc[top_k] = top_v
        src_props = ((src_doc.get("general") or {}).get("properties") or {})
        if isinstance(src_props, dict) and src_props:
            dst_props = doc.setdefault("general", {}).setdefault("properties", {})
            for pk, pv in src_props.items():
                if pk not in dst_props:
                    dst_props[pk] = pv

    if not isinstance(doc, dict):
        doc = {}

    general = doc.setdefault("general", {})
    props = general.setdefault("properties", {})
    changed = False
    for k, v in media_props.items():
        if k not in props or not isinstance(props[k], dict) or props[k].get("index") is None:
            prev = props.get(k) if isinstance(props.get(k), dict) else {}
            merged = dict(v)
            for fk in ("text", "type", "value", "order"):
                if fk in prev:
                    merged[fk] = prev[fk]
            props[k] = merged
            changed = True

    if audio_hooks and not general.get("supportsaudioprocessing"):
        general["supportsaudioprocessing"] = True
        changed = True

    if changed or not os.path.isfile(pj_out):
        try:
            atomic_write_json(pj_out, doc, indent=2)
            logger.info(f"  media properties injected: {list(media_props.keys())}")
        except Exception as e:
            logger.debug(f"media properties injection skipped: {e}")

    return sorted(props.keys())


def is_locked_translation(out_dir):
    """True when translator_version.json has version >= 99 (manual lock)."""
    tv = os.path.join(out_dir, "translator_version.json")
    if not os.path.isfile(tv):
        return False
    try:
        with open(tv, "r", encoding="utf-8") as fh:
            v = int(json.load(fh).get("version", -1))
        return v >= 99
    except Exception:
        return False


def translate_pkg(pkg_path, out_dir, force=False):
    """Extract the pkg and write a translated scene.json with v17 polyfills."""
    if not force and is_locked_translation(out_dir):
        logger.info(f"  {out_dir}: locked (version >= 99), skipping destructive re-extraction")
        return True

    data = open(pkg_path, "rb").read()
    assert data[4:8] == b"PKGV", "not a PKGV pkg"

    entries, dir_end = parse_entries(data)
    if not entries:
        return False

    sid = os.path.basename(out_dir.rstrip("/\\"))
    pkg_dir = os.path.dirname(os.path.abspath(pkg_path))

    scene_entry = next((e for e in entries if e["name"] == "scene.json"), None)
    if scene_entry is None:
        for e in entries:
            blob = data[dir_end + e["off"] : dir_end + e["off"] + e["size"]]
            if blob.lstrip().startswith(b"{") and (
                b"objects" in blob[:4000] or b'"root"' in blob[:4000]
            ):
                scene_entry = e
                break
    if scene_entry is None:
        logger.info(f"  {os.path.basename(pkg_path)}: no scene JSON found, skip")
        return False

    scene_blob = data[
        dir_end + scene_entry["off"] : dir_end + scene_entry["off"] + scene_entry["size"]
    ]
    scene_text = scene_blob.decode("utf-8", "replace")

    trails = []
    try:
        scene_doc = json.loads(scene_text)
        trails = find_trail_objects(scene_doc, data, entries, dir_end)
    except Exception:
        scene_doc = None

    # Deep scan for u_* bindings and audio visualizer shaders/uniforms
    bindings_list, audio_hooks, suggested_res, audio_shaders = extract_bindings_and_audio(
        scene_text, data, entries, dir_end, pkg_dir=pkg_dir
    )

    if scene_doc is not None and trails:
        for node in trails:
            resolve_trail_visibility(node)

    # Build skip_ids for parallax injection
    skip_ids = {n.get("id") for n in trails if n.get("id") is not None}
    if scene_doc is not None:
        for node in walk_nodes(scene_doc):
            if not isinstance(node, dict):
                continue
            nid = node.get("id")
            lname = str(node.get("name") or "").lower()
            if "script" in node or "scriptproperties" in node:
                if nid is not None:
                    skip_ids.add(nid)
            if any(k in lname for k in ("animation", "skeleton", "model", "anim")):
                if nid is not None:
                    skip_ids.add(nid)
            if node.get("particle") or "operator" in node or "controlpoint" in node:
                if nid is not None:
                    skip_ids.add(nid)

    parallax_injected = 0
    scripts_transpiled = 0
    if scene_doc is not None:
        parallax_injected = inject_parallax_on_doc(scene_doc, raw_scene_text=scene_text, skip_ids=skip_ids)
        scripts_transpiled = walk_and_transpile_scene_scripts(scene_doc, sid=sid)

    os.makedirs(out_dir, exist_ok=True)
    for e in entries:
        if e["name"] == "scene.json":
            continue
        blob = data[dir_end + e["off"] : dir_end + e["off"] + e["size"]]
        out_path = os.path.join(out_dir, e["name"])
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "wb") as fh:
            fh.write(blob)

    if scene_doc is not None:
        atomic_write_json(os.path.join(out_dir, "scene.json"), scene_doc, indent="\t")
    else:
        atomic_write_text(os.path.join(out_dir, "scene.json"), scene_text)

    # Write trail manifest
    man_entries = []
    for node in trails:
        pfile = node.get("particle")
        spec = None
        if isinstance(pfile, str) and pfile:
            sc = parse_vec3(node.get("scale", "1 1 1"))
            obj_scale = max(abs(sc[0]), abs(sc[1])) or 1.0
            spec = particle_render_spec(data, entries, dir_end, pfile, obj_scale)
        man_entries.append({
            "id": node.get("id"),
            "name": node.get("name"),
            "particle": pfile,
            "visible_user": node.get("_we_visible_user"),
            "spec": spec,
        })

    assets_root = find_assets_root(pkg_path)
    try:
        for entry, node in zip(man_entries, trails):
            attach_accurate_data(
                entry["spec"], data, entries, dir_end, node, out_dir, assets_root
            )
    except Exception as e:
        logger.debug(f"trail spec attach failed: {e}")

    atomic_write_json(
        os.path.join(out_dir, "mousetrail.json"),
        trail_manifest(sid, man_entries),
        indent=1,
    )

    # Patch $mediaThumbnail materials and sanitize combos
    thumb_patched = patch_media_thumbnail_materials(out_dir)
    shortcuts = scan_shortcuts(scene_doc) if scene_doc is not None else {}
    is_media_player = (
        bool(thumb_patched)
        or bool(shortcuts)
        or '"$mediaThumbnail"' in scene_text
        or "openUserShortcut" in scene_text
    )

    if is_media_player:
        if thumb_patched:
            os.makedirs(os.path.join(out_dir, "materials"), exist_ok=True)
            make_placeholder_thumb(os.path.join(out_dir, "materials", MEDIA_THUMB_FILE))
        atomic_write_json(
            os.path.join(out_dir, "mediaplayer.json"),
            {"has_media_thumbnail": bool(thumb_patched), "shortcuts": shortcuts},
            indent=1,
        )
        logger.info(f"  media player: thumbnail={bool(thumb_patched)} shortcuts={shortcuts}")

    # Inject u_* properties into project.json and write combined bindings + audio manifests
    proj_keys = _inject_media_properties(out_dir, pkg_dir=pkg_dir, audio_hooks=audio_hooks)
    all_bindings = sorted(set(bindings_list).union(proj_keys))
    write_bindings_file(
        out_dir,
        sid,
        all_bindings,
        audio_hooks,
        suggested_res=suggested_res,
        shaders=audio_shaders,
    )

    # Write translator_version.json
    try:
        atomic_write_json(
            os.path.join(out_dir, "translator_version.json"),
            {"translator": "translate_pkg.py", "version": TRANSLATOR_VERSION},
            indent=1,
        )
    except Exception:
        pass

    logger.info(
        f"  {os.path.basename(pkg_path)} ({sid}): scripts={scripts_transpiled}, "
        f"parallax={parallax_injected}, trails={len(trails)}, "
        f"audio={audio_hooks} (res={suggested_res}), binds={len(all_bindings)}"
    )
    return True


def upgrade_existing_dir(out_dir, lock_version=99):
    """Non-destructively upgrade an already-extracted translated/<id> directory in-place."""
    sjson = os.path.join(out_dir, "scene.json")
    if not os.path.isfile(sjson):
        return False
    sid = os.path.basename(out_dir.rstrip("/\\"))
    try:
        with open(sjson, "r", encoding="utf-8") as fh:
            scene_doc = json.load(fh)
    except Exception as e:
        logger.error(f"  failed to parse {sjson}: {e}")
        return False

    scripts_transpiled = walk_and_transpile_scene_scripts(scene_doc, sid=sid)
    if scripts_transpiled > 0:
        atomic_write_json(sjson, scene_doc, indent=2)

    # Scan on-disk files for bindings and audio hooks
    bindings = set()
    audio_hooks = False
    detected_res = 32
    shaders = []
    for rootp, _dirs, files in os.walk(out_dir):
        for fn in files:
            if not fn.lower().endswith((".json", ".frag", ".vert", ".js")):
                continue
            p = os.path.join(rootp, fn)
            if os.path.islink(p) and not os.path.exists(p):
                continue
            try:
                if os.path.getsize(p) > 3_000_000:
                    continue
                with open(p, "r", encoding="utf-8", errors="replace") as fh:
                    txt = fh.read()
            except Exception:
                continue
            for m in _USERVAR_PAT.finditer(txt):
                bindings.add(m.group(0))
            if _AUDIO_PAT.search(txt):
                audio_hooks = True
                if fn.lower().endswith((".frag", ".vert")):
                    rel = os.path.relpath(p, out_dir).replace("\\", "/")
                    sh = re.sub(r"^shaders/|(\.frag|\.vert)$", "", rel)
                    if sh not in shaders:
                        shaders.append(sh)
            for rm in _SPECTRUM_RES_PAT.finditer(txt):
                audio_hooks = True
                rval = int(rm.group(1))
                if rval > detected_res:
                    detected_res = rval

    thumb_patched = patch_media_thumbnail_materials(out_dir)
    shortcuts = scan_shortcuts(scene_doc)
    if thumb_patched or shortcuts:
        if thumb_patched:
            os.makedirs(os.path.join(out_dir, "materials"), exist_ok=True)
            make_placeholder_thumb(os.path.join(out_dir, "materials", MEDIA_THUMB_FILE))
        atomic_write_json(
            os.path.join(out_dir, "mediaplayer.json"),
            {"has_media_thumbnail": bool(thumb_patched), "shortcuts": shortcuts},
            indent=1,
        )

    proj_keys = _inject_media_properties(out_dir, audio_hooks=audio_hooks)
    all_bindings = sorted(bindings.union(proj_keys))
    write_bindings_file(
        out_dir,
        sid,
        all_bindings,
        audio_hooks,
        suggested_res=detected_res,
        shaders=shaders,
    )
    atomic_write_json(
        os.path.join(out_dir, "translator_version.json"),
        {"translator": "translate_pkg.py", "version": lock_version},
        indent=1,
    )
    logger.info(
        f"  upgraded {sid}: scripts={scripts_transpiled}, audio={audio_hooks} (res={detected_res}), binds={len(all_bindings)}"
    )
    return True


def main():
    args = sys.argv[1:]
    if not args:
        logger.info(
            f"usage:\n"
            f"  {sys.argv[0]} [--force] <scene.pkg>...\n"
            f"  {sys.argv[0]} --upgrade-existing [<translated_dir>...]"
        )
        sys.exit(2)

    force = "--force" in args
    upgrade_mode = "--upgrade-existing" in args
    targets = [a for a in args if a not in ("--force", "--upgrade-existing")]

    if upgrade_mode:
        if not targets and os.path.isdir(TRANS_ROOT):
            targets = [
                os.path.join(TRANS_ROOT, d)
                for d in sorted(os.listdir(TRANS_ROOT))
                if os.path.isdir(os.path.join(TRANS_ROOT, d))
            ]
        for tdir in targets:
            upgrade_existing_dir(tdir)
        return

    for pkg in targets:
        if not os.path.isfile(pkg):
            logger.info(f"skip: {pkg}")
            continue
        sid = os.path.basename(os.path.dirname(os.path.abspath(pkg)))
        out = os.path.join(TRANS_ROOT, sid)
        logger.info(pkg)
        translate_pkg(pkg, out, force=force)


if __name__ == "__main__":
    main()
