"""Build an installable RBZ without adding build artifacts to Git."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "sketchup"
OUTPUT = ROOT / "dist" / "homecad.rbz"


def build() -> Path:
    files = [SOURCE / "homecad.rb", *sorted((SOURCE / "homecad").rglob("*.rb"))]
    OUTPUT.parent.mkdir(exist_ok=True)
    with ZipFile(OUTPUT, "w", ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, path.relative_to(SOURCE).as_posix())
    return OUTPUT


if __name__ == "__main__":
    print(build())
