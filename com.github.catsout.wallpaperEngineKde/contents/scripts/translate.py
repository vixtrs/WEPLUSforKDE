#!/usr/bin/env python3
"""waywallen-style effect translator for WE-for-KDE (catsout) — v17.

Reads an unpacked Wallpaper Engine directory (workshop item with scene.json on disk)
and produces a translated copy under ~/.local/share/wallpaperEngineKde/translated/<id>/
with full v17 compatibility:
  - Injects universal WE media/click JS polyfills (__wekTick, cursorDown -> cursorClick)
  - Injects parallaxDepth when appropriate (skipping scripted/trail/model layers)
  - Retargets $mediaThumbnail to materials/media_cover.tex and sanitizes empty combos
  - Declares u_title, u_artist, u_album, u_albumartist, u_playstate, u_position, u_duration
  - Writes bindings.json, <id>_bindings.json, audio_manifest.json, audio_visualizer.json,
    mediaplayer.json, and translator_version.json
  - Symlinks unmodified assets instead of copying
"""

import html
import json
import logging
import os
import re
import shutil
import sys

# Reuse the v17 core helpers from translate_pkg.py when located in the same folder
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

try:
    import translate_pkg as tpkg
except ImportError:
    tpkg = None

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

if os.name == "nt":
    TRANS_ROOT = os.path.join(os.environ.get("APPDATA", ""), "wallpaperEngineKde", "translated")
else:
    TRANS_ROOT = os.path.expanduser("~/.local/share/wallpaperEngineKde/translated")

VISUAL_TYPES = {
    "image", "model", "particle", "shader", "videotexture",
    "cubeTexture", "video", "texture"
}
PARALLAX_HINTS = ("parallaxDepth", "cameraparallax", "g_ParallaxPosition", "depthparallax")

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


def walk_nodes(node, depth=0, max_depth=64):
    if depth > max_depth:
        return
    if isinstance(node, dict):
        yield node, depth
        for child_list in node.values():
            if isinstance(child_list, list):
                for child in child_list:
                    yield from walk_nodes(child, depth + 1, max_depth)
            elif isinstance(child_list, dict):
                yield from walk_nodes(child_list, depth + 1, max_depth)
    elif isinstance(node, list):
        for item in node:
            yield from walk_nodes(item, depth, max_depth)


def has_parallax(scene):
    if not isinstance(scene, (dict, list)):
        return False
    for node, _depth in walk_nodes(scene):
        if any(h in node for h in PARALLAX_HINTS):
            return True
        if isinstance(node, dict) and "general" in node:
            gen = node["general"]
            if isinstance(gen, dict) and any(h in gen for h in PARALLAX_HINTS):
                return True
    return False


def translate_scene(scene):
    changed = False
    nodes = scene.get("root") or scene.get("objects") or scene
    for node, _depth in walk_nodes(nodes):
        if not isinstance(node, dict):
            continue
        if "parallaxDepth" in node:
            continue
        if node.get("type") not in VISUAL_TYPES and not any(
            k in node for k in ("image", "particles", "particle", "instance")
        ):
            continue
        if node.get("name") and "parallax" in str(node.get("name")).lower():
            continue
        if "script" in node or "scriptproperties" in node or "mouseTarget" in node:
            continue
        if any(isinstance(v, dict) and "script" in v for v in node.values()):
            continue

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

        node["parallaxDepth"] = f"{depth:.5f} {depth:.5f}"
        changed = True
    return changed


def scan_directory_audio_and_bindings(root_dir):
    bindings = set()
    audio_hooks = False
    detected_res = 32
    shaders = []

    for r, _dirs, files in os.walk(root_dir):
        for fn in files:
            if not fn.lower().endswith((".json", ".frag", ".vert", ".js")):
                continue
            p = os.path.join(r, fn)
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
                    rel = os.path.relpath(p, root_dir).replace("\\", "/")
                    sh = re.sub(r"^shaders/|(\.frag|\.vert)$", "", rel)
                    if sh not in shaders:
                        shaders.append(sh)
            for rm in _SPECTRUM_RES_PAT.finditer(txt):
                audio_hooks = True
                rval = int(rm.group(1))
                if rval > detected_res:
                    detected_res = rval

    return sorted(bindings), bool(audio_hooks), detected_res, shaders


