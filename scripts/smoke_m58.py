"""Composition section of the existing guarded M5 disposable smoke."""
import base64


async def verify_composition(call, undo, expect_error, output):
    def selector(identity):
        return {key:value for key,value in identity.items() if value is not None}
    async def data(name, args=None):
        value, _ = await call(name, args)
        return value

    async def screenshot(view, target, suffix):
        meta, content = await call('capture_view', {'view':view,'target':target,'max_size':1400,'restore_camera':True})
        assert meta['camera_restored']
        image=next(item for item in content if item.type=='image')
        path=output.with_name(f'm58-{suffix}.png')
        path.write_bytes(base64.b64decode(image.data,validate=True))
        print(f'saved screenshot: {path.resolve()}')

    wall=await data('create_wall',{'start_mm':[6000,0,0],'end_mm':[10000,0,0],'thickness_mm':120,'height_mm':2700})
    wid=wall['created'][0]['homecad_id']
    modules=[{'key':'shelves','type':'base_shelves','width_mm':600,'shelf_z_mm':[220,450],'back_thickness_mm':0},
             {'key':'drawers','type':'base_drawers','width_mm':600},
             {'key':'sink','type':'sink','width_mm':600},
             {'key':'hob','type':'hob','width_mm':600},
             {'key':'dishwasher','type':'dishwasher','width_mm':600}]
    cuts=[{'key':'sink','offset_mm':1300,'front_mm':100,'width_mm':300,'depth_mm':300},
          {'key':'hob','offset_mm':1900,'front_mm':100,'width_mm':300,'depth_mm':300}]
    plan=await data('plan_kitchen_run',{'wall':{'homecad_id':wid},'start_mm':0,'end_mm':3000,
        'side':'negative_v','modules':modules,'countertop_cutouts':cuts})
    assert not plan['conflicts']
    result=await data('apply_kitchen_run',{'plan':plan})
    rid=result['created'][0]['homecad_id']; target={'homecad_id':rid}
    children={item['metadata'].get('module_key'):item for item in result['created'][1:] if item['metadata'].get('module_key')}
    top=next(item for item in result['created'] if item['homecad_type']=='kitchen.countertop')
    rows=(await data('generate_cutlist',{'target':target,'limit':100}))['records']
    assert sum(r['part_kind']=='drawer_slide_pair' for r in rows)==2
    assert sum(r['module_key']=='shelves' and r['part_kind']=='shelf' for r in rows if 'module_key' in r)==2
    assert next(r for r in rows if r['part_key']=='countertop')['cutouts_mm']==cuts
    for child in children.values():
        actual=(await data('get_object',{'target':{'homecad_id':child['homecad_id']}}))
        assert all(abs(actual['bbox_dimensions_mm'][axis]-want)<0.5
                   for axis,want in zip(['width','depth','height'],[600,560,720])), actual
        assert abs(actual['bbox_mm']['min'][2]-100)<0.5, actual
    for key in ['shelves','drawers','sink','hob']:
        child=children[key]
        parts=(await data('list_objects',{'parent':{'homecad_id':child['homecad_id']},'entity_type':'Group','include_generated':True,'limit':100}))['objects']
        matching=[r for r in rows if r.get('module_key')==key and r['record_kind']=='panel']
        assert len(parts)==len(matching)
        for part in parts:
            obj=await data('get_object',{'target':selector(part['identity'])})
            row=next(r for r in matching if r['part_key']==f"module:{key}/{part['name']}")
            kind=row['part_kind']; name=part['name']
            if kind=='drawer_side' or name.endswith('_side'):
                expected=[row['thickness_mm'],row['width_mm'],row['length_mm']]
            elif kind in ['shelf','drawer_base'] or name in ['top','bottom']:
                expected=[row['width_mm'],row['length_mm'],row['thickness_mm']]
            else:
                expected=[row['width_mm'],row['thickness_mm'],row['length_mm']]
            actual=obj['bbox_dimensions_mm']
            assert all(abs(actual[axis]-want)<0.5 for axis,want in zip(['width','depth','height'],expected)), (name,actual,expected)
    # The native Face's area confirms real holes rather than visual markers.
    faces=(await data('list_objects',{'parent':{'homecad_id':top['homecad_id']},'entity_type':'Face','include_generated':True,'limit':100}))['objects']
    areas=[(await data('measure',{'kind':'face_area','target':selector(face['identity'])})) for face in faces]
    print(f'M5.8 native countertop face measurements: {areas}')
    expected_area=3000*580-2*300*300
    assert sum(abs(area['value']-expected_area)<1 for area in areas)==2
    await screenshot('top',target,'top-cutouts')
    await screenshot('front',target,'fronts')
    changed=[dict(m) for m in modules]; changed[1]['width_mm']=650
    changed_cuts=[dict(c) for c in cuts]; changed_cuts[0]['offset_mm']+=50; changed_cuts[1]['offset_mm']+=50
    await data('update_kitchen_run',{'target':target,'changes':{'end_mm':3050,'modules':changed,'countertop_cutouts':changed_cuts}})
    updated=await data('get_object',{'target':{'homecad_id':children['drawers']['homecad_id']}})
    assert updated['metadata']['revision']==2
    newtop=await data('get_object',{'target':{'homecad_id':top['homecad_id']}})
    assert newtop['metadata']['revision']==2
    appliance=await data('get_object',{'target':{'homecad_id':children['dishwasher']['homecad_id']}})
    assert appliance['homecad_type']=='kitchen.appliance'
    await expect_error('update_kitchen_run',{'target':target,'changes':{'countertop_cutouts':[cuts[0].copy(),{**cuts[0],'key':'overlap'}]}},'constraint_violation')
    await undo()
    assert (await data('get_object',{'target':{'homecad_id':top['homecad_id']}}))['metadata']['revision']==1
    await screenshot('iso',target,'composition')
    await undo()  # Kitchen creation
    await undo()  # Wall creation
    # Focused native regression for the existing L-shaped inner-loop generator.
    east=await data('create_wall',{'start_mm':[12000,0,0],'end_mm':[15000,0,0],'thickness_mm':120,'height_mm':2700})
    north=await data('create_wall',{'start_mm':[12000,0,0],'end_mm':[12000,3000,0],'thickness_mm':120,'height_mm':2700})
    corner=await data('plan_corner_kitchen_run',{'legs':[
        {'key':'east','wall':{'homecad_id':east['created'][0]['homecad_id']},'start_mm':0,'end_mm':2200,'side':'positive_v',
         'modules':[{'key':'shelves','type':'base_shelves','width_mm':600}]},
        {'key':'north','wall':{'homecad_id':north['created'][0]['homecad_id']},'start_mm':0,'end_mm':2200,'side':'negative_v',
         'modules':[{'key':'drawers','type':'base_drawers','width_mm':600}]}],
        'corner':{'mode':'void','span_first_mm':900,'span_second_mm':900},
        'countertop':{'enabled':True,'cutouts':[{'key':'corner_sink','leg_key':'east','offset_mm':1100,'front_mm':100,'width_mm':200,'depth_mm':200}]}})
    assert not corner['conflicts']
    applied=await data('apply_kitchen_run',{'plan':corner})
    corner_target={'homecad_id':applied['created'][0]['homecad_id']}
    schedule=(await data('generate_cutlist',{'target':corner_target,'limit':100}))['records']
    assert sum(r['part_kind']=='drawer_slide_pair' for r in schedule)==2
    top=next(o for o in applied['created'] if o['homecad_type']=='kitchen.countertop')
    faces=(await data('list_objects',{'parent':{'homecad_id':top['homecad_id']},'entity_type':'Face','include_generated':True,'limit':100}))['objects']
    # Countertop covers allocated modules/filler, not unallocated requested Wall span.
    lengths=[max(p['offset_mm']+p['width_mm'] for p in leg['positions'])+leg['filler_mm']-60
             for leg in corner['params']['legs']]
    top_area=sum(length*580 for length in lengths)-580*580-200*200
    areas=[(await data('measure',{'kind':'face_area','target':selector(face['identity'])}))['value'] for face in faces]
    assert sum(abs(area-top_area)<1 for area in areas)==2
    await screenshot('top',corner_target,'corner-top')
    for _ in range(3):
        await undo()
    print('M5.8 composition, native part measurements, cutouts and Undo passed')
