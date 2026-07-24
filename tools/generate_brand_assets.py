"""Create deterministic Android and Flutter assets from the approved logo."""

from pathlib import Path
from shutil import copyfile

from PIL import Image

SOURCE = Path(r"D:\algaguard-project\brand\algaguard-logo.png")
ROOT = Path(__file__).resolve().parents[1]


def padded(source: Image.Image, size: int, fraction: float) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    logo = source.copy().convert("RGBA")
    limit = round(size * fraction)
    logo.thumbnail((limit, limit), Image.Resampling.LANCZOS)
    canvas.alpha_composite(logo, ((size - logo.width) // 2, (size - logo.height) // 2))
    return canvas


def save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"Approved logo is missing: {SOURCE}")
    assets = ROOT / "assets" / "brand"
    assets.mkdir(parents=True, exist_ok=True)
    copyfile(SOURCE, assets / "algaguard-logo.png")
    with Image.open(SOURCE) as source:
        for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
            save(padded(source, size, 0.72), ROOT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}" / "ic_launcher.png")
        save(padded(source, 432, 0.46), ROOT / "android" / "app" / "src" / "main" / "res" / "drawable" / "algaguard_launcher_foreground.png")
        save(padded(source, 256, 0.70), ROOT / "android" / "app" / "src" / "main" / "res" / "drawable-nodpi" / "algaguard_splash.png")


if __name__ == "__main__":
    main()
