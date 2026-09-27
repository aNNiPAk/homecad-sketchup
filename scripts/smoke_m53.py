"""Verify M5.3 in the marked disposable SketchUp fixture only."""

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
            created_id = None

            async def call(name: str, args: dict | None = None) -> dict:
                response = await session.call_tool(name, args or {})
                body = next((item.text for item in response.content if item.type == "text"), "{}")
                if response.isError:
                    raise RuntimeError(f"{name}: {body}")
                return json.loads(body)

            async def undo() -> None:
                nonlocal pending
                result = await call("undo")
                if result.get("actions") != 1:
                    raise RuntimeError("Undo did not queue exactly one operation")
                pending -= 1
                await asyncio.sleep(0.5)

            try:
                status = await call("homecad_status")
                if status.get("ruby_extension_version") != VERSION or not {
                    "project.defaults.v1", "furniture.presets.v1"
                } <= set(status.get("capabilities", [])):
                    raise RuntimeError("matching M5.3 extension is not installed")
                before = await call("get_model_info")
                validate_disposable_fixture(True, before)
                initial = await call("get_project_settings")
                presets = await call("list_furniture_presets")
                if not any(item["id"] == "base_open.v1" for item in presets["presets"]):
                    raise RuntimeError("base_open.v1 preset is missing")
                created = await call("create_cabinet_from_preset", {
                    "preset_id": "base_open.v1", "overrides": {"name": "M5.3 Smoke Cabinet"}
                })
                pending += 1
                created_id = created["created"][0]["identity"]["homecad_id"]
                next_panel = initial["values"]["panel_thickness_mm"] + 1
                changed = await call("update_project_settings", {
                    "changes": {"panel_thickness_mm": next_panel}
                })
                pending += 1
                if not any(item["identity"]["homecad_id"] == created_id for item in changed["updated"]):
                    raise RuntimeError("inherited Cabinet was not updated")
                detail = await call("get_object", {"target": {"homecad_id": created_id}})
                if detail["metadata"]["revision"] != 2:
                    raise RuntimeError("Cabinet revision did not increment once")
                await undo()
                restored = await call("get_project_settings")
                if restored != initial:
                    raise RuntimeError("project defaults were not restored by Undo")
                await undo()
                found = await call("find_objects", {"homecad_id": created_id})
                if found["resolution"] != "none":
                    raise RuntimeError("preset Cabinet survived Undo")
                after = await call("get_model_info")
                if after["root_entity_count"] != before["root_entity_count"]:
                    raise RuntimeError("fixture root entity count changed")
                print("M5.3 packaged smoke passed")
            finally:
                while pending > 0:
                    try:
                        await undo()
                    except Exception as error:
                        print(f"CLEANUP FAILED: {error}; disposable fixture may contain geometry", file=sys.stderr)
                        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-disposable", action="store_true", required=True)
    args = parser.parse_args()
    asyncio.run(run())
