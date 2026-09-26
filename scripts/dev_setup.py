"""Configure repository-linked HomeCAD and prepare a marked smoke model."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from homecad_mcp import VERSION
from scripts.dev.bridge import poll_bridge
from scripts.dev.core import (DevError, atomic_json, ensure_config, ensure_dev_links,
                              local_root, repo_root, running_sketchup_processes,
                              start_sketchup, stop_owned_process)
from scripts.dev.fixture import prepare_writable_template, install_bootstrap, read_bootstrap_result


def setup(*, sketchup_exe: str | None = None, plugins_dir: str | None = None) -> dict:
    root = repo_root()
    config = ensure_config(root=root, sketchup_exe=sketchup_exe, plugins_dir=plugins_dir)
    state_root = local_root(root)
    for directory in (state_root / "logs", state_root / "fixture", state_root / "backups"):
        directory.mkdir(parents=True, exist_ok=True)
    stop_owned_process(root, config)
    running = running_sketchup_processes()
    if running:
        raise DevError("close the existing non-owned SketchUp process before changing HomeCAD plugin links")
    config = ensure_dev_links(root, config)
    fixture = Path(config["test_model"])
    fixture.parent.mkdir(parents=True, exist_ok=True)

    # Always verify the existing fixture through a fresh dedicated SketchUp process.
    # If absent, first create it from an authenticated, empty-model bootstrap.
    if not fixture.exists():
        template = prepare_writable_template(root, Path(config["sketchup_exe"]))
        try:
            bootstrap, token, result_path = install_bootstrap(root, config, template)
            try:
                start_sketchup(root, config, template, mode="fixture-bootstrap", bootstrap_token=token,
                               bootstrap_script=bootstrap)
                deadline = time.monotonic() + 90
                result = None
                while time.monotonic() < deadline:
                    result = read_bootstrap_result(result_path)
                    if result:
                        break
                    time.sleep(1)
                if not result:
                    raise DevError(f"fixture bootstrap timed out; inspect {result_path} and SketchUp PID/state")
                if result.get("status") != "success":
                    raise DevError(f"fixture bootstrap refused or failed: {result}")
                if not fixture.is_file():
                    raise DevError("SketchUp reported fixture creation but the .skp file is missing")
            finally:
                bootstrap.unlink(missing_ok=True)
                stop_owned_process(root, config)
        finally:
            template.unlink(missing_ok=True)

    launched = start_sketchup(root, config, fixture, mode="setup")
    try:
        status, info = __import__("asyncio").run(
            poll_bridge(root, config, expected_version=VERSION, required_capability="furniture.core.v1"))
    except Exception:
        stop_owned_process(root, config)
        raise
    report = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "status": "success",
              "sketchup_exe": config["sketchup_exe"], "plugins_dir": config["plugins_dir"],
              "support_junction": str(Path(config["plugins_dir"]) / "homecad"),
              "support_target": config["support_target"], "loader_mode": config["loader_mode"],
              "fixture": str(fixture), "fixture_id": info.get("dev_fixture_id"),
              "pid": launched["pid"], "homecad_status": status}
    atomic_json(state_root / "logs" / "last_setup.json", report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sketchup-exe")
    parser.add_argument("--plugins-dir")
    args = parser.parse_args()
    try:
        result = setup(sketchup_exe=args.sketchup_exe, plugins_dir=args.plugins_dir)
        print(json.dumps(result, indent=2))
        print("Dedicated SketchUp remains open on the HomeCAD smoke fixture.")
    except Exception as error:
        try:
            root = repo_root()
            log = local_root(root) / "logs" / "last_setup.json"
            log.parent.mkdir(parents=True, exist_ok=True)
            atomic_json(log, {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                              "status": "failed", "error": f"{type(error).__name__}: {error}"})
        except Exception:
            pass
        print(f"dev_setup: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
