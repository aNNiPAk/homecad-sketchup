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
from scripts.smoke_m1 import SmokeError, check_capture_capability

ROOT = Path(__file__).resolve().parents[2]


def test_m1_smoke_requires_capture_capability():
    with pytest.raises(SmokeError, match="view.capture.v1"):
        check_capture_capability({"ruby_extension_version": "0.2.1"})


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
        assert "view.capture.v1" in status["capabilities"]
        info = await client.call("get_model_info")
        assert info["root_entity_count"] == 2
        assert info["guid"] == "fixture-guid"
        assert info["dev_fixture"] is False
        assert info["dev_fixture_id"] is None
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
        assert object_info["bbox_dimensions_mm"]["width"] == 25.4
        measured = await client.call("measure", {"kind": "bbox_dimensions", "target": {"persistent_id": 11}})
        assert measured["unit"] == "mm"
        assert measured["targets"] == [target]
        assert measured["value"] == object_info["bbox_dimensions_mm"]
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
async def test_m2_create_box_find_get_transform_get_cross_language():
    ruby = shutil.which("ruby")
    if ruby is None:
        pytest.skip("Ruby executable unavailable")
    process = await asyncio.create_subprocess_exec(
        ruby, "tests/ruby/bridge_fixture.rb", cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        port = int(await asyncio.wait_for(process.stdout.readline(), 5))
        client = BridgeClient(Config(port=port))
        result = await client.call("create_box", {"width_mm": 600, "depth_mm": 560,
                                                    "height_mm": 720, "origin_mm": [100, 200, 30]})
        assert result["status"] == "success"
        assert result["operation"] == "create_box"
        assert result["revision"] == 1
        created = result["created"][0]
        homecad_id = created["identity"]["homecad_id"]
        assert homecad_id
        assert created["metadata"]["type"] == "primitive.box"

        found = await client.call("find_objects", {"homecad_id": homecad_id})
        assert found["resolution"] == "unique"
        target = found["objects"][0]["identity"]
        before = await client.call("get_object", {"target": {"homecad_id": homecad_id}})
        assert before["bbox_dimensions_mm"] == pytest.approx({"width": 600, "depth": 560, "height": 720})

        moved = await client.call("transform_object", {
            "target": target, "transform": {"type": "translate", "vector_mm": [100, -50, 25]}})
        assert moved["status"] == "success"
        assert moved["revision"] == 2
        after = await client.call("get_object", {"target": {"homecad_id": homecad_id}})
        assert after["identity"]["homecad_id"] == homecad_id
        assert after["metadata"]["revision"] == 2
        assert after["bbox_dimensions_mm"] == before["bbox_dimensions_mm"]
        for before_axis, delta in zip(("x", "y", "z"), (100, -50, 25)):
            assert after["bbox_mm"]["min"][{"x": 0, "y": 1, "z": 2}[before_axis]] == pytest.approx(
                before["bbox_mm"]["min"][{"x": 0, "y": 1, "z": 2}[before_axis]] + delta)
    finally:
        process.terminate()
        await process.wait()


@pytest.mark.asyncio
async def test_m3_wall_window_update_delete_cross_language():
    ruby = shutil.which("ruby")
    if ruby is None:
        pytest.skip("Ruby executable unavailable")
    process = await asyncio.create_subprocess_exec(
        ruby, "tests/ruby/bridge_fixture.rb", cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        port = int(await asyncio.wait_for(process.stdout.readline(), 5))
        client = BridgeClient(Config(port=port))
        status = await client.call("homecad_status")
        assert "architecture.core.v1" in status["capabilities"]
        wall_result = await client.call("create_wall", {
            "start_mm": [0, 0, 0], "end_mm": [4000, 0, 0],
            "thickness_mm": 120, "height_mm": 2700,
        })
        wall_id = wall_result["created"][0]["identity"]["homecad_id"]
        frame = await client.call("get_wall_frame", {"wall": {"homecad_id": wall_id}})
        assert frame["u_axis"] == pytest.approx([1, 0, 0])
        window = await client.call("create_window", {
            "wall": {"homecad_id": wall_id}, "offset_mm": 1000, "bottom_mm": 900,
            "width_mm": 1200, "height_mm": 1200,
        })
        window_id = window["created"][0]["identity"]["homecad_id"]
        info = await client.call("get_object", {"target": {"homecad_id": window_id}})
        assert info["metadata"]["type"] == "architecture.window"
        assert info["parameters"]["offset_mm"] == 1000
        updated = await client.call("update_architecture_object", {
            "target": {"homecad_id": wall_id},
            "changes": {"start_mm": [100, 200, 0], "end_mm": [100, 4200, 0]},
        })
        assert updated["revision"] == 3
        moved_frame = await client.call("get_wall_frame", {"wall": {"homecad_id": wall_id}})
        assert moved_frame["u_axis"] == pytest.approx([0, 1, 0])
        still_hosted = await client.call("get_object", {"target": {"homecad_id": window_id}})
        assert still_hosted["parameters"]["offset_mm"] == 1000
        deleted = await client.call("delete_architecture_object", {
            "target": {"homecad_id": window_id}, "cascade": False,
        })
        assert deleted["deleted"][0]["metadata"]["type"] == "architecture.window"
        with pytest.raises(BridgeError) as missing:
            await client.call("get_object", {"target": {"homecad_id": window_id}})
        assert missing.value.category == "target_not_found"
    finally:
        process.terminate()
        await process.wait()


@pytest.mark.asyncio
async def test_m4_cabinet_create_frame_update_cross_language():
    ruby = shutil.which("ruby")
    if ruby is None:
        pytest.skip("Ruby executable unavailable")
    process = await asyncio.create_subprocess_exec(
        ruby, "tests/ruby/bridge_fixture.rb", cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        port = int(await asyncio.wait_for(process.stdout.readline(), 5))
        client = BridgeClient(Config(port=port))
        status = await client.call("homecad_status")
        assert "furniture.core.v1" in status["capabilities"]
        result = await client.call("create_cabinet", {
            "width_mm": 600, "depth_mm": 560, "height_mm": 720,
            "shelf_z_mm": [300], "detail_level": "construction",
        })
        cabinet_id = result["created"][0]["identity"]["homecad_id"]
        assert result["created"][0]["metadata"]["type"] == "furniture.cabinet"
        assert result["created"][0]["metadata"]["revision"] == 1
        found = await client.call("find_objects", {"homecad_id": cabinet_id})
        assert found["resolution"] == "unique"
        frame = await client.call("get_furniture_frame", {"target": {"homecad_id": cabinet_id}})
        assert frame["width_mm"] == 600
        assert frame["x_axis"] == pytest.approx([1, 0, 0])
        schedule = await client.call("list_furniture_parts", {"target": {"homecad_id": cabinet_id}})
        assert schedule["count"] == 6
        updated = await client.call("update_furniture_object", {
            "target": {"homecad_id": cabinet_id}, "changes": {"height_mm": 800},
        })
        assert updated["revision"] == 2
        cabinet = await client.call("get_object", {"target": {"homecad_id": cabinet_id}})
        assert cabinet["parameters"]["height_mm"] == 800
        assert cabinet["metadata"]["revision"] == 2
    finally:
        process.terminate()
        await process.wait()


@pytest.mark.asyncio
async def test_m5_plan_apply_validate_cross_language():
    ruby = shutil.which("ruby")
    if ruby is None:
        pytest.skip("Ruby executable unavailable")
    process = await asyncio.create_subprocess_exec(
        ruby, "tests/ruby/bridge_fixture.rb", cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        port = int(await asyncio.wait_for(process.stdout.readline(), 5))
        client = BridgeClient(Config(port=port))
        status = await client.call("homecad_status")
        assert "kitchen.run.v1" in status["capabilities"]
        wall = await client.call("create_wall", {
            "start_mm": [0, 0, 0], "end_mm": [3000, 0, 0],
            "thickness_mm": 120, "height_mm": 2700,
        })
        wall_id = wall["created"][0]["identity"]["homecad_id"]
        plan = await client.call("plan_kitchen_run", {
            "wall": {"homecad_id": wall_id}, "start_mm": 100,
            "end_mm": 1400, "side": "negative_v", "modules": [
                {"key": "sink", "type": "sink", "width_mm": 600},
                {"key": "hob", "type": "hob", "width_mm": 600},
            ],
        })
        assert not plan["conflicts"]
        assert plan["filler_mm"] == 100
        applied = await client.call("apply_kitchen_run", {"plan": plan})
        run_id = applied["created"][0]["identity"]["homecad_id"]
        assert applied["created"][0]["metadata"]["type"] == "kitchen.run"
        found = await client.call("find_objects", {"homecad_id": run_id})
        assert found["resolution"] == "unique"
        validation = await client.call("validate_kitchen", {"target": {"homecad_id": run_id}})
        assert validation["valid"] is True
        assert validation["module_count"] == 2
    finally:
        process.terminate()
        await process.wait()


def test_m3_smoke_requires_disposable_model_confirmation():
    result = __import__("subprocess").run(
        [sys.executable, "scripts/smoke_m3.py"], cwd=ROOT,
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 2
    assert "--confirm-disposable" in result.stderr


def test_m4_smoke_requires_disposable_model_confirmation():
    result = __import__("subprocess").run(
        [sys.executable, "scripts/smoke_m4.py"], cwd=ROOT,
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 2
    assert "--confirm-disposable" in result.stderr


def test_m5_smoke_requires_disposable_model_confirmation():
    result = __import__("subprocess").run(
        [sys.executable, "scripts/smoke_m5.py"], cwd=ROOT,
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 2
    assert "--confirm-disposable" in result.stderr


@pytest.mark.asyncio
async def test_mcp_stdio_starts_and_lists_supported_tools():
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
                "get_object", "get_selection", "measure", "capture_view", "undo",
                "create_group", "create_face", "create_edge", "create_box", "create_circle",
                "create_arc", "create_polygon", "push_pull", "follow_me", "transform_object",
                "boolean_operation", "get_wall_frame", "create_wall", "create_opening",
                "create_door", "create_window", "create_niche", "create_column",
                "update_architecture_object", "delete_architecture_object", "create_room",
        "detect_rooms", "get_furniture_frame", "list_furniture_parts", "create_cabinet",
        "update_furniture_object", "delete_furniture_object",
        "plan_kitchen_run", "apply_kitchen_run", "validate_kitchen",
        "update_kitchen_run", "delete_kitchen_run"}
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
        for args in (("--name", "Known Chair"), ("--name", "Missing Name"), ()):
            run = await asyncio.create_subprocess_exec(
                sys.executable, "scripts/smoke_m1.py", *args,
                "--output", str(tmp_path), cwd=ROOT,
                env={**os.environ, "HOMECAD_PORT": str(port)},
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(run.communicate(), 40)
            assert run.returncode == 0, (stdout + stderr).decode()
            if args == ("--name", "Missing Name"):
                assert b"Using the single selected object" in stdout
        run = await asyncio.create_subprocess_exec(
            sys.executable, "scripts/smoke_m1.py", "--name", "a",
            "--output", str(tmp_path), cwd=ROOT,
            env={**os.environ, "HOMECAD_PORT": str(port)},
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(run.communicate(), 40)
        assert run.returncode == 2
        assert b"smoke_m1: Name 'a' is multiple" in stderr
        assert b"ExceptionGroup" not in stderr
        assert (tmp_path / "top.png").read_bytes().startswith(b"\x89PNG")
        assert (tmp_path / "iso.png").read_bytes().startswith(b"\x89PNG")
    finally:
        bridge.terminate()
        await bridge.wait()
