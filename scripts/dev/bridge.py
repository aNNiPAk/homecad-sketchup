"""Bounded bridge readiness checks used by Windows dev orchestration."""

from __future__ import annotations

import asyncio
import os
import sys
import time
from pathlib import Path

from .core import DevError


def _client_type(root: Path):
    mcp_root = root / "mcp"
    if str(mcp_root) not in sys.path:
        sys.path.insert(0, str(mcp_root))
    from homecad_mcp.config import Config
    from homecad_mcp.connection import BridgeClient

    return BridgeClient, Config


async def _call(root: Path, port: int, method: str) -> dict:
    BridgeClient, Config = _client_type(root)
    return await BridgeClient(Config(port=port, timeout=3.0)).call(method)


async def poll_bridge(root: Path, config: dict, *, expected_version: str,
                       required_capability: str | None, timeout: float = 120.0) -> tuple[dict, dict]:
    deadline = time.monotonic() + timeout
    last_error = "bridge has not responded yet"
    while time.monotonic() < deadline:
        try:
            status = await _call(root, int(config["homecad_port"]), "homecad_status")
            from homecad_mcp import PROTOCOL_VERSION

            if status.get("connection_status") != "connected":
                last_error = f"bridge status is {status.get('connection_status')!r}"
            elif status.get("protocol_version") != PROTOCOL_VERSION:
                raise DevError(f"protocol mismatch: expected {PROTOCOL_VERSION}, installed {status.get('protocol_version')!r}")
            elif status.get("ruby_extension_version") != expected_version:
                raise DevError(
                    f"HomeCAD version mismatch: expected {expected_version}, installed "
                    f"{status.get('ruby_extension_version')!r}"
                )
            elif required_capability and required_capability not in status.get("capabilities", []):
                raise DevError(f"bridge is missing required capability {required_capability!r}")
            else:
                info = await _call(root, int(config["homecad_port"]), "get_model_info")
                expected_fixture = Path(config["test_model"]).resolve()
                if info.get("dev_fixture") is not True or info.get("dev_fixture_id") != "homecad-smoke-v1":
                    raise DevError("active model is not the designated HomeCAD smoke fixture")
                actual_path = info.get("path")
                if actual_path and os.path.normcase(str(Path(actual_path).resolve())) != os.path.normcase(str(expected_fixture)):
                    raise DevError(f"SketchUp opened unexpected model {actual_path!r}; expected {expected_fixture}")
                return status, info
        except DevError:
            raise
        except Exception as error:
            last_error = f"{type(error).__name__}: {error}"
        await asyncio.sleep(0.75)
    state_path = Path(config["repo_root"]) / ".homecad-dev" / "state.json"
    state = {}
    try:
        import json
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass
    raise DevError(
        f"HomeCAD bridge did not become ready within {timeout:.0f}s: {last_error}. "
        f"PID={state.get('pid')}, SketchUp={config['sketchup_exe']}, "
        f"Plugins={config['plugins_dir']}, model={config['test_model']}, "
        f"expected version={expected_version}, port={config['homecad_port']}"
    )


def call_sync(root: Path, config: dict, method: str) -> dict:
    return asyncio.run(_call(root, int(config["homecad_port"]), method))
