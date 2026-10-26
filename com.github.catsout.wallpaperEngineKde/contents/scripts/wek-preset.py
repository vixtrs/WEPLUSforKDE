#!/usr/bin/env python3
"""Apply or reset a Wallpaper Engine Workshop preset on its base wallpaper (v18).

Key guarantees (addressing audit points 15-37, 48, 51, 58):
  - Non-destructive & reversible: backs up original base files in
    `translated/<baseId>/.wek_base_orig/` before any preset modification.
  - Idempotent multi-preset switching: applying Preset B after Preset A (or
    running `--reset`) first restores `.wek_base_orig/` and purges old
    `wek-preset-*` directories and `materials/wek_preset_*.tex` files, so
    `usertextures` is never permanently lost.
  - Zero 6x disk bloat & zero base collision: stages preset assets ONLY under
    `<baseDir>/wek-preset-<presetId>/` and symlinks that directory into
    `translated/<baseId>/wek-preset-<presetId>` (never touches `<baseDir>/files`).
  - Case-insensitive & URL-decoded relative paths: supports `files/...`,
    `media/...`, `assets/...`, `images/...`, `%20` URL encoding, and
    `file:///...` (preserving leading `/`).
  - Validated `.tex` generation via `png2tex.py` with content hash in filename
    (`wek_preset_<pid>_<key>_<hash8>`) to bust `TextureCache` on change.
"""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

try:
    import png2tex
    HAS_PNG2TEX = True
except ImportError:
    png2tex = None
    HAS_PNG2TEX = False

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    Image = None
    HAS_PIL = False

APPID_DEFAULT = "431960"
MAX_CHAIN = 8
WIN_ABS_RE = re.compile(r"^[A-Za-z]:[/\\]")
MEDIA_EXT_RE = re.compile(r"\.(mp4|webm|mkv|mov|avi|m4v|gif|png|jpe?g|webp|bmp)$", re.I)
VIDEO_EXTS = {".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"}
RELATIVE_ASSET_PREFIXES = ("files/", "media/", "assets/", "images/", "textures/", "videos/")


def fail(message: str) -> int:
    print(f"ERROR {message}", flush=True)
    return 1


def read_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        with path.open("r", encoding="utf-8-sig", errors="replace") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def atomic_write_bytes(dest: Path, data: bytes) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".wek_preset_", dir=str(dest.parent))
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, dest)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        raise


def atomic_write_json(dest: Path, obj: Any, indent: int = 2) -> None:
    text = json.dumps(obj, indent=indent, ensure_ascii=False) + "\n"
    atomic_write_bytes(dest, text.encode("utf-8"))


def normalize_library(value: str) -> Path:
    value = (value or "").strip().strip("'\"")
    if value.startswith("file://"):
        parsed = urllib.parse.urlparse(value)
        value = urllib.parse.unquote(parsed.path or value[7:])
    elif value.startswith("file:"):
        value = urllib.parse.unquote(value[5:])
    else:
        value = urllib.parse.unquote(value)
    path = Path(os.path.normpath(os.path.expanduser(value)))
    for _ in range(4):
        if (path / "steamapps" / "workshop").is_dir():
            break
        if path.name.lower() in {"steamapps", "workshop", "content", "431960"}:
            path = path.parent
            continue
        break
    return path


def config_dir() -> Path:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base / "wekde" / "wallpaper"


def translated_dir(base_id: str) -> Path:
    xdg_data = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg_data) if xdg_data else Path.home() / ".local" / "share"
    return base / "wallpaperEngineKde" / "translated" / base_id


def resolve_case_insensitive_path(root_dir: Path, rel_path: str) -> Optional[Path]:
    """Resolve `rel_path` inside `root_dir`, matching path components case-insensitively."""
    rel_clean = rel_path.replace("\\", "/").lstrip("/")
    if not rel_clean:
        return None
    parts = [p for p in rel_clean.split("/") if p and p != "."]
    if any(p == ".." for p in parts):
        return None
    exact = root_dir.joinpath(*parts)
    if exact.is_file():
        return exact
    cur = root_dir
    for part in parts:
        if not cur.is_dir():
            return None
        cand = cur / part
        if cand.exists():
            cur = cand
            continue
        part_lower = part.lower()
        matched = None
        try:
            for child in sorted(cur.iterdir()):
                if child.name.lower() == part_lower:
                    matched = child
                    break
        except OSError:
            return None
        if matched is None:
            return None
        cur = matched
    return cur if cur.is_file() else None


