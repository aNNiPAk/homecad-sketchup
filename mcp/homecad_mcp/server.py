"""HomeCAD MCP tools over the local SketchUp bridge."""

import base64
import binascii
import json
import logging
import os

from typing import Any

from mcp.server.fastmcp import FastMCP, Image

from . import PROTOCOL_VERSION, VERSION
from .connection import BridgeClient
from .errors import BridgeError

logger = logging.getLogger(__name__)
mcp = FastMCP("HomeCAD for SketchUp")


@mcp.tool()
async def homecad_status() -> dict:
    """Report MCP, bridge, SketchUp and active model status."""
    try:
        result = await BridgeClient().call("homecad_status")
        return {"mcp_version": VERSION, **result}
    except BridgeError as exc:
        logger.warning("homecad_status: %s: %s", exc.category, exc.message)
        return {
            "mcp_version": VERSION, "ruby_extension_version": None,
            "sketchup_version": None, "model_name": None,
            "connection_status": "incompatible" if exc.category == "incompatible_version" else "disconnected",
            "protocol_version": PROTOCOL_VERSION, "error": exc.as_dict(),
        }


@mcp.tool()
async def get_model_info() -> dict:
    """Read the active SketchUp model's identity and collection counts."""
    try:
        return await BridgeClient().call("get_model_info")
    except BridgeError as exc:
        logger.warning("get_model_info: %s: %s", exc.category, exc.message)
        raise RuntimeError(f"{exc.category}: {exc.message}") from exc


async def _scene_call(method: str, params: dict[str, Any]) -> dict:
    try:
        return await BridgeClient().call(method, params)
    except BridgeError as exc:
        logger.warning("%s: %s: %s", method, exc.category, exc.message)
        raise RuntimeError(f"{exc.category}: {exc.message}") from exc


@mcp.tool()
async def list_objects(context: str = "root", parent: dict | None = None,
                       entity_type: str | None = None, include_hidden: bool = False,
                       include_generated: bool = False, limit: int = 50, offset: int = 0) -> dict:
    """List one bounded SketchUp collection; Face and Edge require an explicit type filter."""
    return await _scene_call("list_objects", {"context": context, "parent": parent,
        "entity_type": entity_type, "include_hidden": include_hidden,
        "include_generated": include_generated, "limit": limit, "offset": offset})


@mcp.tool()
async def find_objects(homecad_id: str | None = None, persistent_id: int | None = None,
                       entity_id: int | None = None, entity_type: str | None = None,
                       homecad_type: str | None = None, name: str | None = None,
                       tag: str | None = None, parent_id: int | None = None,
                       metadata: dict | None = None, limit: int = 50, offset: int = 0) -> dict:
    """Find objects with explicit none, unique, ambiguous or multiple resolution."""
    filters = {key: value for key, value in locals().items()
               if value is not None and key not in ("limit", "offset")}
    return await _scene_call("find_objects", {**filters, "limit": limit, "offset": offset})


@mcp.tool()
async def get_object(target: dict) -> dict:
    """Inspect one uniquely identified SketchUp object with dimensions and metadata."""
    return await _scene_call("get_object", {"target": target})


@mcp.tool()
async def get_selection() -> dict:
    """Read selected objects using the same identity and serializer as get_object."""
    return await _scene_call("get_selection", {})


@mcp.tool()
async def measure(kind: str, target: dict, other_target: dict | None = None) -> dict:
    """Measure bounds, dimensions, distances, face area or edge length in metric units."""
    params = {"kind": kind, "target": target}
    if other_target is not None:
        params["other_target"] = other_target
    return await _scene_call("measure", params)


@mcp.tool()
async def capture_view(view: str = "current", zoom_extents: bool = False,
                       target: dict | None = None, max_size: int = 1024,
                       restore_camera: bool = True) -> list:
    """Capture a SketchUp PNG; the original camera is restored by default."""
    params: dict[str, Any] = {"view": view, "zoom_extents": zoom_extents,
                              "max_size": max_size, "restore_camera": restore_camera}
    if target is not None:
        params["target"] = target
    result = await _scene_call("capture_view", params)
    encoded = result.pop("image_base64", None)
    try:
        png = base64.b64decode(encoded, validate=True)
    except (TypeError, ValueError, binascii.Error) as exc:
        raise RuntimeError("invalid_response: capture did not contain valid image data") from exc
    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError("invalid_response: capture was not a PNG")
    return [json.dumps(result), Image(data=png, format="png")]


@mcp.tool()
async def undo() -> dict:
    """Queue exactly one native SketchUp Undo action."""
    return await _scene_call("undo", {})


def main() -> None:
    level = os.environ.get("HOMECAD_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(level=getattr(logging, level, logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    mcp.run(transport="stdio")
