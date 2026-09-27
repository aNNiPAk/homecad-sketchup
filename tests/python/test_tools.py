import pytest

from homecad_mcp.errors import BridgeError
from homecad_mcp.connection import BridgeClient
from homecad_mcp.server import (boolean_operation, capture_view, create_box, find_objects,
                                create_wall, detect_rooms, get_model_info, homecad_status,
                                mcp, push_pull, update_architecture_object, create_cabinet,
                                get_furniture_frame, list_furniture_parts,
                                update_furniture_object, delete_furniture_object,
                                plan_kitchen_run, apply_kitchen_run, validate_kitchen,
                                update_kitchen_run, delete_kitchen_run)


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
                     "update_furniture_object", "delete_furniture_object",
                     "get_project_settings", "update_project_settings",
                     "list_furniture_presets", "get_furniture_preset",
                     "create_cabinet_from_preset",
                     "generate_cutlist",
                     "plan_corner_kitchen_run",
                     "plan_kitchen_run", "apply_kitchen_run", "validate_kitchen",
                     "update_kitchen_run", "delete_kitchen_run"}
    read_only = {"homecad_status", "get_model_info", "list_objects", "find_objects",
                 "get_object", "get_selection", "measure", "capture_view"}
    for name in read_only:
        assert tools[name].annotations.readOnlyHint is True
        assert tools[name].annotations.openWorldHint is False
    for name in {"get_wall_frame", "detect_rooms"}:
        assert tools[name].annotations.readOnlyHint is True
    for name in {"get_furniture_frame", "list_furniture_parts", "plan_kitchen_run",
                 "plan_corner_kitchen_run", "validate_kitchen",
                 "get_project_settings", "list_furniture_presets", "get_furniture_preset",
                 "generate_cutlist"}:
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
    for name in {"create_cabinet", "apply_kitchen_run", "create_cabinet_from_preset"}:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is False
        assert tools[name].annotations.idempotentHint is False
    for name in {"update_architecture_object", "delete_architecture_object"}:
        assert tools[name].annotations.readOnlyHint is False
        assert tools[name].annotations.destructiveHint is True
        assert tools[name].annotations.idempotentHint is False
        assert tools[name].annotations.openWorldHint is False
    for name in {"update_furniture_object", "delete_furniture_object", "update_project_settings",
                 "update_kitchen_run", "delete_kitchen_run"}:
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
    assert "modules" in tools["plan_kitchen_run"].inputSchema["properties"]
    assert "plan" in tools["apply_kitchen_run"].inputSchema["properties"]


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
        "protocol_version": 1, "ruby_extension_version": "0.6.1",
        "capabilities": ["furniture.core.v1", "unknown.future.capability.v9"],
    })


def test_kitchen_methods_require_capability():
    with pytest.raises(BridgeError) as missing:
        BridgeClient._check_method_capability("plan_kitchen_run", {
            "protocol_version": 1, "ruby_extension_version": "0.6.1",
            "capabilities": ["furniture.core.v1"],
        })
    assert missing.value.category == "unsupported_operation"
    BridgeClient._check_method_capability("apply_kitchen_run", {
        "protocol_version": 1, "ruby_extension_version": "0.7.0",
        "capabilities": ["kitchen.run.v1", "unknown.future.capability.v9"],
    })


def test_corner_run_capability_is_additive_and_old_runs_remain_supported():
    old = {"capabilities": ["kitchen.run.v1", "kitchen.service_zone.v1"]}
    new = {"capabilities": old["capabilities"] + ["kitchen.corner_run.v1"]}
    BridgeClient._check_method_capability("plan_kitchen_run", old)
    BridgeClient._check_method_capability("apply_kitchen_run", old,
        {"plan": {"params": {"wall_id": "legacy"}}})
    with pytest.raises(BridgeError, match="kitchen.corner_run.v1"):
        BridgeClient._check_method_capability("plan_corner_kitchen_run", old)
    with pytest.raises(BridgeError, match="kitchen.corner_run.v1"):
        BridgeClient._check_method_capability("apply_kitchen_run", old,
            {"plan": {"params": {"layout_type": "l_shaped"}}})
    with pytest.raises(BridgeError, match="kitchen.corner_run.v1"):
        BridgeClient._check_method_capability("update_kitchen_run", old,
            {"changes": {"corner": {"mode": "void"}}})
    BridgeClient._check_method_capability("plan_corner_kitchen_run", new)
    BridgeClient._check_method_capability("apply_kitchen_run", new,
        {"plan": {"params": {"layout_type": "l_shaped"}}})


@pytest.mark.asyncio
async def test_corner_planner_forwards_two_legs(monkeypatch):
    from homecad_mcp.server import plan_corner_kitchen_run
    calls = []

    async def fake(method, params):
        calls.append((method, params))
        return {"params": {"layout_type": "l_shaped"}, "conflicts": []}

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    legs = [{"key": "a", "wall": {"homecad_id": "w1"}},
            {"key": "b", "wall": {"homecad_id": "w2"}}]
    corner = {"mode": "void", "span_first_mm": 900, "span_second_mm": 900}
    await plan_corner_kitchen_run(legs, corner, "L")
    assert calls == [("plan_corner_kitchen_run", {"legs": legs, "corner": corner, "name": "L"})]


