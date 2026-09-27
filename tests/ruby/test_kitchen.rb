require_relative 'test_furniture'
require_relative '../../sketchup/homecad/core/service_zones'
require_relative '../../sketchup/homecad/core/kitchen'
require_relative '../../sketchup/homecad/core/kitchen_variants'
require_relative '../../sketchup/homecad/core/corner_kitchen'

class KitchenTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
    @wall_id = HomeCAD::Architecture.create_wall(@model,
      'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
    @model.events.clear
  end

  def input
    { 'wall' => { 'homecad_id' => @wall_id }, 'start_mm' => 100,
      'end_mm' => 2000, 'side' => 'positive_v',
      'modules' => [
        { 'key' => 'sink', 'type' => 'sink', 'width_mm' => 600 },
        { 'key' => 'drawers', 'type' => 'base_drawers', 'width_mm' => 600 },
        { 'key' => 'hob', 'type' => 'hob', 'width_mm' => 600 }
      ] }
  end

  def test_plan_is_read_only_and_bounded
    plan = HomeCAD::Kitchen.plan(@model, input)
    assert_empty @model.events
    assert_equal [100.0, 700.0, 1300.0], plan['positions'].map { |p| p['offset_mm'] }
    assert_equal 100.0, plan['filler_mm']
    assert_empty plan['conflicts']
    assert_equal 64, plan['fingerprint'].length
    assert_equal 'base', plan.dig('params', 'tier')
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.plan(@model, input.merge('modules' => Array.new(33) { |i|
        { 'key' => i.to_s, 'type' => 'sink', 'width_mm' => 50 } }))
    end
  end

  def test_start_end_clearances_and_planning_constraints
    layout = input.merge('end_mm' => 2150, 'start_clearance_mm' => 50,
      'end_clearance_mm' => 100, 'constraints' => {
        'require_full_coverage' => true, 'max_module_depth_mm' => 600,
        'min_opening_clearance_mm' => 25 })
    plan = HomeCAD::Kitchen.plan(@model, layout)
    assert_equal 150.0, plan['positions'].first['offset_mm']
    assert_equal 100.0, plan['filler_mm']
    assert_equal 150.0, plan.dig('params', 'run_start_mm')
    assert_empty plan['conflicts']
    assert_empty @model.events
    unfilled = HomeCAD::Kitchen.plan(@model, layout.merge('end_mm' => 2300))
    assert_includes unfilled['conflicts'].map { |c| c['code'] }, 'unallocated_space'
    no_top = HomeCAD::Kitchen.plan(@model, layout.merge('countertop' => false))
    assert_includes no_top['conflicts'].map { |c| c['code'] }, 'countertop_missing_coverage'
    shallow = HomeCAD::Kitchen.plan(@model, layout.merge('constraints' => {
      'max_module_depth_mm' => 500 }))
    assert_includes shallow['conflicts'].map { |c| c['code'] }, 'module_depth_exceeded'
  end

  def test_apply_update_delete_use_one_operation_and_stable_identity
    plan = HomeCAD::Kitchen.plan(@model, input)
    result = HomeCAD::Kitchen.apply(@model, 'plan' => plan)
    id = result.dig('created', 0, 'identity', 'homecad_id')
    assert_equal [:start, :commit], @model.events.map(&:first)
    root = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == id }
    assert_equal 'kitchen.run', HomeCAD::Metadata.read(root)['type']
    assert_equal 1, HomeCAD::Metadata.read(root)['revision']
    assert_equal %w[sink drawers hob], root.entities.select { |e|
      HomeCAD::Metadata.read(e)['module_key'] }.map { |e|
      HomeCAD::Metadata.read(e)['module_key'] }
    assert_equal 'countertop', root.entities.find { |e| e.name == 'countertop' }.name
    assert HomeCAD::Kitchen.validate(@model, 'target' => { 'homecad_id' => id })['valid']
    @model.events.clear
    update = HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => id },
      'changes' => { 'name' => 'South run' })
    assert_equal id, update.dig('updated', 0, 'identity', 'homecad_id')
    assert_equal 2, HomeCAD::Metadata.read(root)['revision']
    assert_equal [:start, :commit], @model.events.map(&:first)
    @model.events.clear
    deleted = HomeCAD::Kitchen.delete(@model, 'target' => { 'homecad_id' => id })
    assert_equal id, deleted.dig('deleted', 0, 'identity', 'homecad_id')
    assert_equal [:start, :commit], @model.events.map(&:first)
  end

  def test_stale_or_tampered_plan_rejected_before_operation
    plan = HomeCAD::Kitchen.plan(@model, input)
    plan['positions'][0]['offset_mm'] = 999
    error = assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Kitchen.apply(@model, 'plan' => plan) }
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    plan = HomeCAD::Kitchen.plan(@model, input)
    wall = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == @wall_id }
    HomeCAD::Metadata.increment_revision!(wall)
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Kitchen.apply(@model, 'plan' => plan) }
    assert_empty @model.events
  end

  def test_cut_collision_and_negative_filler_block_apply
    HomeCAD::Architecture.create_hosted(@model, 'architecture.door', 'wall' => { 'homecad_id' => @wall_id },
      'offset_mm' => 200, 'width_mm' => 900, 'height_mm' => 2100)
    @model.events.clear
    plan = HomeCAD::Kitchen.plan(@model, input)
    assert plan['conflicts'].any? { |c| c['code'] == 'wall_cut_collision' }
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Kitchen.apply(@model, 'plan' => plan) }
    assert_empty @model.events
    too_short = HomeCAD::Kitchen.plan(@model, input.merge('end_mm' => 1500))
    assert too_short['conflicts'].any? { |c| c['code'] == 'negative_filler' }
  end

  def test_opposite_side_and_invalid_inputs
    negative = HomeCAD::Kitchen.plan(@model, input.merge('side' => 'negative_v'))
    result = HomeCAD::Kitchen.apply(@model, 'plan' => negative)
    id = result.dig('created', 0, 'identity', 'homecad_id')
    assert_equal 'negative_v', HomeCAD::KitchenData.read(@model.entities.find { |e|
      HomeCAD::Metadata.read(e)['homecad_id'] == id })['side']
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.plan(@model, input.merge('modules' => [
        { 'key' => 'a', 'type' => 'sink', 'width_mm' => 600 },
        { 'key' => 'b', 'type' => 'fridge', 'width_mm' => 600 }]))
    end
    assert_equal 'constraint_violation', error.category
  end

  def test_wall_move_relocates_run_and_wall_delete_requires_cascade
    result = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::Kitchen.plan(@model, input))
    id = result.dig('created', 0, 'identity', 'homecad_id')
    root = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == id }
    previous = root.transformation.to_a
    previous_params = HomeCAD::KitchenData.read(root)
    @model.events.clear
    updated = HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => @wall_id },
      'changes' => { 'start_mm' => [100, 200, 0], 'end_mm' => [4100, 200, 0] })
    assert_equal [:start, :commit], @model.events.map(&:first)
    assert_includes updated['updated'].map { |e| e.dig('identity', 'homecad_id') }, id
    refute_equal previous, root.transformation.to_a
    assert_equal previous_params, HomeCAD::KitchenData.read(root)
    assert_equal 2, HomeCAD::Metadata.read(root)['revision']
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => @wall_id }, 'cascade' => false)
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    deleted = HomeCAD::Architecture.delete_object(@model,
      'target' => { 'homecad_id' => @wall_id }, 'cascade' => true)
    assert_includes deleted['deleted'].map { |e| e.dig('identity', 'homecad_id') }, id
    assert_equal [:start, :commit], @model.events.map(&:first)
  end

  def test_failed_update_preserves_revision_and_children
    result = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::Kitchen.plan(@model, input))
    id = result.dig('created', 0, 'identity', 'homecad_id')
    root = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == id }
    prior_children = root.entities.map(&:object_id)
    prior_params = HomeCAD::KitchenData.read(root)
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => id },
        'changes' => { 'end_mm' => 500 })
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    assert_equal prior_params, HomeCAD::KitchenData.read(root)
    assert_equal prior_children, root.entities.map(&:object_id)
    assert_equal 1, HomeCAD::Metadata.read(root)['revision']
  end

  def test_semantic_children_keep_uuid_across_regeneration
    result = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::Kitchen.plan(@model, input))
    run_id = result.dig('created', 0, 'identity', 'homecad_id')
    root = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == run_id }
    records = HomeCAD::KitchenData.read(root)['semantic_objects']
    assert_equal %w[module:sink module:drawers module:hob filler countertop plinth].sort, records.keys.sort
    assert_equal records.length, records.values.map { |record| record['homecad_id'] }.uniq.length
    records.each_value do |record|
      assert HomeCAD::Metadata.uuid?(record['homecad_id'])
      assert_equal 1, record['revision']
      entry = HomeCAD::Targeting.resolve_one(@model, { 'homecad_id' => record['homecad_id'] })
      assert_equal run_id, HomeCAD::Metadata.read(entry.parent)['homecad_id']
    end
    sink_id = records.fetch('module:sink')['homecad_id']
    sink = HomeCAD::Targeting.resolve_one(@model, { 'homecad_id' => sink_id }).entity
    assert_equal 'kitchen.base_cabinet', HomeCAD::Metadata.read(sink)['type']
    assert_equal 'sink', HomeCAD::KitchenData.read(sink)['module_type']
    rejection = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::MutationPolicy.validate_target!(
        HomeCAD::Targeting.resolve_one(@model, { 'homecad_id' => sink_id }), model: @model)
    end
    assert_equal 'constraint_violation', rejection.category
    prior_ids = root.entities.map(&:persistent_id)
    renamed = HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => run_id },
      'changes' => { 'name' => 'Renamed kitchen' })
    assert_equal prior_ids, root.entities.map(&:persistent_id)
    assert_equal records, HomeCAD::KitchenData.read(root)['semantic_objects']
    assert_equal 2, renamed['revision']
    assert_empty renamed['created']
    assert_empty renamed['deleted']
    changed_modules = input['modules'].map(&:dup)
    changed_modules[0]['type'] = 'dishwasher'
    changed = HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => run_id },
      'changes' => { 'modules' => changed_modules })
    new_records = HomeCAD::KitchenData.read(root)['semantic_objects']
    assert_equal sink_id, new_records.fetch('module:sink')['homecad_id']
    assert_equal 2, new_records.fetch('module:sink')['revision']
    assert_equal 1, new_records.fetch('module:drawers')['revision']
    new_sink = HomeCAD::Targeting.resolve_one(@model, { 'homecad_id' => sink_id }).entity
    assert_equal 'kitchen.appliance', HomeCAD::Metadata.read(new_sink)['type']
    assert_equal 'dishwasher', HomeCAD::KitchenData.read(new_sink)['module_type']
    assert_equal 3, changed['revision']
    assert_empty changed['deleted']
    assert_equal [], changed['created']
  end

  def test_removed_module_returns_tombstone_and_cannot_be_resolved
    result = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::Kitchen.plan(@model, input))
    run_id = result.dig('created', 0, 'identity', 'homecad_id')
    root = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == run_id }
    old_id = HomeCAD::KitchenData.read(root).dig('semantic_objects', 'module:hob', 'homecad_id')
    changed = HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => run_id },
      'changes' => { 'modules' => input['modules'].first(2) })
    assert_includes changed['deleted'].map { |item| item['homecad_id'] }, old_id
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Targeting.resolve_one(@model, { 'homecad_id' => old_id })
    end
  end

  def test_appliance_and_wall_cabinet_conflicts_use_precise_module_bounds
    HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::Kitchen.plan(@model, input))
    appliance = HomeCAD::Kitchen.plan(@model, input.merge('start_mm' => 200,
      'end_mm' => 800, 'modules' => [{ 'key' => 'fridge', 'type' => 'fridge', 'width_mm' => 600 }]))
    assert_includes appliance['conflicts'].map { |c| c['code'] }, 'appliance_collision'
    upper = HomeCAD::Kitchen.plan(@model, input.merge('start_mm' => 100, 'end_mm' => 700,
      'modules' => [{ 'key' => 'upper', 'type' => 'wall_shelves',
        'width_mm' => 600, 'bottom_mm' => 800 }]))
    assert_includes upper['conflicts'].map { |c| c['code'] }, 'wall_cabinet_collision'
    safe_upper = HomeCAD::Kitchen.plan(@model, input.merge('start_mm' => 100, 'end_mm' => 700,
      'modules' => [{ 'key' => 'upper', 'type' => 'wall_shelves',
        'width_mm' => 600, 'bottom_mm' => 1400 }]))
    assert_empty safe_upper['conflicts']
    opposite_side = HomeCAD::Kitchen.plan(@model, input.merge('side' => 'negative_v'))
    assert_empty opposite_side['conflicts']
  end

  def service_input(clearance, side: 'positive_v', strict: false)
    input.merge('end_mm' => 700, 'side' => side,
      'countertop' => false, 'plinth' => false,
      'constraints' => { 'require_countertop' => false,
        'require_service_clearance' => strict },
      'modules' => [{ 'key' => 'dishwasher', 'type' => 'dishwasher', 'width_mm' => 600,
        'service_clearance_mm' => clearance }])
  end

  def create_obstacle_column(origin, width: 30, depth: 30, height: 30, rotation: 0)
    HomeCAD::Architecture.create_column(@model, 'origin_mm' => origin,
      'width_mm' => width, 'depth_mm' => depth, 'height_mm' => height,
      'rotation_degrees' => rotation).dig('created', 0, 'identity', 'homecad_id')
  end

  def test_service_clearance_schema_and_legacy_defaults
    legacy = HomeCAD::Kitchen.plan(@model, input)
    refute legacy['params']['modules'].first.key?('service_clearance_mm')
    refute legacy.dig('params', 'constraints').key?('require_service_clearance')
    zero = HomeCAD::Kitchen.plan(@model, service_input({}))
    refute zero['params']['modules'].first.key?('service_clearance_mm')
    assert_empty zero['service_zones']
    assert_empty zero['service_findings']
    %w[u_start_mm u_end_mm front_mm back_mm top_mm bottom_mm].each do |direction|
      plan = HomeCAD::Kitchen.plan(@model, service_input({ direction => 25 }))
      assert_equal 25.0, plan.dig('params', 'modules', 0, 'service_clearance_mm', direction)
      assert_equal 1, plan['service_zones'].length
    end
    [-1, 5001, Float::INFINITY].each do |amount|
      assert_raises(HomeCAD::Runtime::BridgeError) do
        HomeCAD::Kitchen.plan(@model, service_input({ 'front_mm' => amount }))
      end
    end
  end

  def test_service_zone_six_directions_and_touching_bounds
    body = [100, 700, 0, 560, 100, 820]
    clearances = HomeCAD::ServiceZones::DIRECTIONS.to_h { |key| [key, 40] }
    slabs = HomeCAD::ServiceZones.slabs(body, clearances)
    assert_equal %w[u_start u_end front back top bottom].sort, slabs.keys.sort
    frame = [[0, 60, 0], [1, 0, 0], [0, 1, 0]]
    boxes = { 'u_start' => [70, 100, 150], 'u_end' => [710, 100, 150],
      'front' => [200, 625, 150], 'back' => [200, 35, 150],
      'top' => [200, 100, 830], 'bottom' => [200, 100, 70] }
    boxes.each do |direction, origin|
      zone = HomeCAD::ServiceZones.box(*frame, slabs.fetch(direction))
      obstacle = HomeCAD::ServiceZones.box(origin, [1, 0, 0], [0, 1, 0], [0, 10, 0, 10, 0, 10])
      assert HomeCAD::ServiceZones.overlap?(zone, obstacle), direction
    end
    touching = HomeCAD::ServiceZones.box([740, 60, 0], [1, 0, 0], [0, 1, 0],
      [0, 10, 0, 10, 100, 110])
    refute HomeCAD::ServiceZones.overlap?(
      HomeCAD::ServiceZones.box(*frame, slabs.fetch('u_end')), touching)
    diagonal = Math.sqrt(0.5)
    rotated = HomeCAD::ServiceZones.box([0, 0, 0], [diagonal, diagonal, 0],
      [-diagonal, diagonal, 0], [0, 1000, 0, 20, 0, 100])
    outside = HomeCAD::ServiceZones.box([600, 0, 0], [1, 0, 0], [0, 1, 0],
      [0, 50, 0, 50, 0, 100])
    refute HomeCAD::ServiceZones.overlap?(rotated, outside)
    %w[positive_v negative_v].each do |side|
      wall = HomeCAD::Architecture.wall_entity!(@model, { 'homecad_id' => @wall_id })[1]
      side_frame = HomeCAD::ServiceZones.frame_from_wall(wall, side: side)
      slabs.each_value do |limits|
        zone = HomeCAD::ServiceZones.box(*side_frame, limits)
        assert HomeCAD::ServiceZones.overlap?(zone, zone)
      end
    end
  end

  def test_same_run_filler_blocks_side_zone_but_own_countertop_is_exempt
    request = input.merge('end_mm' => 800, 'modules' => [
      { 'key' => 'hob', 'type' => 'hob', 'width_mm' => 600,
        'service_clearance_mm' => { 'u_end_mm' => 100, 'top_mm' => 100 } }
    ])
    plan = HomeCAD::Kitchen.plan(@model, request)
    assert_equal 100.0, plan['filler_mm']
    assert plan['service_findings'].any? { |finding|
      finding['direction'] == 'u_end' && finding['obstacle_key'] == 'filler' }
    refute plan['service_findings'].any? { |finding| finding['obstacle_key'] == 'countertop' }
  end

  def test_advisory_and_strict_service_zone_are_read_only_until_apply
    column_id = create_obstacle_column([250, 630, 150])
    request = service_input({ 'front_mm' => 100 })
    @model.events.clear
    advisory = HomeCAD::Kitchen.plan(@model, request)
    assert_empty @model.events
    assert_equal column_id, advisory.dig('service_findings', 0, 'object_id')
    assert_equal 'front', advisory.dig('service_findings', 0, 'direction')
    assert_empty advisory['conflicts']
    assert advisory['warnings'].any? { |warning| warning.include?('service clearance') }
    applied = HomeCAD::Kitchen.apply(@model, 'plan' => advisory)
    assert applied['warnings'].any? { |warning| warning.include?('service clearance') }
    strict = HomeCAD::Kitchen.plan(@model, request.merge('constraints' =>
      request['constraints'].merge('require_service_clearance' => true)))
    assert_includes strict['conflicts'].map { |item| item['code'] }, 'service_clearance_blocked'
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.apply(@model, 'plan' => strict)
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
  end

  def test_adjacent_wall_opening_removes_service_obstacle
    wall_id = HomeCAD::Architecture.create_wall(@model, 'start_mm' => [800, 500, 0],
      'end_mm' => [800, 1100, 0], 'thickness_mm' => 120, 'height_mm' => 2700)
      .dig('created', 0, 'identity', 'homecad_id')
    request = service_input({ 'u_end_mm' => 150, 'front_mm' => 50 })
    blocked = HomeCAD::Kitchen.plan(@model, request)
    assert_includes blocked['service_findings'].map { |finding| finding['object_id'] }, wall_id
    HomeCAD::Architecture.create_hosted(@model, 'architecture.opening',
      'wall' => { 'homecad_id' => wall_id }, 'offset_mm' => 0,
      'bottom_mm' => 0, 'width_mm' => 200, 'height_mm' => 1000)
    clear = HomeCAD::Kitchen.plan(@model, request)
    refute_includes clear['service_findings'].map { |finding| finding['object_id'] }, wall_id
  end

  def test_negative_side_and_rotated_column_collision
    column_id = create_obstacle_column([200, -700, 150], width: 100, depth: 100,
      height: 100, rotation: 45)
    plan = HomeCAD::Kitchen.plan(@model, service_input({ 'front_mm' => 100 }, side: 'negative_v'))
    assert_includes plan['service_findings'].map { |finding| finding['object_id'] }, column_id
  end

  def test_other_kitchen_and_furniture_block_service_volume_without_body_collision
    other_request = input.merge('start_mm' => 800, 'end_mm' => 1400,
      'countertop' => false, 'plinth' => false,
      'constraints' => { 'require_countertop' => false },
      'modules' => [{ 'key' => 'other', 'type' => 'base_shelves', 'width_mm' => 600 }])
    other_id = HomeCAD::Kitchen.apply(@model,
      'plan' => HomeCAD::Kitchen.plan(@model, other_request)).dig('created', 0, 'identity', 'homecad_id')
    plan = HomeCAD::Kitchen.plan(@model, service_input({ 'u_end_mm' => 200 }))
    assert_empty plan['conflicts']
    assert_includes plan['service_findings'].map { |item| item['object_id'] }, other_id

    cabinet_id = HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 100, 'depth_mm' => 100, 'height_mm' => 100,
      'placement' => { 'mode' => 'world', 'origin_mm' => [250, 630, 150],
                       'rotation_degrees' => 0 }).dig('created', 0, 'identity', 'homecad_id')
    front = HomeCAD::Kitchen.plan(@model, service_input({ 'front_mm' => 100 }))
    assert_includes front['service_findings'].map { |item| item['object_id'] }, cabinet_id
  end

  def test_later_obstacle_is_visible_and_strict_update_is_atomic
    request = service_input({ 'front_mm' => 100 })
    created = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::Kitchen.plan(@model, request))
    run_id = created.dig('created', 0, 'identity', 'homecad_id')
    module_id = created['created'].find { |item| item.dig('metadata', 'module_key') == 'dishwasher' }
      .dig('identity', 'homecad_id')
    root = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == run_id }
    assert_empty HomeCAD::Kitchen.validate(@model, 'target' => { 'homecad_id' => run_id })['service_findings']
    column_id = create_obstacle_column([250, 630, 150])
    validation = HomeCAD::Kitchen.validate(@model, 'target' => { 'homecad_id' => run_id })
    assert validation['valid']
    assert_equal column_id, validation.dig('service_findings', 0, 'object_id')
    before = HomeCAD::KitchenData.read(root)
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => run_id },
        'changes' => { 'constraints' => before['constraints'].merge('require_service_clearance' => true) })
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    assert_equal before, HomeCAD::KitchenData.read(root)
    assert_equal 1, HomeCAD::Metadata.read(root)['revision']
    HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => column_id })
    @model.events.clear
    updated = HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => run_id },
      'changes' => { 'constraints' => before['constraints'].merge('require_service_clearance' => true) })
    assert_equal [:start, :commit], @model.events.map(&:first)
    assert_equal 2, updated['revision']
    assert_equal run_id, HomeCAD::Metadata.read(root)['homecad_id']
    assert_equal module_id, HomeCAD::KitchenData.read(root).dig('semantic_objects',
      'module:dishwasher', 'homecad_id')
    assert_empty HomeCAD::Kitchen.validate(@model, 'target' => { 'homecad_id' => run_id })['service_findings']
  end

  def test_service_finding_limit_is_blocking_even_in_advisory_mode
    101.times { |index| create_obstacle_column([200 + index, 630, 150]) }
    @model.events.clear
    plan = HomeCAD::Kitchen.plan(@model, service_input({ 'front_mm' => 100 }))
    assert_equal HomeCAD::ServiceZones::MAX_FINDINGS, plan['service_findings'].length
    assert_includes plan['conflicts'].map { |item| item['code'] }, 'service_check_incomplete'
    assert_empty @model.events
  end

  def test_generator_failure_aborts_whole_kitchen_operation
    plan = HomeCAD::Kitchen.plan(@model, input)
    @model.fail_faces = true
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.apply(@model, 'plan' => plan)
    end
    assert_equal 'geometry_error', error.category
    assert_equal [:start, :abort], @model.events.map(&:first)
    assert_equal 1, @model.entities.length
    assert_equal 'architecture.wall', HomeCAD::Metadata.read(@model.entities.first)['type']
  end
end
