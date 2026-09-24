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


async def run(name: str, output: Path) -> None:
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"], env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            async def call(tool: str, arguments: dict | None = None):
                result = await session.call_tool(tool, arguments or {})
                if result.isError:
                    raise RuntimeError(f"{tool}: {result.content[0].text}")
                data = next((json.loads(item.text) for item in result.content if item.type == "text"), {})
                print(f"{tool}: {json.dumps(data, ensure_ascii=False)}")
                return data, result.content

            status, _ = await call("homecad_status")
            if status["connection_status"] != "connected":
                raise RuntimeError("Open SketchUp with HomeCAD enabled before running M1 smoke")
            model_before, _ = await call("get_model_info")
            await call("list_objects", {"limit": 10})
            found, _ = await call("find_objects", {"name": name, "limit": 10})
            if found["resolution"] != "unique":
                raise RuntimeError(f"Expected one object named {name!r}; got {found['resolution']}")
            identity = found["objects"][0]["identity"]
            key = next((key for key in ("homecad_id", "persistent_id", "entity_id") if identity[key] is not None), None)
            if key is None:
                raise RuntimeError("Known object has no usable identifier")
            target = {key: identity[key], "instance_path": identity["instance_path"]}
            object_data, _ = await call("get_object", {"target": target})
            if object_data["identity"] != identity:
                raise RuntimeError("get_object returned a different identity")
            await call("measure", {"kind": "dimensions", "target": target})
            selection, _ = await call("get_selection", {"limit": 10})
            if selection["total"] == 0:
                raise RuntimeError("Select an object in SketchUp before running M1 smoke")

            output.mkdir(parents=True, exist_ok=True)
            for view in ("top", "iso"):
                meta, content = await call("capture_view", {
                    "view": view, "zoom_extents": True, "max_size": 1024,
                    "restore_camera": True,
                })
                if not meta["camera_restored"] or meta["camera_before"] != meta["camera_after"]:
                    raise RuntimeError(f"Camera was not restored after {view} capture")
                image = next((item for item in content if item.type == "image" and item.mimeType == "image/png"), None)
                if image is None:
                    raise RuntimeError(f"{view} capture returned no MCP PNG image")
                path = output / f"{view}.png"
                path.write_bytes(base64.b64decode(image.data, validate=True))
                print(f"saved: {path.resolve()}")
            model_after, _ = await call("get_model_info")
            if model_before["guid"] != model_after["guid"] or model_before["modified"] != model_after["modified"]:
                raise RuntimeError("Model identity or modified state changed during inspection")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="Unique substring of a known SketchUp object name")
    parser.add_argument("--output", type=Path, default=Path("dist/m1-smoke"))
    args = parser.parse_args()
    asyncio.run(run(args.name, args.output))


if __name__ == "__main__":
    main()
