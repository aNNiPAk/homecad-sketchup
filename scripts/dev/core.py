"""Configuration, discovery, and safe filesystem ownership for dev tooling."""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any


FIXTURE_ID = "homecad-smoke-v1"
CONFIG_NAME = "config.json"
STATE_NAME = "state.json"


class DevError(RuntimeError):
    pass


def repo_root(start: Path | None = None) -> Path:
    current = (start or Path(__file__)).resolve()
    if current.is_file():
        current = current.parent
    for candidate in (current, *current.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "sketchup" / "homecad.rb").is_file():
            return candidate
    raise DevError(f"cannot discover HomeCAD repository root from {start or __file__}")


def local_root(root: Path | None = None) -> Path:
    return (root or repo_root()) / ".homecad-dev"


def atomic_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except (OSError, json.JSONDecodeError) as error:
        raise DevError(f"cannot read {path}: {error}") from error


def canonical(path: Path | str) -> str:
    raw = str(path)
    if raw.startswith("\\\\?\\UNC\\"):
        raw = "\\\\" + raw[8:]
    elif raw.startswith("\\\\?\\"):
        raw = raw[4:]
    return os.path.normcase(os.path.normpath(os.path.abspath(raw)))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_manifest(path: Path) -> dict[str, str]:
    if path.is_symlink() or is_junction(path):
        raise DevError(f"refusing to traverse link while hashing installation: {path}")
    if not path.is_dir():
        raise DevError(f"expected a real directory: {path}")
    result: dict[str, str] = {}
    for item in sorted(path.rglob("*")):
        if item.is_symlink() or is_junction(item):
            raise DevError(f"unknown link inside HomeCAD installation: {item}")
        if item.is_file():
            result[item.relative_to(path).as_posix()] = sha256_file(item)
    return result


