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
                    "fronts": [{"key": "front", "kind": "drawer_front", "x_mm": 0,
                                "z_mm": 0, "width_mm": 600, "height_mm": 720}],
                })
                cabinet_id = made["created"][0]["identity"]["homecad_id"]
                target = {"homecad_id": cabinet_id}
                drawer = {"key": "upper", "front_key": "front", "bottom_mm": 100,
                    "height_mm": 200, "depth_mm": 450, "side_thickness_mm": 16,
                    "base_thickness_mm": 8,
                    "slide": {"family_id": family, "sku": "PROJECT-SLIDE-450",
                              "nominal_length_mm": 450, "side_clearance_mm": 12}}
                proposal = await call("plan_cabinet_drawer", {"target": target, "drawer": drawer})
                if len(proposal["parts"]) != 5 or proposal["hardware"][0]["unit"] != "pair":
                    raise RuntimeError("drawer preview has an invalid composition")
                invalid = {**drawer, "slide": {**drawer["slide"], "nominal_length_mm": 500}}
                await expect_error("plan_cabinet_drawer", {"target": target, "drawer": invalid},
                                   "constraint_violation")
                updated = await mutate("update_furniture_object", {"target": target,
                    "changes": {"drawers": [drawer]}})
                if updated["revision"] != 2:
                    raise RuntimeError("Cabinet revision did not increase once")
                obj = await call("get_object", {"target": target})
                if obj.get("parameters", {}).get("drawers", [{}])[0].get("key") != "upper":
                    raise RuntimeError("drawer parameters were not persisted")
                children = await call("list_objects", {"parent": target,
                    "include_generated": True, "limit": 100})
                child_names = {item["name"] for item in children["objects"]}
                if not {"drawer:upper/base", "drawer:upper/left_side",
                        "drawer:upper/right_side", "drawer:upper/back",
                        "drawer:upper/front"} <= child_names:
                    raise RuntimeError("SketchUp did not generate all five drawer panels")
                schedule = await call("generate_cutlist", {"target": target})
                drawer_rows = [row for row in schedule["records"]
                               if row["part_key"].startswith("drawer:upper/")]
                if len(drawer_rows) != 6 or sum(row["record_kind"] == "hardware"
                                                 for row in drawer_rows) != 1:
                    raise RuntimeError("drawer cutlist has missing or duplicate records")
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
                unchanged = await call("get_object", {"target": target})
                if unchanged["metadata"]["revision"] != 2:
                    raise RuntimeError("failed drawer update changed Cabinet revision")
                await undo()
                cleared = await call("get_object", {"target": target})
                if cleared.get("parameters", {}).get("drawers"):
                    raise RuntimeError("Undo left drawer parameters")
                await undo()
                found = await call("find_objects", {"homecad_id": cabinet_id})
                if found["resolution"] != "none":
                    raise RuntimeError("Undo left the test Cabinet")
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