def backup_original_base(trans_dir: Path) -> Path:
    """Save an immutable snapshot of scene.json, bindings.json, and materials/*.json."""
    orig_dir = trans_dir / ".wek_base_orig"
    marker = orig_dir / ".snapshot_complete"
    if marker.is_file():
        return orig_dir

    if orig_dir.exists():
        shutil.rmtree(orig_dir, ignore_errors=True)
    orig_dir.mkdir(parents=True, exist_ok=True)

    for fname in ("scene.json", "bindings.json", "project.json"):
        src = trans_dir / fname
        if src.is_file():
            shutil.copy2(src, orig_dir / fname)

    mdir = trans_dir / "materials"
    if mdir.is_dir():
        for rootp, _dirs, files in os.walk(mdir):
            for fn in files:
                if fn.endswith(".json"):
                    src_p = Path(rootp) / fn
                    rel_p = src_p.relative_to(trans_dir)
                    dst_p = orig_dir / rel_p
                    dst_p.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src_p, dst_p)

    atomic_write_bytes(marker, b"1\n")
    return orig_dir


def restore_original_base_and_clean(base_dir: Optional[Path], trans_dir: Path, base_id: str) -> None:
    """Restore `.wek_base_orig` into `trans_dir` and purge all previous preset artifacts."""
    orig_dir = trans_dir / ".wek_base_orig"
    if (orig_dir / ".snapshot_complete").is_file():
        for rootp, _dirs, files in os.walk(orig_dir):
            for fn in files:
                if fn == ".snapshot_complete":
                    continue
                src_p = Path(rootp) / fn
                rel_p = src_p.relative_to(orig_dir)
                dst_p = trans_dir / rel_p
                dst_p.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_p, dst_p)

    # Also restore any in-place `_wek_orig_usertextures` if `.wek_base_orig` didn't exist previously
    _revert_inline_orig_markers(trans_dir)

    # Purge old `wek-preset-*` folders in base_dir and trans_dir
    for root in [r for r in (base_dir, trans_dir) if r is not None and r.is_dir()]:
        try:
            for item in list(root.iterdir()):
                if item.name.startswith("wek-preset-"):
                    if item.is_symlink() or item.is_file():
                        item.unlink()
                    elif item.is_dir():
                        shutil.rmtree(item, ignore_errors=True)
        except OSError:
            pass

        mdir = root / "materials"
        if mdir.is_dir():
            try:
                for item in list(mdir.iterdir()):
                    if item.name.startswith("wek_preset_") and item.name.endswith(".tex"):
                        item.unlink()
                    elif item.name.startswith("wek-preset-") and item.is_dir():
                        shutil.rmtree(item, ignore_errors=True)
            except OSError:
                pass


def _revert_inline_orig_markers(trans_dir: Path) -> None:
    """Revert `_wek_orig_usertextures` and `_wek_orig_textures` in materials and scene.json."""
    def revert_passes(passes_list) -> bool:
        if not isinstance(passes_list, list):
            return False
        changed = False
        for pas in passes_list:
            if not isinstance(pas, dict):
                continue
            if "_wek_orig_usertextures" in pas:
                pas["usertextures"] = pas.pop("_wek_orig_usertextures")
                changed = True
            if "_wek_orig_textures" in pas:
                orig_t = pas.pop("_wek_orig_textures")
                if orig_t is None:
                    pas.pop("textures", None)
                else:
                    pas["textures"] = orig_t
                changed = True
        return changed

    mdir = trans_dir / "materials"
    if mdir.is_dir():
        for rootp, _dirs, files in os.walk(mdir):
            for fn in files:
                if not fn.endswith(".json"):
                    continue
                p = Path(rootp) / fn
                doc = read_json(p)
                if doc and revert_passes(doc.get("passes")):
                    try:
                        atomic_write_json(p, doc, indent=2)
                    except OSError:
                        pass

    sjson = trans_dir / "scene.json"
    sdoc = read_json(sjson)
    if sdoc:
        schanged = False

        def walk_revert(node):
            nonlocal schanged
            if isinstance(node, dict):
                if revert_passes(node.get("passes")):
                    schanged = True
                for ikey in ("instanceoverride", "instance"):
                    inst = node.get(ikey)
                    if isinstance(inst, dict):
                        if "_wek_orig_usertextures" in inst:
                            inst["usertextures"] = inst.pop("_wek_orig_usertextures")
                            schanged = True
                        if "_wek_orig_textures" in inst:
                            ot = inst.pop("_wek_orig_textures")
                            if ot is None:
                                inst.pop("textures", None)
                            else:
                                inst["textures"] = ot
                            schanged = True
                for v in node.values():
                    if isinstance(v, (dict, list)):
                        walk_revert(v)
            elif isinstance(node, list):
                for el in node:
                    if isinstance(el, (dict, list)):
                        walk_revert(el)

        walk_revert(sdoc)
        if schanged:
            try:
                atomic_write_json(sjson, sdoc, indent=2)
            except OSError:
                pass


