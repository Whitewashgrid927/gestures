#!/usr/bin/env python3
"""Package verified downloads without copying local filesystem/user metadata."""
import argparse
import hashlib
import plistlib
from pathlib import Path
import re
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ROOT_FILES = (".gitignore", "LICENSE", "README.md", "PRIVACY.md", "SECURITY.md")
DIRECTORIES = {
    "Sources": {".swift", ".metal"},
    "Tests": {".swift"},
    "Scripts": {".sh", ".py", ".swift"},
    "Resources": {".plist", ".entitlements", ".txt"},
}


def source_files():
    files = [ROOT / name for name in ROOT_FILES]
    for directory, extensions in DIRECTORIES.items():
        for path in (ROOT / directory).rglob("*"):
            if path.is_symlink():
                raise ValueError("Source package must not contain symlinks")
            if path.is_file() and path.suffix in extensions:
                files.append(path)
    return sorted(files)


def write_zip(destination, entries):
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, name in sorted(entries, key=lambda entry: entry[1]):
            if path.is_symlink() or not path.is_file():
                raise ValueError("Archive input must be a regular file")
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            mode = 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            info.extra = b""
            info.comment = b""
            archive.writestr(info, path.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    with (ROOT / "Resources/Info.plist").open("rb") as file:
        source_info = plistlib.load(file)
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", version):
        raise ValueError("Unexpected release version")
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if info[key] != source_info[key]:
            raise ValueError("App and source versions must match")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["xcrun", "stapler", "validate", str(app)], check=True)
    subprocess.run(["spctl", "--assess", "--type", "execute", str(app)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source_zip = output / f"Gestures-{version}-Source.zip"
    app_zip = output / f"Gestures-{version}-macOS-arm64.zip"
    # Exclusive creation avoids silently replacing an already published asset.
    if any(path.exists() for path in (source_zip, app_zip, output / "SHA256SUMS.txt")):
        raise FileExistsError("Choose an empty release output directory")
    write_zip(source_zip, [(p, f"Gestures-{version}-Source/{p.relative_to(ROOT).as_posix()}") for p in source_files()])
    app_files = []
    for path in app.rglob("*"):
        if path.is_symlink():
            raise ValueError("App package must not contain symlinks")
        if path.is_file():
            app_files.append((path, "Gestures.app/" + path.relative_to(app).as_posix()))
    write_zip(app_zip, app_files)
    with (output / "SHA256SUMS.txt").open("x") as checksums:
        for path in (source_zip, app_zip):
            checksums.write(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
    print(f"Prepared Gestures {version}: source, verified app, and checksums.")


if __name__ == "__main__":
    main()
