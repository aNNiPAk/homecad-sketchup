import asyncio
import shutil
import pytest
from homecad_mcp import server
from homecad_mcp.connection import BridgeClient, METHOD_CAPABILITIES
from homecad_mcp.config import Config
from homecad_mcp.errors import BridgeError
from test_integration import ROOT

CAPS = {'electrical.panels.v1','electrical.consumers.v1','electrical.routes.v1','electrical.load.v1','electrical.rules.v1'}
NAMES = {name for name,cap in METHOD_CAPABILITIES.items() if cap in CAPS}

@pytest.mark.asyncio
async def test_m61_schemas_annotations_and_forwarding(monkeypatch):
    tools={tool.name:tool for tool in await server.mcp.list_tools()}
    assert len(NAMES)==19 and NAMES <= tools.keys()
    for name in NAMES:
        readonly=name.startswith(('get_','list_','find_'))
        assert tools[name].annotations.readOnlyHint == readonly
        assert tools[name].annotations.openWorldHint is False
        if not readonly:
            assert tools[name].annotations.idempotentHint is False
            assert tools[name].annotations.destructiveHint == (not name.startswith('create_'))
    assert {'source_object_id','name'} <= set(tools['create_consumer'].inputSchema['required'])
    assert 'circuit_id' not in tools['create_consumer'].inputSchema['properties']
    assert 'detach_routes' in tools['delete_circuit'].inputSchema['properties']
    calls=[]; envelope={'status':'success','created':[],'updated':[],'deleted':[],'revision':1,'warnings':[]}
    async def fake(method,params):
        calls.append((method,params)); return envelope
    monkeypatch.setattr(server,'_scene_call',fake)
    placement={'mode':'world','origin_mm':[0,0,0],'normal':[0,1,0],'up':[0,0,1]}
    size={'width_mm':200,'height_mm':300,'depth_mm':100}
    target={'homecad_id':'record'}
    assert await server.create_distribution_panel(placement,size) is envelope
    await server.get_distribution_panel(target)
    await server.update_distribution_panel(target,{'name':'P'})
    await server.delete_distribution_panel(target,True)
    await server.assign_circuit_to_panel(target,None)
    await server.create_consumer('A','source',rated_power_w=2000)
    await server.get_consumer(target)
    await server.list_consumers(1,2)
    await server.update_consumer(target,{'rated_power_w':None})
    await server.delete_consumer(target)
    await server.connect_consumer(target,None)
    await server.find_unpowered_consumers(1,2)
    await server.get_circuit_load(target)
    await server.get_electrical_ruleset()
    await server.create_cable_route('R','circuit',[[0,0,0],[100,0,0]])
    await server.get_cable_route(target)
    await server.list_cable_routes(1,2)
    await server.update_cable_route(target,{'name':'R'})
    await server.delete_cable_route(target)
    assert {method for method,_ in calls} == NAMES
    assert calls[5][1]['voltage_v'] is None
    assert calls[10][1]['point_id'] is None

def test_capability_rejection_and_old_m6_requests():
    old={'capabilities':['electrical.points.v1','electrical.circuits.v1']}
    for name in NAMES:
        with pytest.raises(BridgeError) as error:
            BridgeClient._check_method_capability(name,old)
        assert error.value.category=='unsupported_operation'
        BridgeClient._check_method_capability(name,{'capabilities':old['capabilities']+sorted(CAPS)})
    for method,params in [('create_circuit',{'name':'Old'}),('delete_circuit',{'detach_points':True}),
                          ('update_circuit',{'changes':{'name':'Old'}}),('validate_electrical',{})]:
        BridgeClient._check_method_capability(method,old,params)
    for method,params in [('create_circuit',{'panel_id':'panel'}),('update_circuit',{'changes':{'require_panel':True}}),
                          ('delete_circuit',{'detach_routes':True}),('validate_electrical',{'ruleset':'generic'})]:
        with pytest.raises(BridgeError):
            BridgeClient._check_method_capability(method,old,params)

@pytest.mark.asyncio
async def test_old_fields_are_not_injected(monkeypatch):
    calls=[]
    async def fake(method,params): calls.append((method,params)); return {}
    monkeypatch.setattr(server,'_scene_call',fake)
    await server.create_circuit('Old')
    await server.delete_circuit({'homecad_id':'old'})
    await server.validate_electrical()
    assert 'panel_id' not in calls[0][1] and 'require_panel' not in calls[0][1]
    assert 'detach_routes' not in calls[1][1]
    assert 'ruleset' not in calls[2][1] and 'constraints' not in calls[2][1]

