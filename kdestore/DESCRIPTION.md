# WEPLUSforKDE — Wallpaper Engine for KDE Plasma 6

**Version:** 1.0.0  
**Author:** @vixtrs  
**License:** GPL-2.0-or-later  
**Category:** Plasma 6 → Wallpaper Plugins

## Summary

WEPLUSforKDE is an enhanced Wallpaper Engine plugin for KDE Plasma 6. It combines the native C++/Vulkan SceneViewer with a translator for Scene packages, a Workshop browser/downloader, a preset/dependency resolver, an audio/MPRIS bridge, and a multi-style desktop selector.

## Description

WEPLUSforKDE keeps the original native backend and adds:

- Scene package translation (`PKGV`, `TEXB0003`, GLSL/SPIR-V, SceneScript shims).
- Steam Workshop search, silent downloads, subscription/orphan auditing, and cleanup.
- Preset support with dependency resolution and non-destructive asset staging.
- PipeWire/PulseAudio FFT spectrum and MPRIS2 metadata/cover integration.
- Desktop carousel selector with Default, Glass, Simple, and Hyprland styles.
- Portable configuration: no personal user names or drive UUIDs in the release.

Wallpaper Engine assets are not included. You must own Wallpaper Engine on Steam and subscribe to the Workshop items you use.

## Requirements

KDE Plasma 6.0+, Qt 6.6+, Vulkan 1.2+, and `libWallpaperEngineKde.so`. Recommended: Plasma 6.2+, Qt 6.7+, Vulkan 1.3+, 16 GB RAM, and an SSD. See the repository `REQUIREMENTS.md` for details.

## Installation

Use **System Settings → Wallpaper → Get New Plugins…**, or install the package manually:

```bash
kpackagetool6 -t Plasma/Wallpaper -i com.github.catsout.wallpaperEngineKde
```

Restart Plasma after installation:

```bash
systemctl --user restart plasma-plasmashell.service
```

## Compatibility

This package keeps the upstream plugin id (`com.github.catsout.wallpaperEngineKde`) for drop-in compatibility with existing wallpapers and settings. Remove the original `wallpaper-engine-kde-plugin` package before installing this fork; both cannot be installed side by side.

## Credits

Based on `wallpaper-engine-kde-plugin` by catsout, `linux-wallpaperengine` by Almamu and contributors, and `Smart Video Wallpaper Reborn` by luisbocanegra. WEPLUSforKDE is maintained by @vixtrs.

## License

GPL-2.0-or-later.
