"""Validate and install only the exact HomeCAD RBZ payload."""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile

from .core import DevError, is_junction, sha256_file, tree_manifest


REQUIRED = {
    "homecad.rb", "homecad/main.rb", "homecad/runtime/dispatcher.rb",
    "homecad/core/metadata.rb", "homecad/core/mutation.rb", "homecad/core/geometry.rb",
    "homecad/core/primitives.rb", "homecad/core/mutations.rb",
    "homecad/core/architecture.rb", "homecad/core/furniture.rb",
}


def validate_rbz(path: Path, expected_version: str) -> dict[str, str]:
    try:
        with ZipFile(path) as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            if len(names) != len(set(names)):
                raise DevError("RBZ contains duplicate archive paths")
            for name in names:
                relative = PurePosixPath(name)
                if relative.is_absolute() or ".." in relative.parts or "\\" in name:
                    raise DevError(f"unsafe path in RBZ: {name!r}")
                if not (name == "homecad.rb" or name.startswith("homecad/")):
                    raise DevError(f"unexpected non-extension file in RBZ: {name}")
            if any((entry.external_attr >> 16) & 0o170000 == 0o120000 for entry in entries):
                raise DevError("RBZ symlink entries are not allowed")
            missing = REQUIRED - set(names)
            if missing:
                raise DevError(f"RBZ is missing required runtime files: {', '.join(sorted(missing))}")
            loader = archive.read("homecad.rb").decode("utf-8")
            main = archive.read("homecad/main.rb").decode("utf-8")
            if f"EXTENSION.version = '{expected_version}'" not in loader or f"VERSION = '{expected_version}'" not in main:
                raise DevError(f"RBZ version does not match Python package {expected_version}")
            if any("dev" in PurePosixPath(name).parts or ".homecad-dev" in name for name in names):
                raise DevError("RBZ contains dev harness files")
            return {name: __import__("hashlib").sha256(archive.read(name)).hexdigest()
                    for name in names if not name.endswith("/")}
    except BadZipFile as error:
        raise DevError(f"invalid RBZ archive: {path}") from error


def install_rbz(path: Path, plugins: Path, expected_version: str) -> dict[str, str]:
    manifest = validate_rbz(path, expected_version)
    loader = plugins / "homecad.rb"
    support = plugins / "homecad"
    if loader.exists() or loader.is_symlink() or support.exists() or support.is_symlink():
        raise DevError("HomeCAD plugin paths must be empty before packaged install")
    plugins.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="homecad-rbz-", dir=str(plugins.parent)))
    try:
        with ZipFile(path) as archive:
            archive.extractall(staging)
        staged_loader, staged_support = staging / "homecad.rb", staging / "homecad"
        if not staged_loader.is_file() or not staged_support.is_dir():
            raise DevError("staged RBZ contents are incomplete")
        os.replace(staged_support, support)
        try:
            os.replace(staged_loader, loader)
        except Exception:
            shutil.rmtree(support)
            raise
        installed = {"homecad.rb": sha256_file(loader),
                     **{f"homecad/{name}": digest for name, digest in tree_manifest(support).items()}}
        if installed != manifest:
            raise DevError("installed HomeCAD files differ from the validated RBZ manifest")
        return installed
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def remove_packaged_install(plugins: Path, manifest: dict[str, str]) -> None:
    loader, support = plugins / "homecad.rb", plugins / "homecad"
    current: dict[str, str] = {}
    if loader.is_file() and not loader.is_symlink():
        current["homecad.rb"] = sha256_file(loader)
    if support.is_dir() and not support.is_symlink() and not is_junction(support):
        current.update({f"homecad/{name}": digest for name, digest in tree_manifest(support).items()})
    if current != manifest:
        raise DevError("packaged HomeCAD installation changed during test; refusing to delete unverified files")
    loader.unlink()
    shutil.rmtree(support)