@pytest.mark.asyncio
async def test_m61_cross_language_graph_and_source_lifecycle():
    ruby=shutil.which('ruby')
    if not ruby: pytest.skip('Ruby unavailable')
    process=await asyncio.create_subprocess_exec(ruby,'tests/ruby/bridge_fixture.rb',cwd=ROOT,
        stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        port=int(await asyncio.wait_for(process.stdout.readline(),5)); client=BridgeClient(Config(port=port))
        wall=await client.call('create_wall',{'start_mm':[0,0,0],'end_mm':[4000,0,0],'thickness_mm':120,'height_mm':2700})
        wid=wall['created'][0]['homecad_id']
        placement={'mode':'wall','wall_id':wid,'offset_mm':500,'height_mm':1500,'side':'positive_v'}
        panel=await client.call('create_distribution_panel',{'placement':placement,
            'dimensions_mm':{'width_mm':200,'height_mm':300,'depth_mm':100}})
        pid=panel['created'][0]['homecad_id']
        circuit=await client.call('create_circuit',{'name':'A','panel_id':pid,'voltage_v':230})
        cid=circuit['created'][0]['homecad_id']
        outlet=await client.call('create_outlet',{'placement':{**placement,'offset_mm':1000,'height_mm':300},
            'dimensions_mm':{'width_mm':80,'height_mm':80,'depth_mm':20}})
        point=outlet['created'][0]['homecad_id']
        await client.call('assign_to_circuit',{'target':{'homecad_id':point},'circuit_id':cid})
        plan=await client.call('plan_kitchen_run',{'wall':{'homecad_id':wid},'start_mm':2000,'end_mm':2600,
            'side':'positive_v','modules':[{'key':'dishwasher','type':'dishwasher','width_mm':600}]})
        kitchen=await client.call('apply_kitchen_run',{'plan':plan})
        kid=kitchen['created'][0]['homecad_id']
        source=next(r['homecad_id'] for r in kitchen['created'] if r['homecad_type']=='kitchen.appliance')
        consumer=await client.call('create_consumer',{'name':'Dishwasher','source_object_id':source,'rated_power_w':2000,'voltage_v':230})
        uid=consumer['created'][0]['homecad_id']
        missing=(await client.call('find_unpowered_consumers'))['consumers'][0]
        assert missing['status']=='missing_point' and missing['reason']=='missing_point'
        assert missing['name']=='Dishwasher' and missing['source_type']=='kitchen.appliance'
        assert missing['point_id'] is None and missing['circuit_id'] is None
        assert (await client.call('get_distribution_panel',{'target':{'homecad_id':pid}}))['metadata']['revision']==2
        rules=await client.call('get_electrical_ruleset')
        assert rules['ruleset']=='generic' and 'collision' in rules['checks']
        await client.call('connect_consumer',{'target':{'homecad_id':uid},'point_id':point})
        load=await client.call('get_circuit_load',{'target':{'homecad_id':cid}})
        assert load['rated_power_w']==2000 and load['consumer_ids']==[uid]
        assert load['estimated_current_a']==pytest.approx(2000/230)
        route=await client.call('create_cable_route',{'name':'Route','circuit_id':cid,'path_mm':[[0,0,0],[100,0,0]]})
        assert route['created'][0]['length_mm']==100
        graph=await client.call('get_circuit',{'target':{'homecad_id':cid}})
        assert graph['consumer_ids']==[uid] and graph['route_ids']==[route['created'][0]['homecad_id']]
        assert graph['panel_id']==pid and graph['member_ids']==[point]
        with pytest.raises(BridgeError) as error:
            await client.call('delete_circuit',{'target':{'homecad_id':cid},'detach_points':True})
        assert error.value.category=='constraint_violation'
        deleted=await client.call('delete_kitchen_run',{'target':{'homecad_id':kid}})
        assert any(r['homecad_id']==uid for r in deleted['deleted'])
        assert (await client.call('list_consumers'))['total']==0
        assert (await client.call('get_circuit_load',{'target':{'homecad_id':cid}}))['rated_power_w']==0
    finally:
        process.terminate(); await process.wait()