def ensure_base_translated(base_dir: Path, base_id: str, base_data: Dict[str, Any]) -> Tuple[Path, bool]:
    """Ensure a scene base is extracted into `translated/<baseId>/` and validate scene.json."""
    trans = translated_dir(base_id)
    if str(base_data.get("type") or "").lower() != "scene":
        return trans, True

    sjson = trans / "scene.json"
    if sjson.is_file() and read_json(sjson) is not None:
        return trans, True

    # Check if base_dir already has a loose scene.json
    loose_scene = base_dir / "scene.json"
    pkg = base_dir / "scene.pkg"
    if not pkg.is_file():
        wfile = str(base_data.get("file") or "scene.json").replace("\\", "/")
        alt_pkg = (base_dir / wfile).with_suffix(".pkg")
        if alt_pkg.is_file():
            pkg = alt_pkg

    if pkg.is_file():
        translator = _SCRIPT_DIR / "translate_pkg.py"
        if not translator.is_file():
            return trans, False
        try:
            res = subprocess.run(
                [sys.executable, str(translator), str(pkg)],
                capture_output=True, text=True, timeout=120,
            )
            if res.returncode != 0:
                print(f"WARN translate_pkg exited {res.returncode}: {res.stderr.strip()}", flush=True)
        except Exception as exc:
            print(f"WARN translate_pkg exception for {base_id}: {exc}", flush=True)
            return trans, False
    elif loose_scene.is_file():
        translator_dir = _SCRIPT_DIR / "translate.py"
        if translator_dir.is_file():
            try:
                subprocess.run(
                    [sys.executable, str(translator_dir), str(base_dir)],
                    capture_output=True, text=True, timeout=120,
                )
            except Exception:
                pass

    ok = sjson.is_file() and read_json(sjson) is not None
    return trans, ok


def build_validated_tex_from_asset(src_file: Path) -> Optional[bytes]:
    """Build and validate a TEXV0005 PNG-in-TEX container from an image, GIF, or video frame."""
    if not HAS_PIL or not HAS_PNG2TEX:
        return None
    ext = src_file.suffix.lower()
    tmp_frame = None
    try:
        target_img_path = src_file
        if ext in VIDEO_EXTS:
            if not shutil.which("ffmpeg"):
                return None
            fd, tmp_name = tempfile.mkstemp(suffix=".png", prefix=".wek_vframe_")
            os.close(fd)
            tmp_frame = Path(tmp_name)
            res = subprocess.run(
                [
                    "ffmpeg", "-y", "-loglevel", "error",
                    "-i", str(src_file), "-frames:v", "1", str(tmp_frame),
                ],
                capture_output=True, timeout=30,
            )
            if res.returncode != 0 or not tmp_frame.is_file() or tmp_frame.stat().st_size == 0:
                return None
            target_img_path = tmp_frame

        with Image.open(target_img_path) as im:
            try:
                im.seek(0)
            except EOFError:
                pass
            rgba = im.convert("RGBA")
            tex_bytes = png2tex.build_tex(rgba)

        if not png2tex.validate_tex_bytes(tex_bytes):
            return None
        return tex_bytes
    except Exception as exc:
        print(f"WARN failed to build .tex from {src_file}: {exc}", flush=True)
        return None
    finally:
        if tmp_frame and tmp_frame.exists():
            try:
                tmp_frame.unlink()
            except OSError:
                pass


