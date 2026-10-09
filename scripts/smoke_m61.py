"""Additional M6.1 flow, called only by guarded smoke_m6 on HomeCADDev fixture."""

async def verify_system(call, mutate, undo, get, target, expect_error):
    def first(result): return result['created'][0]['homecad_id']
    wall_id=first(await mutate('create_wall',{'start_mm':[5000,0,0],'end_mm':[9000,0,0],
        'thickness_mm':120,'height_mm':2700,'name':'M6.1 System Wall'}))
    placement={'mode':'wall','wall_id':wall_id,'offset_mm':400,'height_mm':1400,'side':'positive_v'}
    panel_id=first(await mutate('create_distribution_panel',{'name':'M6.1 Panel','placement':placement,
        'dimensions_mm':{'width_mm':240,'height_mm':360,'depth_mm':100}}))
    a=first(await mutate('create_circuit',{'name':'M6.1 A','voltage_v':230,'panel_id':panel_id,'require_panel':True}))
    assert (await get(panel_id))['metadata']['revision']==2
    b=first(await mutate('create_circuit',{'name':'M6.1 B','voltage_v':230}))
    outlet=first(await mutate('create_outlet',{'name':'M6.1 Outlet',
        'placement':{**placement,'offset_mm':1300,'height_mm':300},
        'dimensions_mm':{'width_mm':80,'height_mm':80,'depth_mm':20}}))
    await mutate('assign_to_circuit',{'target':target(outlet),'circuit_id':a})
    plan=await call('plan_kitchen_run',{'wall':target(wall_id),'start_mm':2000,'end_mm':2600,
        'side':'positive_v','modules':[{'key':'dishwasher','type':'dishwasher','width_mm':600}],
        'name':'M6.1 Appliance Run'})
    kitchen=await mutate('apply_kitchen_run',{'plan':plan}); run_id=first(kitchen)
    source=next(item['homecad_id'] for item in kitchen['created'] if item['homecad_type']=='kitchen.appliance')
    consumer=first(await mutate('create_consumer',{'name':'M6.1 Dishwasher','source_object_id':source,
        'connection':'outlet','rated_power_w':2200,'voltage_v':230}))
    missing=await call('find_unpowered_consumers')
    assert any(r['consumer_id']==consumer and r['status']=='missing_point' for r in missing['consumers'])
    entry=next(r for r in missing['consumers'] if r['consumer_id']==consumer)
    assert entry['name']=='M6.1 Dishwasher' and entry['source_type']=='kitchen.appliance'
    assert entry['point_id'] is None and entry['circuit_id'] is None and entry['reason']=='missing_point'
    rules=await call('get_electrical_ruleset')
    assert rules['ruleset']=='generic' and 'collision' in rules['checks']
    await mutate('connect_consumer',{'target':target(consumer),'point_id':outlet})
    load=await call('get_circuit_load',{'target':target(a)})
    assert load['consumer_ids']==[consumer] and load['rated_power_w']==2200
    assert abs(load['estimated_current_a']-2200/230)<1e-6
    assert (await call('get_distribution_panel',{'target':target(panel_id)}))['circuit_ids']==[a]
    connected=await call('get_consumer',{'target':target(consumer)})
    assert connected['parameters']['source_object_id']==source and 'circuit_id' not in connected['parameters']
    await mutate('assign_to_circuit',{'target':target(outlet),'circuit_id':b})
    assert (await call('get_circuit_load',{'target':target(a)}))['rated_power_w']==0
    assert (await call('get_circuit_load',{'target':target(b)}))['consumer_ids']==[consumer]
    assert (await call('get_consumer',{'target':target(consumer)}))['metadata']['revision']==connected['metadata']['revision']
    await undo()
    path=[[5400,75,1400],[5400,75,2500],[6300,75,2500],[6300,75,300]]
    route=first(await mutate('create_cable_route',{'name':'M6.1 Concept Route','circuit_id':a,'path_mm':path}))
    graph=await call('get_circuit',{'target':target(a)})
    assert graph['consumer_ids']==[consumer] and graph['route_ids']==[route] and graph['panel_id']==panel_id
    panel_revision=(await get(panel_id))['metadata']['revision']
    await mutate('assign_circuit_to_panel',{'target':target(b),'panel_id':panel_id})
    assert (await get(panel_id))['metadata']['revision']==panel_revision+1
    await undo()
    assert (await get(panel_id))['metadata']['revision']==panel_revision
    # Native collision regression; a coincident Panel must be visible to validation.
    overlapping=first(await mutate('create_distribution_panel',{'name':'M6.1 Collision Panel','placement':placement,
        'dimensions_mm':{'width_mm':240,'height_mm':360,'depth_mm':100}}))
    findings=(await call('validate_electrical',{'target':target(panel_id)}))['findings']
    assert any(r['category']=='collision' and r.get('panel_id')==panel_id and r.get('obstacle_id')==overlapping for r in findings)
    await undo()
    assert (await call('get_cable_route',{'target':target(route)}))['length_mm']==4200
    route_box=(await get(route))['bbox_mm']
    assert all(abs(x-y)<0.5 for x,y in zip(route_box['min'],[5400,75,300]))
    assert all(abs(x-y)<0.5 for x,y in zip(route_box['max'],[6300,75,2500]))
    await mutate('update_cable_route',{'target':target(route),'changes':{'path_mm':path[:-1]+[[6300,75,200]]}})
    updated=await call('get_cable_route',{'target':target(route)})
    assert updated['homecad_id']==route and updated['length_mm']==4300
    await undo()
    assert (await call('get_cable_route',{'target':target(route)}))['parameters']['path_mm']==path
    await expect_error('delete_distribution_panel',{'target':target(panel_id)},'constraint_violation')
    await expect_error('delete_circuit',{'target':target(a),'detach_points':True},'constraint_violation')
    await mutate('delete_distribution_panel',{'target':target(panel_id),'detach_circuits':True})
    assert (await call('get_circuit',{'target':target(a)}))['parameters']['panel_id'] is None
    await undo()
    assert (await call('get_distribution_panel',{'target':target(panel_id)}))['circuit_ids']==[a]
    await mutate('update_circuit',{'target':target(a),'changes':{'voltage_v':110}})
    assert (await call('get_circuit_load',{'target':target(a)}))['estimated_current_a'] is None
    assert any(r['category']=='voltage_mismatch' for r in (await call('validate_electrical',{'ruleset':'generic'}))['findings'])
    await undo()
    panel_before=await get(panel_id); revision_before=(await call('get_circuit',{'target':target(a)}))['metadata']['revision']
    await mutate('update_architecture_object',{'target':target(wall_id),
        'changes':{'start_mm':[5000,100,0],'end_mm':[9000,100,0]}})
    panel_after=await get(panel_id)
    assert abs(panel_after['bbox_mm']['min'][1]-panel_before['bbox_mm']['min'][1]-100)<0.5
    assert panel_after['metadata']['revision']==panel_before['metadata']['revision']+1
    assert (await call('get_circuit',{'target':target(a)}))['metadata']['revision']==revision_before
    assert (await call('get_cable_route',{'target':target(route)}))['parameters']['path_mm']==path
    await undo()
    capture=await call('capture_view',{'view':'back','target':target(wall_id),'max_size':1400,'restore_camera':True})
    assert capture['camera_restored'] is True
    assert capture['image_has_variation'] is True, 'Electrical system capture contains only a flat background'
    await mutate('update_kitchen_run',{'target':target(run_id),
        'changes':{'modules':[{'key':'dishwasher','type':'dishwasher','width_mm':500}]}})
    assert (await call('get_consumer',{'target':target(consumer)}))['parameters']['source_object_id']==source
    await undo()
    changed=await mutate('update_kitchen_run',{'target':target(run_id),
        'changes':{'modules':[{'key':'dishwasher','type':'base_shelves','width_mm':600}]}})
    assert any(r['homecad_id']==consumer for r in changed['deleted'])
    await expect_error('get_consumer',{'target':target(consumer)},'target_not_found')
    assert (await call('get_circuit_load',{'target':target(a)}))['rated_power_w']==0
    await undo()
    assert (await call('get_consumer',{'target':target(consumer)}))['parameters']==connected['parameters']
    await mutate('delete_circuit',{'target':target(a),'detach_points':True,'detach_routes':True})
    assert (await get(panel_id))['metadata']['revision']==panel_revision+1
    assert (await call('get_cable_route',{'target':target(route)}))['parameters']['circuit_id'] is None
    assert any(r['category']=='invalid_route_circuit' for r in (await call('validate_electrical',{'ruleset':'generic'}))['findings'])
    await undo()
    cascaded=await mutate('delete_architecture_object',{'target':target(wall_id),'cascade':True})
    assert any(r['homecad_id']==consumer for r in cascaded['deleted'])
    assert (await call('get_circuit',{'target':target(a)}))['parameters']['panel_id'] is None
    assert (await call('get_circuit',{'target':target(a)}))['metadata']['revision']==revision_before+1
    await undo()
    assert (await call('get_consumer',{'target':target(consumer)}))['parameters']['source_object_id']==source
    # Undo ten still-active creations/assignments, each one native operation.
    for _ in range(10):
        await undo()
    await expect_error('get_consumer',{'target':target(consumer)},'target_not_found')
    print('M6.1.1 graph, Panel revisions/collisions, source lifecycle and Undo flow passed')
