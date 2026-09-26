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


@mcp.tool(annotations=READ_ONLY_TOOL)
async def get_wall_frame(wall: dict) -> dict:
    """Read a Wall's world origin and stable local U/V/Z frame."""
    return await _scene_call("get_wall_frame", {"wall": wall})


@mcp.tool(annotations=CREATE_TOOL)
async def create_wall(start_mm: list[float], end_mm: list[float], thickness_mm: float,
                      height_mm: float, name: str | None = None) -> dict:
    """Create a generated vertical wall from world-coordinate millimeter parameters."""
    params = {"start_mm": start_mm, "end_mm": end_mm,
              "thickness_mm": thickness_mm, "height_mm": height_mm}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_wall", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_opening(wall: dict, offset_mm: float, bottom_mm: float,
                         width_mm: float, height_mm: float, name: str | None = None) -> dict:
    """Cut a rectangular through opening hosted by a wall."""
    params = {"wall": wall, "offset_mm": offset_mm, "bottom_mm": bottom_mm,
              "width_mm": width_mm, "height_mm": height_mm}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_opening", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_door(wall: dict, offset_mm: float, width_mm: float, height_mm: float,
                      side: str = "center", name: str | None = None) -> dict:
    """Create a semantic door with a through cut beginning at the wall base."""
    params = {"wall": wall, "offset_mm": offset_mm, "width_mm": width_mm,
              "height_mm": height_mm, "side": side}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_door", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_window(wall: dict, offset_mm: float, bottom_mm: float,
                        width_mm: float, height_mm: float, side: str = "center",
                        name: str | None = None) -> dict:
    """Create a semantic window with a through cut in its host wall."""
    params = {"wall": wall, "offset_mm": offset_mm, "bottom_mm": bottom_mm,
              "width_mm": width_mm, "height_mm": height_mm, "side": side}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_window", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_niche(wall: dict, offset_mm: float, bottom_mm: float,
                       width_mm: float, height_mm: float, depth_mm: float,
                       side: str, name: str | None = None) -> dict:
    """Create a partial-depth rectangular niche on positive_v or negative_v."""
    params = {"wall": wall, "offset_mm": offset_mm, "bottom_mm": bottom_mm,
              "width_mm": width_mm, "height_mm": height_mm,
              "depth_mm": depth_mm, "side": side}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_niche", params)


@mcp.tool(annotations=CREATE_TOOL)
async def create_column(origin_mm: list[float], width_mm: float, depth_mm: float,
                        height_mm: float, rotation_degrees: float = 0,
                        name: str | None = None) -> dict:
    """Create a rectangular vertical column in world coordinates."""
    params = {"origin_mm": origin_mm, "width_mm": width_mm,
              "depth_mm": depth_mm, "height_mm": height_mm,
              "rotation_degrees": rotation_degrees}
    if name is not None:
        params["name"] = name
    return await _scene_call("create_column", params)


@mcp.tool(annotations=MUTATE_TOOL)
async def update_architecture_object(target: dict, changes: dict) -> dict:
    """Update semantic parameters and regenerate one architecture object."""
    return await _scene_call("update_architecture_object", {"target": target, "changes": changes})


@mcp.tool(annotations=MUTATE_TOOL)
async def delete_architecture_object(target: dict, cascade: bool = False) -> dict:
    """Delete an architecture object; wall dependencies require cascade=true."""
    return await _scene_call("delete_architecture_object", {"target": target, "cascade": cascade})


@mcp.tool(annotations=CREATE_TOOL)
async def create_room(name: str, wall_ids: list[str]) -> dict:
    """Create a semantic Room from an explicitly ordered, closed wall loop."""
    return await _scene_call("create_room", {"name": name, "wall_ids": wall_ids})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def detect_rooms() -> dict:
    """Find simple closed loops of HomeCAD walls without creating Room objects."""
    return await _scene_call("detect_rooms", {})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def get_furniture_frame(target: dict) -> dict:
    """Read the Cabinet origin and right-handed local frame in world coordinates."""
    return await _scene_call("get_furniture_frame", {"target": target})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def list_furniture_parts(target: dict) -> dict:
    """Return a parameter-derived millimeter part schedule for a Cabinet."""
    return await _scene_call("list_furniture_parts", {"target": target})


