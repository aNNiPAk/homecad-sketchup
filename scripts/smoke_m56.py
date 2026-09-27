"""Verify L-shaped countertop and panel variants in a disposable HomeCAD fixture."""

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
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"], env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            pending = 0
            created_ids = []

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
                created_ids.extend(item["identity"]["homecad_id"] for item in result.get("created", [])
                                   if item.get("identity", {}).get("homecad_id"))
                return result

            async def undo() -> None:
                nonlocal pending
                result = await call("undo")
                if result.get("actions") != 1:
                    raise RuntimeError("Undo did not queue one operation")
                pending -= 1
                await asyncio.sleep(0.5)

            async def expect_error(name: str, arguments: dict, category: str) -> None:
                response = await session.call_tool(name, arguments)
                message = " ".join(item.text for item in response.content if item.type == "text")
                if not response.isError or category not in message:
                    raise RuntimeError(f"expected {category} from {name}, got {message}")

            try:
                status = await call("homecad_status")
                if status.get("ruby_extension_version") != VERSION or "kitchen.variants.v1" not in status.get("capabilities", []):
                    raise RuntimeError("matching M5.6 extension is not installed")
                before = await call("get_model_info")
                validate_disposable_fixture(True, before)
                first = await mutate("create_wall", {"start_mm": [0, 0, 0],
                    "end_mm": [3000, 0, 0], "thickness_mm": 120, "height_mm": 2700})
                second = await mutate("create_wall", {"start_mm": [0, 0, 0],
                    "end_mm": [0, 3000, 0], "thickness_mm": 120, "height_mm": 2700})
                first_id = first["created"][0]["identity"]["homecad_id"]
                second_id = second["created"][0]["identity"]["homecad_id"]
                legs = [
                    {"key": "east", "wall": {"homecad_id": first_id}, "start_mm": 0,
                     "end_mm": 2200, "side": "positive_v", "modules": [
                         {"key": "a", "type": "base_shelves", "width_mm": 600}]},
                    {"key": "north", "wall": {"homecad_id": second_id}, "start_mm": 0,
                     "end_mm": 2200, "side": "negative_v", "modules": [
                         {"key": "b", "type": "base_shelves", "width_mm": 600}]},
                ]
                for mode in ("void", "blind_cabinet"):
                    corner = {"mode": mode, "span_first_mm": 900, "span_second_mm": 900}
                    if mode == "blind_cabinet":
                        corner["access_leg"] = "east"
                    countertop = {"enabled": True, "thickness_mm": 38,
                        "material_id": "smoke-stone", "first_end": {"style": "bevel", "bevel_mm": 60},
                        "second_end": {"style": "square"},
                        "cutouts": [{"key": "sink", "leg_key": "east", "offset_mm": 1100,
                                     "front_mm": 100, "width_mm": 200, "depth_mm": 200}]}
                    panels = {"first": {"thickness_mm": 18, "material_id": "smoke-oak",
                        "grain_axis": "length", "edge_band": {"length_start": "e1",
                        "length_end": "e2", "width_start": "e3", "width_end": "e4"}}}
                    invalid = {**countertop, "cutouts": [{**countertop["cutouts"][0], "offset_mm": 10}]}
                    await expect_error("plan_corner_kitchen_run", {"legs": legs,
                        "corner": corner, "countertop": invalid}, "constraint_violation")
                    plan = await call("plan_corner_kitchen_run", {"legs": legs,
                        "corner": corner, "name": f"M5.6 {mode}",
                        "countertop": countertop, "panels": panels})
                    if plan["conflicts"] or plan["params"]["layout_type"] != "l_shaped":
                        raise RuntimeError(f"corner plan invalid: {plan['conflicts']}")
                    made = await mutate("apply_kitchen_run", {"plan": plan})
                    run_id = made["created"][0]["identity"]["homecad_id"]
                    found = await call("find_objects", {"homecad_id": run_id})
                    if found["resolution"] != "unique":
                        raise RuntimeError("corner run identity is not unique")
                    if not plan["params"]["countertop"]["cutouts"]:
                        raise RuntimeError("countertop cutout was not retained")
                    view = await call("capture_view", {"view": "iso", "target": {"homecad_id": run_id},
                        "max_size": 1000, "restore_camera": True})
                    if view.get("camera_restored") is not True:
                        raise RuntimeError("corner screenshot changed the camera")
                    overhead = await call("capture_view", {"view": "top", "target": {"homecad_id": run_id},
                        "max_size": 1000, "restore_camera": True})
                    if overhead.get("camera_restored") is not True:
                        raise RuntimeError("countertop top screenshot changed the camera")
                    schedule = await call("generate_cutlist", {"target": {"homecad_id": run_id}})
                    top = next((row for row in schedule["records"] if row["part_key"] == "countertop"), None)
                    panel = next((row for row in schedule["records"] if row["part_key"] == "panel:first"), None)
                    if not top or top["record_kind"] != "shaped_panel" or len(top["cutouts_mm"]) != 1:
                        raise RuntimeError("shaped countertop is missing from cutlist")
                    if not panel or panel["edge_band"]["width_end"] != "e4":
                        raise RuntimeError("end panel is missing manufacturing edge data")
                    changed_top = {**countertop, "thickness_mm": 40}
                    await mutate("update_kitchen_run", {"target": {"homecad_id": run_id},
                        "changes": {"countertop": changed_top}})
                    await undo()
                    if mode == "blind_cabinet":
                        schedule = await call("generate_cutlist", {"target": {"homecad_id": run_id}})
                        if not any(item["part_key"].startswith("corner/") for item in schedule["records"]):
                            raise RuntimeError("blind corner parts are missing")
                        await expect_error("update_architecture_object", {"target": {"homecad_id": second_id},
                            "changes": {"start_mm": [100, 100, 0], "end_mm": [100, 3100, 0]}},
                            "constraint_violation")
                        moved = await mutate("update_architecture_object", {"target": {"homecad_id": second_id},
                            "changes": {"thickness_mm": 130}})
                        if not any(item["identity"]["homecad_id"] == run_id for item in moved["updated"]):
                            raise RuntimeError("corner run was not rebuilt with second Wall")
                        await undo()
                    await undo()
                await undo()
                await undo()
                for identifier in created_ids:
                    found = await call("find_objects", {"homecad_id": identifier})
                    if found["resolution"] != "none":
                        raise RuntimeError(f"Undo left object {identifier}")
                after = await call("get_model_info")
                if after["root_entity_count"] != before["root_entity_count"]:
                    raise RuntimeError("fixture root entity count changed")
                print("M5.6 packaged smoke passed")
            finally:
                while pending:
                    try:
                        await undo()
                    except Exception as error:
                        print(f"CLEANUP FAILED: {error}; disposable fixture may contain geometry", file=sys.stderr)
                        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-disposable", action="store_true", required=True)
    parser.parse_args()
    asyncio.run(run())
