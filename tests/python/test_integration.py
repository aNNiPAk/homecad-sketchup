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
