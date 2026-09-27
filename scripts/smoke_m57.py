"""Verify a generic wooden drawer on the dedicated disposable SketchUp fixture."""

import argparse
import asyncio
import json
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from homecad_mcp import VERSION
from smoke_guard import validate_disposable_fixture


async def run() -> None:
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"],
                                   env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            pending = 0
            cabinet_id = None

            async def call(name: str, arguments: dict | None = None) -> dict:
                response = await session.call_tool(name, arguments or {})
                body = next((item.text for item in response.content if item.type == "text"), "{}")
                if response.isError:
                    raise RuntimeError(f"{name}: {body}")
                return json.loads(body)

            async def mutate(name: str, arguments: dict) -> dict:
                nonlocal pending
                result = await call(name, arguments)
                pending += 1
                return result

            async def undo() -> None:
                nonlocal pending
                result = await call("undo")
                if result.get("actions") != 1:
                    raise RuntimeError("Undo did not queue exactly one operation")
                pending -= 1
                await asyncio.sleep(0.5)

            async def expect_error(name: str, arguments: dict, category: str) -> None:
                response = await session.call_tool(name, arguments)
                message = " ".join(item.text for item in response.content if item.type == "text")
                if not response.isError or category not in message:
                    raise RuntimeError(f"expected {category} from {name}, got {message}")

            try:
                status = await call("homecad_status")
                if status.get("ruby_extension_version") != VERSION or \
                        "furniture.hardware.v1" not in status.get("capabilities", []):
                    raise RuntimeError("matching M5.7 extension is not installed")
                before = await call("get_model_info")
                validate_disposable_fixture(True, before)
                family = (await call("list_hardware_catalog"))["families"][0]["id"]
                made = await mutate("create_cabinet", {
                    "width_mm": 600, "depth_mm": 560, "height_mm": 720,
                    "fronts": [
                        {"key": "front", "kind": "drawer_front", "x_mm": 0,
                         "z_mm": 0, "width_mm": 600, "height_mm": 360},
                        {"key": "lower_front", "kind": "drawer_front", "x_mm": 0,
                         "z_mm": 360, "width_mm": 600, "height_mm": 360}],
                })
                cabinet_id = made["created"][0]["identity"]["homecad_id"]
                target = {"homecad_id": cabinet_id}
                drawer = {"key": "upper", "front_key": "front", "bottom_mm": 100,
                    "height_mm": 200, "depth_mm": 450, "side_thickness_mm": 16,
                    "base_thickness_mm": 8,
                    "slide": {"family_id": family, "sku": "PROJECT-SLIDE-450",
                              "nominal_length_mm": 450, "side_clearance_mm": 12}}
                lower = {**drawer, "key": "lower", "front_key": "lower_front",
                         "bottom_mm": 400, "height_mm": 180, "depth_mm": 380,
                         "slide": {**drawer["slide"], "nominal_length_mm": 380}}
                proposal = await call("plan_cabinet_drawer", {"target": target, "drawer": drawer})
                if len(proposal["parts"]) != 5 or proposal["hardware"][0]["unit"] != "pair":
                    raise RuntimeError("drawer preview has an invalid composition")
                invalid = {**drawer, "slide": {**drawer["slide"], "nominal_length_mm": 500}}
                await expect_error("plan_cabinet_drawer", {"target": target, "drawer": invalid},
                                   "constraint_violation")
                updated = await mutate("update_furniture_object", {"target": target,
                    "changes": {"drawers": [drawer, lower]}})
                if updated["revision"] != 2:
                    raise RuntimeError("Cabinet revision did not increase once")
                obj = await call("get_object", {"target": target})
                if [item["key"] for item in obj.get("parameters", {}).get("drawers", [])] != ["upper", "lower"]:
                    raise RuntimeError("drawer parameters were not persisted")
                children = await call("list_objects", {"parent": target,
                    "include_generated": True, "limit": 100})
                child_names = {item["name"] for item in children["objects"]}
                if not {"drawer:upper/base", "drawer:upper/left_side",
                        "drawer:upper/right_side", "drawer:upper/back",
                        "drawer:upper/front", "drawer:lower/base",
                        "drawer:lower/left_side", "drawer:lower/right_side",
                        "drawer:lower/back", "drawer:lower/front"} <= child_names:
                    raise RuntimeError("SketchUp did not generate all ten drawer panels")
                part_records = await call("list_furniture_parts", {"target": target})
                parts = {part["part_key"]: part for part in part_records["parts"]
                         if part["part_key"].startswith("drawer:")}
                if len(parts) != 10:
                    raise RuntimeError("parameter schedule did not produce ten drawer panels")
                for child in children["objects"]:
                    key = child["name"]
                    if key not in parts:
                        continue
                    part = parts[key]
                    info = await call("get_object", {"target": {
                        "persistent_id": child["identity"]["persistent_id"]}})
                    box = info["bbox_mm"]
                    if part["part_kind"] == "drawer_base":
                        size = [part["width_mm"], part["height_mm"], part["thickness_mm"]]
                    elif part["part_kind"] == "drawer_side":
                        size = [part["thickness_mm"], part["width_mm"], part["height_mm"]]
                    else:
                        size = [part["width_mm"], part["thickness_mm"], part["height_mm"]]
                    expected_max = [origin + length for origin, length in zip(part["origin_mm"], size)]
                    if any(abs(actual - expected) > 1 for actual, expected in zip(box["min"], part["origin_mm"])) or \
                            any(abs(actual - expected) > 1 for actual, expected in zip(box["max"], expected_max)):
                        raise RuntimeError(f"{key} bounds disagree with parameter schedule: {box}")
                schedule = await call("generate_cutlist", {"target": target})
                drawer_rows = [row for row in schedule["records"] if row["part_key"].startswith("drawer:")]
                if len(drawer_rows) != 12 or sum(row["record_kind"] == "hardware"
                                                  for row in drawer_rows) != 2:
                    raise RuntimeError("drawer cutlist has missing or duplicate records")
                if not schedule["warnings"] or "project-selected" not in schedule["warnings"][0]:
                    raise RuntimeError("drawer cutlist lacks preliminary-manufacturing warning")
                for key, part in parts.items():
                    record = next(row for row in drawer_rows if row["part_key"] == key)
                    if any(record[field] != part[field] for field in ("width_mm", "thickness_mm")) or \
                            record["length_mm"] != part["height_mm"]:
                        raise RuntimeError(f"{key} cutlist dimensions disagree with geometry")
                purchased = next(row for row in drawer_rows if row["record_kind"] == "hardware")
                if purchased["quantity"] != 1 or purchased["unit"] != "pair":
                    raise RuntimeError("slide pair quantity is incorrect")
                view = await call("capture_view", {"view": "iso", "target": target,
                    "max_size": 1000, "restore_camera": True})
                if view.get("camera_restored") is not True:
                    raise RuntimeError("drawer screenshot changed the camera")
                await mutate("update_furniture_object", {"target": target,
                    "changes": {"detail_level": "concept"}})
                concept = await call("generate_cutlist", {"target": target})
                if concept["records"] != schedule["records"]:
                    raise RuntimeError("drawer cutlist changed with display detail level")
                await undo()
                await expect_error("update_furniture_object", {"target": target,
                    "changes": {"drawers": [invalid]}}, "constraint_violation")
                await expect_error("update_furniture_object", {"target": target,
                    "changes": {"fronts": []}}, "constraint_violation")
                unchanged = await call("get_object", {"target": target})
                if unchanged["metadata"]["revision"] != 2:
                    raise RuntimeError("failed drawer update changed Cabinet revision")
                if unchanged["parameters"] != obj["parameters"]:
                    raise RuntimeError("failed drawer update changed Cabinet parameters")
                preserved = await call("list_objects", {"parent": target,
                    "include_generated": True, "limit": 100})
                if {part["name"] for part in preserved["objects"]} != child_names:
                    raise RuntimeError("failed drawer update changed generated parts")
                await undo()
                cleared = await call("get_object", {"target": target})
                if cleared.get("parameters", {}).get("drawers"):
                    raise RuntimeError("Undo left drawer parameters")
                await undo()
                found = await call("find_objects", {"homecad_id": cabinet_id})
                if found["resolution"] != "none":
                    raise RuntimeError("Undo left the test Cabinet")

                wall = await mutate("create_wall", {
                    "start_mm": [1000, 1000, 0], "end_mm": [1000, 5000, 0],
                    "thickness_mm": 120, "height_mm": 2700})
                wall_id = wall["created"][0]["identity"]["homecad_id"]
                placed = await mutate("create_cabinet", {
                    "width_mm": 600, "depth_mm": 560, "height_mm": 720,
                    "fronts": [{"key": "front", "kind": "drawer_front", "x_mm": 0,
                                "z_mm": 0, "width_mm": 600, "height_mm": 720}],
                    "drawers": [drawer],
                    "placement": {"mode": "wall", "wall_id": wall_id, "offset_mm": 1000,
                                  "bottom_mm": 0, "side": "positive_v", "clearance_mm": 10}})
                placed_id = placed["created"][0]["identity"]["homecad_id"]
                placed_target = {"homecad_id": placed_id}
                frame = await call("get_furniture_frame", {"target": placed_target})
                if frame["origin_mm"] != [930, 2000, 0] or \
                        frame["x_axis"] != [0, 1, 0] or frame["y_axis"] != [-1, 0, 0]:
                    raise RuntimeError(f"wall-mounted Cabinet frame is incorrect: {frame}")
                mounted_parts = await call("list_furniture_parts", {"target": placed_target})
                mounted = {part["part_key"]: part for part in mounted_parts["parts"]
                           if part["part_key"].startswith("drawer:")}
                mounted_children = await call("list_objects", {"parent": placed_target,
                    "include_generated": True, "limit": 100})
                if len(mounted) != 5:
                    raise RuntimeError("wall-mounted Cabinet lacks drawer panel records")
                for child in mounted_children["objects"]:
                    if child["name"] not in mounted:
                        continue
                    part = mounted[child["name"]]
                    if part["part_kind"] == "drawer_base":
                        size = [part["width_mm"], part["height_mm"], part["thickness_mm"]]
                    elif part["part_kind"] == "drawer_side":
                        size = [part["thickness_mm"], part["width_mm"], part["height_mm"]]
                    else:
                        size = [part["width_mm"], part["thickness_mm"], part["height_mm"]]
                    x, y, z = part["origin_mm"]
                    sx, sy, sz = size
                    expected_min = [frame["origin_mm"][0] - y - sy,
                                    frame["origin_mm"][1] + x, z]
                    expected_max = [frame["origin_mm"][0] - y,
                                    frame["origin_mm"][1] + x + sx, z + sz]
                    info = await call("get_object", {"target": {
                        "persistent_id": child["identity"]["persistent_id"]}})
                    box = info["bbox_mm"]
                    if any(abs(actual - expected) > 1 for actual, expected in zip(box["min"], expected_min)) or \
                            any(abs(actual - expected) > 1 for actual, expected in zip(box["max"], expected_max)):
                        raise RuntimeError(f"wall-mounted {child['name']} has incorrect world bounds: {box}")
                await undo()
                await undo()
                for identifier in (placed_id, wall_id):
                    if (await call("find_objects", {"homecad_id": identifier}))["resolution"] != "none":
                        raise RuntimeError("Undo left the wall-mounted smoke geometry")
                after = await call("get_model_info")
                if after["root_entity_count"] != before["root_entity_count"]:
                    raise RuntimeError("disposable fixture root entity count changed")
                print("M5.7 packaged smoke passed")
            finally:
                while pending:
                    try:
                        await undo()
                    except Exception as error:
                        print(f"CLEANUP FAILED: {error}; disposable fixture may contain geometry",
                              file=sys.stderr)
                        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-disposable", action="store_true", required=True)
    parser.parse_args()
    asyncio.run(run())
