import asyncio
import shutil
import subprocess
import sys
import pytest

from homecad_mcp.connection import BridgeClient, METHOD_CAPABILITIES
from homecad_mcp.config import Config
from homecad_mcp.errors import BridgeError
from homecad_mcp import server
from test_integration import ROOT

NAMES = {name for name, cap in METHOD_CAPABILITIES.items() if cap.startswith('electrical.')}

def test_smoke_requires_disposable_confirmation():
    result = subprocess.run([sys.executable, 'scripts/smoke_m6.py'], cwd=ROOT,
                            capture_output=True, text=True)
    assert result.returncode == 2
    assert '--confirm-disposable' in result.stderr

@pytest.mark.asyncio
async def test_schemas_and_annotations():
    tools = {tool.name: tool for tool in await server.mcp.list_tools()}
    assert len(NAMES) == 12 and NAMES <= tools.keys()
    for name in NAMES:
        annotation = tools[name].annotations
        assert annotation.openWorldHint is False
        assert annotation.readOnlyHint == (name in {'validate_electrical', 'get_circuit', 'list_circuits'})
        if name not in {'validate_electrical', 'get_circuit', 'list_circuits'}:
            assert annotation.idempotentHint is False
            assert annotation.destructiveHint == (not name.startswith('create_'))
    schema = tools['create_outlet'].inputSchema
    assert {'placement', 'dimensions_mm'} <= set(schema['required'])
    assert 'normal' in str(schema) and 'width_mm' in str(schema)
    assert tools['assign_to_circuit'].inputSchema['properties']['circuit_id']['anyOf']

def test_capabilities_are_additive_and_assign_needs_both():
    old = {'capabilities': ['furniture.core.v1', 'scene.inspect.v1']}
    BridgeClient._check_method_capability('get_object', old)
    for name in NAMES:
        with pytest.raises(BridgeError) as error:
            BridgeClient._check_method_capability(name, old)
        assert error.value.category == 'unsupported_operation'
        BridgeClient._check_method_capability(name, {'capabilities': ['electrical.points.v1', 'electrical.circuits.v1']})
    with pytest.raises(BridgeError):
        BridgeClient._check_method_capability('assign_to_circuit', {'capabilities': ['electrical.circuits.v1']})

@pytest.mark.asyncio
async def test_forwarding_and_result_passthrough(monkeypatch):
    calls = []
    envelope = {'status': 'success', 'created': [], 'updated': [], 'deleted': [], 'warnings': [], 'revision': 1}
    async def fake(method, params):
        calls.append((method, params))
        return envelope
    monkeypatch.setattr(server, '_scene_call', fake)
    placement = {'mode': 'world', 'origin_mm': [0,0,0], 'normal': [0,0,1], 'up': [0,1,0]}
    dimensions = {'width_mm': 80, 'height_mm': 80, 'depth_mm': 20}
    assert await server.create_outlet(placement, dimensions) is envelope
    await server.create_switch(placement, dimensions)
    await server.create_electrical_point('junction_box', placement, dimensions)
    await server.update_electrical_point({'homecad_id': 'point'}, {'quantity': 2})
    await server.delete_electrical_point({'homecad_id': 'point'})
    await server.validate_electrical(limit=1)
    await server.create_circuit('Kitchen', 230, protection_label='project label')
    await server.get_circuit({'homecad_id': 'circuit'})
    await server.list_circuits(1, 2)
    await server.update_circuit({'homecad_id': 'circuit'}, {'name': 'Other'})
    await server.delete_circuit({'homecad_id': 'circuit'}, True)
    await server.assign_to_circuit({'homecad_id': 'point'}, None)
    assert {method for method, _ in calls} == NAMES
    assert calls[0][1]['placement'] == placement
    assert calls[8][1] == {'limit': 1, 'offset': 2}
    assert calls[-1][1]['circuit_id'] is None

@pytest.mark.asyncio
async def test_electrical_cross_language():
    ruby = shutil.which('ruby')
    if not ruby:
        pytest.skip('Ruby executable unavailable')
    process = await asyncio.create_subprocess_exec(ruby, 'tests/ruby/bridge_fixture.rb', cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        port = int(await asyncio.wait_for(process.stdout.readline(), 5))
        client = BridgeClient(Config(port=port))
        wall = await client.call('create_wall', {'start_mm': [0,0,0], 'end_mm': [4000,0,0],
            'height_mm': 2700, 'thickness_mm': 120})
        wall_id = wall['created'][0]['homecad_id']
        created = await client.call('create_outlet', {'placement': {'mode': 'wall', 'wall_id': wall_id,
            'offset_mm': 1000, 'height_mm': 300, 'side': 'positive_v'},
            'dimensions_mm': {'width_mm': 80, 'height_mm': 80, 'depth_mm': 20}})
        point_id = created['created'][0]['homecad_id']
        circuit = await client.call('create_circuit', {'name': 'Kitchen', 'voltage_v': 230})
        circuit_id = circuit['created'][0]['homecad_id']
        assigned = await client.call('assign_to_circuit', {'target': {'homecad_id': point_id}, 'circuit_id': circuit_id})
        assert assigned['revision'] == 2 and len(assigned['updated']) == 2
        got = await client.call('get_object', {'target': {'homecad_id': point_id}})
        assert got['relationships']['circuit_id'] == circuit_id
        assert (await client.call('get_circuit', {'target': {'homecad_id': circuit_id}}))['member_ids'] == [point_id]
        assert (await client.call('validate_electrical', {}))['total'] == 0
        with pytest.raises(BridgeError) as error:
            await client.call('create_outlet', {'placement': {'mode': 'wall', 'wall_id': wall_id,
                'offset_mm': 0, 'height_mm': 300, 'side': 'positive_v'},
                'dimensions_mm': {'width_mm': 80, 'height_mm': 80, 'depth_mm': 20}})
        assert error.value.category == 'constraint_violation'
    finally:
        process.terminate()
        await process.wait()