def test_project_defaults_and_preset_methods_require_separate_capabilities():
    old = {"protocol_version": 1, "ruby_extension_version": "0.7.1",
           "capabilities": ["furniture.core.v1", "kitchen.run.v1"]}
    for method in ("get_project_settings", "update_project_settings",
                   "list_furniture_presets", "get_furniture_preset",
                   "create_cabinet_from_preset"):
        with pytest.raises(BridgeError) as missing:
            BridgeClient._check_method_capability(method, old)
        assert missing.value.category == "unsupported_operation"
    new = {**old, "capabilities": old["capabilities"] +
           ["project.defaults.v1", "furniture.presets.v1", "future.v9"]}
    for method in ("get_project_settings", "update_project_settings",
                   "list_furniture_presets", "get_furniture_preset",
                   "create_cabinet_from_preset"):
        BridgeClient._check_method_capability(method, new)
    with pytest.raises(BridgeError, match="manufacturing.cutlist.v1"):
        BridgeClient._check_method_capability("generate_cutlist", new)
    BridgeClient._check_method_capability("generate_cutlist", {
        **new, "capabilities": new["capabilities"] + ["manufacturing.cutlist.v1"]
    })


@pytest.mark.asyncio
async def test_project_defaults_and_presets_forward_parameters(monkeypatch):
    from homecad_mcp.server import (get_project_settings, update_project_settings,
                                    list_furniture_presets, get_furniture_preset,
                                    create_cabinet_from_preset, generate_cutlist)
    calls = []

    async def fake(method, params):
        calls.append((method, params))
        return {"status": "success", "operation": method, "revision": 1}

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    await get_project_settings()
    await update_project_settings({"panel_thickness_mm": 20})
    await list_furniture_presets()
    await get_furniture_preset("base_open.v1")
    await create_cabinet_from_preset("base_open.v1", {"width_mm": 700})
    await generate_cutlist({"homecad_id": "cabinet"}, limit=10, offset=2)
    assert calls == [
        ("get_project_settings", {}),
        ("update_project_settings", {"changes": {"panel_thickness_mm": 20}}),
        ("list_furniture_presets", {}),
        ("get_furniture_preset", {"preset_id": "base_open.v1"}),
        ("create_cabinet_from_preset", {"preset_id": "base_open.v1",
                                        "overrides": {"width_mm": 700}}),
        ("generate_cutlist", {"target": {"homecad_id": "cabinet"},
                              "limit": 10, "offset": 2}),
    ]


def test_service_zones_require_additive_capability_only_when_used():
    old = {"capabilities": ["kitchen.run.v1"]}
    new = {"capabilities": ["kitchen.run.v1", "kitchen.service_zone.v1", "future.v9"]}
    legacy = {"modules": [{"key": "sink", "type": "sink", "width_mm": 600}]}
    service = {"modules": [{**legacy["modules"][0],
               "service_clearance_mm": {"front_mm": 100}}]}
    BridgeClient._check_method_capability("plan_kitchen_run", old, legacy)
    BridgeClient._check_method_capability("apply_kitchen_run", old, {"plan": {"params": legacy}})
    BridgeClient._check_method_capability("validate_kitchen", old, {"target": {"homecad_id": "run"}})
    for method, params in (
        ("plan_kitchen_run", service),
        ("apply_kitchen_run", {"plan": {"params": service}}),
        ("update_kitchen_run", {"changes": service}),
        ("plan_kitchen_run", {"constraints": {"require_service_clearance": True}}),
    ):
        with pytest.raises(BridgeError, match="kitchen.service_zone.v1") as missing:
            BridgeClient._check_method_capability(method, old, params)
        assert missing.value.category == "unsupported_operation"
        BridgeClient._check_method_capability(method, new, params)


@pytest.mark.asyncio
async def test_kitchen_tools_forward_plan_and_mutation(monkeypatch):
    calls = []
    async def fake(method, params):
        calls.append((method, params))
        return {"status": "success", "operation": method}

    monkeypatch.setattr("homecad_mcp.server._scene_call", fake)
    modules = [{"key": "sink", "type": "sink", "width_mm": 600}]
    wall = {"homecad_id": "wall"}
    await plan_kitchen_run(wall, 0, 600, "positive_v", modules,
                           start_clearance_mm=20, end_clearance_mm=30,
                           constraints={"require_full_coverage": True})
    await apply_kitchen_run({"fingerprint": "plan"})
    await validate_kitchen({"homecad_id": "run"})
    await update_kitchen_run({"homecad_id": "run"}, {"name": "New"})
    await delete_kitchen_run({"homecad_id": "run"})
    assert [item[0] for item in calls] == ["plan_kitchen_run", "apply_kitchen_run",
                                                "validate_kitchen", "update_kitchen_run",
                                                "delete_kitchen_run"]
    assert calls[0][1]["modules"] == modules
    assert calls[0][1]["start_clearance_mm"] == 20
    assert calls[0][1]["end_clearance_mm"] == 30
    assert calls[0][1]["constraints"] == {"require_full_coverage": True}
    assert calls[1][1] == {"plan": {"fingerprint": "plan"}}
