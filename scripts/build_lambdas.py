"""Build every Lambda deployment zip the same way, every time.

Terraform decides whether a Lambda changed by hashing its zip file. A normal
zip stores file timestamps, so the same code zipped twice gives two different
hashes and Terraform would redeploy every Lambda on every run. This script
fixes the timestamps, file order and permissions, so the same code always
produces the same zip (and the same hash).

Each folder in lambdas/ that has an index.py becomes lambdas/<folder>.zip.
"""
import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAMBDAS = ROOT / "lambdas"
FIXED_TIME = (2020, 1, 1, 0, 0, 0)


def wanted_files(folder):
    files = []
    for path in folder.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(folder)
        if "__pycache__" in rel.parts:
            continue
        if rel.parts == ("requirements.txt",):
            continue
        files.append(rel)
    return sorted(files, key=lambda r: r.as_posix())


def build_zip(folder, dest):
    if dest.exists():
        dest.unlink()
    files = wanted_files(folder)
    with zipfile.ZipFile(dest, "w") as zf:
        for rel in files:
            info = zipfile.ZipInfo(rel.as_posix(), date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o644 << 16
            zf.writestr(info, (folder / rel).read_bytes(), compresslevel=9)
    digest = hashlib.sha256(dest.read_bytes()).hexdigest()[:12]
    print(f"{dest.name}: {len(files)} files, sha256 {digest}")


def main():
    render_pdf = LAMBDAS / "render_pdf"
    if not (render_pdf / "fpdf").is_dir():
        sys.exit("render_pdf libraries are missing - install requirements.txt first")
    for folder in sorted(p for p in LAMBDAS.iterdir() if p.is_dir()):
        if (folder / "index.py").exists():
            build_zip(folder, LAMBDAS / f"{folder.name}.zip")


if __name__ == "__main__":
    main()