def find_fallback_image(
    preset_id: str,
    preset_dir: Path,
    preset_data: Dict[str, Any],
    orig_filename: str,
    allow_preview: bool = True,
) -> Tuple[Optional[Path], bool]:
    """Locate a user fallback or preview image. Returns (path, is_preview_fallback)."""
    # 1. Check user-supplied fallback directory: ~/.config/wekde/preset-fallbacks/<presetId>/
    user_fb_dir = config_dir().parent / "preset-fallbacks" / preset_id
    if user_fb_dir.is_dir():
        exact = resolve_case_insensitive_path(user_fb_dir, orig_filename)
        if exact:
            return exact, False
        for child in sorted(user_fb_dir.iterdir()):
            if child.is_file() and child.suffix.lower() in IMAGE_EXTS:
                return child, False

    # 2. Check if the filename exists anywhere inside preset_dir
    for sub in ("files", "media", "assets", "images", ""):
        cand = resolve_case_insensitive_path(preset_dir / sub if sub else preset_dir, orig_filename)
        if cand and cand.name.lower() not in {"preview.jpg", "preview.png", "preview.gif", "preview.webp"}:
            return cand, False

    if not allow_preview:
        return None, False

    # 3. Preview fallback (explicitly flagged so the UI warns the user)
    prev_name = str(preset_data.get("preview") or "").strip()
    candidates = []
    if prev_name:
        candidates.append(preset_dir / prev_name)
    for ext in ("preview.jpg", "preview.jpeg", "preview.png", "preview.webp", "preview.gif"):
        candidates.append(preset_dir / ext)
    for cand in candidates:
        if cand.is_file() and cand.stat().st_size > 0:
            return cand, True
    return None, False


def normalize_candidate_string(raw: str) -> str:
    s = raw.strip()
    if s.startswith("file://"):
        parsed = urllib.parse.urlparse(s)
        s = urllib.parse.unquote(parsed.path or s[7:])
    else:
        s = urllib.parse.unquote(s)
    s = s.replace("\\", "/")
    while s.startswith("./"):
        s = s[2:]
    return s


def is_relative_preset_asset(s: str, preset_dir: Path) -> Optional[Tuple[Path, str]]:
    """If `s` refers to a relative file inside `preset_dir`, return (resolved_path, norm_rel_path)."""
    if not s or s.startswith("/") or WIN_ABS_RE.match(s):
        return None
    s_lower = s.lower()
    if s_lower in {"project.json", "scene.json", "scene.pkg"}:
        return None
    if any(s_lower.startswith(pref) for pref in RELATIVE_ASSET_PREFIXES) or MEDIA_EXT_RE.search(s_lower):
        resolved = resolve_case_insensitive_path(preset_dir, s)
        if resolved is not None:
            rel_actual = resolved.relative_to(preset_dir).as_posix()
            return resolved, rel_actual
    return None