def translate_dir(wallpaper_dir, force=False):
    sid = os.path.basename(os.path.normpath(wallpaper_dir))
    out = os.path.join(TRANS_ROOT, sid)
    if tpkg is not None and not force and tpkg.is_locked_translation(out):
        logger.info(f"skip locked directory: {out}")
        return out

    scene_path = os.path.join(wallpaper_dir, "scene.json")
    if not os.path.isfile(scene_path):
        pkg_candidate = os.path.join(wallpaper_dir, "scene.pkg")
        if os.path.isfile(pkg_candidate) and tpkg is not None:
            tpkg.translate_pkg(pkg_candidate, out, force=force)
            return out
        logger.info(f"skip: no scene.json in {wallpaper_dir}")
        return None

    os.makedirs(out, exist_ok=True)
    try:
        with open(scene_path, encoding="utf-8") as fh:
            scene = json.load(fh)
    except Exception as e:
        logger.error(f"Failed to parse {scene_path}: {e}")
        return None

    scene_changed = False
    if not has_parallax(scene):
        scene_changed = translate_scene(scene)

    if tpkg is not None:
        patched_scripts = tpkg.walk_and_transpile_scene_scripts(scene, sid=sid)
        if patched_scripts > 0:
            scene_changed = True

    with open(os.path.join(out, "scene.json"), "w", encoding="utf-8") as fh:
        json.dump(scene, fh, indent=2, ensure_ascii=False)

    # Copy materials directory instead of symlinking if it contains $mediaThumbnail so we don't mutate Steam files
    for name in os.listdir(wallpaper_dir):
        if name in ("scene.json", "project.json", "config.json"):
            continue
        src = os.path.join(wallpaper_dir, name)
        dst = os.path.join(out, name)
        if name == "materials" and os.path.isdir(src):
            if os.path.islink(dst):
                os.unlink(dst)
            shutil.copytree(src, dst, dirs_exist_ok=True)
            continue
        try:
            if (os.path.isdir(src) or os.path.isfile(src)) and not os.path.lexists(dst):
                os.symlink(src, dst)
        except OSError as e:
            logger.debug(f"Failed to symlink {src} -> {dst}: {e}")

    bindings_list, audio_hooks, detected_res, shaders = scan_directory_audio_and_bindings(wallpaper_dir)

    if tpkg is not None:
        thumb_patched = tpkg.patch_media_thumbnail_materials(out)
        shortcuts = tpkg.scan_shortcuts(scene)
        if thumb_patched or shortcuts:
            if thumb_patched:
                os.makedirs(os.path.join(out, "materials"), exist_ok=True)
                tpkg.make_placeholder_thumb(os.path.join(out, "materials", tpkg.MEDIA_THUMB_FILE))
            tpkg.atomic_write_json(
                os.path.join(out, "mediaplayer.json"),
                {"has_media_thumbnail": bool(thumb_patched), "shortcuts": shortcuts},
                indent=1,
            )
        proj_keys = tpkg._inject_media_properties(out, pkg_dir=wallpaper_dir, audio_hooks=audio_hooks)
        all_binds = sorted(set(bindings_list).union(proj_keys))
        tpkg.write_bindings_file(
            out, sid, all_binds, audio_hooks, suggested_res=detected_res, shaders=shaders
        )
        tpkg.atomic_write_json(
            os.path.join(out, "translator_version.json"),
            {"translator": "translate.py", "version": tpkg.TRANSLATOR_VERSION},
            indent=1,
        )

    status = "translated" if scene_changed else "updated"
    logger.info(f"{status}: {sid} -> {out}")
    return out


def main():
    args = sys.argv[1:]
    if not args:
        logger.info(f"usage: {sys.argv[0]} [--force] <wallpaper-dir>...")
        sys.exit(2)
    force = "--force" in args
    for arg in args:
        if arg == "--force":
            continue
        translate_dir(arg, force=force)


if __name__ == "__main__":
    main()
