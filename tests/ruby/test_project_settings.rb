require_relative 'test_furniture'
require_relative '../../sketchup/homecad/core/project_settings'
require_relative '../../sketchup/homecad/core/furniture_presets'

class ProjectSettingsTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
  end

  def cabinet(id)
    @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == id }
  end

  def test_preset_creation_and_project_inheritance
    source = HomeCAD::FurniturePresets.resolve(@model, 'base_open.v1', {})
    created = HomeCAD::Furniture.create_cabinet(@model, source[0], source: source[1])
    id = created.dig('created', 0, 'homecad_id')
    entity = cabinet(id)
    assert_equal [:start, :commit], @model.events.map(&:first)
    assert_equal 18.0, HomeCAD::FurnitureData.read_params(entity)['panel_thickness_mm']
    assert_includes HomeCAD::FurnitureData.read_source(entity)['inherited_fields'], 'panel_thickness_mm'
    @model.events.clear
    changed = HomeCAD::ProjectSettings.update(@model, 'panel_thickness_mm' => 20)
    assert_equal 1, changed['revision']
    assert_equal [:start, :commit], @model.events.map(&:first)
    assert_equal 20.0, HomeCAD::FurnitureData.read_params(entity)['panel_thickness_mm']
    assert_equal 2, HomeCAD::Metadata.read(entity)['revision']
    assert_equal id, HomeCAD::Metadata.read(entity)['homecad_id']
  end

  def test_legacy_and_explicit_override_do_not_follow_default
    legacy = HomeCAD::Furniture.create_cabinet(@model,
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720)
    params, source = HomeCAD::FurniturePresets.resolve(@model, 'base_open.v1',
      'panel_thickness_mm' => 21)
    explicit = HomeCAD::Furniture.create_cabinet(@model, params, source: source)
    @model.events.clear
    HomeCAD::ProjectSettings.update(@model, 'panel_thickness_mm' => 22)
    assert_equal 18.0, HomeCAD::FurnitureData.read_params(cabinet(legacy.dig('created', 0, 'homecad_id')))['panel_thickness_mm']
    assert_equal 21.0, HomeCAD::FurnitureData.read_params(cabinet(explicit.dig('created', 0, 'homecad_id')))['panel_thickness_mm']
    assert_equal [:start, :commit], @model.events.map(&:first)
  end

  def test_invalid_dependent_change_fails_before_operation
    params, source = HomeCAD::FurniturePresets.resolve(@model, 'base_open.v1',
      'width_mm' => 38, 'height_mm' => 100)
    result = HomeCAD::Furniture.create_cabinet(@model, params, source: source)
    entity = cabinet(result.dig('created', 0, 'homecad_id'))
    @model.events.clear
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::ProjectSettings.update(@model, 'panel_thickness_mm' => 20)
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
    assert_equal 0, HomeCAD::ProjectSettings.read(@model)['revision']
    assert_equal 1, HomeCAD::Metadata.read(entity)['revision']
  end

  def test_direct_override_breaks_inheritance_even_at_same_value
    params, source = HomeCAD::FurniturePresets.resolve(@model, 'base_open.v1', {})
    created = HomeCAD::Furniture.create_cabinet(@model, params, source: source)
    id = created.dig('created', 0, 'homecad_id')
    entity = cabinet(id)
    @model.events.clear
    HomeCAD::Furniture.update_object(@model, 'target' => { 'homecad_id' => id },
      'changes' => { 'panel_thickness_mm' => 18 })
    refute_includes HomeCAD::FurnitureData.read_source(entity)['inherited_fields'], 'panel_thickness_mm'
    assert_equal 2, HomeCAD::Metadata.read(entity)['revision']
    @model.events.clear
    HomeCAD::ProjectSettings.update(@model, 'panel_thickness_mm' => 19)
    assert_equal 18.0, HomeCAD::FurnitureData.read_params(entity)['panel_thickness_mm']
    assert_equal 2, HomeCAD::Metadata.read(entity)['revision']
  end
end