@mcp.tool(annotations=CREATE_TOOL)
async def create_cabinet(width_mm: float, depth_mm: float, height_mm: float,
                         panel_thickness_mm: float = 18, back_thickness_mm: float = 4,
                         shelf_z_mm: list[float] | None = None, fronts: list[dict] | None = None,
                         detail_level: str = "construction", placement: dict | None = None,
                         name: str = "Cabinet") -> dict:
    """Create a parametric Cabinet; all dimensions and coordinates are millimeters."""
    params = {"width_mm": width_mm, "depth_mm": depth_mm, "height_mm": height_mm,
              "panel_thickness_mm": panel_thickness_mm, "back_thickness_mm": back_thickness_mm,
              "shelf_z_mm": shelf_z_mm or [], "fronts": fronts or [],
              "detail_level": detail_level, "name": name}
    if placement is not None:
        params["placement"] = placement
    return await _scene_call("create_cabinet", params)


@mcp.tool(annotations=MUTATE_TOOL)
async def update_furniture_object(target: dict, changes: dict) -> dict:
    """Update Cabinet parameters and regenerate its generated parts."""
    return await _scene_call("update_furniture_object", {"target": target, "changes": changes})


@mcp.tool(annotations=MUTATE_TOOL)
async def delete_furniture_object(target: dict) -> dict:
    """Delete a Cabinet and return its pre-delete tombstone."""
    return await _scene_call("delete_furniture_object", {"target": target})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def plan_kitchen_run(wall: dict, start_mm: float, end_mm: float,
                           side: str, modules: list[dict], clearance_mm: float = 0,
                           filler_max_mm: float = 150, countertop: bool | None = None,
                           countertop_thickness_mm: float = 38,
                           plinth: bool | None = None, name: str = "Kitchen run") -> dict:
    """Plan ordered modules on one Wall side in millimeters without modifying SketchUp."""
    params = {"wall": wall, "start_mm": start_mm, "end_mm": end_mm,
              "side": side, "modules": modules, "clearance_mm": clearance_mm,
              "filler_max_mm": filler_max_mm,
              "countertop_thickness_mm": countertop_thickness_mm, "name": name}
    if countertop is not None:
        params["countertop"] = countertop
    if plinth is not None:
        params["plinth"] = plinth
    return await _scene_call("plan_kitchen_run", params)


@mcp.tool(annotations=CREATE_TOOL)
async def apply_kitchen_run(plan: dict) -> dict:
    """Apply a current conflict-free kitchen plan in one SketchUp Undo operation."""
    return await _scene_call("apply_kitchen_run", {"plan": plan})


@mcp.tool(annotations=READ_ONLY_TOOL)
async def validate_kitchen(target: dict) -> dict:
    """Check an existing KitchenRun against current walls, cuts and attachments."""
    return await _scene_call("validate_kitchen", {"target": target})


@mcp.tool(annotations=MUTATE_TOOL)
async def update_kitchen_run(target: dict, changes: dict) -> dict:
    """Update KitchenRun parameters and regenerate its managed child geometry."""
    return await _scene_call("update_kitchen_run", {"target": target, "changes": changes})


@mcp.tool(annotations=MUTATE_TOOL)
async def delete_kitchen_run(target: dict) -> dict:
    """Delete one managed KitchenRun and its generated children."""
    return await _scene_call("delete_kitchen_run", {"target": target})


def main() -> None:
    level = os.environ.get("HOMECAD_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(level=getattr(logging, level, logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    mcp.run(transport="stdio")
