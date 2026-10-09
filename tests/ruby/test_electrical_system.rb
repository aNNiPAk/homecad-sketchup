require_relative 'test_electrical'
root = File.expand_path('../../sketchup/homecad/core',__dir__)
%w[electrical_panels electrical_consumers electrical_routes electrical_rules electrical_system].each { |name| require File.join(root,name) }

class ElectricalSystemTest < ElectricalTest
  def test_panel_membership_revisions_transfer_noop_and_locks
    a = HomeCAD::ElectricalPanels.create(@model, request)['created'].first['homecad_id']
    b = HomeCAD::ElectricalPanels.create(@model, request.merge('placement'=>request['placement'].merge('offset_mm'=>500)))['created'].first['homecad_id']
    c = HomeCAD::Circuits.create(@model, 'name'=>'Assigned', 'panel_id'=>a)['created'].first['homecad_id']
    assert_equal 2, HomeCAD::Metadata.read(entity(a))['revision']
    @model.events.clear
    HomeCAD::ElectricalPanels.assign(@model, 'target'=>target(c), 'panel_id'=>b)
    assert_equal [:start,:commit], @model.events.map(&:first)
    assert_equal 3, HomeCAD::Metadata.read(entity(a))['revision']
    assert_equal 2, HomeCAD::Metadata.read(entity(b))['revision']
    entity(b).define_singleton_method(:locked?) { true }
    @model.events.clear
    HomeCAD::ElectricalPanels.assign(@model, 'target'=>target(c), 'panel_id'=>b)
    assert_empty @model.events
    snapshot = HomeCAD::Circuits.resolve(@model,target(c))
    [-> { HomeCAD::ElectricalPanels.assign(@model,'target'=>target(c),'panel_id'=>nil) },
     -> { HomeCAD::Circuits.delete(@model,'target'=>target(c)) },
     -> { HomeCAD::Circuits.create(@model,'name'=>'Locked','panel_id'=>b) },
     -> { HomeCAD::ElectricalPanels.assign(@model,'target'=>target(c),'panel_id'=>a) }].each do |action|
      error = assert_raises(HomeCAD::Runtime::BridgeError, &action)
      assert_equal 'constraint_violation', error.category
      assert_empty @model.events
      assert_equal snapshot, HomeCAD::Circuits.resolve(@model,target(c))
    end
    entity(b).define_singleton_method(:locked?) { false }
    HomeCAD::ElectricalPanels.assign(@model,'target'=>target(c),'panel_id'=>nil)
    assert_equal 3, HomeCAD::Metadata.read(entity(b))['revision']
    HomeCAD::ElectricalPanels.assign(@model,'target'=>target(c),'panel_id'=>a)
    HomeCAD::Circuits.delete(@model,'target'=>target(c))
    assert_equal 5, HomeCAD::Metadata.read(entity(a))['revision']
  end

  def test_panel_collision_with_points_panels_and_column
    panel = HomeCAD::ElectricalPanels.create(@model, request)['created'].first['homecad_id']
    other = HomeCAD::ElectricalPanels.create(@model, request)['created'].first['homecad_id']
    p = point
    column = HomeCAD::Architecture.create_column(@model, 'origin_mm'=>[970,65,270],
      'width_mm'=>60,'depth_mm'=>15,'height_mm'=>60)['created'].first['homecad_id']
    cabinet = HomeCAD::Furniture.create_cabinet(@model,'width_mm'=>600,'depth_mm'=>560,'height_mm'=>720,
      'placement'=>{'mode'=>'world','origin_mm'=>[800,60,0],'rotation_degrees'=>0})['created'].first['homecad_id']
    findings = HomeCAD::ElectricalRules.validate(@model,'target'=>target(panel))['findings']
    obstacles = findings.select { |r| r['category']=='collision' && r['panel_id']==panel }.map { |r| r['obstacle_id'] }
    [other,p,column,cabinet].each { |id| assert_includes obstacles,id }
    refute_includes obstacles,panel
    point_findings=HomeCAD::ElectricalRules.validate(@model,'target'=>target(p))['findings']
    assert point_findings.any? { |r| r['point_id']==p && r['obstacle_id']==panel }
    refute HomeCAD::SceneVolumes.obstacles(@model).any? { |r| r['type']=='electrical.panel' }
  end

  def test_panel_kitchen_collision_and_world_contact_without_penetration
    appliance
    panel = HomeCAD::ElectricalPanels.create(@model,request.merge('placement'=>request['placement'].merge('offset_mm'=>2300)))['created'].first['homecad_id']
    assert HomeCAD::ElectricalRules.validate(@model,'target'=>target(panel))['findings'].any? { |r| r['category']=='collision' && r['obstacle_id']==@run }
    world={'mode'=>'world','origin_mm'=>[10000,0,0],'normal'=>[0,0,1],'up'=>[0,1,0]}
    a=HomeCAD::ElectricalPanels.create(@model,request.merge('placement'=>world))['created'].first['homecad_id']
    b=HomeCAD::ElectricalPanels.create(@model,request.merge('placement'=>world.merge('origin_mm'=>[10000,0,20])))['created'].first['homecad_id']
    refute HomeCAD::ElectricalRules.validate(@model,'target'=>target(a))['findings'].any? { |r| r['category']=='collision' && r['obstacle_id']==b }
  end

  def test_unrelated_mutation_preserves_corrupted_consumer_for_diagnostics
    id=consumer
    records=HomeCAD::ElectricalConsumers.records(@model)
    records.first['parameters']['source_object_id']=SecureRandom.uuid
    HomeCAD::ElectricalConsumers.write(@model,records)
    HomeCAD::Architecture.create_wall(@model,'start_mm'=>[0,5000,0],'end_mm'=>[4000,5000,0],
      'thickness_mm'=>120,'height_mm'=>2700)
    assert_equal records,HomeCAD::ElectricalConsumers.records(@model)
    assert HomeCAD::ElectricalRules.validate(@model,{})['findings'].any? { |r| r['category']=='orphan_reference' && r['consumer_id']==id }
  end

  def test_graph_inspection_ruleset_and_unpowered_details
    id=consumer; c=circuit; p=point
    missing=HomeCAD::ElectricalConsumers.unpowered(@model,{})['consumers'].first
    assert_equal 'Dishwasher',missing['name']
    assert_equal 'kitchen.appliance',missing['source_type']
    assert_nil missing['point_id']; assert_nil missing['circuit_id']
    assert_equal missing['status'],missing['reason']
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>c)
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    route=HomeCAD::ElectricalRoutes.create(@model,'name'=>'Route','circuit_id'=>c,'path_mm'=>[[0,0,0],[100,0,0]])['created'].first['homecad_id']
    graph=HomeCAD::Circuits.get(@model,'target'=>target(c))
    assert_equal [p],graph['member_ids']; assert_equal [id],graph['consumer_ids']; assert_equal [route],graph['route_ids']
    @model.events.clear
    assert_includes HomeCAD::ElectricalRules.describe({})['checks'],'voltage_mismatch'
    assert_empty @model.events
    error=assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::ElectricalRules.describe('ruleset'=>'RU') }
    assert_equal 'unsupported_operation',error.category
  end

  def appliance
    return @appliance if @appliance
    plan = HomeCAD::Kitchen.plan(@model, { 'wall'=>target(wall),'start_mm'=>2000,'end_mm'=>2600,
      'side'=>'positive_v','modules'=>[{'key'=>'dishwasher','type'=>'dishwasher','width_mm'=>600}] })
    result = HomeCAD::Kitchen.apply(@model,'plan'=>plan)
    @run = result['created'].first['homecad_id']
    @appliance = result['created'].find { |r| r['homecad_type']=='kitchen.appliance' }['homecad_id']
  end

  def consumer(power = nil)
    HomeCAD::ElectricalConsumers.create(@model,'name'=>'Dishwasher','source_object_id'=>appliance,
      'connection'=>'outlet','rated_power_w'=>power,'voltage_v'=>230)['created'].first['homecad_id']
  end

  def test_panel_assignment_delete_detach_and_wall_motion
    panel = HomeCAD::ElectricalPanels.create(@model,request)['created'].first['homecad_id']
    c = circuit
    HomeCAD::ElectricalPanels.assign(@model,'target'=>target(c),'panel_id'=>panel)
    assert_equal [c], HomeCAD::ElectricalPanels.get(@model,'target'=>target(panel))['circuit_ids']
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::ElectricalPanels.delete(@model,'target'=>target(panel)) }
    HomeCAD::Architecture.update_object(@model,'target'=>target(wall),
      'changes'=>{'start_mm'=>[0,0,0],'end_mm'=>[0,4000,0]})
    assert_equal 3, HomeCAD::Metadata.read(entity(panel))['revision']
    deleted = HomeCAD::ElectricalPanels.delete(@model,'target'=>target(panel),'detach_circuits'=>true)
    assert_equal 3, HomeCAD::Circuits.resolve(@model,target(c))['revision']
    assert_nil HomeCAD::Circuits.resolve(@model,target(c))['parameters']['panel_id']
    assert_equal panel, deleted['deleted'].first['homecad_id']
  end

  def test_consumer_connect_and_point_transfer_drive_load
    id=consumer(2000); p=point; a=circuit; b=circuit('Other')
    assert_equal 'missing_point', HomeCAD::ElectricalConsumers.unpowered(@model,{})['consumers'].first['status']
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    assert_equal 'point_not_on_circuit', HomeCAD::ElectricalConsumers.unpowered(@model,{})['consumers'].first['status']
    HomeCAD::Circuits.update(@model,'target'=>target(a),'changes'=>{'voltage_v'=>230})
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>a)
    load=HomeCAD::ElectricalConsumers.load(@model,'target'=>target(a))
    assert_equal [id],load['consumer_ids']; assert_equal 2000,load['rated_power_w']
    assert_in_delta 2000.0/230,load['estimated_current_a'],1e-8
    refute HomeCAD::ElectricalConsumers.resolve(@model,target(id))['parameters'].key?('circuit_id')
    assert_equal appliance,HomeCAD::ElectricalConsumers.resolve(@model,target(id))['parameters']['source_object_id']
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>b)
    assert_equal 0,HomeCAD::ElectricalConsumers.load(@model,'target'=>target(a))['known_consumer_count']
    assert_equal [id],HomeCAD::ElectricalConsumers.load(@model,'target'=>target(b))['consumer_ids']
    HomeCAD::Electrical.delete(@model,'target'=>target(p))
    assert_equal 'point_missing',HomeCAD::ElectricalConsumers.unpowered(@model,{})['consumers'].first['status']
  end

  def test_unknown_power_and_voltage_mismatch_are_deterministic
    id=consumer; p=point; c=circuit
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>c)
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    load=HomeCAD::ElectricalConsumers.load(@model,'target'=>target(c))
    assert_equal 1,load['unknown_power_count']; assert_equal 0,load['rated_power_w']; assert_nil load['estimated_current_a']
    HomeCAD::Circuits.update(@model,'target'=>target(c),'changes'=>{'voltage_v'=>110,'require_panel'=>true})
    HomeCAD::ElectricalConsumers.update(@model,'target'=>target(id),'changes'=>{'rated_power_w'=>1500})
    rules=HomeCAD::ElectricalRules.validate(@model,{})['findings']
    assert_includes rules.map { |r| r['category'] },'voltage_mismatch'
    assert_includes rules.map { |r| r['category'] },'missing_panel'
    assert_nil HomeCAD::ElectricalConsumers.load(@model,'target'=>target(c))['estimated_current_a']
  end

  def test_source_regeneration_preserves_link_then_source_type_change_cascades
    id=consumer(100); p=point; c=circuit
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>c)
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    HomeCAD::Kitchen.update(@model,'target'=>target(@run),'changes'=>{'modules'=>[{'key'=>'dishwasher','type'=>'dishwasher','width_mm'=>500}]})
    assert_equal appliance,HomeCAD::ElectricalConsumers.resolve(@model,target(id))['parameters']['source_object_id']
    before=HomeCAD::Circuits.resolve(@model,target(c))['revision']
    @model.events.clear
    result=HomeCAD::Kitchen.update(@model,'target'=>target(@run),'changes'=>{'modules'=>[{'key'=>'dishwasher','type'=>'base_shelves','width_mm'=>500}]})
    assert result['deleted'].any? { |r| r['homecad_id']==id }
    assert_equal before+1,HomeCAD::Circuits.resolve(@model,target(c))['revision']
    assert_empty HomeCAD::ElectricalConsumers.records(@model)
    assert_equal [:start,:commit],@model.events.map(&:first)
  end

  def test_wall_cascade_prunes_consumers_and_panels_without_double_circuit_revision
    id=consumer(100); p=point; c=circuit
    panel=HomeCAD::ElectricalPanels.create(@model,request.merge('placement'=>request['placement'].merge('offset_mm'=>500)))['created'].first['homecad_id']
    HomeCAD::ElectricalPanels.assign(@model,'target'=>target(c),'panel_id'=>panel)
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>c)
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    before=HomeCAD::Circuits.resolve(@model,target(c))['revision']; @model.events.clear
    result=HomeCAD::Architecture.delete_object(@model,'target'=>target(wall),'cascade'=>true)
    assert_empty HomeCAD::ElectricalConsumers.records(@model)
    assert_nil HomeCAD::Circuits.resolve(@model,target(c))['parameters']['panel_id']
    assert_equal before+1,HomeCAD::Circuits.resolve(@model,target(c))['revision']
    assert result['deleted'].any? { |r| r['homecad_id']==id }
    assert_equal [:start,:commit],@model.events.map(&:first)
  end

  def test_route_update_uuid_length_noop_and_circuit_detach
    c=circuit
    route=HomeCAD::ElectricalRoutes.create(@model,'name'=>'Route','circuit_id'=>c,
      'path_mm'=>[[0,0,0],[300,0,0],[300,400,0]])['created'].first
    id=route['homecad_id']; assert_equal 700,route['length_mm']
    @model.events.clear
    HomeCAD::ElectricalRoutes.update(@model,'target'=>target(id),'changes'=>{'name'=>'Route'})
    assert_empty @model.events
    HomeCAD::ElectricalRoutes.update(@model,'target'=>target(id),'changes'=>{'path_mm'=>[[0,0,0],[100,0,0]]})
    assert_equal id,HomeCAD::ElectricalRoutes.get(@model,'target'=>target(id))['homecad_id']
    assert_equal 100,HomeCAD::ElectricalRoutes.get(@model,'target'=>target(id))['length_mm']
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Circuits.delete(@model,'target'=>target(c),'detach_points'=>true) }
    HomeCAD::Circuits.delete(@model,'target'=>target(c),'detach_routes'=>true)
    assert_nil HomeCAD::ElectricalRoutes.read(entity(id))['circuit_id']
    assert_includes HomeCAD::ElectricalRules.validate(@model,{})['findings'].map { |r| r['category'] },'invalid_route_circuit'
  end

  def test_connection_rejection_and_consumer_noop
    id=consumer; switch=HomeCAD::Electrical.create(@model,request,'switch')['created'].first['homecad_id']
    @model.events.clear
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>switch) }
    assert_empty @model.events
    HomeCAD::ElectricalConsumers.update(@model,'target'=>target(id),'changes'=>{'name'=>'Dishwasher'})
    assert_empty @model.events
    records=HomeCAD::ElectricalConsumers.records(@model)
    records.first['parameters']['point_id']=switch; HomeCAD::ElectricalConsumers.write(@model,records)
    assert_equal 'incompatible_connection',HomeCAD::ElectricalConsumers.unpowered(@model,{})['consumers'].first['status']
  end

  def test_direct_consumer_and_disconnect_update_circuit_graph_once
    id=consumer(500)
    HomeCAD::ElectricalConsumers.update(@model,'target'=>target(id),'changes'=>{'connection'=>'direct'})
    p=HomeCAD::Electrical.create(@model,request,'connection_point')['created'].first['homecad_id']; c=circuit
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>c)
    before=HomeCAD::Circuits.resolve(@model,target(c))['revision']
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    assert_equal before+1,HomeCAD::Circuits.resolve(@model,target(c))['revision']
    assert_empty HomeCAD::ElectricalConsumers.unpowered(@model,{})['consumers']
    @model.events.clear
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    assert_empty @model.events
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>nil)
    assert_equal before+2,HomeCAD::Circuits.resolve(@model,target(c))['revision']
    assert_equal 'missing_point',HomeCAD::ElectricalConsumers.unpowered(@model,{})['consumers'].first['status']
  end

  def test_route_limits_and_full_serialization_of_128_points
    c=circuit; path=128.times.map { |i| [i*10,0,0] }
    result=HomeCAD::ElectricalRoutes.create(@model,'name'=>'Long','circuit_id'=>c,'path_mm'=>path)
    route=result['created'].first
    assert_equal 128,route['parameters']['path_mm'].length
    assert_equal 1270,route['length_mm']
    @model.events.clear
    [[],[[0,0,0]],[[0,0,0],[0,0,0]],129.times.map { |i| [i,0,0] }].each do |bad|
      assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::ElectricalRoutes.update(@model,'target'=>target(route['homecad_id']),'changes'=>{'path_mm'=>bad}) }
    end
    assert_empty @model.events
    assert_equal 1,HomeCAD::Metadata.read(entity(route['homecad_id']))['revision']
  end

  def test_failed_cross_domain_hook_aborts_source_and_consumer_state
    id=consumer(500); c=circuit; p=point
    HomeCAD::Electrical.assign(@model,'target'=>target(p),'circuit_id'=>c)
    HomeCAD::ElectricalConsumers.connect(@model,'target'=>target(id),'point_id'=>p)
    before=HomeCAD::Circuits.resolve(@model,target(c)); original=HomeCAD::ElectricalConsumers.resolve(@model,target(id))
    @model.events.clear
    HomeCAD::ElectricalConsumers.stub(:write,->(*) { raise 'injected registry failure' }) do
      assert_raises(HomeCAD::Runtime::BridgeError) do
        HomeCAD::Kitchen.update(@model,'target'=>target(@run),
          'changes'=>{'modules'=>[{'key'=>'dishwasher','type'=>'base_shelves','width_mm'=>600}]})
      end
    end
    assert_equal [:start,:abort],@model.events.map(&:first)
    assert_equal before,HomeCAD::Circuits.resolve(@model,target(c))
    assert_equal original,HomeCAD::ElectricalConsumers.resolve(@model,target(id))
    assert_equal 'kitchen.appliance',HomeCAD::Metadata.read(HomeCAD::ElectricalConsumers.source(@model,appliance))['type']
  end

  def test_generic_rules_are_readonly_and_bounded
    consumer; before=@model.instance_variable_get(:@attributes).dup
    @model.events.clear
    findings=HomeCAD::ElectricalRules.validate(@model,'limit'=>1,'constraints'=>{'require_panel'=>true})
    assert_equal 1,findings['findings'].length
    assert_empty @model.events
    assert_equal before,@model.instance_variable_get(:@attributes)
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::ElectricalRules.validate(@model,'ruleset'=>'RU') }
  end
end
