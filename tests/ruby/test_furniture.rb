require_relative 'test_architecture'

class FurnitureTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
  end

  def create_wall
    HomeCAD::Architecture.create_wall(@model, 'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
  end

  def test_frame_right_handed_and_world_coordinates
    result = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720, 'placement' => { 'mode' => 'world', 'origin_mm' => [100, 200, 0],
      'rotation_degrees' => 90 })
    id = result.dig('created', 0, 'identity', 'homecad_id')
    assert_equal [:start, :commit], @model.events.map(&:first)
    frame = HomeCAD::Furniture.get_frame(@model, 'target' => { 'homecad_id' => id })
    cross = [frame['x_axis'][1] * frame['y_axis'][2] - frame['x_axis'][2] * frame['y_axis'][1],
             frame['x_axis'][2] * frame['y_axis'][0] - frame['x_axis'][0] * frame['y_axis'][2],
             frame['x_axis'][0] * frame['y_axis'][1] - frame['x_axis'][1] * frame['y_axis'][0]]
    assert_equal [0.0, 0.0, 1.0], cross
    assert_equal [100.0, 200.0, 0.0], frame['origin_mm']
    assert_in_delta 0, frame['x_axis'][0], 1e-8
    assert_in_delta 1, frame['x_axis'][1], 1e-8
    assert_in_delta(-1, frame['y_axis'][0], 1e-8)
    assert_equal 600.0, frame['width_mm']
  end

  def test_create_updates_preserving_uuid_and_schedule
    created = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 800, 'depth_mm' => 600,
      'height_mm' => 2100, 'shelf_z_mm' => [500, 1000], 'fronts' => [
        { 'key' => 'door_left', 'kind' => 'door', 'x_mm' => 0, 'z_mm' => 0,
          'width_mm' => 390, 'height_mm' => 2090 }])
    cabinet_id = created.dig('created', 0, 'identity', 'homecad_id')
    group = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
    assert_equal 'furniture.cabinet', HomeCAD::Metadata.read(group)['type']
    assert_equal 1, HomeCAD::Metadata.read(group)['revision']
    assert_equal 8, group.entities.length
    right_side = group.entities.find { |part| part.name == 'right_side' }
    shelf = group.entities.find { |part| part.name == 'shelf:0' }
    assert_point_bounds([782, 0, 0], [800, 600, 2100], right_side)
    assert_point_bounds([18, 4, 500], [782, 600, 518], shelf)
    assert_equal 8, HomeCAD::Furniture.list_parts(@model, 'target' => { 'homecad_id' => cabinet_id })['count']
    before = @model.events.count { |event| event.first == :start }
    update = HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => cabinet_id },
      'changes' => { 'height_mm' => 2200 })
    assert_equal cabinet_id, update.dig('updated', 0, 'identity', 'homecad_id')
    assert_equal 2, HomeCAD::Metadata.read(group)['revision']
    assert_equal before + 1, @model.events.count { |event| event.first == :start }
  end

  def test_part_extrusion_follows_positive_world_z_for_reversed_face_normal
    face = Object.new
    face.define_singleton_method(:normal) { Geom::Vector3d.new(0, 0, -1) }
    face.define_singleton_method(:pushpull) { |distance| @distance = distance }
    HomeCAD::Furniture.extrude_to_positive_z!(face, 12.0, 'test')
    assert_equal(-12.0, face.instance_variable_get(:@distance))
  end

  def assert_point_bounds(min_mm, max_mm, entity)
    box = entity.bounds
    actual_min = box.corner(0)
    actual_max = box.corner(7)
    min_values = [actual_min.x, actual_min.y, actual_min.z].map { |value| HomeCAD::Units.internal_to_mm(value) }
    max_values = [actual_max.x, actual_max.y, actual_max.z].map { |value| HomeCAD::Units.internal_to_mm(value) }
    min_mm.zip(min_values).each { |expected, actual| assert_in_delta expected, actual, 0.01 }
    max_mm.zip(max_values).each { |expected, actual| assert_in_delta expected, actual, 0.01 }
  end

  def test_invalid_front_rejected_before_operation
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 500,
        'height_mm' => 700, 'fronts' => [{ 'key' => 'bad', 'x_mm' => 590, 'z_mm' => 0,
          'width_mm' => 100, 'height_mm' => 100 }])
    end
    assert_empty @model.events
    assert_empty @model.entities
  end

  def test_generated_part_descendants_are_blocked_from_primitive_mutation
    result = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 500,
      'height_mm' => 700)
    cabinet_id = result.dig('created', 0, 'identity', 'homecad_id')
    entry = nil
    HomeCAD::Scene.walk(@model) do |candidate|
      if candidate.parent && HomeCAD::Metadata.read(candidate.parent)['type'] == 'furniture.part'
        entry = candidate
        break
      end
    end
    refute_nil entry
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::MutationPolicy.validate_target!(entry, model: @model)
    end
    assert_equal 'constraint_violation', error.category
    assert_equal cabinet_id, HomeCAD::Metadata.read(entry.parent.parent)['homecad_id']
  end

  def test_generation_failure_aborts_operation_and_leaves_no_root_object
    @model.fail_faces = true
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 500,
        'height_mm' => 700)
    end
    assert_empty @model.entities
    assert_equal [:start, :abort], @model.events.map(&:first)
  end

  def test_wall_attachment_relocates_from_wall_local_parameters
    wall_id = create_wall
    created = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720, 'placement' => { 'mode' => 'wall', 'wall_id' => wall_id,
      'offset_mm' => 1000, 'bottom_mm' => 0, 'side' => 'positive_v', 'clearance_mm' => 10 })
    cabinet_id = created.dig('created', 0, 'identity', 'homecad_id')
    cabinet = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
    assert_equal wall_id, HomeCAD::WallAttachment.read(cabinet)['wall_id']
    wall = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == wall_id }
    old_transform = cabinet.transformation
    prior_operations = @model.events.count { |event| event.first == :start }
    update = HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => wall_id },
      'changes' => { 'start_mm' => [100, 100, 0], 'end_mm' => [100, 4100, 0] })
    assert_equal 2, HomeCAD::Metadata.read(cabinet)['revision']
    refute_same old_transform, cabinet.transformation
    assert update['updated'].any? { |entity| entity.dig('identity', 'homecad_id') == cabinet_id }
    assert_equal 'wall', HomeCAD::FurnitureData.read_params(cabinet).dig('placement', 'mode')
    assert_equal 2, HomeCAD::Metadata.read(wall)['revision']
    assert_equal prior_operations + 1, @model.events.count { |event| event.first == :start }
    assert_equal 2, HomeCAD::Metadata.read(cabinet)['revision']
  end

  def test_same_transform_wall_to_world_detach_changes_revision_and_clears_projection
    wall_id = create_wall
    created = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720, 'placement' => { 'mode' => 'wall', 'wall_id' => wall_id,
      'offset_mm' => 1000, 'bottom_mm' => 0, 'side' => 'positive_v', 'clearance_mm' => 0 })
    cabinet_id = created.dig('created', 0, 'identity', 'homecad_id')
    cabinet = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
    before_transform = cabinet.transformation.to_a
    children = cabinet.entities.map(&:object_id)
    frame = HomeCAD::Furniture.get_frame(@model, 'target' => { 'homecad_id' => cabinet_id })
    result = HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => cabinet_id },
      'changes' => { 'placement' => { 'mode' => 'world', 'origin_mm' => frame['origin_mm'],
        'rotation_degrees' => 0 } })

    assert_equal before_transform, cabinet.transformation.to_a
    assert_equal 'world', HomeCAD::FurnitureData.read_params(cabinet).dig('placement', 'mode')
    assert_empty HomeCAD::FurnitureData.read_relationships(cabinet)
    assert_nil HomeCAD::WallAttachment.read(cabinet)
    refute HomeCAD::Metadata.read(cabinet).key?('wall_id')
    assert_empty HomeCAD::WallAttachment.dependents_for(@model, wall_id)
    assert_equal children, cabinet.entities.map(&:object_id)
    assert_equal 2, HomeCAD::Metadata.read(cabinet)['revision']
    assert_equal 2, result['revision']
    HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => wall_id }, 'cascade' => false)
  end

  def test_same_transform_wall_reattach_transfers_dependency_and_increments_revision
    wall_a = create_wall
    wall_b = HomeCAD::Architecture.create_wall(@model, 'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
    created = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720, 'placement' => { 'mode' => 'wall', 'wall_id' => wall_a,
      'offset_mm' => 1000, 'bottom_mm' => 0, 'side' => 'positive_v', 'clearance_mm' => 0 })
    cabinet_id = created.dig('created', 0, 'identity', 'homecad_id')
    cabinet = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
    before_transform = cabinet.transformation.to_a
    children = cabinet.entities.map(&:object_id)
    result = HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => cabinet_id },
      'changes' => { 'placement' => { 'mode' => 'wall', 'wall_id' => wall_b,
        'offset_mm' => 1000, 'bottom_mm' => 0, 'side' => 'positive_v', 'clearance_mm' => 0 } })

    assert_equal before_transform, cabinet.transformation.to_a
    assert_equal wall_b, HomeCAD::FurnitureData.read_relationships(cabinet)['wall_id']
    assert_equal wall_b, HomeCAD::WallAttachment.read(cabinet)['wall_id']
    assert_empty HomeCAD::WallAttachment.dependents_for(@model, wall_a)
    assert_equal [cabinet], HomeCAD::WallAttachment.dependents_for(@model, wall_b)
    assert_equal children, cabinet.entities.map(&:object_id)
    assert_equal 2, HomeCAD::Metadata.read(cabinet)['revision']
    assert_equal 2, result['revision']
    HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => wall_a }, 'cascade' => false)
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => wall_b }, 'cascade' => false)
    end
  end

  def test_canonical_noop_does_not_open_operation_or_increment_revision
    created = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720)
    cabinet_id = created.dig('created', 0, 'identity', 'homecad_id')
    cabinet = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
    before_operations = @model.events.count { |event| event.first == :start }
    children = cabinet.entities.map(&:object_id)
    result = HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => cabinet_id },
      'changes' => { 'width_mm' => 600, 'name' => 'Cabinet' })
    assert_equal 1, result['revision']
    assert_equal before_operations, @model.events.count { |event| event.first == :start }
    assert_equal children, cabinet.entities.map(&:object_id)
  end

  def test_wall_shorten_and_height_rejections_are_preflighted
    wall_id = create_wall
    created = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720, 'placement' => { 'mode' => 'wall', 'wall_id' => wall_id,
      'offset_mm' => 1000, 'bottom_mm' => 0, 'side' => 'negative_v', 'clearance_mm' => 0 })
    cabinet_id = created.dig('created', 0, 'identity', 'homecad_id')
    cabinet = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
    wall = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == wall_id }
    before_operations = @model.events.count { |event| event.first == :start }
    before_transform = cabinet.transformation
    [{ 'end_mm' => [1500, 0, 0] }, { 'height_mm' => 700 }].each do |changes|
      assert_raises(HomeCAD::Runtime::BridgeError) do
        HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => wall_id }, 'changes' => changes)
      end
    end
    assert_equal before_operations, @model.events.count { |event| event.first == :start }
    assert_equal 1, HomeCAD::Metadata.read(wall)['revision']
    assert_equal 1, HomeCAD::Metadata.read(cabinet)['revision']
    assert_equal before_transform.to_a, cabinet.transformation.to_a
  end

  def test_wall_direction_reversal_keeps_local_attachment_and_reframes_cabinet
    wall_id = create_wall
    result = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720, 'placement' => { 'mode' => 'wall', 'wall_id' => wall_id,
      'offset_mm' => 1000, 'bottom_mm' => 0, 'side' => 'positive_v', 'clearance_mm' => 10 })
    cabinet_id = result.dig('created', 0, 'identity', 'homecad_id')
    cabinet = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
    update = HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => wall_id },
      'changes' => { 'start_mm' => [4000, 0, 0], 'end_mm' => [0, 0, 0] })
    frame = HomeCAD::Furniture.get_frame(@model, 'target' => { 'homecad_id' => cabinet_id })
    placement = HomeCAD::FurnitureData.read_params(cabinet)['placement']
    assert_equal 1000.0, placement['offset_mm']
    assert_equal 'positive_v', placement['side']
    assert_equal [-1.0, 0.0, 0.0], frame['x_axis']
    assert_equal [0.0, -1.0, 0.0], frame['y_axis']
    assert_equal [3000.0, -70.0, 0.0], frame['origin_mm']
    assert_equal 2, HomeCAD::Metadata.read(cabinet)['revision']
    assert_equal 2, update.dig('updated').find { |entry| entry.dig('identity', 'homecad_id') == cabinet_id }.dig('metadata', 'revision')
  end

  def test_delete_wall_requires_cascade_and_cascade_includes_cabinet
    wall_id = create_wall
    created = HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
      'height_mm' => 720, 'placement' => { 'mode' => 'wall', 'wall_id' => wall_id,
      'offset_mm' => 100, 'bottom_mm' => 0, 'side' => 'positive_v', 'clearance_mm' => 0 })
    cabinet_id = created.dig('created', 0, 'identity', 'homecad_id')
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => wall_id }, 'cascade' => false)
    end
    result = HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => wall_id }, 'cascade' => true)
    assert result['deleted'].any? { |entry| entry.dig('identity', 'homecad_id') == cabinet_id }
    assert_nil @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == cabinet_id }
  end
end
