"""HomeCAD MCP tools over the local SketchUp bridge."""

import base64
import binascii
import json
import logging
import os

from typing import Any

from mcp.server.fastmcp import FastMCP, Image
from mcp.types import ToolAnnotations

from . import PROTOCOL_VERSION, VERSION
from .connection import BridgeClient
from .errors import BridgeError

logger = logging.getLogger(__name__)
mcp = FastMCP("HomeCAD for SketchUp")
READ_ONLY_TOOL = ToolAnnotations(readOnlyHint=True, openWorldHint=False)
UNDO_TOOL = ToolAnnotations(readOnlyHint=False, destructiveHint=True,
                            idempotentHint=False, openWorldHint=False)
CREATE_TOOL = ToolAnnotations(readOnlyHint=False, destructiveHint=False,
                               idempotentHint=False, openWorldHint=False)
MUTATE_TOOL = ToolAnnotations(readOnlyHint=False, destructiveHint=True,
                               idempotentHint=False, openWorldHint=False)


@mcp.tool(annotations=READ_ONLY_TOOL)
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


@mcp.tool(annotations=READ_ONLY_TOOL)
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


@mcp.tool(annotations=READ_ONLY_TOOL)
async def list_objects(context: str = "root", parent: dict | None = None,
                       entity_type: str | None = None, include_hidden: bool = False,
                       include_generated: bool = False, limit: int = 50, offset: int = 0) -> dict:
    """List one bounded SketchUp collection; Face and Edge require an explicit type filter."""
    return await _scene_call("list_objects", {"context": context, "parent": parent,
        "entity_type": entity_type, "include_hidden": include_hidden,
        "include_generated": include_generated, "limit": limit, "offset": offset})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def find_objects(homecad_id: str | None = None, persistent_id: int | None = None,
                       entity_id: int | None = None, entity_type: str | None = None,
                       homecad_type: str | None = None, name: str | None = None,
                       tag: str | None = None, parent_id: int | str | None = None,
                       room_id: str | None = None,
                       metadata: dict | None = None, limit: int = 50, offset: int = 0) -> dict:
    """Find objects with explicit none, unique, ambiguous or multiple resolution."""
    filters = {key: value for key, value in locals().items()
               if value is not None and key not in ("limit", "offset")}
    return await _scene_call("find_objects", {**filters, "limit": limit, "offset": offset})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def get_object(target: dict) -> dict:
    """Inspect one uniquely identified SketchUp object with dimensions and metadata."""
    return await _scene_call("get_object", {"target": target})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def get_selection(limit: int = 50, offset: int = 0) -> dict:
    """Read selected objects using the same identity and serializer as get_object."""
    return await _scene_call("get_selection", {"limit": limit, "offset": offset})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def measure(kind: str, target: dict, other_target: dict | None = None) -> dict:
    """Measure bounds, dimensions, distances, face area or edge length in metric units."""
    params = {"kind": kind, "target": target}
    if other_target is not None:
        params["other_target"] = other_target
    return await _scene_call("measure", params)


@mcp.tool(annotations=READ_ONLY_TOOL)
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


@mcp.tool(annotations=UNDO_TOOL)
async def undo() -> dict:
    """Queue exactly one native SketchUp Undo action."""
    return await _scene_call("undo", {})


@mcp.tool(annotations=CREATE_TOOL)
async def create_group(name: str | None = None) -> dict:
    """Create a named, HomeCAD-managed Group in world coordinates."""
    params = {"name": name} if name is not None else {}
    return await _scene_call("create_group", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_face(points_mm: list[list[float]], name: str | None = None) -> dict:
    """Create a face inside a managed Group from world-coordinate millimeter points."""
    params = {"points_mm": points_mm}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_face", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_edge(start_mm: list[float], end_mm: list[float], name: str | None = None) -> dict:
    """Create a managed Group containing one edge between world-coordinate points."""
    params = {"start_mm": start_mm, "end_mm": end_mm}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_edge", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_box(width_mm: float, depth_mm: float, height_mm: float,
                     origin_mm: list[float] | None = None, name: str | None = None) -> dict:
    """Create a managed box Group; dimensions and world origin are in millimeters."""
    params = {"width_mm": width_mm, "depth_mm": depth_mm, "height_mm": height_mm}
    if origin_mm is not None:
        params["origin_mm"] = origin_mm
    if name is not None:
        params["name"] = name
    return await _scene_call("create_box", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_circle(radius_mm: float, center_mm: list[float] | None = None,
                        normal: list[float] | None = None, segments: int = 24,
                        name: str | None = None) -> dict:
    """Create a managed circle outline using millimeters and a direction vector."""
    params = {"radius_mm": radius_mm, "segments": segments}
    if center_mm is not None:
        params["center_mm"] = center_mm
    if normal is not None:
        params["normal"] = normal
    if name is not None:
        params["name"] = name
    return await _scene_call("create_circle", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_arc(radius_mm: float, start_angle_degrees: float = 0,
                     end_angle_degrees: float = 90, center_mm: list[float] | None = None,
                     normal: list[float] | None = None, x_axis: list[float] | None = None,
                     segments: int = 12, name: str | None = None) -> dict:
    """Create a managed arc; angles are degrees and lengths are millimeters."""
    params = {"radius_mm": radius_mm, "start_angle_degrees": start_angle_degrees,
              "end_angle_degrees": end_angle_degrees, "segments": segments}
    if center_mm is not None:
        params["center_mm"] = center_mm
    if normal is not None:
        params["normal"] = normal
    if x_axis is not None:
        params["x_axis"] = x_axis
    if name is not None:
        params["name"] = name
    return await _scene_call("create_arc", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_polygon(radius_mm: float, sides: int, center_mm: list[float] | None = None,
                         normal: list[float] | None = None, name: str | None = None) -> dict:
    """Create a managed regular polygon face with a circumradius in millimeters."""
    params = {"radius_mm": radius_mm, "sides": sides}
    if center_mm is not None:
        params["center_mm"] = center_mm
    if normal is not None:
        params["normal"] = normal
    if name is not None:
        params["name"] = name
    return await _scene_call("create_polygon", params)


@mcp.tool(annotations=MUTATE_TOOL)
async def push_pull(target: dict, distance_mm: float) -> dict:
    """Extrude a uniquely resolved Face inside a root-level Group by millimeters."""
    return await _scene_call("push_pull", {"target": target, "distance_mm": distance_mm})


@mcp.tool(annotations=MUTATE_TOOL)
async def follow_me(target: dict, path_points_mm: list[list[float]]) -> dict:
    """Sweep a uniquely resolved Face along bounded world-coordinate path points."""
    return await _scene_call("follow_me", {"target": target, "path_points_mm": path_points_mm})


@mcp.tool(annotations=MUTATE_TOOL)
async def transform_object(target: dict, transform: dict) -> dict:
    """Translate, rotate, or scale a uniquely resolved root-level object."""
    return await _scene_call("transform_object", {"target": target, "transform": transform})


@mcp.tool(annotations=CREATE_TOOL)
async def boolean_operation(target: dict, tool: dict, operation: str) -> dict:
    """Create a new solid result from two uniquely resolved manifold solids."""
    return await _scene_call("boolean_operation", {"target": target, "tool": tool,
                                                    "operation": operation})


def main() -> None:
    level = os.environ.get("HOMECAD_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(level=getattr(logging, level, logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    mcp.run(transport="stdio")
