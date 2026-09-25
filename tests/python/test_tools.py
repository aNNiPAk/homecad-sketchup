import pytest

from homecad_mcp.errors import BridgeError
from homecad_mcp.connection import BridgeClient
from homecad_mcp.server import (boolean_operation, capture_view, create_box, find_objects,
                                create_wall, detect_rooms, get_model_info, homecad_status,
                                mcp, push_pull, update_architecture_object, create_cabinet,
                                get_furniture_frame, list_furniture_parts,
                                update_furniture_object, delete_furniture_object)


@pytest.mark.asyncio
async def test_mcp_tools_expose_mutation_schemas_and_annotations():
    tools = {tool.name: tool for tool in await mcp.list_tools()}
    names = set(tools)
    assert names == {"homecad_status", "get_model_info", "list_objects", "find_objects",
                     "get_object", "get_selection", "measure", "capture_view", "undo",
                     "create_group", "create_face", "create_edge", "create_box",
                     "create_circle", "create_arc", "create_polygon", "push_pull",
                     "follow_me", "transform_object", "boolean_operation", "get_wall_frame",
                     "create_wall", "create_opening", "create_door", "create_window",
                     "create_niche", "create_column", "update_architecture_object",
                     "delete_architecture_object", "create_room", "detect_rooms",
                     "get_furniture_frame", "list_furniture_parts", "create_cabinet",
                     "update_furniture_object", "delete_furniture_object"}
    read_only = {"homecad_status", "get_model_info", "list_objects", "find_objects",
                 "get_object", "get_selection", "measure", "capture_view"}
    for name in read_only:
        assert tools[name].annotations.readOnlyHint is True
        assert tools[name].annotations.openWorldHint is False
    for name in {"get_wall_frame", "detect_rooms"}:
        assert tools[name].annotations.readOnlyHint is True
    for name in {"get_furniture_frame", "list_furniture_parts"}:
        assert tools[name].annotations.readOnlyHint is True
    create_tools = {"create_group", "create_face", "create_edge", "create_box", "create_circle",
                    "create_arc", "create_polygon", "boolean_operation"}
    for name in create_tools:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is False
        assert tools[name].annotations.idempotentHint is False
        assert tools[name].annotations.openWorldHint is False
    architecture_creates = {"create_wall", "create_opening", "create_door", "create_window",
                            "create_niche", "create_column", "create_room"}
    for name in architecture_creates:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is False
        assert tools[name].annotations.idempotentHint is False
        assert tools[name].annotations.openWorldHint is False
    for name in {"create_cabinet"}:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is False
        assert tools[name].annotations.idempotentHint is False
    for name in {"update_architecture_object", "delete_architecture_object"}:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is True
        assert tools[name].annotations.idempotentHint is False
        assert tools[name].annotations.openWorldHint is False
    for name in {"update_furniture_object", "delete_furniture_object"}:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is True
        assert tools[name].annotations.idempotentHint is False
        assert tools[name].annotations.openWorldHint is False
    for name in {"push_pull", "follow_me", "transform_object"}:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is True
        assert tools[name].annotations.idempotentHint is False
        assert tools[name].annotations.openWorldHint is False
    assert tools["undo"].annotations.readOnlyHint is False
    assert tools["undo"].annotations.destructiveHint is True
    assert tools["undo"].annotations.idempotentHint is False
    assert tools["undo"].annotations.openWorldHint is False
    assert "width_mm" in tools["create_box"].inputSchema["properties"]
    assert "target" in tools["transform_object"].inputSchema["properties"]
    assert "start_mm" in tools["create_wall"].inputSchema["properties"]
    assert "wall_ids" in tools["create_room"].inputSchema["properties"]
    assert "width_mm" in tools["create_cabinet"].inputSchema["properties"]


@pytest.mark.asyncio
async def test_disconnected_status_is_actionable(monkeypatch):
    async def fail(self, method):
        raise BridgeError("connection_error", "Open SketchUp and enable HomeCAD")

    monkeypatch.setattr("homecad_mcp.server.BridgeClient.call", fail)
    result = await homecad_status()
    assert result["connection_status"] == "disconnected"
    assert "Open SketchUp" in result["error"]["message"]


@pytest.mark.asyncio
async def test_get_model_info_surfaces_bridge_error(monkeypatch):
    async def fail(self, method):
        raise BridgeError("incompatible_version", "Install matching RBZ")

    monkeypatch.setattr("homecad_mcp.server.BridgeClient.call", fail)
    with pytest.raises(RuntimeError, match="incompatible_version: Install matching RBZ"):
        await get_model_info()


