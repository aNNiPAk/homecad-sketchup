import asyncio
import json
import os
import shutil
import sys
from pathlib import Path

import pytest
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from homecad_mcp.config import Config
from homecad_mcp.connection import BridgeClient
from homecad_mcp.errors import BridgeError

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.asyncio
async def test_python_to_ruby_bridge():
    ruby = shutil.which("ruby")
    if ruby is None:
        pytest.skip("Ruby executable unavailable")
    process = await asyncio.create_subprocess_exec(
        ruby, "tests/ruby/bridge_fixture.rb", cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        line = await asyncio.wait_for(process.stdout.readline(), 5)
        if not line:
            raise AssertionError((await process.stderr.read()).decode())
        port = int(line)
        client = BridgeClient(Config(port=port))
        status = await client.call("homecad_status")
        assert status["connection_status"] == "connected"
        assert status["model_name"] == "Fixture Apartment"
        info = await client.call("get_model_info")
        assert info["root_entity_count"] == 2
        assert info["guid"] == "fixture-guid"
        listing = await client.call("list_objects", {"limit": 1})
        assert listing["has_more"] is True
        assert listing["objects"][0]["identity"]["persistent_id"] == 11
        found = await client.call("find_objects", {"name": "Known Chair"})
        assert found["resolution"] == "unique"
        assert (await client.call("find_objects", {"name": "a"}))["resolution"] == "multiple"
        assert (await client.call("find_objects", {"homecad_id": "ambiguous-fixture"}))["resolution"] == "ambiguous"
        assert (await client.call("find_objects", {"persistent_id": 999}))["resolution"] == "none"
        with pytest.raises(BridgeError) as ambiguous:
            await client.call("get_object", {"target": {"homecad_id": "ambiguous-fixture"}})
        assert ambiguous.value.category == "ambiguous_target"
        with pytest.raises(BridgeError) as missing:
            await client.call("get_object", {"target": {"persistent_id": 999}})
        assert missing.value.category == "target_not_found"
        target = found["objects"][0]["identity"]
        object_info = await client.call("get_object", {"target": {"persistent_id": 11}})
        assert object_info["identity"] == target
        assert object_info["dimensions_mm"]["width"] == 25.4
        measured = await client.call("measure", {"kind": "dimensions", "target": {"persistent_id": 11}})
        assert measured["unit"] == "mm"
        assert measured["targets"] == [target]
        selected = await client.call("get_selection")
        assert selected["objects"][0]["identity"] == target
        for direction in ("top", "iso"):
            capture = await client.call("capture_view", {"view": direction, "max_size": 400})
            assert capture["camera_restored"] is True
            assert capture["camera_before"] == capture["camera_after"]
        params = StdioServerParameters(
            command=sys.executable, args=["-m", "homecad_mcp"],
            env={**os.environ, "HOMECAD_PORT": str(port)},
        )
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool("homecad_status", {})
                assert json.loads(result.content[0].text)["model_name"] == "Fixture Apartment"
                result = await session.call_tool("get_model_info", {})
                assert json.loads(result.content[0].text)["guid"] == "fixture-guid"
                result = await session.call_tool("capture_view", {"view": "top", "max_size": 400})
                assert not result.isError
                assert any(item.type == "image" and item.mimeType == "image/png" for item in result.content)
    finally:
        process.terminate()
        await process.wait()


@pytest.mark.asyncio
async def test_mcp_stdio_starts_and_lists_m1_tools():
    # No SketchUp process is required to initialize the MCP server.
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "homecad_mcp"],
        env={**os.environ, "HOMECAD_PORT": "1"},
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert {tool.name for tool in tools.tools} == {
                "homecad_status", "get_model_info", "list_objects", "find_objects",
                "get_object", "get_selection", "measure", "capture_view", "undo"}
            status = await session.call_tool("homecad_status", {})
            assert not status.isError
            assert json.loads(status.content[0].text)["connection_status"] == "disconnected"
            info = await session.call_tool("get_model_info", {})
            assert info.isError


@pytest.mark.asyncio
async def test_m1_smoke_script_against_ruby_fixture(tmp_path):
    ruby = shutil.which("ruby")
    if ruby is None:
        pytest.skip("Ruby executable unavailable")
    bridge = await asyncio.create_subprocess_exec(
        ruby, "tests/ruby/bridge_fixture.rb", cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        port = int(await asyncio.wait_for(bridge.stdout.readline(), 5))
        run = await asyncio.create_subprocess_exec(
            sys.executable, "scripts/smoke_m1.py", "--name", "Known Chair",
            "--output", str(tmp_path), cwd=ROOT,
            env={**os.environ, "HOMECAD_PORT": str(port)},
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(run.communicate(), 40)
        assert run.returncode == 0, (stdout + stderr).decode()
        assert (tmp_path / "top.png").read_bytes().startswith(b"\x89PNG")
        assert (tmp_path / "iso.png").read_bytes().startswith(b"\x89PNG")
    finally:
        bridge.terminate()
        await bridge.wait()
