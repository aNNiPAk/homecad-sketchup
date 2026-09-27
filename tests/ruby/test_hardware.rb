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
end
