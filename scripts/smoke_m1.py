"""End-to-end M1 inspection smoke test against an open SketchUp model."""

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
    """Expected failure with a short, actionable CLI message."""


def check_capture_capability(status: dict) -> None:
    capabilities = status.get("capabilities", [])
    if not isinstance(capabilities, list) or "view.capture.v1" not in capabilities:
        installed = status.get("ruby_extension_version")
        raise SmokeError(
            f"SketchUp HomeCAD RBZ {installed!r} does not advertise required capability "
            "'view.capture.v1'. Install dist\\homecad.rbz and restart SketchUp before capture."
        )


def same_camera(before: dict, after: dict) -> bool:
    for key, value in before.items():
        other = after.get(key)
        if isinstance(value, list):
            if not isinstance(other, list) or len(value) != len(other):
                return False
            if any(abs(a - b) > 0.0001 for a, b in zip(value, other)):
                return False
        elif isinstance(value, (int, float)) and not isinstance(value, bool):
            if not isinstance(other, (int, float)) or abs(value - other) > 0.0001:
                return False
        elif value != other:
            return False
    return True


def first_smoke_error(error: BaseException) -> SmokeError:
    if isinstance(error, SmokeError):
        return error
    for child in error.exceptions:
        found = first_smoke_error(child)
        if found:
            return found
    raise RuntimeError("Expected smoke error was absent")


async def run(name: str | None, output: Path) -> None:
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"], env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            async def call(tool: str, arguments: dict | None = None):
                result = await session.call_tool(tool, arguments or {})
                if result.isError:
                    raise SmokeError(f"{tool}: {result.content[0].text}")
                data = next((json.loads(item.text) for item in result.content if item.type == "text"), {})
                print(f"{tool}: {json.dumps(data, ensure_ascii=False)}")
                return data, result.content

            status, _ = await call("homecad_status")
            if status["connection_status"] != "connected":
                raise SmokeError("Open SketchUp with HomeCAD enabled before running M1 smoke")
            check_capture_capability(status)
            model_before, _ = await call("get_model_info")
            await call("list_objects", {"limit": 10})
            selection, _ = await call("get_selection", {"limit": 10})
            identity = None
            if name:
                found, _ = await call("find_objects", {"name": name, "limit": 10})
                if found["resolution"] == "unique":
                    identity = found["objects"][0]["identity"]
                elif found["resolution"] != "none":
                    raise SmokeError(f"Name {name!r} is {found['resolution']}; use a unique name or one selected object")
            if identity is None:
                if selection["total"] != 1:
                    raise SmokeError(
                        f"No unique object named {name!r}; select exactly one object in SketchUp "
                        "or pass --name with a unique existing name"
                    )
                identity = selection["objects"][0]["identity"]
                print("Using the single selected object for M1 inspection.")
                lookup_key = "persistent_id" if identity["persistent_id"] is not None else "entity_id"
                await call("find_objects", {lookup_key: identity[lookup_key], "limit": 10})
            key = next((key for key in ("homecad_id", "persistent_id", "entity_id") if identity[key] is not None), None)
            if key is None:
                raise SmokeError("Selected object has no usable identifier")
            target = {key: identity[key], "instance_path": identity["instance_path"]}
            object_data, _ = await call("get_object", {"target": target})
            if object_data["identity"] != identity:
                raise SmokeError("get_object returned a different identity")
            await call("measure", {"kind": "bbox_dimensions", "target": target})

            output.mkdir(parents=True, exist_ok=True)
            for view in ("top", "iso"):
                meta, content = await call("capture_view", {
                    "view": view, "zoom_extents": True, "max_size": 1024,
                    "restore_camera": True,
                })
                if not meta["camera_restored"] or not same_camera(meta["camera_before"], meta["camera_after"]):
                    raise SmokeError(f"Camera was not restored after {view} capture")
                await asyncio.sleep(0.5)
                current, _ = await call("capture_view", {"view": "current", "max_size": 64})
                if not same_camera(meta["camera_before"], current["camera_before"]):
                    raise SmokeError(f"Camera changed after {view} capture returned")
                image = next((item for item in content if item.type == "image" and item.mimeType == "image/png"), None)
                if image is None:
                    raise SmokeError(f"{view} capture returned no MCP PNG image")
                path = output / f"{view}.png"
                path.write_bytes(base64.b64decode(image.data, validate=True))
                print(f"saved: {path.resolve()}")
            model_after, _ = await call("get_model_info")
            if model_before["guid"] != model_after["guid"] or model_before["modified"] != model_after["modified"]:
                raise SmokeError("Model identity or modified state changed during inspection")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", help="Unique substring of an existing SketchUp object name; otherwise use selection")
    parser.add_argument("--output", type=Path, default=Path("dist/m1-smoke"))
    args = parser.parse_args()
    try:
        asyncio.run(run(args.name, args.output))
    except BaseExceptionGroup as exc:
        expected, unexpected = exc.split(SmokeError)
        if unexpected:
            raise
        print(f"smoke_m1: {first_smoke_error(expected)}", file=sys.stderr)
        raise SystemExit(2) from None
    except SmokeError as exc:
        print(f"smoke_m1: {exc}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