def _registry_sketchup_entries() -> list[tuple[str, Path]]:
    if os.name != "nt":
        return []
    import winreg

    entries: list[tuple[str, Path]] = []
    locations = (
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
        (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
    )
    for hive, base in locations:
        try:
            with winreg.OpenKey(hive, base) as parent:
                count = winreg.QueryInfoKey(parent)[0]
                for index in range(count):
                    try:
                        subkey = winreg.EnumKey(parent, index)
                        with winreg.OpenKey(parent, subkey) as item:
                            values = {}
                            for value_name in ("DisplayName", "InstallLocation", "DisplayVersion"):
                                try:
                                    values[value_name] = winreg.QueryValueEx(item, value_name)[0]
                                except OSError:
                                    pass
                        display = str(values.get("DisplayName", ""))
                        install = values.get("InstallLocation")
                        if "SketchUp" in display and install:
                            entries.append((display, Path(str(install))))
                    except OSError:
                        continue
        except OSError:
            continue
    return entries


def discover_sketchup(
    explicit: str | Path | None = None,
    configured: str | Path | None = None,
    environ: dict[str, str] | None = None,
    registry_entries: list[tuple[str, Path]] | None = None,
) -> Path:
    environ = environ or os.environ
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    if configured:
        candidates.append(Path(configured))
    entries = _registry_sketchup_entries() if registry_entries is None else registry_entries
    for _, location in sorted(entries, key=lambda row: _year_number(row[0]), reverse=True):
        candidates.extend((location / "SketchUp.exe", location / "SketchUp" / "SketchUp.exe"))
    for env_key in ("ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"):
        base = environ.get(env_key)
        if not base:
            continue
        root = Path(base) / "SketchUp"
        if root.is_dir():
            versions = sorted(root.glob("SketchUp *"), key=lambda p: _year_number(p.name), reverse=True)
            for version in versions:
                candidates.append(version / "SketchUp.exe")
    for path in candidates:
        if path.is_file():
            return path.resolve()
        if explicit and path == Path(explicit):
            raise DevError(f"SketchUp executable override does not exist: {path}")
    raise DevError("SketchUp.exe was not found. Pass --sketchup-exe with its full path.")


def _year_number(value: str) -> int:
    match = re.search(r"20\d{2}", value)
    return int(match.group()) if match else 0


def discover_plugins(sketchup_exe: Path, appdata: str | Path | None = None) -> Path:
    year = _year_number(sketchup_exe.parent.parent.name) or _year_number(str(sketchup_exe))
    if not year:
        raise DevError(f"cannot derive SketchUp year from executable path: {sketchup_exe}")
    roaming_value = str(appdata) if appdata else os.environ.get("APPDATA")
    if not roaming_value:
        raise DevError("APPDATA is unavailable; pass --plugins-dir")
    roaming = Path(roaming_value)
    return roaming / "SketchUp" / f"SketchUp {year}" / "SketchUp" / "Plugins"


def config_path(root: Path | None = None) -> Path:
    return local_root(root) / CONFIG_NAME


def load_config(path: Path | None = None) -> dict[str, Any] | None:
    config = read_json(path or config_path())
    if config is None:
        return None
    required = {"repo_root", "sketchup_exe", "plugins_dir", "test_model", "homecad_port", "ownership_id"}
    missing = required - set(config)
    if missing:
        raise DevError(f"dev config is missing fields: {', '.join(sorted(missing))}")
    return config


def ensure_config(
    *,
    root: Path | None = None,
    sketchup_exe: str | Path | None = None,
    plugins_dir: str | Path | None = None,
    environ: dict[str, str] | None = None,
) -> dict[str, Any]:
    root = (root or repo_root()).resolve()
    path = config_path(root)
    existing = load_config(path)
    if existing:
        if canonical(existing["repo_root"]) != canonical(root):
            raise DevError(f"dev config belongs to another checkout: {existing['repo_root']}")
        exe = discover_sketchup(sketchup_exe, existing.get("sketchup_exe"), environ)
        plugins = Path(plugins_dir).resolve() if plugins_dir else Path(existing["plugins_dir"])
        existing.update(sketchup_exe=str(exe), plugins_dir=str(plugins.resolve()),
                        test_model=str((local_root(root) / "fixture" / "HomeCAD-Smoke.skp").resolve()))
        atomic_json(path, existing)
        return existing
    exe = discover_sketchup(sketchup_exe, environ=environ)
    plugins = Path(plugins_dir).resolve() if plugins_dir else discover_plugins(exe, (environ or os.environ).get("APPDATA"))
    port = choose_port(37_941)
    config = {
        "repo_root": str(root),
        "sketchup_exe": str(exe),
        "plugins_dir": str(plugins),
        "test_model": str((local_root(root) / "fixture" / "HomeCAD-Smoke.skp").resolve()),
        "homecad_port": port,
        "ownership_id": uuid.uuid4().hex,
        "loader_mode": None,
        "loader_sha256": None,
        "support_target": str((root / "sketchup" / "homecad").resolve()),
        "backup": None,
    }
    atomic_json(path, config)
    return config


def choose_port(preferred: int) -> int:
    import socket

    for port in [preferred, *range(preferred + 1, min(preferred + 100, 65_536))]:
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise DevError(f"could not find an available HomeCAD port near {preferred}")


def is_junction(path: Path) -> bool:
    if not path.exists() and not path.is_symlink():
        return False
    if hasattr(path, "is_junction") and path.is_junction():
        return True
    if os.name != "nt":
        return False
    get_attributes = ctypes.windll.kernel32.GetFileAttributesW
    get_attributes.argtypes = [ctypes.c_wchar_p]
    get_attributes.restype = ctypes.c_uint32
    attributes = get_attributes(str(path))
    return attributes != 0xFFFFFFFF and bool(attributes & 0x400)


def link_target(path: Path) -> Path | None:
    if not (path.is_symlink() or is_junction(path)):
        return None
    try:
        return Path(os.readlink(path)).resolve(strict=False)
    except OSError as error:
        raise DevError(f"cannot read link target for {path}: {error}") from error


def create_junction(link: Path, target: Path) -> None:
    if link.exists() or link.is_symlink():
        raise DevError(f"refusing to create a link over existing path: {link}")
    if not target.is_dir():
        raise DevError(f"junction target is not a directory: {target}")
    link.parent.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        link.symlink_to(target.resolve(), target_is_directory=True)
    else:
        command = ["cmd.exe", "/c", "mklink", "/J", str(link), str(target.resolve())]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            # os.symlink may succeed when Windows Developer Mode is enabled.
            try:
                os.symlink(target.resolve(), link, target_is_directory=True)
            except OSError as error:
                raise DevError(f"could not create directory junction {link} -> {target}: {result.stderr.strip() or error}") from error
    if canonical(link_target(link) or Path(".")) != canonical(target):
        raise DevError(f"created link target did not verify: {link}")


def remove_verified_directory_link(link: Path, target: Path) -> None:
    if canonical(link_target(link) or Path(".")) != canonical(target):
        raise DevError(f"refusing to remove unverified HomeCAD directory link: {link}")
    if is_junction(link):
        os.rmdir(link)
    else:
        link.unlink()


def create_loader(source: Path, destination: Path, preferred_mode: str | None = None) -> tuple[str, str]:
    if destination.exists() or destination.is_symlink():
        raise DevError(f"refusing to create loader over existing path: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if preferred_mode != "copy":
        try:
            os.symlink(source.resolve(), destination)
            if canonical(link_target(destination) or Path(".")) == canonical(source):
                return "symlink", sha256_file(source)
            destination.unlink(missing_ok=True)
        except OSError:
            if destination.is_symlink():
                destination.unlink()
    shutil.copy2(source, destination)
    digest = sha256_file(destination)
    if digest != sha256_file(source):
        destination.unlink(missing_ok=True)
        raise DevError("managed homecad.rb copy failed its content verification")
    return "copy", digest


def sync_loader(source: Path, destination: Path, config: dict[str, Any], config_file: Path) -> None:
    mode = config.get("loader_mode")
    if mode == "symlink":
        if canonical(link_target(destination) or Path(".")) != canonical(source):
            raise DevError(f"HomeCAD loader symlink ownership check failed: {destination}")
        return
    if mode != "copy" or not destination.is_file() or destination.is_symlink():
        raise DevError(f"HomeCAD loader is in an unknown state: {destination}")
    current = sha256_file(destination)
    if current != config.get("loader_sha256"):
        raise DevError(f"managed HomeCAD loader was modified outside the dev harness: {destination}")
    source_hash = sha256_file(source)
    if current != source_hash:
        temporary = destination.with_name(destination.name + ".tmp-" + uuid.uuid4().hex)
        shutil.copy2(source, temporary)
        if sha256_file(temporary) != source_hash:
            temporary.unlink(missing_ok=True)
            raise DevError("refreshed HomeCAD loader copy failed hash verification")
        os.replace(temporary, destination)
        config["loader_sha256"] = source_hash
        atomic_json(config_file, config)


def _is_homecad_rbz_install(loader: Path, support: Path) -> bool:
    if not loader.is_file() or loader.is_symlink() or not support.is_dir() or support.is_symlink() or is_junction(support):
        return False
    try:
        loader_text = loader.read_text(encoding="utf-8")
        main_text = (support / "main.rb").read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return False
    return "HomeCAD" in loader_text and "homecad/main" in loader_text and "VERSION" in main_text


def _copy_installation_backup(plugins: Path, config: dict[str, Any], config_file: Path, root: Path) -> None:
    loader = plugins / "homecad.rb"
    support = plugins / "homecad"
    has_loader = loader.exists() or loader.is_symlink()
    has_support = support.exists() or support.is_symlink()
    if not has_loader and not has_support:
        return
    backup = config.get("backup")
    backup_root = local_root(root) / "backups" / "original-homecad"
    if backup:
        backup_root = Path(backup["path"])
        if not (backup_root / "homecad.rb").is_file() or not (backup_root / "homecad").is_dir():
            raise DevError(f"recorded HomeCAD backup is incomplete: {backup_root}")
        return
    source_loader = root / "sketchup" / "homecad.rb"
    source_support = Path(config.get("support_target", root / "sketchup" / "homecad"))
    support_is_dev = ((support.is_symlink() or is_junction(support))
                      and canonical(link_target(support) or Path(".")) == canonical(source_support))
    loader_mode = config.get("loader_mode")
    loader_is_dev = ((loader.is_symlink() and canonical(link_target(loader) or Path(".")) == canonical(source_loader))
                     or (loader_mode == "copy" and loader.is_file() and not loader.is_symlink()
                         and sha256_file(loader) == config.get("loader_sha256")))
    if support_is_dev and loader_is_dev:
        return
    if not has_loader or not has_support or not _is_homecad_rbz_install(loader, support):
        raise DevError(
            "Plugins/homecad.rb or Plugins/homecad is not a recognized HomeCAD RBZ install; "
            "leaving unknown content untouched"
        )
    if backup_root.exists():
        raise DevError(f"unowned backup path already exists; refusing to overwrite: {backup_root}")
    backup_root.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(loader, backup_root.with_suffix(".loader.tmp"))
    temporary_dir = backup_root.with_name(backup_root.name + ".tmp-" + uuid.uuid4().hex)
    temporary_dir.mkdir()
    shutil.copytree(support, temporary_dir / "homecad")
    os.replace(backup_root.with_suffix(".loader.tmp"), temporary_dir / "homecad.rb")
    loader_hash = sha256_file(temporary_dir / "homecad.rb")
    files = tree_manifest(temporary_dir / "homecad")
    if loader_hash != sha256_file(loader) or files != tree_manifest(support):
        shutil.rmtree(temporary_dir)
        raise DevError("HomeCAD production backup did not match the installed files")
    backup_root.parent.mkdir(parents=True, exist_ok=True)
    os.replace(temporary_dir, backup_root)
    config["backup"] = {"path": str(backup_root), "loader_sha256": loader_hash,
                        "support_manifest": files}
    atomic_json(config_file, config)


def ensure_dev_links(root: Path, config: dict[str, Any]) -> dict[str, Any]:
    plugins = Path(config["plugins_dir"])
    loader = plugins / "homecad.rb"
    support = plugins / "homecad"
    source_loader = root / "sketchup" / "homecad.rb"
    source_support = (root / "sketchup" / "homecad").resolve()
    plugins.mkdir(parents=True, exist_ok=True)
    config_file = config_path(root)

    _copy_installation_backup(plugins, config, config_file, root)

    if support.exists() or support.is_symlink():
        if canonical(link_target(support) or Path(".")) != canonical(source_support):
            if _is_known_backup_copy(support, config):
                shutil.rmtree(support)
            else:
                raise DevError(f"Plugins/homecad is not the verified repository junction: {support}")
    if not support.exists() and not support.is_symlink():
        create_junction(support, source_support)
    if canonical(link_target(support) or Path(".")) != canonical(source_support):
        raise DevError("HomeCAD support junction points to the wrong target")

    if loader.exists() or loader.is_symlink():
        mode = config.get("loader_mode")
        if mode == "symlink" and canonical(link_target(loader) or Path(".")) == canonical(source_loader):
            pass
        elif mode == "copy" and loader.is_file() and not loader.is_symlink() and sha256_file(loader) == config.get("loader_sha256"):
            sync_loader(source_loader, loader, config, config_file)
        elif _is_known_backup_loader(loader, config):
            loader.unlink()
            mode, digest = create_loader(source_loader, loader)
            config["loader_mode"], config["loader_sha256"] = mode, digest
        else:
            raise DevError(f"Plugins/homecad.rb is not the verified HomeCAD dev loader: {loader}")
    else:
        mode, digest = create_loader(source_loader, loader, config.get("loader_mode"))
        config["loader_mode"], config["loader_sha256"] = mode, digest
    config["support_target"] = str(source_support)
    config["links_ready"] = True
    atomic_json(config_file, config)
    return config


def _is_known_backup_copy(support: Path, config: dict[str, Any]) -> bool:
    backup = config.get("backup")
    if not backup or not support.is_dir() or support.is_symlink() or is_junction(support):
        return False
    try:
        return tree_manifest(support) == backup["support_manifest"]
    except DevError:
        return False


def _is_known_backup_loader(loader: Path, config: dict[str, Any]) -> bool:
    backup = config.get("backup")
    return bool(backup and loader.is_file() and not loader.is_symlink()
                and sha256_file(loader) == backup.get("loader_sha256"))


def remove_dev_links(root: Path, config: dict[str, Any], *, restore_backup: bool = False) -> None:
    plugins = Path(config["plugins_dir"])
    loader = plugins / "homecad.rb"
    support = plugins / "homecad"
    source_support = Path(config.get("support_target", root / "sketchup" / "homecad"))
    support_present = support.exists() or support.is_symlink()
    loader_present = loader.exists() or loader.is_symlink()
    if support_present and canonical(link_target(support) or Path(".")) != canonical(source_support):
        raise DevError(f"refusing to remove unverified HomeCAD directory link: {support}")
    mode = config.get("loader_mode")
    if loader_present:
        if mode == "symlink":
            if canonical(link_target(loader) or Path(".")) != canonical(root / "sketchup" / "homecad.rb"):
                raise DevError(f"refusing to remove unverified loader symlink: {loader}")
        elif mode != "copy" or not loader.is_file() or loader.is_symlink() or sha256_file(loader) != config.get("loader_sha256"):
            raise DevError(f"refusing to remove unknown HomeCAD loader: {loader}")
    backup = None
    if restore_backup and config.get("backup"):
        backup = Path(config["backup"]["path"])
        backup_loader = backup / "homecad.rb"
        backup_support = backup / "homecad"
        if (not backup_loader.is_file() or sha256_file(backup_loader) != config["backup"].get("loader_sha256")
                or not backup_support.is_dir()
                or tree_manifest(backup_support) != config["backup"].get("support_manifest")):
            raise DevError("saved HomeCAD production backup failed integrity verification; refusing restore")
    if support_present:
        remove_verified_directory_link(support, source_support)
    if loader_present:
        loader.unlink()
    if backup is not None:
        if support.exists() or support.is_symlink() or loader.exists() or loader.is_symlink():
            raise DevError("HomeCAD paths unexpectedly occupied before backup restore")
        shutil.copytree(backup / "homecad", plugins / "homecad")
        shutil.copy2(backup / "homecad.rb", plugins / "homecad.rb")


def _process_identity(pid: int) -> dict[str, Any] | None:
    if os.name != "nt":
        return None
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    SYNCHRONIZE = 0x00100000
    WAIT_TIMEOUT = 0x00000102
    class FILETIME(ctypes.Structure):
        _fields_ = [("low", ctypes.c_uint32), ("high", ctypes.c_uint32)]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel.WaitForSingleObject.restype = ctypes.c_uint32
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.restype = ctypes.c_int
    handle = kernel.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, False, pid)
    if not handle:
        return None
    try:
        if kernel.WaitForSingleObject(handle, 0) != WAIT_TIMEOUT:
            return None
        size = ctypes.c_uint32(32768)
        buffer = ctypes.create_unicode_buffer(size.value)
        query = kernel.QueryFullProcessImageNameW
        query.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
        query.restype = ctypes.c_int
        if not query(handle, 0, buffer, ctypes.byref(size)):
            return None
        created, exited, kernel_time, user_time = FILETIME(), FILETIME(), FILETIME(), FILETIME()
        get_times = kernel.GetProcessTimes
        get_times.argtypes = [ctypes.c_void_p, ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME),
                              ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME)]
        get_times.restype = ctypes.c_int
        if not get_times(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel_time), ctypes.byref(user_time)):
            return None
        created_value = (int(created.high) << 32) | int(created.low)
        return {"pid": pid, "executable": str(Path(buffer.value).resolve()), "created_filetime": created_value}
    finally:
        kernel.CloseHandle(handle)


