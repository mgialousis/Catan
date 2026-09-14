#!/usr/bin/env python3
"""Regenerate every launcher icon from one definition.

    python3 scripts/generate-app-icons.py

The artwork mirrors apps/mobile/android/app/src/main/res/drawable/
ic_launcher_custom.xml, which Android renders directly as a vector, so the
raster platforms and Android show the same picture. It is original work, not
traced from or imitative of any published game's branding.

Rasterising here rather than through a Flutter widget test is deliberate: the
software rasteriser in `flutter test` needs minutes per toImage() call, which
made a 25-file regeneration time out.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent / "apps" / "mobile"

OCEAN = (23, 108, 148)
RIM = (247, 239, 217)
GOLD = (231, 189, 88)
CLAY = (184, 93, 67)
FOREST = (58, 123, 82)
TOKEN = (248, 241, 223)
TOKEN_RING = (200, 135, 50)

# Design space is 48x48, matching the Android vector's viewport.
HEX = [(24, 5), (40, 14.5), (40, 33.5), (24, 43), (8, 33.5), (8, 14.5)]
FACES = [
    ([(24, 24), (9, 15), (24, 6), (39, 15)], GOLD),
    ([(24, 24), (39, 15), (39, 33), (24, 42)], CLAY),
    ([(24, 24), (24, 42), (9, 33), (9, 15)], FOREST),
]
DISCS = [(7, TOKEN), (4.5, TOKEN_RING), (2, TOKEN)]

# Supersample, then downsample: PIL's polygon fill has no antialiasing.
SS = 8


def render(size: int, background: bool = True, logo: float = 1.0) -> Image.Image:
    px = size * SS
    scale = px / 48
    image = Image.new("RGBA", (px, px), OCEAN + (255,) if background else (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    def place(point):
        x, y = point
        # Scale the mark about the centre so adaptive and maskable variants can
        # keep it inside their safe zones.
        return ((24 + (x - 24) * logo) * scale, (24 + (y - 24) * logo) * scale)

    if logo > 0:
        draw.polygon([place(p) for p in HEX], fill=RIM)
        for points, colour in FACES:
            draw.polygon([place(p) for p in points], fill=colour)
        cx, cy = place((24, 24))
        for radius, colour in DISCS:
            r = radius * logo * scale
            draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=colour)
    return image.resize((size, size), Image.LANCZOS)


def write(path: Path, size: int, *, background: bool = True, logo: float = 1.0,
          opaque: bool = False) -> None:
    image = render(size, background=background, logo=logo)
    if opaque:
        # iOS rejects launcher icons carrying an alpha channel.
        flat = Image.new("RGB", image.size, OCEAN)
        flat.paste(image, mask=image.split()[3])
        image = flat
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def main() -> None:
    written = 0
    # Android keeps PNG mipmaps even though the manifest points at the vector,
    # so they must not be left holding the stale template artwork.
    for density, size in {
        "mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192,
    }.items():
        write(ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png", size)
        written += 1

    for name, size in {
        "Icon-App-20x20@1x": 20, "Icon-App-20x20@2x": 40, "Icon-App-20x20@3x": 60,
        "Icon-App-29x29@1x": 29, "Icon-App-29x29@2x": 58, "Icon-App-29x29@3x": 87,
        "Icon-App-40x40@1x": 40, "Icon-App-40x40@2x": 80, "Icon-App-40x40@3x": 120,
        "Icon-App-60x60@2x": 120, "Icon-App-60x60@3x": 180,
        "Icon-App-76x76@1x": 76, "Icon-App-76x76@2x": 152,
        "Icon-App-83.5x83.5@2x": 167, "Icon-App-1024x1024@1x": 1024,
    }.items():
        write(
            ROOT / f"ios/Runner/Assets.xcassets/AppIcon.appiconset/{name}.png",
            size,
            opaque=True,
        )
        written += 1

    write(ROOT / "web/favicon.png", 32)
    write(ROOT / "web/icons/Icon-192.png", 192)
    write(ROOT / "web/icons/Icon-512.png", 512)
    # Maskable icons are cropped to a circle inscribed in the middle 80%.
    write(ROOT / "web/icons/Icon-maskable-192.png", 192, logo=0.66)
    write(ROOT / "web/icons/Icon-maskable-512.png", 512, logo=0.66)
    written += 5
    print(f"wrote {written} icons")


if __name__ == "__main__":
    main()
