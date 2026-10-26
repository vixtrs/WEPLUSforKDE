#!/usr/bin/env python3
"""Optimizador y Limpiador de ~/.local/share/wallpaperEngineKde/translated/ (v17).

- Elimina enlaces simbólicos rotos o huérfanos.
- Purga carpetas de wallpapers incompletas (sin scene.json).
- Limpia archivos temporales de portadas (.art_*.raw, .art_*.png, .art_seq,
  materials/.media_cover_*.tex, .wek_tmp_*, media_thumbnail.png.raw, cover_art.png,
  covertest.tex) y mueve cualquier backup (.bak*) fuera de translated/ hacia
  ~/.local/share/wallpaperEngineKde/backups_v17/.
- Muestra el resumen completo y el espacio liberado.
"""

import os
import re
import shutil

TRANS_ROOT = os.path.expanduser("~/.local/share/wallpaperEngineKde/translated")
BACKUP_ROOT = os.path.expanduser("~/.local/share/wallpaperEngineKde/backups_v17")

STALE_TEMP_PAT = re.compile(
    r"^(\.art_\d+\.(raw|png)|\.art_seq|\.wek_tmp_.*|\.media_cover_.*\.tex(\.tmp)?|"
    r"media_thumbnail\.png\.raw|cover_art\.png|covertest\.tex)$"
)


def optimize():
    if not os.path.exists(TRANS_ROOT):
        print(f"Directorio no encontrado: {TRANS_ROOT}")
        return

    freed_space = 0
    removed_items = 0
    broken_links = 0
    cleaned_temps = 0
    moved_backups = 0

    print(f"Analizando {TRANS_ROOT}...")

    for item in sorted(os.listdir(TRANS_ROOT)):
        path = os.path.join(TRANS_ROOT, item)
        if not os.path.isdir(path):
            continue

        scene_json = os.path.join(path, "scene.json")
        if not os.path.exists(scene_json):
            print(f"[-] Eliminando carpeta incompleta/huérfana: {item}")
            try:
                for root, _dirs, files in os.walk(path):
                    for f in files:
                        fp = os.path.join(root, f)
                        if not os.path.islink(fp):
                            freed_space += os.path.getsize(fp)
                shutil.rmtree(path, ignore_errors=True)
                removed_items += 1
            except Exception as e:
                print(f"    Error al borrar {item}: {e}")
            continue

        for root, _dirs, files in os.walk(path):
            for f in files:
                fp = os.path.join(root, f)
                if os.path.islink(fp):
                    target = os.readlink(fp)
                    if not os.path.exists(target):
                        try:
                            os.unlink(fp)
                            broken_links += 1
                        except Exception:
                            pass
                    continue

                if f.startswith("scene.json.bak") or f.endswith(".bak"):
                    os.makedirs(os.path.join(BACKUP_ROOT, item), exist_ok=True)
                    dst = os.path.join(BACKUP_ROOT, item, f)
                    try:
                        sz = os.path.getsize(fp)
                        shutil.move(fp, dst)
                        freed_space += sz
                        moved_backups += 1
                    except Exception:
                        pass
                    continue

                if STALE_TEMP_PAT.match(f):
                    try:
                        sz = os.path.getsize(fp)
                        os.unlink(fp)
                        freed_space += sz
                        cleaned_temps += 1
                    except Exception:
                        pass

    print("\n--- Optimización v17 Finalizada ---")
    print(f"Carpetas huérfanas eliminadas   : {removed_items}")
    print(f"Enlaces simbólicos rotos limpios: {broken_links}")
    print(f"Temporales/debug eliminados     : {cleaned_temps}")
    print(f"Backups movidos fuera del dir   : {moved_backups}")
    print(f"Espacio liberado en translated/ : {freed_space / (1024 * 1024):.2f} MB")


if __name__ == "__main__":
    optimize()
