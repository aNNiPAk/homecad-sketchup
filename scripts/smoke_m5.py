"""Exercise M5 Kitchen only in the marked disposable HomeCAD SketchUp fixture."""

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
from smoke_guard import SmokeGuardError, validate_disposable_fixture


class SmokeError(RuntimeError):
    pass


async def run(output: Path) -> None:
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"], env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            pending_undos = 0
            created_ids: list[str] = []

            async def call(name: str, arguments: dict | None = None) -> tuple[dict, list]:
                nonlocal pending_undos
                response = await session.call_tool(name, arguments or {})
                text = next((item.text for item in response.content if item.type == "text"), "{}")
                if response.isError:
                    raise SmokeError(f"{name}: {text}")
                data = json.loads(text)
                if name in {"create_wall", "create_door", "apply_kitchen_run",
                            "update_kitchen_run", "update_architecture_object"} and data.get("status") == "success":
                    pending_undos += 1
                    created_ids.extend(obj["identity"]["homecad_id"] for obj in data.get("created", []))
                print(f"{name}: {json.dumps(data, ensure_ascii=True)}")
                return data, response.content

            async def undo_one() -> None:
                nonlocal pending_undos
                result, _ = await call("undo")
                if result.get("actions") != 1:
                    raise SmokeError("Undo did not queue one native action")
                pending_undos -= 1
                await asyncio.sleep(0.5)

            async def expect_error(name: str, arguments: dict, category: str) -> None:
                response = await session.call_tool(name, arguments)
                message = " ".join(item.text for item in response.content if item.type == "text")
                if not response.isError or category not in message:
                    raise SmokeError(f"{name} expected {category}, got {message!r}")

            try:
                status, _ = await call("homecad_status")
                if status.get("ruby_extension_version") != VERSION or "kitchen.run.v1" not in status.get("capabilities", []):
                    raise SmokeError("matching Kitchen RBZ is not installed")
                info, _ = await call("get_model_info")
                validate_disposable_fixture(True, info)

                wall, _ = await call("create_wall", {"start_mm": [0, 0, 0], "end_mm": [4000, 0, 0],
                    "thickness_mm": 120, "height_mm": 2700, "name": "M5 Smoke Wall"})
                wall_id = wall["created"][0]["identity"]["homecad_id"]
                request = {"wall": {"homecad_id": wall_id}, "start_mm": 100, "end_mm": 2000,
                    "side": "negative_v", "modules": [
                        {"key": "sink", "type": "sink", "width_mm": 600},
                        {"key": "dishwasher", "type": "dishwasher", "width_mm": 600},
                        {"key": "hob", "type": "hob", "width_mm": 600}]}
                before_plan, _ = await call("get_model_info")
                plan, _ = await call("plan_kitchen_run", request)
                after_plan, _ = await call("get_model_info")
                if plan["conflicts"] or plan["filler_mm"] != 100 or before_plan["root_entity_count"] != after_plan["root_entity_count"]:
                    raise SmokeError("planning changed the model or produced an unexpected layout")
                result, _ = await call("apply_kitchen_run", {"plan": plan})
                run_id = result["created"][0]["identity"]["homecad_id"]
                run, _ = await call("get_object", {"target": {"homecad_id": run_id}})
                if run["metadata"]["type"] != "kitchen.run" or run["metadata"]["revision"] != 1:
                    raise SmokeError("KitchenRun metadata is incorrect")
                validation, _ = await call("validate_kitchen", {"target": {"homecad_id": run_id}})
                if not validation["valid"] or validation["module_count"] != 3:
                    raise SmokeError(f"Kitchen validation failed: {validation}")
                await call("create_door", {"wall": {"homecad_id": wall_id},
                    "offset_mm": 300, "width_mm": 800, "height_mm": 2100})
                invalid, _ = await call("validate_kitchen", {"target": {"homecad_id": run_id}})
                if invalid["valid"] or not any(c["code"] == "wall_cut_collision" for c in invalid["conflicts"]):
                    raise SmokeError("a new Door did not invalidate the KitchenRun")
                await undo_one()
                valid_again, _ = await call("validate_kitchen", {"target": {"homecad_id": run_id}})
                if not valid_again["valid"]:
                    raise SmokeError("Undo did not restore Kitchen validation")
                await expect_error("update_architecture_object", {"target": {"homecad_id": wall_id},
                    "changes": {"end_mm": [1500, 0, 0]}}, "constraint_violation")
                original_matrix = run["transformation"]["matrix"]
                await call("update_architecture_object", {"target": {"homecad_id": wall_id},
                    "changes": {"start_mm": [0, 200, 0], "end_mm": [4000, 200, 0]}})
                relocated, _ = await call("get_object", {"target": {"homecad_id": run_id}})
                if relocated["transformation"]["matrix"] == original_matrix or relocated["metadata"]["revision"] != 2:
                    raise SmokeError("Wall move did not relocate/revise KitchenRun")
                await undo_one()
                restored_wall, _ = await call("get_object", {"target": {"homecad_id": run_id}})
                if restored_wall["transformation"]["matrix"] != original_matrix or restored_wall["metadata"]["revision"] != 1:
                    raise SmokeError("Undo did not restore KitchenRun placement")
                view, content = await call("capture_view", {"view": "iso", "target": {"homecad_id": run_id},
                    "max_size": 1000, "restore_camera": True})
                if view.get("camera_restored") is not True:
                    raise SmokeError("camera was not restored")
                image = next((item for item in content if item.type == "image" and item.mimeType == "image/png"), None)
                if image is None:
                    raise SmokeError("capture did not return PNG")
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(base64.b64decode(image.data, validate=True))
                print(f"saved screenshot: {output.resolve()}")
                updated, _ = await call("update_kitchen_run", {"target": {"homecad_id": run_id},
                    "changes": {"name": "M5 Updated Run"}})
                if updated["revision"] != 2:
                    raise SmokeError("KitchenRun revision did not increment")
                await undo_one()
                restored, _ = await call("get_object", {"target": {"homecad_id": run_id}})
                if restored["metadata"]["revision"] != 1:
                    raise SmokeError("Undo did not restore KitchenRun revision")
            finally:
                cleanup_failed = False
                while pending_undos > 0:
                    try:
                        await undo_one()
                    except Exception as error:
                        print(f"CLEANUP FAILED: {error}", file=sys.stderr)
                        cleanup_failed = True
                        break
                for identifier in created_ids:
                    response = await session.call_tool("find_objects", {"homecad_id": identifier, "limit": 5})
                    if response.isError:
                        cleanup_failed = True
                        continue
                    data = json.loads(next(item.text for item in response.content if item.type == "text"))
                    if data.get("resolution") != "none":
                        cleanup_failed = True
                        print(f"CLEANUP FAILED: {identifier} remains", file=sys.stderr)
                if cleanup_failed:
                    raise SmokeError("CLEANUP FAILED; disposable model may contain test geometry")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-disposable", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("dist/m5-smoke/kitchen.png"))
    args = parser.parse_args()
    if not args.confirm_disposable:
        parser.error("M5 smoke mutates SketchUp; pass --confirm-disposable on the HomeCADDev fixture")
    try:
        asyncio.run(run(args.output))
    except (SmokeError, SmokeGuardError, ValueError) as error:
        print(f"smoke_m5: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
