"""Exercise M4 Furniture against a disposable SketchUp model only."""

import argparse
import asyncio
import base64
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from homecad_mcp import VERSION


class SmokeError(RuntimeError):
    pass


async def run(output: Path) -> None:
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"], env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            pending_undos = 0
            created_ids: list[str] = []
            initial_modified: bool | None = None
            output.parent.mkdir(parents=True, exist_ok=True)

            async def call(tool: str, arguments: dict | None = None) -> tuple[dict, list]:
                nonlocal pending_undos
                result = await session.call_tool(tool, arguments or {})
                if result.isError:
                    message = " ".join(item.text for item in result.content if item.type == "text")
                    raise SmokeError(f"{tool}: {message}")
                data = next((json.loads(item.text) for item in result.content if item.type == "text"), {})
                if data.get("status") == "success" and tool in {
                    "create_wall", "create_cabinet", "update_furniture_object",
                    "update_architecture_object", "delete_furniture_object",
                    "delete_architecture_object",
                }:
                    pending_undos += 1
                    created_ids.extend(obj["identity"]["homecad_id"] for obj in data.get("created", [])
                                       if obj.get("identity", {}).get("homecad_id"))
                print(f"{tool}: {json.dumps(data, ensure_ascii=True)}")
                return data, result.content

            async def expected_error(tool: str, arguments: dict, category: str) -> None:
                result = await session.call_tool(tool, arguments)
                message = " ".join(item.text for item in result.content if item.type == "text")
                if not result.isError or category not in message:
                    raise SmokeError(f"{tool} expected {category}, got {message!r}")
                print(f"{tool} expected error: {message}")

            async def undo_one() -> None:
                nonlocal pending_undos
                result, _ = await call("undo")
                if result.get("actions") != 1:
                    raise SmokeError("Undo did not queue exactly one SketchUp action")
                pending_undos -= 1
                await asyncio.sleep(0.4)

            async def get(identifier: str) -> dict:
                value, _ = await call("get_object", {"target": {"homecad_id": identifier}})
                return value

            async def run_steps() -> None:
                nonlocal initial_modified
                status, _ = await call("homecad_status")
                if status.get("connection_status") != "connected":
                    raise SmokeError("Open SketchUp with HomeCAD enabled before running this smoke test")
                if status.get("ruby_extension_version") != VERSION:
                    raise SmokeError(f"Python is {VERSION}, installed Ruby extension is {status.get('ruby_extension_version')!r}")
                if "furniture.core.v1" not in status.get("capabilities", []):
                    raise SmokeError("Installed RBZ does not advertise furniture.core.v1; install the M4 RBZ and restart SketchUp")
                info, _ = await call("get_model_info")
                initial_modified = info["modified"]

                wall, _ = await call("create_wall", {"start_mm": [0, 0, 0], "end_mm": [4000, 0, 0],
                    "thickness_mm": 120, "height_mm": 2700, "name": "M4 Smoke Wall"})
                wall_id = wall["created"][0]["identity"]["homecad_id"]
                cabinet, _ = await call("create_cabinet", {"width_mm": 600, "depth_mm": 560,
                    "height_mm": 720, "panel_thickness_mm": 18, "back_thickness_mm": 4,
                    "shelf_z_mm": [300], "fronts": [{"key": "door", "kind": "door", "x_mm": 0,
                        "z_mm": 0, "width_mm": 600, "height_mm": 720, "hinge": "left"}],
                    "detail_level": "construction", "placement": {"mode": "wall", "wall_id": wall_id,
                        "offset_mm": 1000, "bottom_mm": 0, "side": "positive_v", "clearance_mm": 0},
                    "name": "M4 Smoke Cabinet"})
                cabinet_id = cabinet["created"][0]["identity"]["homecad_id"]
                metadata = cabinet["created"][0]["metadata"]
                if metadata.get("type") != "furniture.cabinet" or not metadata.get("homecad_id"):
                    raise SmokeError("Cabinet is missing generated HomeCAD identity metadata")
                frame, _ = await call("get_furniture_frame", {"target": {"homecad_id": cabinet_id}})
                if frame["width_mm"] != 600 or frame["depth_mm"] != 560 or frame["height_mm"] != 720:
                    raise SmokeError("Furniture frame does not match the requested case dimensions")
                if frame["x_axis"] != [1.0, 0.0, 0.0] or frame["y_axis"] != [0.0, 1.0, 0.0]:
                    raise SmokeError("positive_v Cabinet frame does not align with Wall U/V")
                schedule, _ = await call("list_furniture_parts", {"target": {"homecad_id": cabinet_id}})
                if schedule["count"] != 7:
                    raise SmokeError(f"expected 7 scheduled panels, got {schedule['count']}")

                image_result, image_content = await call("capture_view", {"view": "iso", "target": {"homecad_id": cabinet_id},
                    "max_size": 1000, "restore_camera": True})
                image = next((item for item in image_content if item.type == "image" and item.mimeType == "image/png"), None)
                if image is None:
                    raise SmokeError("capture_view did not return an MCP PNG image")
                screenshot_path = output.with_suffix(".png")
                screenshot_path.parent.mkdir(parents=True, exist_ok=True)
                screenshot_path.write_bytes(base64.b64decode(image.data, validate=True))
                print(f"saved screenshot: {screenshot_path.resolve()}")

                wall_update, _ = await call("update_architecture_object", {"target": {"homecad_id": wall_id},
                    "changes": {"start_mm": [200, 100, 0], "end_mm": [200, 4100, 0]}})
                moved_frame, _ = await call("get_furniture_frame", {"target": {"homecad_id": cabinet_id}})
                if moved_frame["origin_mm"] == frame["origin_mm"]:
                    raise SmokeError("wall rotation did not relocate the Cabinet")
                relocated = await get(cabinet_id)
                if relocated["parameters"]["placement"]["offset_mm"] != 1000:
                    raise SmokeError("wall update changed the Cabinet's local U offset")
                await expected_error("update_architecture_object", {"target": {"homecad_id": wall_id},
                    "changes": {"end_mm": [700, 100, 0]}}, "constraint_violation")
                unchanged = await get(cabinet_id)
                if unchanged["metadata"]["revision"] != relocated["metadata"]["revision"]:
                    raise SmokeError("rejected wall update changed the Cabinet revision")

                await undo_one()  # restore wall frame and Cabinet placement
                restored_frame, _ = await call("get_furniture_frame", {"target": {"homecad_id": cabinet_id}})
                if restored_frame["origin_mm"] != frame["origin_mm"]:
                    raise SmokeError("Undo did not restore wall-attached Cabinet placement")
                update, _ = await call("update_furniture_object", {"target": {"homecad_id": cabinet_id},
                    "changes": {"height_mm": 800}})
                if update["revision"] != 3:
                    raise SmokeError("Cabinet revision did not advance once after update")
                await undo_one()
                current = await get(cabinet_id)
                if current["parameters"]["height_mm"] != 720:
                    raise SmokeError("Cabinet parameter update Undo did not restore height")
                await call("delete_architecture_object", {"target": {"homecad_id": wall_id}, "cascade": True})
                await undo_one()
                if (await get(wall_id))["metadata"]["type"] != "architecture.wall":
                    raise SmokeError("Undo did not restore the Wall")
                if (await get(cabinet_id))["metadata"]["type"] != "furniture.cabinet":
                    raise SmokeError("Undo did not restore the Cabinet")

            try:
                await run_steps()
            finally:
                cleanup_failed = False
                while pending_undos > 0:
                    try:
                        await undo_one()
                    except Exception as error:  # report cleanup failure without hiding original smoke error
                        print(f"CLEANUP FAILED: {error}", file=sys.stderr)
                        cleanup_failed = True
                        break
                for identifier in created_ids:
                    result = await session.call_tool("find_objects", {"homecad_id": identifier, "limit": 5})
                    if result.isError:
                        cleanup_failed = True
                        print(f"CLEANUP FAILED: could not verify {identifier}", file=sys.stderr)
                        continue
                    data = next((json.loads(item.text) for item in result.content if item.type == "text"), {})
                    if data.get("resolution") != "none":
                        cleanup_failed = True
                        print(f"CLEANUP FAILED: smoke object {identifier} remains", file=sys.stderr)
                if cleanup_failed:
                    print("The disposable SketchUp model may still contain HomeCAD smoke geometry.", file=sys.stderr)
                if initial_modified is not None:
                    final, _ = await call("get_model_info")
                    print(f"model modified state: before={initial_modified}, after={final['modified']}")
                    if final["modified"] != initial_modified:
                        print("The model modified state differs after smoke; inspect the disposable model before saving.", file=sys.stderr)
                if cleanup_failed:
                    raise SmokeError("CLEANUP FAILED")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run M4 Furniture smoke against a disposable SketchUp model.")
    parser.add_argument("--confirm-disposable", action="store_true",
                        help="confirm that the active SketchUp model is disposable/test data")
    parser.add_argument("--output", type=Path, default=Path("dist/m4-smoke/cabinet.png"))
    args = parser.parse_args()
    if not args.confirm_disposable:
        parser.error("M4 smoke mutates SketchUp. Open a disposable model and pass --confirm-disposable.")
    try:
        asyncio.run(run(args.output))
    except SmokeError as error:
        print(f"smoke_m4: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
