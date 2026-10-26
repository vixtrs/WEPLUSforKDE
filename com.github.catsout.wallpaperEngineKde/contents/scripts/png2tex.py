#!/usr/bin/env python3
"""Convert a PNG/JPEG/WebP into a Wallpaper-Engine `.tex` (PNG-in-TEX, TEXV0005).

v17 Enhancements:
- Atomic write via temporary file + fsync + os.replace() in destination directory,
  guaranteeing SceneViewer never reads a truncated/corrupt `.tex` mid-write.
- Automatic validation of the generated TEXV0005 / TEXI0001 / TEXB0003 container
  and embedded PNG signature before replacing the target file.
- Caps oversized source images (>1024px) to 1024px max dimension to prevent VRAM
  spikes and speed up mipmap generation while keeping full visual sharpness.

Usage: png2tex.py <src_image> <dest.tex>
"""
import io
import os
import struct
import sys
import tempfile

try:
    from PIL import Image
except ImportError:
    Image = None

MAX_COVER_DIM = 1024


def u32(x):
    return struct.pack("<I", int(x))


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=False)
    return buf.getvalue()


def build_tex(img):
    """Build a full-mip-chain TEXV0005 container around `img`."""
    base = img.convert("RGBA")
    w0, h0 = base.size
    if w0 <= 0 or h0 <= 0:
        raise ValueError(f"Invalid image dimensions: {w0}x{h0}")

    # Cap extreme dimensions to save VRAM and mip-generation latency
    if w0 > MAX_COVER_DIM or h0 > MAX_COVER_DIM:
        scale = min(MAX_COVER_DIM / float(w0), MAX_COVER_DIM / float(h0))
        w0 = max(1, int(round(w0 * scale)))
        h0 = max(1, int(round(h0 * scale)))
        base = base.resize((w0, h0), Image.LANCZOS)

    mips = [base]
    cur = base
    while True:
        nw = max(1, cur.width // 2)
        nh = max(1, cur.height // 2)
        if nw == cur.width and nh == cur.height:
            break
        cur = cur.resize((nw, nh), Image.LANCZOS)
        mips.append(cur.copy())

    header = (
        b"TEXV0005\x00"
        + b"TEXI0001\x00"
        + u32(0)
        + u32(2)
        + u32(w0)
        + u32(h0)
        + u32(w0)
        + u32(h0)
        + b"\x00\x00\x00\xff"
    )
    png0 = png_bytes(mips[0])
    data = (
        header
        + b"TEXB0003\x00"
        + u32(1)
        + u32(13)
        + u32(3)
        + u32(w0)
        + u32(h0)
        + u32(0)
        + u32(0)
        + u32(len(png0))
        + png0
    )
    for mip in mips[1:]:
        p = png_bytes(mip)
        data += u32(mip.width) + u32(mip.height) + u32(0) + u32(0) + u32(len(p)) + p
    return data


def validate_tex_bytes(data):
    """Verify TEXV0005/TEXI0001/TEXB0003 headers and first embedded PNG signature."""
    if len(data) < 100:
        return False
    if not data.startswith(b"TEXV0005\x00TEXI0001\x00"):
        return False
    if data[46:55] != b"TEXB0003\x00":
        return False
    if data[87:95] != b"\x89PNG\r\n\x1a\n":
        return False
    return True


def main():
    if len(sys.argv) != 3:
        print("usage: png2tex.py <src_image> <dest.tex>", file=sys.stderr)
        return 2
    src, dest = sys.argv[1], sys.argv[2]
    if Image is None:
        print("Pillow not available", file=sys.stderr)
        return 1
    if not os.path.isfile(src) or os.path.getsize(src) == 0:
        print(f"png2tex failed: source file missing or empty: {src}", file=sys.stderr)
        return 1

    tmp_path = None
    try:
        with Image.open(src) as im:
            im.load()
            tex = build_tex(im)

        if not validate_tex_bytes(tex):
            raise RuntimeError("Generated .tex failed header validation")

        dest_abs = os.path.abspath(dest)
        dest_dir = os.path.dirname(dest_abs)
        os.makedirs(dest_dir, exist_ok=True)

        fd, tmp_path = tempfile.mkstemp(prefix=".media_cover_", suffix=".tex.tmp", dir=dest_dir)
        with os.fdopen(fd, "wb") as fh:
            fh.write(tex)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, dest_abs)
        tmp_path = None
    except Exception as e:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        print(f"png2tex failed: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
