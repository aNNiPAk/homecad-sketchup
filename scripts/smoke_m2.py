"""Run M2 mutations against a disposable SketchUp model only."""

import argparse
import asyncio
import base64
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


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

            async def call(tool: str, arguments: dict | None = None):
                result = await session.call_tool(tool, arguments or {})
                if result.isError:
                    text = next((item.text for item in result.content if item.type == "text"), "unknown error")
                    raise SmokeError(f"{tool}: {text}")
                data = next((json.loads(item.text) for item in result.content if item.type == "text"), {})
                print(f"{tool}: {json.dumps(data, ensure_ascii=False)}")
                return data, result.content

            status, _ = await call("homecad_status")
            if status.get("connection_status") != "connected":
                raise SmokeError("Open SketchUp with HomeCAD enabled before running this smoke test")
            capabilities = status.get("capabilities", [])
            if "geometry.primitive.v1" not in capabilities:
                raise SmokeError("Installed RBZ does not advertise geometry.primitive.v1; rebuild, reinstall, and restart SketchUp")

            model_before, _ = await call("get_model_info")
            print(f"Initial model modified state: {model_before['modified']}")
            created, _ = await call("create_box", {
                "width_mm": 600, "depth_mm": 560, "height_mm": 720,
                "origin_mm": [1000, 1000, 0], "name": "HomeCAD M2 Smoke Box",
            })
            if created.get("status") != "success" or len(created.get("created", [])) != 1:
                raise SmokeError("create_box did not return exactly one created object")
            homecad_id = created["created"][0]["identity"]["homecad_id"]
            if not homecad_id:
                raise SmokeError("created box has no HomeCAD UUID")
            target = {"homecad_id": homecad_id}

            found, _ = await call("find_objects", {"homecad_id": homecad_id, "limit": 5})
            if found.get("resolution") != "unique":
                raise SmokeError(f"Expected unique HomeCAD target; got {found.get('resolution')}")
            before, _ = await call("get_object", {"target": target})
            dims = before.get("bbox_dimensions_mm") or {}
            expected = {"width": 600, "depth": 560, "height": 720}
            for axis, value in expected.items():
                if abs(dims.get(axis, float("inf")) - value) > 0.5:
                    raise SmokeError(f"Unexpected {axis} bbox dimension: {dims.get(axis)} mm")

            original_min = before["bbox_mm"]["min"]
            await call("transform_object", {"target": target,
                "transform": {"type": "translate", "vector_mm": [125, -40, 25]}})
            moved, _ = await call("get_object", {"target": target})
            moved_min = moved["bbox_mm"]["min"]
            for axis, delta in enumerate([125, -40, 25]):
                if abs((moved_min[axis] - original_min[axis]) - delta) > 0.5:
                    raise SmokeError("Translated object bounds do not match the requested millimeter vector")

            output.parent.mkdir(parents=True, exist_ok=True)
            capture, content = await call("capture_view", {
                "view": "iso", "target": target, "max_size": 1024, "restore_camera": True,
            })
            image = next((item for item in content if item.type == "image" and item.mimeType == "image/png"), None)
            if image is not None:
                image_bytes = base64.b64decode(image.data, validate=True)
            else:
                encoded = capture.get("image_base64")
                image_bytes = base64.b64decode(encoded, validate=True) if encoded else b""
            if not image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
                raise SmokeError("capture_view did not return a PNG image")
            output.write_bytes(image_bytes)
            print(f"saved screenshot: {output.resolve()}")

            undo_transform, _ = await call("undo")
            if undo_transform.get("actions") != 1:
                raise SmokeError("Undo did not queue exactly one SketchUp action")
            restored = None
            for _ in range(20):
                await asyncio.sleep(0.25)
                restored, _ = await call("get_object", {"target": target})
                restored_min = restored["bbox_mm"]["min"]
                if all(abs(a - b) <= 0.5 for a, b in zip(restored_min, original_min)):
                    break
            else:
                raise SmokeError("Undo did not restore the box position")

            undo_creation, _ = await call("undo")
            if undo_creation.get("actions") != 1:
                raise SmokeError("Undo did not queue exactly one SketchUp action")
            for _ in range(20):
                await asyncio.sleep(0.25)
                missing, _ = await call("find_objects", {"homecad_id": homecad_id, "limit": 5})
                if missing.get("resolution") == "none":
                    break
            else:
                raise SmokeError("Undo did not remove the created box")
            model_after, _ = await call("get_model_info")
            print(f"Final model modified state: {model_after['modified']}")
            print("M2 smoke passed. Check whether the model modified state matches its initial value.")


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