def process_identity(pid: int) -> dict[str, Any] | None:
    return _process_identity(pid)


def _window_close(pid: int) -> None:
    if os.name != "nt":
        return
    user = ctypes.WinDLL("user32", use_last_error=True)
    user.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    user.GetWindowThreadProcessId.restype = ctypes.c_uint32
    user.IsWindowVisible.argtypes = [ctypes.c_void_p]
    user.IsWindowVisible.restype = ctypes.c_int
    user.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_size_t, ctypes.c_ssize_t]
    user.PostMessageW.restype = ctypes.c_int
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    user.EnumWindows.argtypes = [callback_type, ctypes.c_void_p]
    user.EnumWindows.restype = ctypes.c_int
    def visit(hwnd: int, _parameter: int) -> bool:
        owner = ctypes.c_uint32()
        user.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user.IsWindowVisible(hwnd):
            user.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE
        return True
    user.EnumWindows(callback_type(visit), 0)


def _terminate_exact(pid: int, expected: dict[str, Any], timeout: float = 15.0) -> None:
    if os.name != "nt":
        raise DevError("process teardown is supported only on Windows")
    current = process_identity(pid)
    if current is None:
        return
    if current["created_filetime"] != expected.get("created_filetime") or canonical(current["executable"]) != canonical(expected["executable"]):
        raise DevError(f"refusing to terminate PID {pid}: process ownership verification failed")
    _window_close(pid)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    PROCESS_TERMINATE = 0x0001
    SYNCHRONIZE = 0x00100000
    WAIT_OBJECT_0 = 0
    WAIT_TIMEOUT = 0x00000102
    kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel.WaitForSingleObject.restype = ctypes.c_uint32
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.restype = ctypes.c_int
    kernel.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel.TerminateProcess.restype = ctypes.c_int
    handle = kernel.OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, False, pid)
    if not handle:
        raise DevError(f"cannot open owned SketchUp PID {pid} for graceful shutdown")
    try:
        milliseconds = max(0, int(timeout * 1000))
        if kernel.WaitForSingleObject(handle, milliseconds) == WAIT_TIMEOUT:
            current = process_identity(pid)
            if current is None:
                return
            if current["created_filetime"] != expected.get("created_filetime") or canonical(current["executable"]) != canonical(expected["executable"]):
                raise DevError(f"refusing to terminate PID {pid}: process identity changed")
            if not kernel.TerminateProcess(handle, 1):
                raise DevError(f"failed to terminate owned SketchUp PID {pid}")
            if kernel.WaitForSingleObject(handle, 10_000) != WAIT_OBJECT_0:
                raise DevError(f"owned SketchUp PID {pid} did not exit after termination")
    finally:
        kernel.CloseHandle(handle)


