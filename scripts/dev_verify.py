"""Run a real SketchUp milestone smoke through dev links or the freshly built RBZ."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from homecad_mcp import VERSION
from scripts.dev.bridge import poll_bridge
from scripts.dev.core import (DevError, atomic_json, ensure_config, ensure_dev_links,
                              local_root, repo_root, start_sketchup, stop_owned_process,
                              sync_loader)
from scripts.dev.package import install_rbz, remove_packaged_install


SMOKES = {
    "m1": (["scripts/smoke_m1.py", "--name", "HomeCAD Smoke Target"], "view.capture.v1"),
    "m2": (["scripts/smoke_m2.py", "--confirm-disposable"], "geometry.primitive.v1"),
    "m3": (["scripts/smoke_m3.py", "--confirm-disposable"], "architecture.core.v1"),
    "m4": (["scripts/smoke_m4.py", "--confirm-disposable"], "furniture.core.v1"),
    "m5": (["scripts/smoke_m5.py", "--confirm-disposable"], "kitchen.run.v1"),
}

FOCUSED_RUBY_TESTS = {
    "m1": "tests/ruby/test_inspection.rb",
    "m2": "tests/ruby/test_mutations.rb",
    "m3": "tests/ruby/test_architecture.rb",
    "m4": "tests/ruby/test_furniture.rb",
    "m5": "tests/ruby/test_kitchen.rb",
}


class VerificationFailure(DevError):
    pass


def _run(command: list[str], *, root: Path, env: dict[str, str], label: str,
         echo_output: bool = True) -> dict:
    print(f"[{label}] {' '.join(command)}", flush=True)
    result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True, check=False)
    if result.stdout and (echo_output or result.returncode):
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", flush=True)
    if result.stderr and (echo_output or result.returncode):
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=sys.stderr, flush=True)
    return {"label": label, "command": command, "returncode": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}


def _run_full_tests(root: Path, env: dict[str, str]) -> list[dict]:
    results = []
    for command, label in [
        (["uv", "run", "--project", "mcp", "--extra", "dev", "python", "-m", "pytest", "tests/python", "-q"], "Python tests"),
        *[(["ruby", path], f"Ruby {path}") for path in (
            "tests/ruby/test_m0.rb", "tests/ruby/test_targeting.rb", "tests/ruby/test_serializer.rb",
            "tests/ruby/test_inspection.rb", "tests/ruby/test_measurement.rb", "tests/ruby/test_capture.rb",
            "tests/ruby/test_undo.rb", "tests/ruby/test_mutation_core.rb", "tests/ruby/test_geometry_validation.rb",
            "tests/ruby/test_primitives.rb", "tests/ruby/test_mutations.rb", "tests/ruby/test_architecture.rb",
            "tests/ruby/test_furniture.rb", "tests/ruby/test_kitchen.rb")],
        (["uv", "run", "--project", "mcp", "python", "scripts/build_rbz.py"], "RBZ build"),
    ]:
        row = _run(command, root=root, env=env, label=label)
        results.append(row)
        if row["returncode"]:
            raise VerificationFailure(f"{label} failed with exit code {row['returncode']}")
    return results


def _run_focused_tests(root: Path, env: dict[str, str], milestone: str) -> list[dict]:
    results = []
    for command, label in (
        (["uv", "run", "--project", "mcp", "--extra", "dev", "python", "-m", "pytest",
          "tests/python/test_dev_workflow.py", "-q"], "Dev harness tests"),
        (["ruby", FOCUSED_RUBY_TESTS[milestone]], f"Ruby {milestone.upper()} tests"),
    ):
        row = _run(command, root=root, env=env, label=label)
        results.append(row)
        if row["returncode"]:
            raise VerificationFailure(f"{label} failed with exit code {row['returncode']}")
    return results


def verify(milestone: str, mode: str = "fast", *, keep_open: bool = False,
           skip_tests: bool = False, sketchup_exe: str | None = None,
           plugins_dir: str | None = None) -> dict:
    root = repo_root()
    smoke_args, required_capability = SMOKES[milestone]
    config = ensure_config(root=root, sketchup_exe=sketchup_exe, plugins_dir=plugins_dir)
    state_root = local_root(root)
    log_path = state_root / "logs" / f"last_{mode}_verify.json"
    state_root.joinpath("logs").mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["HOMECAD_PORT"] = str(config["homecad_port"])
    report = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "mode": mode,
              "milestone": milestone, "version": VERSION, "sketchup_exe": config["sketchup_exe"],
              "plugins_dir": config["plugins_dir"], "fixture": config["test_model"],
              "tests": [], "smoke": None, "status": "running"}
    atomic_json(log_path, report)
    package_manifest = None
    installed_manifest = None
    links_removed = False
    launched = False
    failure: Exception | None = None
    try:
        stop_owned_process(root, config)
        if mode == "fast":
            if not skip_tests:
                report["tests"] = _run_focused_tests(root, env, milestone)
            if not Path(config["test_model"]).is_file():
                raise DevError("designated fixture is missing; run scripts/dev_setup.py before real SketchUp verification")
            config = ensure_dev_links(root, config)
            sync_loader(root / "sketchup" / "homecad.rb", Path(config["plugins_dir"]) / "homecad.rb",
                        config, root / ".homecad-dev" / "config.json")
        else:
            report["tests"] = _run_full_tests(root, env)
            if not Path(config["test_model"]).is_file():
                raise DevError("designated fixture is missing; tests and RBZ build passed, but packaged SketchUp acceptance cannot run")
            rbz_path = root / "dist" / "homecad.rbz"
            from scripts.dev.package import validate_rbz
            package_manifest = validate_rbz(rbz_path, VERSION)
            report["rbz"] = str(rbz_path)
            report["rbz_manifest_files"] = len(package_manifest)
            from scripts.dev.core import remove_dev_links
            remove_dev_links(root, config, restore_backup=False)
            links_removed = True
            installed_manifest = install_rbz(rbz_path, Path(config["plugins_dir"]), VERSION)
            report["installed_file_count"] = len(installed_manifest)
        launched = True
        owned = start_sketchup(root, config, Path(config["test_model"]), mode=mode)
        report["pid"] = owned["pid"]
        status, model_info = __import__("asyncio").run(
            poll_bridge(root, config, expected_version=VERSION, required_capability=required_capability))
        report["homecad_status"] = status
        report["model_info"] = model_info
        command = ["uv", "run", "--project", "mcp", "python", *smoke_args]
        if milestone == "m4":
            command.extend(["--output", "dist/m4-smoke/cabinet.png"])
        smoke = _run(command, root=root, env=env, label=f"{milestone.upper()} real SketchUp smoke",
                     echo_output=False)
        report["smoke"] = smoke
        if smoke["returncode"]:
            raise VerificationFailure(f"{milestone.upper()} smoke failed with exit code {smoke['returncode']}")
        report["status"] = "success"
    except Exception as error:
        failure = error
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        cleanup_errors = []
        leave_running = keep_open and mode == "fast" and report["status"] == "success"
        stopped = leave_running
        if not leave_running:
            try:
                stop_owned_process(root, config)
                stopped = True
            except Exception as error:
                cleanup_errors.append(f"could not stop owned SketchUp: {error}")
        if mode == "packaged" and links_removed and stopped:
            try:
                if installed_manifest is not None:
                    remove_packaged_install(Path(config["plugins_dir"]), installed_manifest)
                config = ensure_dev_links(root, config)
                report["dev_links_restored"] = True
            except Exception as error:
                cleanup_errors.append(f"could not safely restore dev links: {error}")
                report["dev_links_restored"] = False
        if leave_running:
            # Preserve the exact owned state only when the requested fresh process is alive.
            report["kept_open"] = True
        report["cleanup_errors"] = cleanup_errors
        if cleanup_errors:
            report["status"] = "failed"
        atomic_json(log_path, report)
    if failure:
        if report.get("cleanup_errors"):
            raise VerificationFailure(f"{failure}; cleanup: {'; '.join(report['cleanup_errors'])}") from failure
        raise failure
    if report.get("cleanup_errors"):
        raise VerificationFailure("; ".join(report["cleanup_errors"]))
    print(json.dumps({"status": report["status"], "mode": mode, "milestone": milestone,
                      "version": VERSION, "pid": report.get("pid"),
                      "sketchup_version": report.get("homecad_status", {}).get("sketchup_version"),
                      "fixture": report["fixture"], "rbz": report.get("rbz"),
                      "tests_passed": len(report["tests"]), "smoke_exit_code": report["smoke"]["returncode"],
                      "dev_links_restored": report.get("dev_links_restored"),
                      "cleanup_errors": report["cleanup_errors"]}, indent=2))
    print(f"verification report: {log_path}")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--milestone", required=True, choices=sorted(SMOKES))
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--fast", action="store_true")
    modes.add_argument("--packaged", action="store_true")
    parser.add_argument("--keep-open", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--sketchup-exe")
    parser.add_argument("--plugins-dir")
    args = parser.parse_args()
    mode = "packaged" if args.packaged else "fast"
    if mode == "packaged" and args.skip_tests:
        parser.error("--packaged always runs the full test suite; --skip-tests is not allowed")
    if mode == "packaged" and args.keep_open:
        parser.error("--packaged always stops its dedicated SketchUp process during cleanup")
    try:
        verify(args.milestone, mode, keep_open=args.keep_open, skip_tests=args.skip_tests,
               sketchup_exe=args.sketchup_exe, plugins_dir=args.plugins_dir)
    except Exception as error:
        print(f"dev_verify: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