def stage_preset_chain(
    chain: List[Tuple[str, Dict[str, Any]]],
    content_root: Path,
    base_dir: Path,
    trans_dir: Path,
    base_type: str,
    allow_preview_fallback: bool = True,
) -> Tuple[Dict[str, Any], Dict[str, str], List[Dict[str, str]]]:
    """Stage assets for all presets in `chain`, returning (merged_props, tex_map, missing_warnings)."""
    presets = [(pid, data) for pid, data in chain if isinstance(data.get("preset"), dict)]
    merged: Dict[str, Any] = {}
    staged_tex_map: Dict[str, str] = {}
    missing_warnings: List[Dict[str, str]] = []

    for pid, pdata in reversed(presets):
        pdir = content_root / pid
        prefix = f"wek-preset-{pid}"
        stage_root_base = base_dir / prefix

        # Copy preset's `files/` directory into `<baseDir>/wek-preset-<pid>/files/` if present
        src_files_dir = resolve_case_insensitive_path(pdir, "files")
        if src_files_dir is None and (pdir / "files").is_dir():
            src_files_dir = pdir / "files"
        else:
            # Check case-insensitively for a directory named `files`
            if pdir.is_dir():
                for ch in pdir.iterdir():
                    if ch.is_dir() and ch.name.lower() == "files":
                        src_files_dir = ch
                        break
        if src_files_dir and src_files_dir.is_dir():
            dest_files = stage_root_base / "files"
            dest_files.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src_files_dir, dest_files, dirs_exist_ok=True)

        def transform_val(key: str, val: Any) -> Any:
            if isinstance(val, list):
                return [transform_val(key, v) for v in val]
            if isinstance(val, dict):
                return {k: transform_val(k, v) for k, v in val.items()}
            if not isinstance(val, str) or not val.strip():
                return val

            s = normalize_candidate_string(val)
            src_file: Optional[Path] = None
            rel_subpath: Optional[str] = None

            rel_match = is_relative_preset_asset(s, pdir)
            if rel_match is not None:
                src_file, rel_subpath = rel_match
            elif s.lower().startswith("files/"):
                # Referenced `files/...` that was not in `pdir`; check if base_dir already has it
                base_cand = resolve_case_insensitive_path(base_dir, s)
                if base_cand is not None:
                    return base_cand.relative_to(base_dir).as_posix()
                fb_path, is_prev = find_fallback_image(
                    pid, pdir, pdata, Path(s).name, allow_preview=allow_preview_fallback
                )
                if fb_path is not None:
                    src_file = fb_path
                    try:
                        h8 = hashlib.sha256(src_file.read_bytes()).hexdigest()[:8]
                    except OSError:
                        h8 = "fb"
                    rel_subpath = f"files/{fb_path.stem}_{h8}{fb_path.suffix}"
                    missing_warnings.append({
                        "key": str(key),
                        "original": val,
                        "fallback": fb_path.name,
                        "is_preview": "true" if is_prev else "false",
                    })
                    print(
                        f"WARN_MISSING_EXTERNAL_ASSET key={key} original={val!r} fallback={fb_path.name!r}",
                        flush=True,
                    )
                else:
                    raise FileNotFoundError(f"Preset #{pid} references missing file: {val}")
            elif WIN_ABS_RE.match(s) or (s.startswith("/") and not Path(s).is_file() and MEDIA_EXT_RE.search(s)):
                orig_name = Path(s).name
                fb_path, is_prev = find_fallback_image(
                    pid, pdir, pdata, orig_name, allow_preview=allow_preview_fallback
                )
                if fb_path is not None:
                    src_file = fb_path
                    # Use a clean ASCII filename for web/scene compatibility
                    clean_ext = fb_path.suffix.lower() or ".jpg"
                    clean_key = re.sub(r"[^a-zA-Z0-9_]", "_", str(key))
                    try:
                        h8 = hashlib.sha256(fb_path.read_bytes()).hexdigest()[:8]
                    except OSError:
                        h8 = "fb"
                    rel_subpath = f"files/fallback_{clean_key}_{h8}{clean_ext}"
                    missing_warnings.append({
                        "key": str(key),
                        "original": val,
                        "fallback": fb_path.name,
                        "is_preview": "true" if is_prev else "false",
                    })
                    print(
                        f"WARN_MISSING_EXTERNAL_ASSET key={key} original={val!r} fallback={fb_path.name!r}",
                        flush=True,
                    )
                else:
                    missing_warnings.append({
                        "key": str(key),
                        "original": val,
                        "fallback": "",
                        "is_preview": "false",
                    })
                    print(
                        f"WARN_MISSING_EXTERNAL_ASSET key={key} original={val!r} fallback=none",
                        flush=True,
                    )
                    return val

            if src_file is None or rel_subpath is None:
                return val

            # Stage into `<baseDir>/wek-preset-<pid>/<rel_subpath>`
            staged_rel = f"{prefix}/{rel_subpath}"
            dest_in_base = base_dir / staged_rel
            dest_in_base.parent.mkdir(parents=True, exist_ok=True)
            if not dest_in_base.exists() or dest_in_base.stat().st_size != src_file.stat().st_size:
                shutil.copy2(src_file, dest_in_base)

            # For scene wallpapers, build a validated .tex with a content hash to bust TextureCache
            if base_type == "scene" and HAS_PIL and HAS_PNG2TEX:
                tex_bytes = build_validated_tex_from_asset(src_file)
                if tex_bytes is not None:
                    h8 = hashlib.sha256(tex_bytes[:4096] + str(src_file.stat().st_size).encode()).hexdigest()[:8]
                    safe_key = re.sub(r"[^a-zA-Z0-9_]", "_", str(key))
                    tex_name = f"wek_preset_{pid}_{safe_key}_{h8}"
                    atomic_write_bytes(trans_dir / "materials" / f"{tex_name}.tex", tex_bytes)
                    staged_tex_map[str(key)] = tex_name

            # WE web wallpapers expect Windows-style absolute paths and
            # prepend "file:///" themselves; a base-relative path would
            # resolve to file:///wek-preset-... and never load.
            if base_type == "web":
                return str(dest_in_base.resolve())
            return staged_rel

        raw_preset = pdata.get("preset") or {}
        resolved_map = {k: transform_val(k, v) for k, v in raw_preset.items()}
        merged.update(resolved_map)

        # Link `<baseDir>/wek-preset-<pid>` into `translated/<baseId>/wek-preset-<pid>` without duplicating disk space
        if stage_root_base.is_dir() and trans_dir != base_dir and (base_type == "scene" or trans_dir.is_dir()):
            trans_stage = trans_dir / prefix
            trans_dir.mkdir(parents=True, exist_ok=True)
            if trans_stage.is_symlink() or trans_stage.is_file():
                trans_stage.unlink()
            elif trans_stage.is_dir():
                shutil.rmtree(trans_stage, ignore_errors=True)
            try:
                os.symlink(stage_root_base, trans_stage)
            except OSError:
                shutil.copytree(stage_root_base, trans_stage, dirs_exist_ok=True)

    return merged, staged_tex_map, missing_warnings


