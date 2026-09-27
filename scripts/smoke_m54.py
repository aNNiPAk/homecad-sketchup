"""Verify Cabinet and Kitchen cutlists in the marked disposable SketchUp fixture."""

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
                created_ids.extend(item["identity"]["homecad_id"] for item in result.get("created", []))
                return result

            async def undo() -> None:
                nonlocal pending
                result = await call("undo")
                if result.get("actions") != 1:
                    raise RuntimeError("Undo did not queue one operation")
                pending -= 1
                await asyncio.sleep(0.5)

            try:
                status = await call("homecad_status")
                if status.get("ruby_extension_version") != VERSION or "manufacturing.cutlist.v1" not in status.get("capabilities", []):
                    raise RuntimeError("matching M5.4 extension is not installed")
                before = await call("get_model_info")
                validate_disposable_fixture(True, before)
                made = await mutate("create_cabinet", {"width_mm": 600, "depth_mm": 560,
                    "height_mm": 720, "material_id": "smoke-board", "manufacturing": {
                        "parts": {"left_side": {"grain_axis": "length", "edge_band": {
                            "length_start": "smoke-edge", "length_end": "smoke-edge",
                            "width_start": "smoke-edge", "width_end": "smoke-edge"}}},
                        "hardware": [{"key": "hinge", "sku": "smoke-hinge", "quantity": 2}]}})
                cabinet_id = made["created"][0]["identity"]["homecad_id"]
                target = {"homecad_id": cabinet_id}
                first = await call("generate_cutlist", {"target": target, "limit": 100})
                if first["total"] != 6 or first["records"][0]["grain_axis"] != "length":
                    raise RuntimeError("Cabinet cutlist is incomplete")
                if first["records"][-1]["sku"] != "smoke-hinge":
                    raise RuntimeError("hardware was not included")
                await mutate("update_furniture_object", {"target": target,
                    "changes": {"detail_level": "concept"}})
                second = await call("generate_cutlist", {"target": target, "limit": 100})
                if first["records"] != second["records"]:
                    raise RuntimeError("Cabinet cutlist changed with LOD")
                await undo()
                await undo()
                wall = await mutate("create_wall", {"start_mm": [0, 0, 0],
                    "end_mm": [3000, 0, 0], "thickness_mm": 120, "height_mm": 2700})
                wall_id = wall["created"][0]["identity"]["homecad_id"]
                plan = await call("plan_kitchen_run", {"wall": {"homecad_id": wall_id},
                    "start_mm": 0, "end_mm": 1200, "side": "positive_v", "modules": [
                        {"key": "shelf", "type": "base_shelves", "width_mm": 600,
                         "material_id": "smoke-board"},
                        {"key": "oven", "type": "oven", "width_mm": 600}]})
                if plan["conflicts"]:
                    raise RuntimeError(f"unexpected Kitchen conflicts: {plan['conflicts']}")
                run = await mutate("apply_kitchen_run", {"plan": plan})
                run_id = run["created"][0]["identity"]["homecad_id"]
                schedule = await call("generate_cutlist", {"target": {"homecad_id": run_id}})
                if schedule["total"] != 5 or not any("oven" in item for item in schedule["warnings"]):
                    raise RuntimeError("Kitchen concept cutlist is incorrect")
                await undo()
                await undo()
                for identifier in created_ids:
                    found = await call("find_objects", {"homecad_id": identifier})
                    if found["resolution"] != "none":
                        raise RuntimeError(f"Undo left object {identifier}")
                after = await call("get_model_info")
                if after["root_entity_count"] != before["root_entity_count"]:
                    raise RuntimeError("fixture root entity count changed")
                print("M5.4 packaged smoke passed")
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
