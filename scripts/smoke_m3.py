"""Exercise M3 Architecture against a disposable SketchUp model."""

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
            initial_info: dict = {}
            output.parent.mkdir(parents=True, exist_ok=True)

            async def call(tool: str, arguments: dict | None = None):
                nonlocal pending_undos
                result = await session.call_tool(tool, arguments or {})
                if result.isError:
                    message = " ".join(item.text for item in result.content if item.type == "text")
                    raise SmokeError(f"{tool}: {message}")
                data = next((json.loads(item.text) for item in result.content if item.type == "text"), {})
                if data.get("status") == "success" and tool in {
                    "create_wall", "create_opening", "create_door", "create_window",
                    "create_niche", "create_column", "create_room", "update_architecture_object",
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
                await asyncio.sleep(0.35)

            async def get(identifier: str) -> dict:
                result, _ = await call("get_object", {"target": {"homecad_id": identifier}})
                return result

            async def find(identifier: str) -> dict:
                result, _ = await call("find_objects", {"homecad_id": identifier, "limit": 5})
                return result

            async def screenshot(filename: str, target: str | None = None, view: str = "iso") -> None:
                args = {"view": view, "max_size": 1200, "restore_camera": True}
                if target:
                    args["target"] = {"homecad_id": target}
                result, content = await call("capture_view", args)
                image = next((item for item in content if item.type == "image" and item.mimeType == "image/png"), None)
                png = base64.b64decode(image.data, validate=True) if image else base64.b64decode(result["image_base64"])
                if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise SmokeError("capture_view did not return PNG data")
                path = output.with_name(f"{output.stem}-{filename}.png")
                path.write_bytes(png)
                print(f"saved screenshot: {path.resolve()}")

            async def create_wall(start: list[float], end: list[float], name: str) -> str:
                data, _ = await call("create_wall", {"start_mm": start, "end_mm": end,
                    "thickness_mm": 120, "height_mm": 2700, "name": name})
                identifier = data["created"][0]["identity"]["homecad_id"]
                if not identifier or (await find(identifier)).get("resolution") != "unique":
                    raise SmokeError(f"Wall {name} did not receive a unique HomeCAD identity")
                return identifier

            async def run_steps() -> None:
                nonlocal initial_info
                status, _ = await call("homecad_status")
                if status.get("connection_status") != "connected":
                    raise SmokeError("Open SketchUp with HomeCAD enabled before running this smoke test")
                if status.get("ruby_extension_version") != VERSION:
                    raise SmokeError(f"Python is {VERSION}, installed Ruby extension is {status.get('ruby_extension_version')!r}")
                if "architecture.core.v1" not in status.get("capabilities", []):
                    raise SmokeError("Installed RBZ does not advertise architecture.core.v1; install the built M3 RBZ and restart SketchUp")
                initial_info, _ = await call("get_model_info")
                print(f"Initial model modified state: {initial_info['modified']}")

                wall_id = await create_wall([0, 0, 0], [4000, 0, 0], "M3 Smoke Wall")
                frame, _ = await call("get_wall_frame", {"wall": {"homecad_id": wall_id}})
                if frame["u_axis"] != [1, 0, 0] or frame["v_axis"] != [0, 1, 0] or frame["z_axis"] != [0, 0, 1]:
                    raise SmokeError(f"Unexpected X-axis wall frame: {frame}")
                if abs(frame["length_mm"] - 4000) > 0.5:
                    raise SmokeError(f"Unexpected wall length: {frame['length_mm']}")
                await screenshot("wall", wall_id)

                plain, _ = await get(wall_id), None
                base_faces = plain.get("children", {}).get("by_type", {}).get("Face", 0)
                window, _ = await call("create_window", {"wall": {"homecad_id": wall_id},
                    "offset_mm": 1000, "bottom_mm": 900, "width_mm": 1200,
                    "height_mm": 1200, "side": "center", "name": "M3 Smoke Window"})
                window_id = window["created"][0]["identity"]["homecad_id"]
                window_info = await get(window_id)
                if window_info["metadata"]["type"] != "architecture.window" or window_info["relationships"]["wall_id"] != wall_id:
                    raise SmokeError("Window semantic type or wall relationship is missing")
                if window_info["parameters"]["offset_mm"] != 1000 or window_info["children"]["total"] < 1:
                    raise SmokeError("Window local position or concept geometry is missing")
                wall_after_window = await get(wall_id)
                if wall_after_window["children"]["by_type"].get("Face", 0) <= base_faces:
                    raise SmokeError("Window did not regenerate the wall cut geometry")
                await screenshot("window", wall_id)

                door, _ = await call("create_door", {"wall": {"homecad_id": wall_id},
                    "offset_mm": 2500, "width_mm": 900, "height_mm": 2100,
                    "name": "M3 Smoke Door"})
                door_id = door["created"][0]["identity"]["homecad_id"]
                if (await get(door_id))["parameters"]["bottom_mm"] != 0:
                    raise SmokeError("Door cut does not begin at the wall base")
                await screenshot("door", wall_id)

                await call("update_architecture_object", {"target": {"homecad_id": wall_id},
                    "changes": {"start_mm": [500, 500, 0], "end_mm": [500, 4500, 0]}})
                frame_after, _ = await call("get_wall_frame", {"wall": {"homecad_id": wall_id}})
                if frame_after["u_axis"] != [0, 1, 0]:
                    raise SmokeError(f"Wall rotation did not update its local frame: {frame_after}")
                if (await get(window_id))["parameters"]["offset_mm"] != 1000 or (await get(door_id))["parameters"]["offset_mm"] != 2500:
                    raise SmokeError("Hosted local offsets changed after rotating the wall")
                await screenshot("rotated-wall", wall_id)

                wall_before = await get(wall_id)
                window_before = await get(window_id)
                door_before = await get(door_id)
                await expected_error("update_architecture_object", {"target": {"homecad_id": wall_id},
                    "changes": {"end_mm": [500, 3500, 0]}}, "constraint_violation")
                if await get(wall_id) != wall_before or await get(window_id) != window_before or await get(door_id) != door_before:
                    raise SmokeError("Rejected wall shortening changed geometry, parameters, or revisions")

                niche, _ = await call("create_niche", {"wall": {"homecad_id": wall_id},
                    "offset_mm": 100, "bottom_mm": 400, "width_mm": 300,
                    "height_mm": 500, "depth_mm": 40, "side": "positive_v",
                    "name": "M3 Smoke Niche"})
                niche_id = niche["created"][0]["identity"]["homecad_id"]
                if (await get(niche_id))["parameters"]["depth_mm"] != 40:
                    raise SmokeError("Niche depth/side parameters are incorrect")
                await screenshot("niche", wall_id)

                room_walls = [
                    await create_wall([10000, 0, 0], [14000, 0, 0], "M3 Room South"),
                    await create_wall([14000, 0, 0], [14000, 3000, 0], "M3 Room East"),
                    await create_wall([14000, 3000, 0], [10000, 3000, 0], "M3 Room North"),
                    await create_wall([10000, 3000, 0], [10000, 0, 0], "M3 Room West"),
                ]
                detected, _ = await call("detect_rooms")
                candidates = [candidate for candidate in detected["candidates"]
                              if set(candidate["wall_ids"]) == set(room_walls)]
                if len(candidates) != 1:
                    raise SmokeError(f"Expected one simple room candidate, got {detected}")
                room, _ = await call("create_room", {"name": "M3 Smoke Room", "wall_ids": room_walls})
                room_id = room["created"][0]["identity"]["homecad_id"]
                room_info = await get(room_id)
                if room_info["parameters"]["wall_ids"] != room_walls or len(room_info["parameters"]["room_sides"]) != 4:
                    raise SmokeError("Room lost its ordered boundary or room-side assignments")
                await screenshot("room-top", room_id, "top")

                def assert_room_consistent(room_data: dict, expected_walls: list[str]) -> None:
                    room_params = room_data["parameters"]
                    if room_params["wall_ids"] != expected_walls:
                        raise SmokeError("Room wall_ids do not match the expected ordered boundary")
                    expected_relationships = {
                        f"wall_{wall_id}": side for wall_id, side in room_params["room_sides"]
                    }
                    if room_data["relationships"] != expected_relationships:
                        raise SmokeError("Room relationships are stale relative to room_sides")
                    if len(room_params["boundary_mm"]) != len(expected_walls):
                        raise SmokeError("Room boundary vertex count does not match wall count")
                    if room_params["approx_area_mm2"] <= 0:
                        raise SmokeError("Room derived area must be positive")

                room_before = room_info
                replacement_walls = [
                    await create_wall([20000, 0, 0], [25000, 0, 0], "M3 Room Replacement South"),
                    await create_wall([25000, 0, 0], [25000, 2000, 0], "M3 Room Replacement East"),
                    await create_wall([25000, 2000, 0], [20000, 2000, 0], "M3 Room Replacement North"),
                    await create_wall([20000, 2000, 0], [20000, 0, 0], "M3 Room Replacement West"),
                ]
                await call("update_architecture_object", {
                    "target": {"homecad_id": room_id}, "changes": {"wall_ids": replacement_walls}
                })
                room_changed = await get(room_id)
                assert_room_consistent(room_changed, replacement_walls)
                expected_boundary = [[20000, 0, 0], [25000, 0, 0], [25000, 2000, 0], [20000, 2000, 0]]
                if room_changed["parameters"]["boundary_mm"] != expected_boundary:
                    raise SmokeError("Room boundary_mm was not regenerated from replacement walls")
                if abs(room_changed["parameters"]["approx_area_mm2"] - 10_000_000) > 1:
                    raise SmokeError("Room area was not regenerated from replacement boundary")
                dimensions = room_changed["bbox_dimensions_mm"]
                if abs(dimensions["width"] - 5000) > 1 or abs(dimensions["depth"] - 2000) > 1:
                    raise SmokeError("Generated Room reference face does not match the replacement boundary")
                if room_changed["metadata"]["revision"] != room_before["metadata"]["revision"] + 1:
                    raise SmokeError("Room wall_ids update did not increment its revision exactly once")
                await screenshot("room-reassigned", room_id, "top")
                await undo_one()
                room_restored = await get(room_id)
                if (room_restored["parameters"] != room_before["parameters"] or
                        room_restored["relationships"] != room_before["relationships"] or
                        room_restored["metadata"]["revision"] != room_before["metadata"]["revision"]):
                    raise SmokeError("Undo did not restore the prior Room derived state")

                room_before_reverse = room_restored
                first_wall_before = await get(room_walls[0])
                await call("update_architecture_object", {
                    "target": {"homecad_id": room_walls[0]},
                    "changes": {"start_mm": [14000, 0, 0], "end_mm": [10000, 0, 0]},
                })
                room_reversed = await get(room_id)
                assert_room_consistent(room_reversed, room_walls)
                old_boundary = room_before_reverse["parameters"]["boundary_mm"]
                old_area = room_before_reverse["parameters"]["approx_area_mm2"]
                old_sides = dict(room_before_reverse["parameters"]["room_sides"])
                new_sides = dict(room_reversed["parameters"]["room_sides"])
                if room_reversed["parameters"]["boundary_mm"] != old_boundary:
                    raise SmokeError("Reversing wall direction changed the physical Room boundary")
                if room_reversed["parameters"]["approx_area_mm2"] != old_area:
                    raise SmokeError("Reversing wall direction changed Room area")
                if old_sides[room_walls[0]] == new_sides[room_walls[0]]:
                    raise SmokeError("Reversing wall direction did not update the Room-facing side")
                if room_reversed["metadata"]["revision"] != room_before_reverse["metadata"]["revision"] + 1:
                    raise SmokeError("Dependent Room revision did not increment exactly once")
                reversed_wall = await get(room_walls[0])
                if reversed_wall["metadata"]["revision"] != first_wall_before["metadata"]["revision"] + 1:
                    raise SmokeError("Reversed Wall revision did not increment exactly once")
                await screenshot("room-wall-direction", room_id, "top")
                await undo_one()
                room_restored = await get(room_id)
                if (room_restored["parameters"] != room_before_reverse["parameters"] or
                        room_restored["relationships"] != room_before_reverse["relationships"]):
                    raise SmokeError("Undo did not restore Room side relationships after Wall reversal")

            try:
                await run_steps()
            finally:
                if pending_undos:
                    print(f"Cleanup: undoing {pending_undos} mutation operation(s).", file=sys.stderr)
                    try:
                        while pending_undos:
                            await undo_one()
                    except Exception as error:
                        print(f"CLEANUP FAILED: disposable model may still contain M3 geometry ({error}).", file=sys.stderr)
                        raise
            remaining = [identifier for identifier in created_ids if (await find(identifier)).get("resolution") != "none"]
            if remaining:
                raise SmokeError(f"CLEANUP FAILED: smoke IDs remain in the model: {remaining}")
            final, _ = await call("get_model_info")
            print(f"Final model modified state: {final['modified']}; initial: {initial_info['modified']}")
            print("M3 smoke passed; inspect saved screenshots and confirm Undo restored the disposable model.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-disposable", action="store_true",
                        help="confirm that the active SketchUp model is disposable or a test model")
    parser.add_argument("--output", type=Path, default=Path("dist/m3-smoke.png"))
    args = parser.parse_args()
    print("Run M3 smoke only on a disposable/test SketchUp model.")
    if not args.confirm_disposable:
        parser.error("pass --confirm-disposable only after opening a disposable/test model")
    try:
        asyncio.run(run(args.output))
    except SmokeError as error:
        print(f"smoke_m3: {error}", file=sys.stderr)
        raise SystemExit(2) from None
    except BaseExceptionGroup as error:
        print(f"smoke_m3: {error}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
