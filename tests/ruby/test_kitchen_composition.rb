require_relative 'test_electrical_system'

class KitchenCompositionTest < ElectricalSystemTest
  def test_legacy_modules_remain_fixed_on_read_rename_and_normalized_noop
    plan=HomeCAD::Kitchen.plan(@model,{'wall'=>target(wall),'start_mm'=>0,'end_mm'=>600,
      'side'=>'positive_v','modules'=>[module_input('base_shelves')]},preserve_legacy:true)
    result=apply_plan(plan); id=result['created'].first['homecad_id']; root=entity(id)
    original=HomeCAD::KitchenData.read(root); children=root.entities.to_a.dup
    @model.events.clear
    HomeCAD::Kitchen.validate(@model,'target'=>target(id))
    assert_equal original,HomeCAD::KitchenData.read(root)
    assert_empty @model.events
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'name'=>'Legacy renamed'})
    renamed=HomeCAD::KitchenData.read(root)
    assert_equal original['modules'],renamed['modules']
    assert_equal children,root.entities.to_a
    assert_equal [:start,:commit],@model.events.map(&:first)
    @model.events.clear
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'name'=>'Legacy renamed'})
    assert_empty @model.events
    assert_equal renamed,HomeCAD::KitchenData.read(root)
  end

  def test_appliance_extrudes_up_when_native_base_normal_points_down
    calls=[]
    face=Object.new
    face.define_singleton_method(:normal) { Geom::Vector3d.new(0,0,-1) }
    face.define_singleton_method(:pushpull) { |distance| calls << distance }
    group=@model.entities.add_group
    group.entities.stub(:add_face,face) do
      HomeCAD::KitchenCabinetDefinition.build!(@model,group,
        {'type'=>'dishwasher','width_mm'=>600,'depth_mm'=>560,'height_mm'=>720})
    end
    assert_in_delta(-HomeCAD::Units.mm_to_internal(720),calls.fetch(0),1e-9)
  end

  def test_generation_failure_aborts_root_parameters_revisions_and_geometry
    result=apply_plan(plan_for('base_shelves')); id=result['created'].first['homecad_id']
    root=entity(id); before=HomeCAD::KitchenData.read(root)
    children=root.entities.to_a.dup; metadata=HomeCAD::Metadata.read(root)
    @model.events.clear
    HomeCAD::CountertopCutouts.stub(:build!, ->(*) { raise 'injected native geometry failure' }) do
      error=assert_raises(HomeCAD::Runtime::BridgeError) do
        HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'countertop_cutouts'=>[
          {'key'=>'cut','offset_mm'=>100,'front_mm'=>100,'width_mm'=>200,'depth_mm'=>200}]})
      end
      assert_equal 'geometry_error',error.category
    end
    assert_equal [:start,:abort],@model.events.map(&:first)
    assert_equal before,HomeCAD::KitchenData.read(root)
    assert_equal metadata,HomeCAD::Metadata.read(root)
    assert_equal children,root.entities.to_a
  end

  def test_straight_cutouts_revisions_and_atomic_rejection
    modules=[{'key'=>'sink','type'=>'sink','width_mm'=>600},{'key'=>'hob','type'=>'hob','width_mm'=>600}]
    cuts=[{'key'=>'sink','offset_mm'=>100,'front_mm'=>100,'width_mm'=>300,'depth_mm'=>300},
      {'key'=>'hob','offset_mm'=>700,'front_mm'=>100,'width_mm'=>300,'depth_mm'=>300}]
    request={'wall'=>target(wall),'start_mm'=>0,'end_mm'=>1200,'side'=>'positive_v','modules'=>modules,'countertop_cutouts'=>cuts}
    plan=HomeCAD::Kitchen.plan(@model,request)
    assert_equal 2,HomeCAD::CountertopCutouts.straight(plan['params'])['holes_mm'].length
    result=apply_plan(plan); id=result['created'].first['homecad_id']
    top=HomeCAD::KitchenData.read(entity(id))['semantic_objects']['countertop']
    record=HomeCAD::Cutlist.generate(@model,'target'=>target(id))['records'].find { |r| r['part_key']=='countertop' }
    assert_equal 'concept_shaped',record['manufacturing_status']; assert_equal cuts,record['cutouts_mm']
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'name'=>'Renamed'})
    assert_equal top,HomeCAD::KitchenData.read(entity(id))['semantic_objects']['countertop']
    changed=cuts.map(&:dup); changed[0]['width_mm']=250
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'countertop_cutouts'=>changed})
    updated=HomeCAD::KitchenData.read(entity(id))['semantic_objects']['countertop']
    assert_equal top['homecad_id'],updated['homecad_id']; assert_equal top['revision']+1,updated['revision']
    before=HomeCAD::KitchenData.read(entity(id)); revision=HomeCAD::Metadata.read(entity(id))['revision']
    @model.events.clear
    [cuts.map { |c| c.merge('offset_mm'=>100) },[cuts[0].merge('offset_mm'=>0)]].each do |bad|
      error=assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'countertop_cutouts'=>bad}) }
      assert_equal 'constraint_violation',error.category
      assert_empty @model.events; assert_equal before,HomeCAD::KitchenData.read(entity(id))
      assert_equal revision,HomeCAD::Metadata.read(entity(id))['revision']
    end
    negative=HomeCAD::Kitchen.plan(@model,request.merge('side'=>'negative_v'))
    assert_equal [800.0,100.0,1100.0,400.0],HomeCAD::CountertopCutouts.straight(negative['params'])['holes_mm'].first
  end

  def test_neighbor_cabinet_internals_preserve_m6_consumer_source
    modules=[{'key'=>'dishwasher','type'=>'dishwasher','width_mm'=>600},
      {'key'=>'storage','type'=>'base_shelves','width_mm'=>600}]
    plan=HomeCAD::Kitchen.plan(@model,{'wall'=>target(wall),'start_mm'=>2000,'end_mm'=>3200,
      'side'=>'positive_v','modules'=>modules})
    created=apply_plan(plan); @run=created['created'].first['homecad_id']
    @appliance=created['created'].find { |r| r['module_type']=='dishwasher' || r.dig('metadata','module_type')=='dishwasher' }['homecad_id']
    id=consumer(2000); before=HomeCAD::ElectricalConsumers.resolve(@model,target(id))
    modules[1]=modules[1].merge('shelf_z_mm'=>[200,450])
    HomeCAD::Kitchen.update(@model,'target'=>target(@run),'changes'=>{'modules'=>modules})
    assert_equal before,HomeCAD::ElectricalConsumers.resolve(@model,target(id))
    assert_equal 'kitchen.appliance',HomeCAD::Metadata.read(HomeCAD::ElectricalConsumers.source(@model,@appliance))['type']
    modules[0]=modules[0].merge('type'=>'base_shelves')
    result=HomeCAD::Kitchen.update(@model,'target'=>target(@run),'changes'=>{'modules'=>modules})
    assert result['deleted'].any? { |r| r['homecad_id']==id }
  end

  def test_both_corner_legs_use_identical_furniture_definition
    first=wall
    second=HomeCAD::Architecture.create_wall(@model,'start_mm'=>[0,0,0],'end_mm'=>[0,4000,0],
      'thickness_mm'=>120,'height_mm'=>2700)['created'].first['homecad_id']
    legs=[['east',first,'positive_v','base_shelves'],['north',second,'negative_v','base_drawers']].map do |key,id,side,type|
      {'key'=>key,'wall'=>target(id),'start_mm'=>0,'end_mm'=>2200,'side'=>side,'modules'=>[module_input(type)]}
    end
    plan=HomeCAD::CornerKitchen.plan(@model,{'legs'=>legs,'corner'=>{'mode'=>'void','span_first_mm'=>900,'span_second_mm'=>900}})
    result=apply_plan(plan); run=entity(result['created'].first['homecad_id'])
    plan['params']['legs'].each do |leg|
      item=leg['modules'].first; key="leg:#{leg['key']}/module:m"
      child=run.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id']==HomeCAD::KitchenData.read(run)['semantic_objects'][key]['homecad_id'] }
      parts=HomeCAD::Furniture.part_schedule(HomeCAD::KitchenCabinetDefinition.for_module(@model,item))
      assert_equal parts.map { |p| p['part_key'] }.sort,child.entities.grep(Sketchup::Group).map(&:name).sort
    end
  end

  def module_input(type, extra = {})
    { 'key'=>'m', 'type'=>type, 'width_mm'=>600 }.merge(extra)
  end

  def plan_for(type, extra = {})
    HomeCAD::Kitchen.plan(@model,{'wall'=>target(wall),'start_mm'=>0,'end_mm'=>600,
      'side'=>'positive_v','modules'=>[module_input(type,extra)]})
  end

  def apply_plan(plan)
    HomeCAD::Kitchen.apply(@model,'plan'=>plan)
  end

  def test_all_module_types_use_shared_definition_and_matching_parts
    HomeCAD::Kitchen::TYPES.each_key do |type|
      plan=plan_for(type)
      item=plan['params']['modules'].first
      config=HomeCAD::KitchenCabinetDefinition.for_module(@model,item)
      if %w[dishwasher fridge].include?(type)
        assert_nil config
        next
      end
      assert_equal 'construction',config['detail_level']
      assert_equal 1,item['composition_version']
      assert config['shelf_z_mm'].any? if %w[base_shelves wall_shelves tall_storage].include?(type)
      result=apply_plan(plan); run=entity(result['created'].first['homecad_id'])
      child=run.entities.find { |e| HomeCAD::Metadata.read(e)['module_key']=='m' }
      parts=HomeCAD::Furniture.part_schedule(config)
      records=HomeCAD::Cutlist.generate(@model,'target'=>target(result['created'].first['homecad_id']))['records']
      parts.each do |part|
        group=child.entities.find { |e| e.name==part['part_key'] }
        refute_nil group, "#{type}:#{part['part_key']}"
        size=case part['part_kind']
        when 'drawer_side' then [part['thickness_mm'],part['width_mm'],part['height_mm']]
        when 'shelf','drawer_base' then [part['width_mm'],part['height_mm'],part['thickness_mm']]
        else
          if part['part_key'].end_with?('_side')
            [part['thickness_mm'],part['width_mm'],part['height_mm']]
          elsif %w[top bottom].include?(part['part_key'])
            [part['width_mm'],part['height_mm'],part['thickness_mm']]
          else [part['width_mm'],part['thickness_mm'],part['height_mm']]
          end
        end
        min=group.bounds.corner(0); max=group.bounds.corner(7)
        actual=[max.x-min.x,max.y-min.y,max.z-min.z].map { |v| HomeCAD::Units.internal_to_mm(v) }
        size.zip(actual).each { |want,got| assert_in_delta want,got,0.01,"#{type}:#{part['part_key']}" }
        [min.x,min.y,min.z].map { |v| HomeCAD::Units.internal_to_mm(v) }.zip(part['origin_mm']).each { |got,want| assert_in_delta want,got,0.01 }
        row=records.find { |r| r['part_key']=="module:m/#{part['part_key']}" }
        assert_equal part['length_mm'],row['length_mm']
        assert_equal part['width_mm'],row['width_mm']
        assert_equal part['thickness_mm'],row['thickness_mm']
      end
      HomeCAD::Kitchen.delete(@model,'target'=>target(result['created'].first['homecad_id']))
    end
  end

  def test_drawers_schedules_uuid_update_invalid_fit_and_one_operation
    result=apply_plan(plan_for('base_drawers')); id=result['created'].first['homecad_id']
    child_id=result['created'].find { |r| r['module_key']=='m' || r.dig('metadata','module_key')=='m' }&.dig('homecad_id')
    child_id=HomeCAD::KitchenData.read(entity(id))['semantic_objects']['module:m']['homecad_id']
    rows=HomeCAD::Cutlist.generate(@model,'target'=>target(id))['records']
    assert_equal 10,rows.count { |r| r['part_key'].start_with?('module:m/drawer:') && r['record_kind']=='panel' }
    slides=rows.select { |r| r['part_kind']=='drawer_slide_pair' }
    assert_equal 2,slides.length; assert slides.all? { |r| r['sku'].nil? }
    @model.events.clear
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'end_mm'=>700,
      'modules'=>[module_input('base_drawers','width_mm'=>700)]})
    assert_equal [:start,:commit],@model.events.map(&:first)
    assert_equal child_id,HomeCAD::KitchenData.read(entity(id))['semantic_objects']['module:m']['homecad_id']
    before=HomeCAD::KitchenData.read(entity(id)); revision=HomeCAD::Metadata.read(entity(id))['revision']
    @model.events.clear
    error=assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'modules'=>[module_input('base_drawers','drawer_layout'=>{'slide'=>{
        'family_id'=>HomeCAD::HardwareCatalog::FAMILY_ID,'sku'=>'PROJECT','nominal_length_mm'=>2000,'side_clearance_mm'=>10}})]})
    end
    assert_equal 'constraint_violation',error.category
    assert_empty @model.events
    assert_equal before,HomeCAD::KitchenData.read(entity(id))
    assert_equal revision,HomeCAD::Metadata.read(entity(id))['revision']
  end

  def test_project_defaults_and_zero_back_are_snapshotted
    HomeCAD::ProjectSettings.update(@model,'panel_thickness_mm'=>20,'back_thickness_mm'=>0,'material_id'=>'board')
    plan=plan_for('base_shelves')
    item=plan['params']['modules'].first
    assert_equal 20,item['panel_thickness_mm']; assert_equal 0,item['back_thickness_mm']
    config=HomeCAD::KitchenCabinetDefinition.for_module(@model,item)
    refute HomeCAD::Furniture.part_schedule(config).any? { |r| r['part_key']=='back' }
    assert_equal 560,HomeCAD::Furniture.part_schedule(config).find { |r| r['part_kind']=='shelf' }['length_mm']
    result=apply_plan(plan); id=result['created'].first['homecad_id']
    HomeCAD::ProjectSettings.update(@model,'panel_thickness_mm'=>22)
    @model.events.clear
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'name'=>'Kitchen run'})
    assert_empty @model.events
    assert_equal 20,HomeCAD::KitchenData.read(entity(id))['modules'].first['panel_thickness_mm']
  end
end
