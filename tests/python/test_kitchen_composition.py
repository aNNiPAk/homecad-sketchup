import asyncio
import shutil

import pytest
from homecad_mcp import server
from homecad_mcp.config import Config
from homecad_mcp.connection import BridgeClient
from homecad_mcp.errors import BridgeError
from test_integration import ROOT


def test_composition_capability_is_additive_and_nested():
    old={"capabilities":["kitchen.run.v1","kitchen.corner_run.v1","kitchen.variants.v1"]}
    plain={"modules":[{"key":"a","type":"base_drawers","width_mm":600}]}
    BridgeClient._check_method_capability("plan_kitchen_run",old,plain)
    cases=[("plan_kitchen_run",{"countertop_cutouts":[]}),
           ("plan_kitchen_run",{"modules":[{"drawer_layout":{"count":2}}]}),
           ("plan_corner_kitchen_run",{"legs":[{"modules":[{"shelf_z_mm":[200]}]}]}),
           ("update_kitchen_run",{"changes":{"modules":[{"back_thickness_mm":0}]}}),
           ("apply_kitchen_run",{"plan":{"params":{"modules":[{"composition_version":1}]}}})]
    for method,params in cases:
        with pytest.raises(BridgeError) as error:
            BridgeClient._check_method_capability(method,old,params)
        assert error.value.category=="unsupported_operation"
        assert "kitchen.composition.v1" in str(error.value)
        BridgeClient._check_method_capability(method,{"capabilities":old["capabilities"]+["kitchen.composition.v1"]},params)


@pytest.mark.asyncio
async def test_cutout_schema_forwarding_and_existing_annotations(monkeypatch):
    tools={t.name:t for t in await server.mcp.list_tools()}
    assert "countertop_cutouts" in tools["plan_kitchen_run"].inputSchema["properties"]
    assert tools["plan_kitchen_run"].annotations.readOnlyHint
    assert not tools["apply_kitchen_run"].annotations.readOnlyHint
    calls=[]
    async def fake(method,params):
        calls.append((method,params)); return {"params":params}
    monkeypatch.setattr(server,"_scene_call",fake)
    await server.plan_kitchen_run({},0,600,"positive_v",[])
    assert "countertop_cutouts" not in calls[-1][1]
    cuts=[{"key":"sink","offset_mm":100,"front_mm":100,"width_mm":300,"depth_mm":300}]
    await server.plan_kitchen_run({},0,600,"positive_v",[],countertop_cutouts=cuts)
    assert calls[-1][1]["countertop_cutouts"]==cuts


@pytest.mark.asyncio
async def test_cross_language_composition_cutlist_and_atomic_errors():
    ruby=shutil.which("ruby")
    if not ruby: pytest.skip("Ruby unavailable")
    process=await asyncio.create_subprocess_exec(ruby,"tests/ruby/bridge_fixture.rb",cwd=ROOT,
        stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        port=int(await asyncio.wait_for(process.stdout.readline(),5))
        client=BridgeClient(Config(port=port))
        wall=await client.call("create_wall",{"start_mm":[0,0,0],"end_mm":[4000,0,0],"height_mm":2700,"thickness_mm":120})
        target={"homecad_id":wall["created"][0]["homecad_id"]}
        plan=await client.call("plan_kitchen_run",{"wall":target,"start_mm":0,"end_mm":1800,"side":"positive_v",
            "modules":[{"key":"shelves","type":"base_shelves","width_mm":600,"back_thickness_mm":0},
                       {"key":"drawers","type":"base_drawers","width_mm":600},
                       {"key":"dishwasher","type":"dishwasher","width_mm":600}],
            "countertop_cutouts":[{"key":"explicit","offset_mm":100,"front_mm":100,"width_mm":300,"depth_mm":300}]})
        result=await client.call("apply_kitchen_run",{"plan":plan})
        run={"homecad_id":result["created"][0]["homecad_id"]}
        rows=(await client.call("generate_cutlist",{"target":run,"limit":100}))["records"]
        assert any(r["part_kind"]=="shelf" for r in rows)
        assert sum(r["part_kind"]=="drawer_slide_pair" for r in rows)==2
        assert not any(r["part_key"]=="module:shelves/back" for r in rows)
        assert next(r for r in rows if r["part_key"]=="countertop")["manufacturing_status"]=="concept_shaped"
        before=await client.call("get_object",{"target":run})
        with pytest.raises(BridgeError) as error:
            await client.call("update_kitchen_run",{"target":run,"changes":{"countertop_cutouts":[{"key":"bad","offset_mm":0,"front_mm":0,"width_mm":500,"depth_mm":500}]}})
        assert error.value.category=="constraint_violation"
        assert await client.call("get_object",{"target":run})==before
    finally:
        process.terminate(); await process.wait()
