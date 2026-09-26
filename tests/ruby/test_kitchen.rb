require_relative 'test_furniture'
require_relative '../../sketchup/homecad/core/kitchen'

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
