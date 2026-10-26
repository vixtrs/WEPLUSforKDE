# WEPLUSforKDE — Requirements

These values are approximate and depend on the wallpaper type, resolution, effects, and number of monitors.

| Component | Minimum (1080p @ 30 FPS, 1 monitor) | Recommended (1440p/4K @ 55-60 FPS, 1-2 monitors) |
| :--- | :--- | :--- |
| Operating system | Linux with KDE Plasma 6.0+ (Wayland or X11), Qt 6.6+ | KDE Plasma 6.2+ (Wayland), Qt 6.7+, PipeWire |
| CPU | 4 cores / 4 threads (Intel Core i3 8th gen / AMD Ryzen 3 2200G or equivalent) | 6 cores / 12 threads or better (AMD Ryzen 5 5600X+ / Intel Core i5 12th gen+) |
| GPU | Integrated or dedicated GPU with Vulkan 1.2+ and 1 GB VRAM (Intel UHD 620 / AMD Vega / NVIDIA GTX 1050) | Dedicated GPU with Vulkan 1.3+ and 4 GB+ VRAM (AMD RX 6600+ / NVIDIA RTX 3060+) |
| RAM | 8 GB (the engine uses roughly 350-650 MB per complex Scene or WebEngine wallpaper) | 16 GB (about 1.3-1.7 GB RSS with two 4K scenes) |
| Storage | 2 GB free for the translation cache (`~/.local/share/wallpaperEngineKde/translated`) and SPIR-V | 10 GB+ on SSD/NVMe for fast extraction of large `.pkg` files and raw RGBA8/WAV assets |
| Software | `steam`, `python3` (3.10+), `mpv`, QtWebEngine, `libWallpaperEngineKde.so` | + `python-pillow`, `python-numpy`, `python-websockets`, `playerctl`, `ffmpeg`, `curl`, `kdotool` (optional, window minimize) |

## Distribution packages

Arch/CachyOS:

```bash
sudo pacman -S --needed python python-pillow python-numpy python-websockets playerctl ffmpeg curl mpv
```

Fedora:

```bash
sudo dnf install -y python3 python3-pillow python3-numpy python3-websockets playerctl ffmpeg curl mpv
```

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y python3 python3-pil python3-numpy python3-websockets playerctl ffmpeg curl mpv
```

openSUSE:

```bash
sudo zypper install -y python3 python3-Pillow python3-numpy python3-websockets playerctl ffmpeg curl mpv
```

## Native backend

Scene and video wallpapers require `libWallpaperEngineKde.so`. On Arch/CachyOS the usual package is `wallpaper-engine-kde-plugin-git` from the AUR. On other distributions, build the upstream C++/Vulkan backend and install it system-wide.

## Notes

- 60 FPS can crash `plasmashell` on some systems; 30 FPS is the safe default.
- The first Scene load can take tens of seconds while audio and textures are extracted and cached.
- Web wallpapers depend on QtWebEngine; WebGL support varies by distribution and driver.