def stop_owned_process(root: Path, config: dict[str, Any]) -> None:
    path = local_root(root) / STATE_NAME
    state = read_json(path)
    if not state:
        return
    if state.get("started_by_homecad_dev") is not True or state.get("ownership_id") != config.get("ownership_id"):
        raise DevError("dev process state is not owned by this HomeCAD harness")
    pid = int(state.get("pid", 0))
    current = process_identity(pid)
    if current is None:
        if process_exists(pid):
            raise DevError(f"PID {pid} still exists but its identity cannot be verified; leaving it untouched")
        path.unlink(missing_ok=True)
        return
    expected_exe = config["sketchup_exe"]
    if (current["created_filetime"] != state.get("process_created_filetime")
            or canonical(current["executable"]) != canonical(expected_exe)
            or canonical(state.get("sketchup_exe", "")) != canonical(expected_exe)):
        raise DevError(f"refusing to close SketchUp PID {pid}: executable or creation identity differs")
    _terminate_exact(pid, current)
    path.unlink(missing_ok=True)


def write_process_state(root: Path, config: dict[str, Any], identity: dict[str, Any], model: Path | None, mode: str) -> None:
    state = {"pid": identity["pid"], "started_by_homecad_dev": True,
             "ownership_id": config["ownership_id"], "sketchup_exe": config["sketchup_exe"],
             "process_created_filetime": identity["created_filetime"], "test_model": str(model) if model else None,
             "mode": mode, "homecad_port": config["homecad_port"]}
    atomic_json(local_root(root) / STATE_NAME, state)


