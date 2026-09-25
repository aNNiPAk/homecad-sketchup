"""Run M2/M2.1 mutations against a disposable SketchUp model only."""

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


def find_smoke_error(error: BaseException) -> SmokeError | None:
    if isinstance(error, SmokeError):
        return error
    if isinstance(error, BaseExceptionGroup):
        for child in error.exceptions:
            found = find_smoke_error(child)
            if found:
                return found
    return None


async def run(output: Path) -> None:
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"], env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            pending_undos = 0
            created_ids: list[str] = []
            output.parent.mkdir(parents=True, exist_ok=True)

            async def call(tool: str, arguments: dict | None = None):
                nonlocal pending_undos
                result = await session.call_tool(tool, arguments or {})
                if result.isError:
                    text = next((item.text for item in result.content if item.type == "text"), "unknown error")
                    raise SmokeError(f"{tool}: {text}")
                data = next((json.loads(item.text) for item in result.content if item.type == "text"), {})
                if data.get("status") == "success" and tool in {
                    "create_box", "create_face", "push_pull", "follow_me", "transform_object", "boolean_operation"
                }:
                    pending_undos += 1
                    created_ids.extend(obj["identity"]["homecad_id"] for obj in data.get("created", [])
                                       if obj.get("identity", {}).get("homecad_id"))
                # ASCII-escaped JSON is reliable in Windows consoles using legacy code pages.
                print(f"{tool}: {json.dumps(data, ensure_ascii=True)}")
                return data, result.content

            async def expected_error(tool: str, arguments: dict, category: str) -> str:
                result = await session.call_tool(tool, arguments)
                if not result.isError:
                    raise SmokeError(f"{tool} unexpectedly succeeded; expected {category}")
                message = " ".join(item.text for item in result.content if item.type == "text")
                if category not in message:
                    raise SmokeError(f"{tool} returned {message!r}; expected category {category}")
                print(f"{tool} expected error: {message}")
                return message

            async def undo_one() -> None:
                nonlocal pending_undos
                result, _ = await call("undo")
                if result.get("actions") != 1:
                    raise SmokeError("Undo did not queue exactly one SketchUp action")
                pending_undos -= 1
                await asyncio.sleep(0.35)

            async def get(target: dict) -> dict:
                result, _ = await call("get_object", {"target": target})
                return result

            async def find(homecad_id: str) -> dict:
                result, _ = await call("find_objects", {"homecad_id": homecad_id, "limit": 5})
                return result

            async def screenshot(path: Path, target: dict | None = None) -> None:
                args = {"view": "iso", "max_size": 1024, "restore_camera": True}
                if target is not None:
                    args["target"] = target
                result, content = await call("capture_view", args)
                image = next((item for item in content if item.type == "image" and item.mimeType == "image/png"), None)
                encoded = result.get("image_base64")
                data = base64.b64decode(image.data, validate=True) if image else (
                    base64.b64decode(encoded, validate=True) if encoded else b"")
                if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise SmokeError("capture_view did not return a PNG image")
                path.write_bytes(data)
                print(f"saved screenshot: {path.resolve()}")

            async def create_face(points: list[list[float]], name: str) -> str:
                result, _ = await call("create_face", {"points_mm": points, "name": name})
                if result.get("status") != "success" or len(result.get("created", [])) != 1:
                    raise SmokeError(f"{name} face creation did not return one managed Group")
                identifier = result["created"][0]["identity"]["homecad_id"]
                if not identifier:
                    raise SmokeError(f"{name} has no HomeCAD UUID")
                return identifier

            async def child_face(group_id: str) -> dict:
                listed, _ = await call("list_objects", {
                    "parent": {"homecad_id": group_id}, "entity_type": "Face",
                    "include_generated": True, "limit": 10,
                })
                faces = listed.get("objects", [])
                if len(faces) != 1:
                    raise SmokeError(f"Expected one Face in {group_id}; got {len(faces)}")
                identity = faces[0].get("identity", {})
                selector = {key: identity[key] for key in ("persistent_id", "entity_id")
                            if identity.get(key) is not None}
                if not selector:
                    raise SmokeError("Face has no resolvable SketchUp identity")
                return selector

            status, _ = await call("homecad_status")
            if status.get("connection_status") != "connected":
                raise SmokeError("Open SketchUp with HomeCAD enabled before running this smoke test")
            if status.get("ruby_extension_version") != VERSION:
                raise SmokeError(
                    f"MCP package is {VERSION}, but installed Ruby extension is "
                    f"{status.get('ruby_extension_version')!r}; rebuild/install the matching RBZ and restart SketchUp"
                )
            if "geometry.primitive.v1" not in status.get("capabilities", []):
                raise SmokeError("Installed RBZ does not advertise geometry.primitive.v1; rebuild, reinstall, and restart SketchUp")
            initial, _ = await call("get_model_info")
            print(f"Initial model modified state: {initial['modified']}")

            try:
                # Managed box, world-space translation, screenshot and native undo.
                box, _ = await call("create_box", {
                    "width_mm": 600, "depth_mm": 560, "height_mm": 720,
                    "origin_mm": [1000, 1000, 0], "name": "HomeCAD M2.1 Smoke Box",
                })
                box_id = box["created"][0]["identity"]["homecad_id"]
                box_target = {"homecad_id": box_id}
                if (await find(box_id)).get("resolution") != "unique":
                    raise SmokeError("Created box did not resolve uniquely")
                before = await get(box_target)
                dims = before.get("bbox_dimensions_mm") or {}
                for axis, expected in {"width": 600, "depth": 560, "height": 720}.items():
                    if abs(dims.get(axis, float("inf")) - expected) > 0.5:
                        raise SmokeError(f"Unexpected box {axis}: {dims.get(axis)} mm")
                original_min = before["bbox_mm"]["min"]
                await call("transform_object", {"target": box_target,
                    "transform": {"type": "translate", "vector_mm": [125, -40, 25]}})
                moved = await get(box_target)
                if any(abs((moved["bbox_mm"]["min"][i] - original_min[i]) - delta) > 0.5
                       for i, delta in enumerate([125, -40, 25])):
                    raise SmokeError("Translated bounds do not match requested millimeters")
                await screenshot(output.with_name(output.stem + "-box.png"), box_target)
                await undo_one()
                if (await get(box_target))["bbox_mm"]["min"] != original_min:
                    raise SmokeError("Undo did not restore box position")
                await undo_one()
                if (await find(box_id)).get("resolution") != "none":
                    raise SmokeError("Undo did not remove smoke box")

                # Asymmetric subtraction: target [1000,1600], tool [1300,1800] => target-tool [1000,1300].
                target_result, _ = await call("create_box", {
                    "width_mm": 600, "depth_mm": 400, "height_mm": 300,
                    "origin_mm": [1000, 0, 0], "name": "M2.1 Boolean Target",
                })
                target_id = target_result["created"][0]["identity"]["homecad_id"]
                tool_result, _ = await call("create_box", {
                    "width_mm": 500, "depth_mm": 400, "height_mm": 300,
                    "origin_mm": [1300, 0, 0], "name": "M2.1 Boolean Tool",
                })
                tool_id = tool_result["created"][0]["identity"]["homecad_id"]
                target_selector, tool_selector = {"homecad_id": target_id}, {"homecad_id": tool_id}
                boolean, _ = await call("boolean_operation", {
                    "target": target_selector, "tool": tool_selector, "operation": "difference",
                })
                boolean_obj = boolean["created"][0]
                boolean_id = boolean_obj["identity"]["homecad_id"]
                boolean_target = {"homecad_id": boolean_id}
                bounds = boolean_obj["bbox_mm"]
                if abs(bounds["min"][0] - 1000) > 0.5 or abs(bounds["max"][0] - 1300) > 0.5:
                    raise SmokeError(f"Boolean result is not target - tool: x bounds {bounds}")
                metadata = boolean_obj.get("metadata") or {}
                if metadata.get("type") != "primitive.boolean" or metadata.get("revision") != 1:
                    raise SmokeError(f"Unexpected boolean metadata: {metadata}")
                if (await find(target_id)).get("resolution") != "unique" or (await find(tool_id)).get("resolution") != "unique":
                    raise SmokeError("Boolean operation did not preserve both source objects")
                await screenshot(output.with_name(output.stem + "-boolean.png"), boolean_target)
                await undo_one()
                if (await find(boolean_id)).get("resolution") != "none":
                    raise SmokeError("Undo did not remove boolean result")
                if (await find(target_id)).get("resolution") != "unique" or (await find(tool_id)).get("resolution") != "unique":
                    raise SmokeError("Boolean undo did not preserve source objects")
                await undo_one()  # tool box
                await undo_one()  # target box

                # Ordinary push_pull must honor public world millimeters.
                push_group = await create_face([[0, 0, 0], [200, 0, 0], [200, 150, 0], [0, 150, 0]],
                                               "M2.1 PushPull Profile")
                face_selector = await child_face(push_group)
                await call("push_pull", {"target": face_selector, "distance_mm": 80})
                pushed = await get({"homecad_id": push_group})
                if abs(pushed["bbox_dimensions_mm"]["height"] - 80) > 0.5:
                    raise SmokeError(f"Ordinary push_pull did not produce 80 mm height: {pushed}")
                await screenshot(output.with_name(output.stem + "-push-pull.png"), {"homecad_id": push_group})
                await undo_one()
                await undo_one()

                # Scaled parent must be rejected without a revision or geometry change.
                scaled_group = await create_face([[0, 0, 0], [100, 0, 0], [100, 80, 0], [0, 80, 0]],
                                                 "M2.1 Scaled PushPull Profile")
                scaled_target = {"homecad_id": scaled_group}
                face_selector = await child_face(scaled_group)
                await call("transform_object", {"target": scaled_target,
                    "transform": {"type": "scale", "origin_mm": [0, 0, 0], "factors": [2, 3, 1]}})
                scaled_before = await get(scaled_target)
                await expected_error("push_pull", {"target": face_selector, "distance_mm": 80}, "constraint_violation")
                scaled_after = await get(scaled_target)
                if scaled_after.get("metadata", {}).get("revision") != scaled_before.get("metadata", {}).get("revision"):
                    raise SmokeError("Rejected scaled push_pull changed the object revision")
                if scaled_after.get("bbox_mm") != scaled_before.get("bbox_mm"):
                    raise SmokeError("Rejected scaled push_pull changed geometry")
                await undo_one()  # scale
                await undo_one()  # profile creation

                # L-shaped sweep: temporary path edges should not survive unless shared with the sweep.
                follow_group = await create_face([[0, 0, 0], [0, 50, 0], [0, 50, 50], [0, 0, 50]],
                                                 "M2.1 FollowMe Profile")
                follow_face = await child_face(follow_group)
                sweep, _ = await call("follow_me", {"target": follow_face,
                    "path_points_mm": [[0, 0, 0], [200, 0, 0], [200, 150, 0]]})
                if sweep.get("status") != "success" or sweep.get("updated", [{}])[0].get("identity", {}).get("homecad_id") != follow_group:
                    raise SmokeError("follow_me did not update the profile Group")
                swept = await get({"homecad_id": follow_group})
                swept_dims = swept.get("bbox_dimensions_mm") or {}
                if sweep.get("revision") != 2 or not all(swept_dims.get(axis, 0) > 0
                                                          for axis in ("width", "depth", "height")):
                    raise SmokeError("Follow Me did not produce the expected L-shaped solid bounds/revision")
                retained_warnings = [warning for warning in sweep.get("warnings", [])
                                     if "path edges" in warning.lower() and "retained" in warning.lower()]
                if retained_warnings:
                    print("Follow Me retained path edges connected to swept topology; mutation reported its warning.")
                else:
                    print("Follow Me reported no retained helper path edges after cleanup.")
                await screenshot(output.with_name(output.stem + "-follow-me.png"), {"homecad_id": follow_group})
                await undo_one()
                await undo_one()

                remaining = [identifier for identifier in created_ids if (await find(identifier)).get("resolution") != "none"]
                if remaining:
                    raise SmokeError(f"Smoke-created objects remain after undo: {remaining}")
                final, _ = await call("get_model_info")
                print(f"Final model modified state: {final['modified']}")
                if final.get("modified") != initial.get("modified"):
                    print("WARNING: model modified state differs from its initial value; save state may need review.")
                print("M2.1 smoke passed. Confirm screenshots and camera restoration in SketchUp.")
            finally:
                if pending_undos:
                    print(f"Cleanup: issuing {pending_undos} native Undo action(s).", file=sys.stderr)
                    try:
                        while pending_undos:
                            await undo_one()
                    except Exception as error:  # Best effort only; explicitly report uncertain model state.
                        print(f"CLEANUP FAILED: disposable model may still contain smoke geometry ({error}).", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-disposable", action="store_true",
                        help="confirm the active SketchUp model is disposable or a test model")
    parser.add_argument("--output", type=Path, default=Path("dist/m2-smoke.png"))
    args = parser.parse_args()
    print("Run M2 smoke only on a disposable/test SketchUp model.")
    if not args.confirm_disposable:
        parser.error("pass --confirm-disposable only after opening a disposable/test model")
    try:
        asyncio.run(run(args.output))
    except BaseExceptionGroup as exc:
        expected, unexpected = exc.split(SmokeError)
        if unexpected:
            raise
        error = find_smoke_error(expected)
        print(f"smoke_m2: {error or 'M2 smoke failed'}", file=sys.stderr)
        raise SystemExit(2) from None
    except SmokeError as exc:
        print(f"smoke_m2: {exc}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