def patch_scene_usertextures(trans_dir: Path, staged_tex_map: Dict[str, str]) -> int:
    """Non-destructively bind `usertextures` slots in `materials/*.json` and `scene.json`."""
    if not staged_tex_map or not trans_dir.is_dir():
        return 0
    patched = 0
    lower_map = {k.lower(): v for k, v in staged_tex_map.items()}

    def patch_passes(passes_list) -> bool:
        nonlocal patched
        if not isinstance(passes_list, list):
            return False
        changed_local = False
        for pas in passes_list:
            if not isinstance(pas, dict):
                continue
            ut = pas.get("_wek_orig_usertextures") or pas.get("usertextures")
            if not isinstance(ut, list):
                continue
            orig_texs = pas.get("_wek_orig_textures") if "_wek_orig_textures" in pas else pas.get("textures")
            texs = list(orig_texs) if isinstance(orig_texs, list) else []
            # Never pad with None (`null`); pad with empty string `""` if shorter
            while len(texs) < len(ut):
                texs.append("")
            matched_any = False
            for idx, item in enumerate(ut):
                prop_name = ""
                if isinstance(item, str):
                    prop_name = item.strip().lower()
                elif isinstance(item, dict):
                    prop_name = str(item.get("name") or item.get("user") or "").strip().lower()
                if prop_name and prop_name in lower_map:
                    texs[idx] = lower_map[prop_name]
                    matched_any = True
            if matched_any:
                if "_wek_orig_usertextures" not in pas:
                    pas["_wek_orig_usertextures"] = list(ut)
                if "_wek_orig_textures" not in pas:
                    pas["_wek_orig_textures"] = list(orig_texs) if isinstance(orig_texs, list) else None
                pas["textures"] = texs
                pas.pop("usertextures", None)
                changed_local = True
                patched += 1
        return changed_local

    mdir = trans_dir / "materials"
    if mdir.is_dir():
        for rootp, _dirs, files in os.walk(mdir):
            for fn in files:
                if not fn.endswith(".json"):
                    continue
                p = Path(rootp) / fn
                doc = read_json(p)
                if doc and patch_passes(doc.get("passes")):
                    atomic_write_json(p, doc, indent=2)

    sjson = trans_dir / "scene.json"
    sdoc = read_json(sjson)
    if sdoc:
        s_changed = False

        def walk_scene(node):
            nonlocal s_changed, patched
            if isinstance(node, dict):
                if patch_passes(node.get("passes")):
                    s_changed = True
                for ikey in ("instanceoverride", "instance"):
                    inst = node.get(ikey)
                    if isinstance(inst, dict):
                        ut = inst.get("_wek_orig_usertextures") or inst.get("usertextures")
                        if isinstance(ut, list):
                            orig_t = inst.get("_wek_orig_textures") if "_wek_orig_textures" in inst else inst.get("textures")
                            texs = list(orig_t) if isinstance(orig_t, list) else []
                            while len(texs) < len(ut):
                                texs.append("")
                            m_any = False
                            for idx, item in enumerate(ut):
                                pname = (
                                    item.strip().lower()
                                    if isinstance(item, str)
                                    else str((item or {}).get("name") or (item or {}).get("user") or "").strip().lower()
                                )
                                if pname and pname in lower_map:
                                    texs[idx] = lower_map[pname]
                                    m_any = True
                            if m_any:
                                if "_wek_orig_usertextures" not in inst:
                                    inst["_wek_orig_usertextures"] = list(ut)
                                if "_wek_orig_textures" not in inst:
                                    inst["_wek_orig_textures"] = list(orig_t) if isinstance(orig_t, list) else None
                                inst["textures"] = texs
                                inst.pop("usertextures", None)
                                s_changed = True
                                patched += 1
                for v in node.values():
                    if isinstance(v, (dict, list)):
                        walk_scene(v)
            elif isinstance(node, list):
                for el in node:
                    if isinstance(el, (dict, list)):
                        walk_scene(el)

        walk_scene(sdoc)
        if s_changed:
            atomic_write_json(sjson, sdoc, indent=2)

    return patched


