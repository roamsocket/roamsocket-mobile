#!/usr/bin/env python3
"""
Regenerate platform icon assets (icon.png, icon.icns, icon.ico, tray-light/dark)
from the SVG/PNG masters in /icons.

Run from repo root:
    python3 desktop-server/scripts/icons/build_icons.py

Output: desktop-server/build/{icon.png, icon-1024.png, icon-light.png,
        icon-dark.png, icon-color.png, icon.icns, icon.ico,
        tray-light.png, tray-dark.png, tray-light-<n>.png, tray-dark-<n>.png}

macOS-only: relies on /usr/bin/iconutil. PIL is required for PNG decode +
the ICO multi-res writer. Both ship with macOS by default; install Pillow
via `pip3 install --user pillow` if missing.
"""
from __future__ import annotations

import io
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

from PIL import Image

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
ICON_DIR = REPO_ROOT / "icons"
BUILD_DIR = REPO_ROOT / "desktop-server" / "build"


def sips_resize(src: pathlib.Path, size: int, out: pathlib.Path) -> None:
    subprocess.run(
        ["sips", "-s", "format", "png", "-z", str(size), str(size), str(src), "--out", str(out)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def build_master_pngs() -> None:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    for variant in ("color", "light", "dark"):
        sips_resize(ICON_DIR / f"{variant}.png", 1024, BUILD_DIR / f"icon-{variant}.png")
    sips_resize(ICON_DIR / "color.png", 512, BUILD_DIR / "icon.png")
    sips_resize(ICON_DIR / "color.png", 1024, BUILD_DIR / "icon-1024.png")


def build_icns() -> None:
    # iconutil is strict: the iconset directory must end in `.iconset`.
    iconset = pathlib.Path(tempfile.mkdtemp(prefix="roam-", suffix=".iconset", dir=BUILD_DIR))
    try:
        for size, name in [
            (16, "16"),
            (32, "32"),
            (32, "32@2x"),
            (64, "64"),
            (128, "128"),
            (128, "128@2x"),
            (256, "256"),
            (256, "256@2x"),
            (512, "512"),
            (512, "512@2x"),
        ]:
            sips_resize(BUILD_DIR / "icon-color.png", size, iconset / f"icon_{name}.png")
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(BUILD_DIR / "icon.icns")],
            check=True,
        )
    finally:
        shutil.rmtree(iconset, ignore_errors=True)


def build_ico() -> None:
    color = Image.open(ICON_DIR / "color.png").convert("RGBA")
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    pngs: list[tuple[int, int, bytes]] = []
    for w, h in sizes:
        buf = io.BytesIO()
        color.resize((w, h), Image.LANCZOS).save(buf, format="PNG")
        pngs.append((w, h, buf.getvalue()))

    count = len(pngs)
    header_len = 6 + 16 * count
    dir_buf = bytearray(header_len)
    struct.pack_into("<HHH", dir_buf, 0, 0, 1, count)  # reserved, type=icon, count
    data = bytearray()
    offset = header_len
    for i, (w, h, blob) in enumerate(pngs):
        base = 6 + 16 * i
        dir_buf[base + 0] = w if w < 256 else 0
        dir_buf[base + 1] = h if h < 256 else 0
        dir_buf[base + 2] = 0  # color count
        dir_buf[base + 3] = 0  # reserved
        struct.pack_into("<HHII", dir_buf, base + 4, 1, 32, len(blob), offset)
        data += blob
        offset += len(blob)
    (BUILD_DIR / "icon.ico").write_bytes(bytes(dir_buf) + bytes(data))


def to_template(img: Image.Image, dark_template: bool) -> Image.Image:
    """Return a monochrome (black or white) silhouette with the source's alpha
    preserved, over a transparent background. macOS treats these as template
    images when `setTemplateImage(true)` is called on them."""
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    src = img.convert("RGBA").load()
    dst = out.load()
    fg = (0, 0, 0) if dark_template else (255, 255, 255)
    for y in range(img.size[1]):
        for x in range(img.size[0]):
            r, g, b, a = src[x, y]
            if a == 0:
                continue
            # Drop the white card background, keep everything else.
            if r > 240 and g > 240 and b > 240:
                continue
            # Drop near-black card backgrounds (dark.svg uses #100A16).
            if r < 32 and g < 32 and b < 32:
                continue
            dst[x, y] = (fg[0], fg[1], fg[2], a)
    return out


def build_tray_variants() -> None:
    """Tray icons in 16/24/32/48/64/128/256/512 plus 32px defaults."""
    light = Image.open(ICON_DIR / "light.png")
    dark = Image.open(ICON_DIR / "dark.png")
    light_tmpl = to_template(light, dark_template=True)  # dark glyph for light menu bar
    dark_tmpl = to_template(dark, dark_template=False)  # light glyph for dark menu bar
    sizes = [16, 24, 32, 48, 64, 128, 256, 512]
    for size in sizes:
        light_tmpl.resize((size, size), Image.LANCZOS).save(BUILD_DIR / f"tray-light-{size}.png")
        dark_tmpl.resize((size, size), Image.LANCZOS).save(BUILD_DIR / f"tray-dark-{size}.png")
    light_tmpl.resize((32, 32), Image.LANCZOS).save(BUILD_DIR / "tray-light.png")
    dark_tmpl.resize((32, 32), Image.LANCZOS).save(BUILD_DIR / "tray-dark.png")


def build_renderer_assets() -> None:
    """Copy icon variants into the renderer for use from HTML/CSS. We keep
    these small (64 + 128) because the renderer's brand mark is a 34px
    square and the favicon is even smaller. 1024 masters are kept only in
    `desktop-server/build/` and shipped as the app icon."""
    renderer_assets = REPO_ROOT / "desktop-server" / "src" / "renderer" / "assets"
    renderer_assets.mkdir(parents=True, exist_ok=True)
    for variant in ("color", "light", "dark"):
        src = Image.open(ICON_DIR / f"{variant}.png").convert("RGBA")
        for size in (64, 128):
            src.resize((size, size), Image.LANCZOS).save(renderer_assets / f"brand-{variant}-{size}.png")


def main() -> int:
    if not ICON_DIR.exists():
        print(f"[icons] missing source: {ICON_DIR}", file=sys.stderr)
        return 1
    if sys.platform != "darwin":
        print("[icons] note: iconutil is macOS-only; non-macOS skips the .icns", file=sys.stderr)
    build_master_pngs()
    if sys.platform == "darwin":
        build_icns()
    build_ico()
    build_tray_variants()
    build_renderer_assets()
    print(f"[icons] wrote assets to {BUILD_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
