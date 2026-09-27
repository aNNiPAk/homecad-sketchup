require_relative 'test_cutlist'

class HardwareCoreTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
  end

  def cabinet
    HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
      'fronts' => [{ 'key' => 'drawer_front', 'kind' => 'drawer_front',
        'x_mm' => 0, 'z_mm' => 0, 'width_mm' => 600, 'height_mm' => 720 }])
      .dig('created', 0, 'identity', 'homecad_id')
  end

  def drawer(key = 'upper')
    { 'key' => key, 'front_key' => 'drawer_front', 'bottom_mm' => 100,
      'height_mm' => 200, 'depth_mm' => 450,
      'side_thickness_mm' => 16, 'base_thickness_mm' => 8,
      'slide' => { 'family_id' => HomeCAD::HardwareCatalog::FAMILY_ID,
        'sku' => 'PROJECT-SLIDE-450', 'nominal_length_mm' => 450,
        'side_clearance_mm' => 12 } }
  end

  def root(id)
    @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == id }
  end

  def assert_drawer_bounds(id)
    cabinet = root(id)
    parts = HomeCAD::Furniture.list_parts(@model, 'target' => { 'homecad_id' => id })['parts']
      .select { |part| part['part_key'].start_with?('drawer:') }
    schedule = HomeCAD::Cutlist.generate(@model, 'target' => { 'homecad_id' => id })['records']
    parts.each do |part|
      child = cabinet.entities.find { |entity| entity.name == part['part_key'] }
      refute_nil child, part['part_key']
      bounds = child.bounds
      refute_nil bounds, part['part_key']
      expected_size = case part['part_kind']
                      when 'drawer_base' then [part['width_mm'], part['height_mm'], part['thickness_mm']]
                      when 'drawer_side' then [part['thickness_mm'], part['width_mm'], part['height_mm']]
                      else [part['width_mm'], part['thickness_mm'], part['height_mm']]
                      end
      expected_min = part['origin_mm']
      expected_max = expected_min.zip(expected_size).map { |origin, size| origin + size }
      [expected_min, expected_max].zip([bounds.corner(0), bounds.corner(7)]).each do |expected, point|
        actual = [point.x, point.y, point.z].map { |value| HomeCAD::Units.internal_to_mm(value) }
        expected.zip(actual).each do |want, got|
          assert_in_delta want, got, 0.01, "#{part['part_key']} bounds"
        end
      end
      row = schedule.find { |item| item['part_key'] == part['part_key'] }
      refute_nil row, part['part_key']
      assert_equal part['height_mm'], row['length_mm']
      assert_equal part['width_mm'], row['width_mm']
      assert_equal part['thickness_mm'], row['thickness_mm']
    end
  end

  def test_catalog_and_planning_are_read_only
    catalog = HomeCAD::HardwareCatalog.list(@model, {})
    family = catalog['families'].first
    assert_equal HomeCAD::HardwareCatalog::FAMILY_ID, family['id']
    assert_equal 'pair', family['unit']
    assert_equal 1, family['quantity_per_assembly']
    assert_nil family['sku']
    catalog['families'].first['id'] = 'tampered'
    assert_equal HomeCAD::HardwareCatalog::FAMILY_ID,
      HomeCAD::HardwareCatalog.list(@model, {})['families'].first['id']
    id = cabinet
    @model.events.clear
    plan = HomeCAD::Furniture.plan_drawer(@model,
      'target' => { 'homecad_id' => id }, 'drawer' => drawer)
    assert_equal 'valid', plan['status']
    assert_equal 1, plan['cabinet_revision']
    assert_equal 5, plan['parts'].length
    assert_equal 'drawer:upper/slide_pair', plan['hardware'][0]['part_key']
    assert_equal 'pair', plan['hardware'][0]['unit']
    assert_equal 1, plan['hardware'][0]['quantity']
    assert_empty @model.events
    refute HomeCAD::FurnitureData.read_params(root(id)).key?('drawers')
  end

  def test_drawer_update_generates_five_panels_and_one_purchased_pair
    id = cabinet
    @model.events.clear
    updated = HomeCAD::Furniture.update_object(@model,
      'target' => { 'homecad_id' => id }, 'changes' => { 'drawers' => [drawer] })
    assert_equal [:start, :commit], @model.events.map(&:first)
    assert_equal 2, updated['revision']
    assert_equal id, HomeCAD::Metadata.read(root(id))['homecad_id']
    keys = root(id).entities.map(&:name)
    assert_includes keys, 'drawer:upper/base'
    assert_includes keys, 'drawer:upper/left_side'
    schedule = HomeCAD::Cutlist.generate(@model, 'target' => { 'homecad_id' => id })
    panels = schedule['records'].select { |record| record['part_key'].start_with?('drawer:upper/') &&
      record['record_kind'] == 'panel' }
    assert_equal 5, panels.length
    assert_equal 540, panels.find { |record| record['part_key'] == 'drawer:upper/base' }['width_mm']
    bought = schedule['records'].find { |record| record['part_key'] == 'drawer:upper/slide_pair' }
    assert_equal 'PROJECT-SLIDE-450', bought['sku']
    assert_equal 'drawer_front', bought['front_key']
    assert_equal 1, bought['quantity']
    assert_equal 'pair', bought['unit']
    assert_equal 1, schedule['warnings'].length
    assert_match(/project-selected/, schedule['warnings'].first)
    assert_drawer_bounds(id)
  end

  def test_invalid_configuration_rejects_before_operation_and_keeps_revision
    id = cabinet
    saved = HomeCAD::FurnitureData.read_params(root(id))
    @model.events.clear
    wrong = drawer
    wrong['slide']['nominal_length_mm'] = 500
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Furniture.update_object(@model,
        'target' => { 'homecad_id' => id }, 'changes' => { 'drawers' => [wrong] })
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    assert_equal saved, HomeCAD::FurnitureData.read_params(root(id))
    assert_equal 1, HomeCAD::Metadata.read(root(id))['revision']
  end

  def test_part_schedule_is_independent_of_detail_level
    id = cabinet
    HomeCAD::Furniture.update_object(@model,
      'target' => { 'homecad_id' => id }, 'changes' => { 'drawers' => [drawer] })
    first = HomeCAD::Cutlist.generate(@model, 'target' => { 'homecad_id' => id })['records']
    HomeCAD::Furniture.update_object(@model,
      'target' => { 'homecad_id' => id }, 'changes' => { 'detail_level' => 'concept' })
    second = HomeCAD::Cutlist.generate(@model, 'target' => { 'homecad_id' => id })['records']
    assert_equal first, second
  end

  def test_wrong_family_and_shelf_intersection_are_rejected_before_mutation
    id = cabinet
    @model.events.clear
    wrong = drawer
    wrong['slide']['family_id'] = 'unknown.family.v1'
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Furniture.plan_drawer(@model, 'target' => { 'homecad_id' => id }, 'drawer' => wrong)
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events

    HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => id },
      'changes' => { 'shelf_z_mm' => [150] })
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => id },
        'changes' => { 'drawers' => [drawer] })
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    assert_equal 2, HomeCAD::Metadata.read(root(id))['revision']
  end

  def test_drawer_panel_positions_are_cabinet_local
    params = HomeCAD::Furniture.validate_params!(@model, {
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
      'fronts' => [{ 'key' => 'drawer_front', 'kind' => 'drawer_front',
        'x_mm' => 0, 'z_mm' => 0, 'width_mm' => 600, 'height_mm' => 720 }],
      'drawers' => [drawer] })
    parts = HomeCAD::DrawerHardware.parts(params).to_h { |part| [part['part_key'], part] }
    assert_equal [30.0, 110.0, 100.0], parts['drawer:upper/base']['origin_mm']
    assert_equal [554.0, 110.0, 108.0], parts['drawer:upper/right_side']['origin_mm']
    assert_equal 508.0, parts['drawer:upper/back']['width_mm']
  end

  def test_two_drawers_with_different_dimensions_match_geometry_and_cutlist
    first = drawer('upper')
    second = drawer('lower')
    second['front_key'] = 'lower_front'
    second['bottom_mm'] = 400
    second['height_mm'] = 180
    second['depth_mm'] = 380
    second['side_thickness_mm'] = 18
    second['slide']['nominal_length_mm'] = 380
    result = HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 740, 'depth_mm' => 600, 'height_mm' => 800,
      'fronts' => [
        { 'key' => 'drawer_front', 'kind' => 'drawer_front', 'x_mm' => 0,
          'z_mm' => 0, 'width_mm' => 740, 'height_mm' => 350 },
        { 'key' => 'lower_front', 'kind' => 'drawer_front', 'x_mm' => 0,
          'z_mm' => 350, 'width_mm' => 740, 'height_mm' => 350 }
      ], 'drawers' => [first, second],
      'placement' => { 'mode' => 'world', 'origin_mm' => [100, 200, 0],
        'rotation_degrees' => 90 })
    id = result.dig('created', 0, 'identity', 'homecad_id')
    assert_drawer_bounds(id)
    frame = HomeCAD::Furniture.get_frame(@model, 'target' => { 'homecad_id' => id })
    assert_equal [100.0, 200.0, 0.0], frame['origin_mm']
    assert_in_delta 1, frame['x_axis'][1], 1e-8
    base = root(id).entities.find { |part| part.name == 'drawer:upper/base' }
    world_corners = [base.bounds.corner(0), base.bounds.corner(7)]
      .map { |point| root(id).transformation * point }
      .map { |point| [point.x, point.y, point.z].map { |value| HomeCAD::Units.internal_to_mm(value) } }
    assert_in_delta(-500, world_corners[1][0], 0.01)
    assert_in_delta 230, world_corners[0][1], 0.01
    assert_equal 2, HomeCAD::Cutlist.generate(@model,
      'target' => { 'homecad_id' => id })['records'].count { |row| row['record_kind'] == 'hardware' }
  end

  def test_wall_placed_drawer_keeps_local_panel_dimensions
    wall_id = HomeCAD::Architecture.create_wall(@model,
      'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
    created = HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
      'fronts' => [{ 'key' => 'drawer_front', 'kind' => 'drawer_front',
        'x_mm' => 0, 'z_mm' => 0, 'width_mm' => 600, 'height_mm' => 720 }],
      'drawers' => [drawer],
      'placement' => { 'mode' => 'wall', 'wall_id' => wall_id,
        'offset_mm' => 1000, 'bottom_mm' => 0, 'side' => 'positive_v', 'clearance_mm' => 10 })
    id = created.dig('created', 0, 'identity', 'homecad_id')
    assert_drawer_bounds(id)
    assert_equal 'wall', HomeCAD::FurnitureData.read_params(root(id)).dig('placement', 'mode')
    frame = HomeCAD::Furniture.get_frame(@model, 'target' => { 'homecad_id' => id })
    assert_equal [1000.0, 70.0, 0.0], frame['origin_mm']
    base = root(id).entities.find { |part| part.name == 'drawer:upper/base' }
    world_min = root(id).transformation * base.bounds.corner(0)
    assert_equal [1030.0, 180.0, 100.0],
      [world_min.x, world_min.y, world_min.z].map { |value| HomeCAD::Units.internal_to_mm(value) }
  end

  def test_overlapping_drawers_reject_before_mutation
    id = HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
      'fronts' => [
        { 'key' => 'drawer_front', 'kind' => 'drawer_front', 'x_mm' => 0,
          'z_mm' => 0, 'width_mm' => 600, 'height_mm' => 350 },
        { 'key' => 'second', 'kind' => 'drawer_front', 'x_mm' => 0,
          'z_mm' => 350, 'width_mm' => 600, 'height_mm' => 350 }
      ]).dig('created', 0, 'identity', 'homecad_id')
    first = drawer
    first['bottom_mm'] = 250
    first['height_mm'] = 100
    second = drawer('second')
    second['front_key'] = 'second'
    second['bottom_mm'] = 340
    second['height_mm'] = 100
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => id },
        'changes' => { 'drawers' => [first, second] })
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    assert_equal 1, HomeCAD::Metadata.read(root(id))['revision']
  end

  def test_explicit_hardware_is_not_merged_with_derived_slide_pair
    id = cabinet
    HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => id },
      'changes' => { 'drawers' => [drawer], 'manufacturing' => {
        'hardware' => [{ 'key' => 'manual_slide', 'sku' => 'PROJECT-SLIDE-450', 'quantity' => 1 }] } })
    schedule = HomeCAD::Cutlist.generate(@model, 'target' => { 'homecad_id' => id })
    same_sku = schedule['records'].select { |row| row['sku'] == 'PROJECT-SLIDE-450' }
    assert_equal %w[drawer:upper/slide_pair hardware:manual_slide], same_sku.map { |row| row['part_key'] }.sort
    assert_equal 1, schedule['warnings'].length
  end

  def test_invalid_drawer_related_updates_preserve_state_before_operation
    id = cabinet
    HomeCAD::Furniture.update_object(@model,
      'target' => { 'homecad_id' => id }, 'changes' => { 'drawers' => [drawer] })
    before_params = HomeCAD::FurnitureData.read_params(root(id))
    before_revision = HomeCAD::Metadata.read(root(id))['revision']
    before_bounds = root(id).entities.select { |entity| entity.name.start_with?('drawer:') }
      .to_h { |entity| [entity.name, [entity.bounds.corner(0), entity.bounds.corner(7)]] }
    changes = [
      { 'fronts' => [] },
      { 'fronts' => [{ 'key' => 'drawer_front', 'kind' => 'door', 'x_mm' => 0,
        'z_mm' => 0, 'width_mm' => 600, 'height_mm' => 720 }] },
      { 'shelf_z_mm' => [150] },
      { 'depth_mm' => 400 },
      { 'drawers' => Array.new(17) { |index| drawer("drawer#{index}") } }
    ]
    changes.each do |change|
      @model.events.clear
      assert_raises(HomeCAD::Runtime::BridgeError) do
        HomeCAD::Furniture.update_object(@model,
          'target' => { 'homecad_id' => id }, 'changes' => change)
      end
      assert_empty @model.events
      assert_equal before_params, HomeCAD::FurnitureData.read_params(root(id))
      assert_equal before_revision, HomeCAD::Metadata.read(root(id))['revision']
      assert_equal id, HomeCAD::Metadata.read(root(id))['homecad_id']
      before_bounds.each do |key, corners|
        entity = root(id).entities.find { |part| part.name == key }
        refute_nil entity
        assert_equal corners.map { |point| [point.x, point.y, point.z] },
          [entity.bounds.corner(0), entity.bounds.corner(7)].map { |point| [point.x, point.y, point.z] }
      end
    end
  end
end
