require_relative 'test_cutlist'

class CornerKitchenTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
    @first = wall([0, 0, 0], [3000, 0, 0])
    @second = wall([0, 0, 0], [0, 3000, 0])
    @model.events.clear
  end

  def wall(start_point, end_point)
    HomeCAD::Architecture.create_wall(@model,
      'start_mm' => start_point, 'end_mm' => end_point,
      'thickness_mm' => 120, 'height_mm' => 2700
    ).dig('created', 0, 'identity', 'homecad_id')
  end

  def input(mode = 'void', access = nil)
    corner = { 'mode' => mode, 'span_first_mm' => 900, 'span_second_mm' => 900 }
    corner['access_leg'] = access if access
    { 'legs' => [
        { 'key' => 'east', 'wall' => { 'homecad_id' => @first }, 'start_mm' => 0,
          'end_mm' => 2200, 'side' => 'positive_v',
          'modules' => [{ 'key' => 'a', 'type' => 'base_shelves', 'width_mm' => 600 }] },
        { 'key' => 'north', 'wall' => { 'homecad_id' => @second }, 'start_mm' => 0,
          'end_mm' => 2200, 'side' => 'negative_v',
          'modules' => [{ 'key' => 'b', 'type' => 'base_shelves', 'width_mm' => 600 }] }
      ], 'corner' => corner, 'name' => 'Corner fixture' }
  end

  def root_for(id)
    @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == id }
  end

  def test_plan_is_read_only_and_apply_uses_one_operation
    plan = HomeCAD::CornerKitchen.plan(@model, input)
    assert_empty @model.events
    assert_empty plan['conflicts']
    assert_equal 'l_shaped', plan.dig('params', 'layout_type')
    assert_equal 2, plan['wall_revisions'].length
    result = HomeCAD::Kitchen.apply(@model, 'plan' => plan)
    id = result.dig('created', 0, 'identity', 'homecad_id')
    assert_equal [:start, :commit], @model.events.map(&:first)
    root = root_for(id)
    assert_equal 3, root.entities.count { |child| HomeCAD::Metadata.read(child)['homecad_id'] }
    assert_equal [@first, @second], HomeCAD::MultiWallAttachment.read(root)
    assert_equal 3, result['created'].length - 1
    assert HomeCAD::Kitchen.validate(@model, 'target' => { 'homecad_id' => id })['valid']
  end

  def test_blind_corner_access_from_either_leg_and_cutlist
    %w[east north].each do |access|
      plan = HomeCAD::CornerKitchen.plan(@model, input('blind_cabinet', access))
      result = HomeCAD::Kitchen.apply(@model, 'plan' => plan)
      id = result.dig('created', 0, 'identity', 'homecad_id')
      root = root_for(id)
      corner = root.entities.find { |child| child.name == 'corner' }
      assert_equal 'kitchen.corner_cabinet', HomeCAD::Metadata.read(corner)['type']
      assert corner.entities.length >= 5
      schedule = HomeCAD::Cutlist.generate(@model, 'target' => { 'homecad_id' => id })
      assert schedule['records'].any? { |row| row['part_key'].start_with?('corner/') }
      top = schedule['records'].find { |row| row['part_key'] == 'corner/top' }
      assert_in_delta 804, top['width_mm'], 0.01
      HomeCAD::Kitchen.delete(@model, 'target' => { 'homecad_id' => id })
    end
  end

  def test_invalid_orientation_and_stale_plan_rejected_before_operation
    wrong = input
    wrong['legs'][1]['side'] = 'positive_v'
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::CornerKitchen.plan(@model, wrong)
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    plan = HomeCAD::CornerKitchen.plan(@model, input)
    plan['params']['corner']['span_first_mm'] = 1000
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.apply(@model, 'plan' => plan)
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
  end

  def test_either_wall_thickness_update_rebuilds_one_run_in_same_undo
    result = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::CornerKitchen.plan(@model, input))
    id = result.dig('created', 0, 'identity', 'homecad_id')
    root = root_for(id)
    @model.events.clear
    [@first, @second].each_with_index do |wall_id, index|
      changed = HomeCAD::Architecture.update_object(@model,
        'target' => { 'homecad_id' => wall_id },
        'changes' => { 'thickness_mm' => 130 + index * 10 })
      assert_equal [:start, :commit], @model.events.map(&:first)
      assert_includes changed['updated'].map { |entry| entry.dig('identity', 'homecad_id') }, id
      assert_equal index + 2, HomeCAD::Metadata.read(root)['revision']
      @model.events.clear
    end
    assert_equal id, HomeCAD::Metadata.read(root)['homecad_id']
  end

  def test_wall_detachment_rejected_before_mutation_and_cascade_deletes_run
    result = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::CornerKitchen.plan(@model, input))
    id = result.dig('created', 0, 'identity', 'homecad_id')
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.update_object(@model,
        'target' => { 'homecad_id' => @second },
        'changes' => { 'start_mm' => [100, 100, 0], 'end_mm' => [100, 3100, 0] })
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    assert_equal 1, HomeCAD::Metadata.read(root_for(id))['revision']
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.delete_object(@model,
        'target' => { 'homecad_id' => @first }, 'cascade' => false)
    end
    HomeCAD::Architecture.delete_object(@model,
      'target' => { 'homecad_id' => @first }, 'cascade' => true)
    assert_nil root_for(id)
  end

  def test_cross_leg_service_zone_warns_and_strict_mode_blocks
    request = input
    request['legs'][0]['modules'][0]['service_clearance_mm'] = { 'u_start_mm' => 100 }
    advisory = HomeCAD::CornerKitchen.plan(@model, request)
    assert advisory['service_findings'].any? { |finding| finding['obstacle_key'] == 'corner:second_panel' }
    assert_empty advisory['conflicts']
    request['legs'][0]['constraints'] = { 'require_service_clearance' => true }
    strict = HomeCAD::CornerKitchen.plan(@model, request)
    assert strict['conflicts'].any? { |conflict| conflict['code'] == 'service_clearance_blocked' }
    assert_empty @model.events
  end

  def test_update_preserves_root_and_module_identity_and_one_revision
    made = HomeCAD::Kitchen.apply(@model,
      'plan' => HomeCAD::CornerKitchen.plan(@model, input))
    id = made.dig('created', 0, 'identity', 'homecad_id')
    root = root_for(id)
    before = HomeCAD::KitchenData.read(root)
    @model.events.clear
    changed = HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => id },
      'changes' => { 'corner' => { 'mode' => 'blind_cabinet',
        'span_first_mm' => 900, 'span_second_mm' => 900, 'access_leg' => 'east' } })
    assert_equal [:start, :commit], @model.events.map(&:first)
    assert_same root, root_for(id)
    assert_equal 2, HomeCAD::Metadata.read(root)['revision']
    after = HomeCAD::KitchenData.read(root)
    %w[leg:east/module:a leg:north/module:b corner].each do |key|
      assert_equal before['semantic_objects'][key]['homecad_id'],
        after['semantic_objects'][key]['homecad_id']
    end
    assert_equal 'kitchen.corner_cabinet', root.entities.find { |child| child.name == 'corner' }
      .then { |child| HomeCAD::Metadata.read(child)['type'] }
    assert_equal id, changed.dig('updated', 0, 'identity', 'homecad_id')
  end
end
