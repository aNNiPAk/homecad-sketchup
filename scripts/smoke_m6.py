"""Run M6 only on the dedicated disposable HomeCADDev SketchUp model."""
import argparse
import asyncio
import json
import os
import sys
import base64
from pathlib import Path
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from homecad_mcp import VERSION
from smoke_guard import validate_disposable_fixture
from smoke_m61 import verify_system

async def run():
    params = StdioServerParameters(command=sys.executable, args=['-m', 'homecad_mcp'], env=os.environ.copy())
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            pending = 0
            object_ids, circuit_ids = [], []

            async def call(name, args=None):
                response = await session.call_tool(name, args or {})
                body = next((item.text for item in response.content if item.type == 'text'), '{}')
                if response.isError:
                    raise RuntimeError(f'{name}: {body}')
                if name == 'capture_view':
                    image = next((item for item in response.content if item.type == 'image'), None)
                    if image is None:
                        raise RuntimeError('capture_view did not return an image')
                    path = Path(__file__).resolve().parents[1] / '.homecad-dev' / 'screenshots' / f'm6-{(args or {}).get("view","current")}.png'
                    path.parent.mkdir(parents=True,exist_ok=True)
                    path.write_bytes(base64.b64decode(image.data,validate=True))
                    print(f'saved screenshot: {path}')
                    metadata=json.loads(body)
                    if (args or {}).get('target'):
                        metadata['target_bbox_mm']=(await call('get_object',{'target':args['target']}))['bbox_mm']
                    path.with_suffix('.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
                return json.loads(body)

            async def mutate(name, args):
                nonlocal pending
                result = await call(name, args)
                pending += 1
                for item in result.get('created', []):
                    identifier = item['identity']['homecad_id']
                    (circuit_ids if item.get('homecad_type') == 'electrical.circuit' else object_ids).append(identifier)
                return result

            async def undo():
                nonlocal pending
                result = await call('undo')
                if result.get('actions') != 1:
                    raise RuntimeError('Undo did not accept one operation')
                pending -= 1
                await asyncio.sleep(0.5)

            async def expect_error(name, args, category):
                response = await session.call_tool(name, args)
                text = ' '.join(item.text for item in response.content if item.type == 'text')
                if not response.isError or category not in text:
                    raise RuntimeError(f'expected {category}: {name}: {text}')

            def target(identifier):
                return {'homecad_id': identifier}

            async def get(identifier):
                return await call('get_object', {'target': target(identifier)})

            def check_bounds(obj, minimum, maximum):
                for key, expected in [('min', minimum), ('max', maximum)]:
                    if any(abs(a-b) > 0.5 for a, b in zip(obj['bbox_mm'][key], expected)):
                        raise RuntimeError(f'Electrical bounds mismatch: {obj["bbox_mm"]}, expected {minimum}..{maximum}')

            try:
                status = await call('homecad_status')
                if status['ruby_extension_version'] != VERSION or not {'electrical.points.v1', 'electrical.circuits.v1'} <= set(status['capabilities']):
                    raise RuntimeError('matching M6 extension is required')
                before = await call('get_model_info')
                validate_disposable_fixture(True, before)
                wall = await mutate('create_wall', {'start_mm': [0,0,0], 'end_mm': [4000,0,0],
                    'thickness_mm': 120, 'height_mm': 2700})
                wall_id = wall['created'][0]['homecad_id']
                dimensions = {'width_mm': 80, 'height_mm': 80, 'depth_mm': 20}
                placement = {'mode': 'wall', 'wall_id': wall_id, 'offset_mm': 1000,
                    'height_mm': 300, 'side': 'positive_v'}
                made = await mutate('create_outlet', {'placement': placement, 'dimensions_mm': dimensions})
                outlet_id = made['created'][0]['homecad_id']
                check_bounds(await get(outlet_id), [960,60,260], [1040,80,340])
                switch = await mutate('create_switch', {'placement': {**placement, 'side': 'negative_v',
                    'offset_mm': 1500, 'height_mm': 1200}, 'dimensions_mm': dimensions})
                switch_id = switch['created'][0]['homecad_id']
                check_bounds(await get(switch_id), [1460,-80,1160], [1540,-60,1240])
                floor = await mutate('create_electrical_point', {'kind': 'junction_box',
                    'placement': {'mode': 'world', 'origin_mm': [3000,1000,0],
                        'normal': [0,0,1], 'up': [0,1,0]}, 'dimensions_mm': dimensions})
                check_bounds(await get(floor['created'][0]['homecad_id']), [2960,960,0], [3040,1040,20])
                ceiling = await mutate('create_electrical_point', {'kind': 'connection_point',
                    'placement': {'mode': 'world', 'origin_mm': [3000,1000,2700],
                        'normal': [0,0,-1], 'up': [0,1,0]}, 'dimensions_mm': dimensions})
                check_bounds(await get(ceiling['created'][0]['homecad_id']), [2960,960,2680], [3040,1040,2700])
                tilted = await mutate('create_electrical_point', {'kind': 'connection_point',
                    'placement': {'mode': 'world', 'origin_mm': [3500,1000,1000],
                        'normal': [0,1,1], 'up': [1,0,0]}, 'dimensions_mm': dimensions})
                tilted_id = tilted['created'][0]['homecad_id']
                tilted_before = await get(tilted_id)
                reapplied = await call('update_electrical_point', {'target': target(tilted_id),
                    'changes': {'placement': tilted_before['parameters']['placement']}})
                assert reapplied['revision'] == 1
                assert (await get(tilted_id))['parameters'] == tilted_before['parameters']
                a = (await mutate('create_circuit', {'name': 'A', 'voltage_v': 230}))['created'][0]['homecad_id']
                b = (await mutate('create_circuit', {'name': 'B', 'cable_label': 'PROJECT-CABLE'}))['created'][0]['homecad_id']
                await mutate('assign_to_circuit', {'target': target(outlet_id), 'circuit_id': a})
                await mutate('assign_to_circuit', {'target': target(switch_id), 'circuit_id': a})
                saved = await get(outlet_id)
                assert (await call('get_circuit', {'target': target(a)}))['metadata']['revision'] == 3
                await mutate('assign_to_circuit', {'target': target(outlet_id), 'circuit_id': b})
                assert (await call('get_circuit', {'target': target(b)}))['member_ids'] == [outlet_id]
                await undo()
                assert (await get(outlet_id))['parameters'] == saved['parameters']
                assert (await call('get_circuit', {'target': target(b)}))['metadata']['revision'] == 1
                await expect_error('delete_circuit', {'target': target(a)}, 'constraint_violation')
                await expect_error('update_electrical_point', {'target': target(outlet_id),
                    'changes': {'placement': {**placement, 'offset_mm': 0}}}, 'constraint_violation')
                assert (await get(outlet_id))['metadata']['revision'] == saved['metadata']['revision']
                await mutate('update_architecture_object', {'target': target(wall_id),
                    'changes': {'start_mm': [100,100,0], 'end_mm': [100,4100,0]}})
                moved = await get(outlet_id)
                check_bounds(moved, [20,1060,260], [40,1140,340])
                assert moved['metadata']['revision'] == saved['metadata']['revision'] + 1
                assert (await call('get_circuit', {'target': target(a)}))['metadata']['revision'] == 3
                await undo()
                check_bounds(await get(outlet_id), [960,60,260], [1040,80,340])
                opening = await mutate('create_opening', {'wall': target(wall_id), 'offset_mm': 900,
                    'bottom_mm': 200, 'width_mm': 200, 'height_mm': 200})
                assert any('missing_support' in warning for warning in opening['warnings'])
                findings = await call('validate_electrical', {'target': target(outlet_id), 'limit': 1})
                assert findings['findings'][0]['category'] == 'missing_support'
                await expect_error('create_outlet', {'placement': placement, 'dimensions_mm': dimensions}, 'constraint_violation')
                view = await call('capture_view', {'view': 'iso', 'target': target(wall_id), 'restore_camera': True})
                assert view['camera_restored'] is True
                await undo()
                assert (await call('validate_electrical', {'target': target(outlet_id)}))['total'] == 0
                await mutate('delete_architecture_object', {'target': target(wall_id), 'cascade': True})
                assert (await call('get_circuit', {'target': target(a)}))['member_ids'] == []
                assert (await call('get_circuit', {'target': target(a)}))['metadata']['revision'] == 4
                await undo()
                assert set((await call('get_circuit', {'target': target(a)}))['member_ids']) == {outlet_id, switch_id}
                while pending:
                    await undo()
                for identifier in object_ids:
                    assert (await call('find_objects', {'homecad_id': identifier}))['resolution'] == 'none'
                for identifier in circuit_ids:
                    await expect_error('get_circuit', {'target': target(identifier)}, 'target_not_found')
                if VERSION != '0.13.0':
                    if not {'electrical.panels.v1','electrical.consumers.v1','electrical.routes.v1',
                            'electrical.load.v1','electrical.rules.v1'} <= set(status['capabilities']):
                        raise RuntimeError('matching M6.1 system capabilities are required')
                    await verify_system(call,mutate,undo,get,target,expect_error)
                for identifier in object_ids:
                    assert (await call('find_objects',{'homecad_id':identifier}))['resolution']=='none'
                for identifier in circuit_ids:
                    await expect_error('get_circuit',{'target':target(identifier)},'target_not_found')
                assert (await call('get_model_info'))['root_entity_count'] == before['root_entity_count']
                print('M6 real SketchUp smoke passed; points, circuits and Undo cleanup verified')
            finally:
                while pending:
                    try:
                        await undo()
                    except Exception as error:
                        print(f'CLEANUP FAILED: {error}; disposable fixture may contain geometry', file=sys.stderr)
                        raise

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--confirm-disposable', action='store_true', required=True)
    parser.parse_args()
    asyncio.run(run())
