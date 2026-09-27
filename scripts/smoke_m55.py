"""Verify both L-shaped KitchenRun corner modes in the disposable HomeCAD fixture."""

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
                if status.get("ruby_extension_version") != VERSION or "kitchen.corner_run.v1" not in status.get("capabilities", []):
                    raise RuntimeError("matching M5.5 extension is not installed")
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
                    plan = await call("plan_corner_kitchen_run", {"legs": legs,
                        "corner": corner, "name": f"M5.5 {mode}"})
                    if plan["conflicts"] or plan["params"]["layout_type"] != "l_shaped":
                        raise RuntimeError(f"corner plan invalid: {plan['conflicts']}")
                    made = await mutate("apply_kitchen_run", {"plan": plan})
                    run_id = made["created"][0]["identity"]["homecad_id"]
                    found = await call("find_objects", {"homecad_id": run_id})
                    if found["resolution"] != "unique":
                        raise RuntimeError("corner run identity is not unique")
                    view = await call("capture_view", {"view": "iso", "target": {"homecad_id": run_id},
                        "max_size": 1000, "restore_camera": True})
                    if view.get("camera_restored") is not True:
                        raise RuntimeError("corner screenshot changed the camera")
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
                print("M5.5 packaged smoke passed")
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
