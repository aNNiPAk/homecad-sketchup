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

  def test_apply_update_delete_use_one_operation_and_stable_identity
    plan = HomeCAD::Kitchen.plan(@model, input)
    result = HomeCAD::Kitchen.apply(@model, 'plan' => plan)
    id = result.dig('created', 0, 'identity', 'homecad_id')
    assert_equal [:start, :commit], @model.events.map(&:first)
    root = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == id }
    assert_equal 'kitchen.run', HomeCAD::Metadata.read(root)['type']
    assert_equal 1, HomeCAD::Metadata.read(root)['revision']
    assert_equal %w[sink drawers hob], root.entities.select { |e|
      HomeCAD::Metadata.read(e)['type'] == 'kitchen.module' }.map { |e|
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