@pytest.mark.asyncio
async def test_find_omits_empty_filters_and_maps_ambiguity(monkeypatch):
    seen = []

    async def fake(method, params):
        seen.append((method, params))
        raise BridgeError("ambiguous_target", "two placements")

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    with pytest.raises(BridgeError, match="two placements"):
        await find_objects(name="Chair")
    assert seen == [("find_objects", {"name": "Chair", "limit": 50, "offset": 0})]


@pytest.mark.asyncio
async def test_capture_returns_mcp_image(monkeypatch):
    import base64
    from mcp.server.fastmcp import Image

    async def fake(method, params):
        assert method == "capture_view"
        assert params["restore_camera"] is True
        return {"image_base64": base64.b64encode(b"\x89PNG\r\n\x1a\nimage").decode(),
                "view": "top", "camera_restored": True}

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    content = await capture_view(view="top")
    assert isinstance(content[1], Image)
    assert content[1].to_image_content().mimeType == "image/png"


@pytest.mark.asyncio
async def test_mutation_result_is_returned_without_schema_drift(monkeypatch):
    envelope = {"status": "success", "operation": "create_box", "created": [{"identity": {"homecad_id": "fixture"}}],
                "updated": [], "deleted": [], "warnings": [], "revision": 1}

    async def fake(method, params):
        assert method == "create_box"
        assert params == {"width_mm": 600, "depth_mm": 560, "height_mm": 720}
        return envelope

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    result = await create_box(600, 560, 720)
    assert result is envelope


@pytest.mark.asyncio
async def test_mutation_tools_forward_explicit_targets(monkeypatch):
    calls = []

    async def fake(method, params):
        calls.append((method, params))
        return {"status": "success"}

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    await push_pull({"persistent_id": 42}, 125)
    await boolean_operation({"homecad_id": "a"}, {"persistent_id": 9}, "difference")
    assert calls == [
        ("push_pull", {"target": {"persistent_id": 42}, "distance_mm": 125}),
        ("boolean_operation", {"target": {"homecad_id": "a"},
                               "tool": {"persistent_id": 9}, "operation": "difference"}),
    ]


@pytest.mark.asyncio
async def test_architecture_tools_forward_domain_parameters(monkeypatch):
    calls = []

    async def fake(method, params):
        calls.append((method, params))
        return {"status": "success", "operation": method}

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    await create_wall([0, 0, 0], [4000, 0, 0], 120, 2700)
    await update_architecture_object({"homecad_id": "wall-id"}, {"height_mm": 2800})
    await detect_rooms()
    assert calls == [
        ("create_wall", {"start_mm": [0, 0, 0], "end_mm": [4000, 0, 0],
                          "thickness_mm": 120, "height_mm": 2700}),
        ("update_architecture_object", {"target": {"homecad_id": "wall-id"},
                                         "changes": {"height_mm": 2800}}),
        ("detect_rooms", {}),
    ]


@pytest.mark.asyncio
async def test_furniture_tools_forward_parameters_and_preserve_envelope(monkeypatch):
    calls = []
    envelope = {"status": "success", "operation": "create_cabinet", "created": [],
                "updated": [], "deleted": [], "warnings": [], "revision": 1}

    async def fake(method, params):
        calls.append((method, params))
        return envelope

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    assert await create_cabinet(600, 560, 720, shelf_z_mm=[300]) is envelope
    await get_furniture_frame({"homecad_id": "cabinet"})
    await list_furniture_parts({"homecad_id": "cabinet"})
    await update_furniture_object({"homecad_id": "cabinet"}, {"height_mm": 800})
    await delete_furniture_object({"homecad_id": "cabinet"})
    assert calls[0][0] == "create_cabinet"
    assert calls[0][1]["shelf_z_mm"] == [300]
    assert calls[1:] == [
        ("get_furniture_frame", {"target": {"homecad_id": "cabinet"}}),
        ("list_furniture_parts", {"target": {"homecad_id": "cabinet"}}),
        ("update_furniture_object", {"target": {"homecad_id": "cabinet"}, "changes": {"height_mm": 800}}),
        ("delete_furniture_object", {"target": {"homecad_id": "cabinet"}}),
    ]


def test_furniture_methods_require_advertised_capability():
    with pytest.raises(BridgeError) as missing:
        BridgeClient._check_method_capability("create_cabinet", {
            "protocol_version": 1, "ruby_extension_version": "0.5.0", "capabilities": ["architecture.core.v1"]
        })
    assert missing.value.category == "unsupported_operation"
    BridgeClient._check_method_capability("create_cabinet", {
        "protocol_version": 1, "ruby_extension_version": "0.6.0",
        "capabilities": ["furniture.core.v1", "unknown.future.capability.v9"],
    })