def sync_bindings_manifest(trans_dir: Path, base_id: str, extra_keys: Set[str]) -> None:
    """Keep `bindings.json` and `~/.config/wekde/wallpaper/<baseId>_bindings.json` in sync."""
    bpath = trans_dir / "bindings.json"
    existing: Set[str] = set()
    if bpath.is_file():
        try:
            arr = json.loads(bpath.read_text(encoding="utf-8", errors="replace"))
            if isinstance(arr, list):
                existing.update(str(x) for x in arr)
        except Exception:
            pass
    merged_binds = sorted(existing.union(extra_keys))
    if trans_dir.is_dir():
        try:
            atomic_write_json(bpath, merged_binds, indent=2)
        except OSError:
            pass
    cfg_bpath = config_dir() / f"{base_id}_bindings.json"
    try:
        cfg_bpath.parent.mkdir(parents=True, exist_ok=True)
        atomic_write_json(cfg_bpath, merged_binds, indent=2)
    except OSError:
        pass


def reset_base_preset(lib_arg: Optional[str], base_id: str, appid: str = APPID_DEFAULT) -> int:
    """Reset a base wallpaper back to its original state, removing all preset staging and overrides."""
    base_dir: Optional[Path] = None
    if lib_arg:
        lib = normalize_library(lib_arg)
        cand = lib / "steamapps" / "workshop" / "content" / appid / base_id
        if cand.is_dir():
            base_dir = cand
    trans_dir = translated_dir(base_id)
    restore_original_base_and_clean(base_dir, trans_dir, base_id)

    cfg_path = config_dir() / f"{base_id}.json"
    if cfg_path.is_file():
        existing = read_json(cfg_path) or {}
        existing["user_props"] = {}
        existing.pop("applied_preset", None)
        existing.pop("missing_external_assets", None)
        try:
            atomic_write_json(cfg_path, existing, indent=2)
        except OSError as exc:
            return fail(f"could not reset {cfg_path}: {exc}")

    print(f"OK reset base={base_id}", flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Apply or reset a WE Workshop preset")
    ap.add_argument("--library", default="", help="Steam library path or file:// URL")
    ap.add_argument("--preset", default="", help="outer preset workshop id")
    ap.add_argument("--base", required=True, help="downloaded base workshop id")
    ap.add_argument("--appid", default=APPID_DEFAULT)
    ap.add_argument("--reset", action="store_true", help="restore base wallpaper to original state")
    ap.add_argument("--no-preview-fallback", action="store_true", help="do not use preview.jpg for missing external Windows paths")
    args = ap.parse_args()

    if args.reset:
        return reset_base_preset(args.library, str(args.base).strip(), args.appid)

    if not args.library or not args.preset:
        return fail("--library and --preset are required unless --reset is used")

    lib = normalize_library(args.library)
    content = lib / "steamapps" / "workshop" / "content" / args.appid
    if not content.is_dir():
        return fail(f"workshop content not found: {content}")

    chain: List[Tuple[str, Dict[str, Any]]] = []
    seen: Set[str] = set()
    cur = str(args.preset).strip()
    while cur and cur not in seen and len(chain) < MAX_CHAIN:
        seen.add(cur)
        data = read_json(content / cur / "project.json")
        if data is None:
            return fail(f"project.json missing/unreadable for item #{cur}")
        chain.append((cur, data))
        if data.get("file") and data.get("type"):
            break
        dep = data.get("dependency")
        if not dep:
            return fail(f"item #{cur} has no file/type and no dependency")
        cur = str(dep).strip()
    else:
        return fail("dependency chain too long or cyclic")

    if not chain:
        return fail("empty dependency chain")

    base_id, base_data = chain[-1]
    if not (base_data.get("file") and base_data.get("type")):
        return fail(f"dependency chain did not end in a renderable base (#{base_id})")
    if str(args.base).strip() != base_id:
        print(f"WARN requested base #{args.base}, chain ends at #{base_id}", flush=True)

    base_dir = content / base_id
    if not base_dir.is_dir():
        return fail(f"base content not downloaded: {base_dir}")

    presets = [pid for pid, data in chain if isinstance(data.get("preset"), dict)]
    if not presets:
        return fail(f"preset #{args.preset} has no preset data")

    base_type = str(base_data.get("type") or "scene").strip().lower()
    trans_dir, trans_ok = ensure_base_translated(base_dir, base_id, base_data)
    if base_type == "scene" and not trans_ok:
        return fail(f"base scene #{base_id} could not be translated into {trans_dir}")

    # 1. Backup original base files once, then restore clean state before applying this preset
    if base_type == "scene" and trans_dir.is_dir():
        backup_original_base(trans_dir)
    restore_original_base_and_clean(base_dir, trans_dir, base_id)

    # 2. Transactional staging + .tex generation + usertextures binding
    try:
        merged, staged_tex_map, missing_warnings = stage_preset_chain(
            chain,
            content,
            base_dir,
            trans_dir,
            base_type,
            allow_preview_fallback=not args.no_preview_fallback,
        )
        tex_patched = 0
        if base_type == "scene" and staged_tex_map:
            tex_patched = patch_scene_usertextures(trans_dir, staged_tex_map)
            if tex_patched == 0:
                print(
                    f"WARN_UNBOUND_PRESET_TEXTURES keys={list(staged_tex_map.keys())}",
                    flush=True,
                )
        if base_type == "scene":
            sync_bindings_manifest(trans_dir, base_id, set(merged.keys()))
    except Exception as exc:
        restore_original_base_and_clean(base_dir, trans_dir, base_id)
        return fail(f"preset staging failed (rolled back cleanly): {exc}")

    cfg_path = config_dir() / f"{base_id}.json"
    try:
        existing = read_json(cfg_path) or {}
        existing["user_props"] = merged
        existing["applied_preset"] = str(args.preset).strip()
        if missing_warnings:
            existing["missing_external_assets"] = missing_warnings
        else:
            existing.pop("missing_external_assets", None)
        atomic_write_json(cfg_path, existing, indent=2)
        preset_id_clean = str(args.preset).strip()
        if preset_id_clean and preset_id_clean != base_id:
            preset_cfg_path = config_dir() / f"{preset_id_clean}.json"
            preset_cfg = read_json(preset_cfg_path) or {}
            preset_cfg["user_props"] = merged
            preset_cfg["applied_preset"] = preset_id_clean
            preset_cfg["base_id"] = base_id
            if missing_warnings:
                preset_cfg["missing_external_assets"] = missing_warnings
            else:
                preset_cfg.pop("missing_external_assets", None)
            atomic_write_json(preset_cfg_path, preset_cfg, indent=2)
    except OSError as exc:
        restore_original_base_and_clean(base_dir, trans_dir, base_id)
        return fail(f"could not write {cfg_path}: {exc}")

    title = str(base_data.get("title") or base_id)
    print(
        f"OK base={base_id} title={title} preset={args.preset} "
        f"props={len(merged)} tex_patched={tex_patched} "
        f"warnings={len(missing_warnings)} "
        f"chain={'->'.join(pid for pid, _ in chain)}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