def start_sketchup(root: Path, config: dict[str, Any], model: Path | None, *, mode: str,
                   bootstrap_token: str | None = None,
                   bootstrap_script: Path | None = None) -> dict[str, Any]:
    if os.name != "nt":
        raise DevError("the SketchUp dev harness requires Windows")
    exe = Path(config["sketchup_exe"]).resolve()
    if not exe.is_file():
        raise DevError(f"SketchUp executable disappeared: {exe}")
    running = [item for item in running_sketchup_processes()
               if not item.get("executable") or canonical(item["executable"]) == canonical(exe)]
    if running:
        details = "; ".join(f"PID {item['pid']} ({item.get('executable') or 'path unavailable'})" for item in running)
        raise DevError(f"refusing to launch while a non-owned SketchUp process is running: {details}")
    arguments = [str(exe)]
    if bootstrap_token:
        if bootstrap_script is None or not bootstrap_script.is_file():
            raise DevError("fixture bootstrap token requires its temporary Ruby startup script")
        arguments.extend(["-RubyStartup", str(bootstrap_script.resolve())])
    if model is not None:
        arguments.append(str(model.resolve()))
    environment = os.environ.copy()
    environment["HOMECAD_PORT"] = str(config["homecad_port"])
    if bootstrap_token:
        environment["HOMECAD_DEV_BOOTSTRAP_TOKEN"] = bootstrap_token
    process = subprocess.Popen(arguments, cwd=str(exe.parent), env=environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
    import time
    deadline = time.monotonic() + 10
    identity = None
    while time.monotonic() < deadline:
        identity = process_identity(process.pid)
        if identity:
            break
        if process.poll() is not None:
            raise DevError("SketchUp launcher exited before a dedicated process could be verified; no existing process was touched")
        time.sleep(0.1)
    if not identity:
        raise DevError("could not verify the new SketchUp process identity")
    if canonical(identity["executable"]) != canonical(exe):
        raise DevError(f"new PID {process.pid} is not the configured SketchUp executable; refusing process ownership")
    expected = {"pid": process.pid, "created_filetime": identity["created_filetime"],
                "executable": str(exe)}
    write_process_state(root, config, identity, model, mode)
    return expected


def running_sketchup_processes() -> list[dict[str, Any]]:
    """Read-only inventory; used to avoid SketchUp single-instance forwarding."""
    if os.name != "nt":
        return []
    command = "Get-CimInstance Win32_Process -Filter \"Name='SketchUp.exe'\" | " \
              "Select-Object ProcessId,ExecutablePath | ConvertTo-Json -Compress"
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                            capture_output=True, text=True, check=False, timeout=15)
    if result.returncode != 0:
        raise DevError(f"could not safely check for existing SketchUp processes: {result.stderr.strip()}")
    if not result.stdout.strip():
        return []
    try:
        decoded = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise DevError("could not parse the existing SketchUp process inventory") from error
    rows = decoded if isinstance(decoded, list) else [decoded]
    return [{"pid": int(row["ProcessId"]),
             "executable": str(row["ExecutablePath"]) if row.get("ExecutablePath") else None}
            for row in rows if row.get("ProcessId")]


def process_exists(pid: int) -> bool:
    """Return whether the Windows process table still contains this PID."""
    if os.name != "nt":
        return False
    command = f"Get-CimInstance Win32_Process -Filter \"ProcessId={int(pid)}\" | Measure-Object | Select-Object -ExpandProperty Count"
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                            capture_output=True, text=True, check=False, timeout=15)
    if result.returncode != 0:
        raise DevError(f"could not safely determine whether PID {pid} exists")
    try:
        return int(result.stdout.strip()) > 0
    except ValueError as error:
        raise DevError(f"could not parse process existence result for PID {pid}") from error
