require_relative 'test_kitchen'
require_relative '../../sketchup/homecad/core/cutlist'

class CutlistTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
  end

  def target(result)
    { 'homecad_id' => result.dig('created', 0, 'identity', 'homecad_id') }
  end

  def test_panel_material_grain_all_edges_and_explicit_hardware
    manufacturing = { 'parts' => { 'left_side' => {
      'material_id' => 'oak-18', 'grain_axis' => 'length', 'sku' => 'SIDE-1',
      'edge_band' => { 'length_start' => 'edge-a', 'length_end' => 'edge-b',
                       'width_start' => 'edge-c', 'width_end' => 'edge-d' }
    } }, 'hardware' => [{ 'key' => 'hinge', 'sku' => 'HINGE-100', 'quantity' => 4 }] }
    result = HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
      'material_id' => 'board-default', 'manufacturing' => manufacturing)
    schedule = HomeCAD::Cutlist.generate(@model, 'target' => target(result), 'limit' => 2)
    assert_equal 6, schedule['total']
    assert_equal 2, schedule['records'].length
    assert schedule['has_more']
    side = schedule['records'].first
    assert_equal 'left_side', side['part_key']
    assert_equal 720.0, side['length_mm']
    assert_equal 560.0, side['width_mm']
    assert_equal 'oak-18', side['material_id']
    assert_equal 'length', side['grain_axis']
    assert_equal %w[edge-a edge-b edge-c edge-d],
      %w[length_start length_end width_start width_end].map { |key| side['edge_band'][key] }
    assert_equal 'board-default', schedule['records'][1]['material_id']
    last = HomeCAD::Cutlist.generate(@model, 'target' => target(result), 'limit' => 1, 'offset' => 5)
    assert_equal 'hardware', last['records'][0]['record_kind']
    assert_equal 4, last['records'][0]['quantity']
    assert_equal 'HINGE-100', last['records'][0]['sku']
    assert_empty @model.events.drop(2)
  end

  def test_cutlist_is_stable_across_lod_and_reports_unknown_as_null
    result = HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720)
    selector = target(result)
    first = HomeCAD::Cutlist.generate(@model, 'target' => selector)['records']
    assert_nil first.first['material_id']
    assert_nil first.first['sku']
    HomeCAD::Furniture.update_object(@model, 'target' => selector,
      'changes' => { 'detail_level' => 'concept' })
    assert_equal first, HomeCAD::Cutlist.generate(@model, 'target' => selector)['records']
  end

  def test_invalid_manufacturing_rejected_before_operation
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560,
        'height_mm' => 720, 'manufacturing' => { 'parts' => {
          'missing' => { 'material_id' => 'x' }
        } })
    end
    assert_equal 'invalid_request', error.category
    assert_empty @model.events
  end

  def test_kitchen_schedule_is_bounded_and_concept_limits_are_reported
    wall = HomeCAD::Architecture.create_wall(@model,
      'start_mm' => [0, 0, 0], 'end_mm' => [3000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700)
    plan = HomeCAD::Kitchen.plan(@model, { 'wall' => target(wall),
      'start_mm' => 0, 'end_mm' => 1500, 'side' => 'positive_v',
      'modules' => [
        { 'key' => 'shelves', 'type' => 'base_shelves', 'width_mm' => 600,
          'material_id' => 'white-board' },
        { 'key' => 'oven', 'type' => 'oven', 'width_mm' => 600 }
      ] })
    result = HomeCAD::Kitchen.apply(@model, 'plan' => plan)
    schedule = HomeCAD::Cutlist.generate(@model, 'target' => target(result))
    assert_equal 11, schedule['total']
    shelf_records = schedule['records'].select { |record| record['module_key'] == 'shelves' }
    assert_equal 6, shelf_records.length
    assert shelf_records.all? { |record| record['material_id'] == 'white-board' }
    assert schedule['records'].any? { |record| record['module_type'] == 'oven' }
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Cutlist.generate(@model, 'target' => target(result), 'limit' => 101)
    end
  end
end
