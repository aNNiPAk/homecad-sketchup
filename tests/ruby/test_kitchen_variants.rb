require_relative 'test_corner_kitchen'

class KitchenVariantsTest < CornerKitchenTest
  def request
    data = input
    data['countertop'] = { 'enabled' => true, 'thickness_mm' => 38,
      'material_id' => 'stone-01',
      'first_end' => { 'style' => 'bevel', 'bevel_mm' => 60 },
      'second_end' => { 'style' => 'square' },
      'cutouts' => [{ 'key' => 'sink', 'leg_key' => 'east',
        'offset_mm' => 1100, 'front_mm' => 100, 'width_mm' => 200, 'depth_mm' => 200 }] }
    data['panels'] = { 'first' => { 'thickness_mm' => 18, 'material_id' => 'oak',
      'grain_axis' => 'length', 'sku' => 'P-01',
      'edge_band' => { 'length_start' => 'a', 'length_end' => 'b',
        'width_start' => 'c', 'width_end' => 'd' } } }
    data
  end

  def test_explicit_variants_produce_one_countertop_with_cutout_and_schedule
    plan = HomeCAD::CornerKitchen.plan(@model, request)
    assert_empty plan['conflicts']
    assert_empty @model.events
    shape = HomeCAD::KitchenVariants.footprint(@model, plan['params'])
    assert_equal 1, shape['holes_mm'].length
    assert_equal 7, shape['polygon_mm'].length
    result = HomeCAD::Kitchen.apply(@model, 'plan' => plan)
    id = result.dig('created', 0, 'identity', 'homecad_id')
    root = root_for(id)
    top = root.entities.find { |child| child.name == 'countertop' }
    refute_nil top
    assert_equal 'kitchen.countertop', HomeCAD::Metadata.read(top)['type']
    assert_equal 1, top.entities.count { |child| child.typename == 'Face' }
    panel = root.entities.find { |child| child.name == 'panel:first' }
    assert_equal 'kitchen.end_panel', HomeCAD::Metadata.read(panel)['type']
    schedule = HomeCAD::Cutlist.generate(@model, 'target' => { 'homecad_id' => id })
    top_record = schedule['records'].find { |row| row['part_key'] == 'countertop' }
    assert_equal 'shaped_panel', top_record['record_kind']
    assert_equal 'concept_shaped', top_record['manufacturing_status']
    assert_equal 'stone-01', top_record['material_id']
    assert_equal 'sink', top_record['cutouts_mm'][0]['key']
    panel_record = schedule['records'].find { |row| row['part_key'] == 'panel:first' }
    assert_equal %w[a b c d], %w[length_start length_end width_start width_end].map { |key| panel_record['edge_band'][key] }
    assert_equal [:start, :commit], @model.events.map(&:first)
  end

  def test_invalid_cutout_and_panel_reject_before_mutation
    bad = request
    bad['countertop']['cutouts'][0]['offset_mm'] = 10
    error = assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::CornerKitchen.plan(@model, bad) }
    assert_equal 'constraint_violation', error.category
    bad = request
    bad['panels']['first']['thickness_mm'] = 1000
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::CornerKitchen.plan(@model, bad) }
    assert_empty @model.events
  end

  def test_overlapping_cutouts_reject_and_failed_update_keeps_revision
    data = request
    data['countertop']['cutouts'] << { 'key' => 'hob', 'leg_key' => 'east',
      'offset_mm' => 1150, 'front_mm' => 150, 'width_mm' => 200, 'depth_mm' => 200 }
    error = assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::CornerKitchen.plan(@model, data) }
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events

    made = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::CornerKitchen.plan(@model, request))
    id = made.dig('created', 0, 'identity', 'homecad_id')
    root = root_for(id)
    before = HomeCAD::KitchenData.read(root)
    revision = HomeCAD::Metadata.read(root)['revision']
    @model.events.clear
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => id },
        'changes' => { 'countertop' => data['countertop'] })
    end
    assert_empty @model.events
    assert_equal before, HomeCAD::KitchenData.read(root)
    assert_equal revision, HomeCAD::Metadata.read(root)['revision']
  end

  def test_variant_update_keeps_run_identity_and_one_undo
    made = HomeCAD::Kitchen.apply(@model, 'plan' => HomeCAD::CornerKitchen.plan(@model, request))
    id = made.dig('created', 0, 'identity', 'homecad_id')
    root = root_for(id)
    top_id = HomeCAD::KitchenData.read(root).dig('semantic_objects', 'countertop', 'homecad_id')
    @model.events.clear
    changed = request['countertop'].merge('thickness_mm' => 40)
    result = HomeCAD::Kitchen.update(@model, 'target' => { 'homecad_id' => id },
      'changes' => { 'countertop' => changed })
    assert_equal [:start, :commit], @model.events.map(&:first)
    assert_same root, root_for(id)
    assert_equal 2, HomeCAD::Metadata.read(root)['revision']
    assert_equal top_id, HomeCAD::KitchenData.read(root).dig('semantic_objects', 'countertop', 'homecad_id')
    assert_equal id, result.dig('updated', 0, 'identity', 'homecad_id')
  end

  def test_legacy_corner_plan_has_no_countertop
    plan = HomeCAD::CornerKitchen.plan(@model, input)
    assert_equal({ 'enabled' => false }, plan['params']['countertop'])
    assert_empty plan['params']['panels']
  end
end
