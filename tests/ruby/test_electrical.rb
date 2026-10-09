require_relative 'test_hardware'
root = File.expand_path('../../sketchup/homecad/core', __dir__)
%w[electrical_data circuits electrical].each { |name| require File.join(root, name) }

class ElectricalTest < Minitest::Test
  # Snapshot only the fake kernel state used by these tests; production rollback
  # is SketchUp's abort_operation, verified independently by packaged smoke/Undo.
  class RollbackModel < Sketchup::Model
    def start_operation(*)
      visit = lambda do |entities|
        entities.grep(Sketchup::Group).flat_map do |group|
          [[group, group.entities.dup, Marshal.load(Marshal.dump(group.instance_variable_get(:@attributes))),
            Array(group.instance_variable_get(:@points)).dup, group.transformation, group.name]] + visit.call(group.entities)
        end
      end
      @rollback_state = [entities.dup, Marshal.load(Marshal.dump(@attributes)), visit.call(entities)]
      super
    end

    def abort_operation
      super
      roots, attributes, groups = @rollback_state
      entities.replace(roots); @attributes = attributes
      groups.each do |group, children, data, points, transform, name|
        group.entities.replace(children); group.instance_variable_set(:@attributes, data)
        group.instance_variable_set(:@points, points); group.instance_variable_set(:@valid, true)
        group.transformation = transform; group.name = name
      end
      true
    end
  end

  def setup
    @model = RollbackModel.new
    Sketchup.active_model = @model
  end

  def wall
    @wall ||= HomeCAD::Architecture.create_wall(@model,
      'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'homecad_id')
  end

  def request(side = 'positive_v')
    { 'name' => 'Outlet', 'dimensions_mm' => { 'width_mm' => 80, 'height_mm' => 80, 'depth_mm' => 20 },
      'placement' => { 'mode' => 'wall', 'wall_id' => wall, 'offset_mm' => 1000,
        'height_mm' => 300, 'side' => side } }
  end

  def point(params = request)
    HomeCAD::Electrical.create(@model, params, 'outlet')['created'].first['homecad_id']
  end

  def target(id) = { 'homecad_id' => id }
  def entity(id) = @model.entities.find { |e| HomeCAD::Metadata.read(e)['homecad_id'] == id }
  def circuit(name = 'Kitchen') = HomeCAD::Circuits.create(@model, 'name' => name)['created'].first['homecad_id']

  def test_wall_center_frames_both_sides_and_relocation
    %w[positive_v negative_v].each do |side|
      id = point(request(side)); e = entity(id)
      p = HomeCAD::WallAttachment.read(e)
      assert_equal 960, p['offset_mm']; assert_equal 260, p['bottom_mm']
      matrix = e.transformation.to_a
      origin = matrix[12, 3].map { |v| HomeCAD::Units.internal_to_mm(v) }
      assert_equal(side == 'positive_v' ? [960, 60, 260] : [1040, -60, 260], origin)
      assert HomeCAD::Electrical.supported?(@model, HomeCAD::ElectricalData.read(e))
    end
    changed = HomeCAD::Architecture.update_object(@model, 'target' => target(wall),
      'changes' => { 'start_mm' => [100, 100, 0], 'end_mm' => [100, 4100, 0] })
    assert_equal 3, changed['updated'].length
    HomeCAD::Electrical.points(@model).each { |e| assert_equal 2, HomeCAD::Metadata.read(e)['revision'] }
  end

  def test_world_floor_ceiling_and_invalid_vectors
    [[0, 0, 1], [0, 0, -1], [0, 1, 1]].each do |normal|
      id = point(request.merge('placement' => { 'mode' => 'world', 'origin_mm' => [0, 0, 0],
        'normal' => normal, 'up' => [1, 0, 0] }))
      box = HomeCAD::Electrical.obb(entity(id))
      box[:axes].each { |axis| assert_in_delta 1, HomeCAD::SceneVolumes.dot(axis, axis), 1e-8 }
      assert_in_delta 0, HomeCAD::SceneVolumes.dot(box[:axes][1], box[:axes][2]), 1e-8
      @model.events.clear
      HomeCAD::Electrical.update(@model, 'target' => target(id), 'changes' => { 'name' => 'Outlet' })
      assert_empty @model.events, 'normalized world-frame no-op must not create an operation'
      HomeCAD::Electrical.update(@model, 'target' => target(id),
        'changes' => { 'placement' => HomeCAD::ElectricalData.read(entity(id))['placement'] })
      assert_empty @model.events, 'reapplying a normalized frame must be a no-op'
    end
    @model.events.clear
    assert_raises(HomeCAD::Runtime::BridgeError) do
      point(request.merge('placement' => { 'mode' => 'world', 'origin_mm' => [0, 0, 0],
        'normal' => [0, 0, 1], 'up' => [0, 0, 1] }))
    end
    assert_empty @model.events
  end

  def test_opening_creation_warns_but_direct_point_creation_rejects
    id = point
    opening = HomeCAD::Architecture.create_hosted(@model, 'architecture.opening',
      'wall' => target(wall), 'offset_mm' => 900, 'bottom_mm' => 200,
      'width_mm' => 200, 'height_mm' => 200)
    assert opening['warnings'].any? { |warning| warning.include?('missing_support') }
    findings = HomeCAD::Electrical.validate_scene(@model, 'target' => target(id))
    assert_equal 'missing_support', findings['findings'].first['category']
    @model.events.clear
    assert_raises(HomeCAD::Runtime::BridgeError) { point }
    assert_empty @model.events
  end

  def test_niche_support_depends_on_side
    HomeCAD::Architecture.create_hosted(@model, 'architecture.niche',
      'wall' => target(wall), 'offset_mm' => 900, 'bottom_mm' => 200,
      'width_mm' => 200, 'height_mm' => 200, 'depth_mm' => 40, 'side' => 'positive_v')
    assert_raises(HomeCAD::Runtime::BridgeError) { point }
    assert point(request('negative_v'))
  end

  def test_circuit_membership_transfer_noop_detach_and_delete
    id = point; a = circuit; b = circuit('Other')
    @model.events.clear
    assigned = HomeCAD::Electrical.assign(@model, 'target' => target(id), 'circuit_id' => a)
    assert_equal 2, assigned['revision']; assert_equal [:start, :commit], @model.events.map(&:first)
    assert_equal [id], HomeCAD::Circuits.get(@model, 'target' => target(a))['member_ids']
    @model.events.clear
    HomeCAD::Electrical.assign(@model, 'target' => target(id), 'circuit_id' => a)
    assert_empty @model.events
    HomeCAD::Electrical.assign(@model, 'target' => target(id), 'circuit_id' => b)
    assert_equal 3, HomeCAD::Circuits.resolve(@model, target(a))['revision']
    assert_equal 2, HomeCAD::Circuits.resolve(@model, target(b))['revision']
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Circuits.delete(@model, 'target' => target(b)) }
    HomeCAD::Circuits.delete(@model, 'target' => target(b), 'detach_points' => true)
    assert_nil HomeCAD::ElectricalData.read(entity(id))['circuit_id']
    assert_equal 4, HomeCAD::Metadata.read(entity(id))['revision']
  end

  def test_wall_cascade_updates_circuit_once
    a = circuit; ids = [point, point(request.merge('placement' => request['placement'].merge('offset_mm' => 1500)))]
    ids.each { |id| HomeCAD::Electrical.assign(@model, 'target' => target(id), 'circuit_id' => a) }
    @model.events.clear
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Architecture.delete_object(@model, 'target' => target(wall)) }
    assert_empty @model.events
    deleted = HomeCAD::Architecture.delete_object(@model, 'target' => target(wall), 'cascade' => true)
    assert_equal 4, HomeCAD::Circuits.resolve(@model, target(a))['revision']
    assert_empty HomeCAD::Circuits.members(@model, a)
    assert_equal 3, deleted['deleted'].length
    assert_equal [:start, :commit], @model.events.map(&:first)
  end

  def test_invalid_update_locked_and_ambiguous_targets
    id = point; e = entity(id); before = HomeCAD::ElectricalData.read(e)
    @model.events.clear
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Electrical.update(@model, 'target' => target(id),
        'changes' => { 'placement' => before['placement'].merge('offset_mm' => 0) })
    end
    assert_empty @model.events; assert_equal before, HomeCAD::ElectricalData.read(e)
    e.define_singleton_method(:locked?) { true }
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Electrical.delete(@model, 'target' => target(id)) }
    e.define_singleton_method(:locked?) { false }
    other = entity(point)
    other.set_attribute(HomeCAD::Metadata::DICTIONARY, 'homecad_id', id)
    error = assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Electrical.resolve(@model, target(id)) }
    assert_equal 'ambiguous_target', error.category
  end

  def test_obb_touching_and_rotated_separation
    a = { center: [0, 0, 0], axes: [[1,0,0], [0,1,0], [0,0,1]], half: [1,1,1] }
    refute HomeCAD::SceneVolumes.overlap?(a, a.merge(center: [2,0,0]))
    assert HomeCAD::SceneVolumes.overlap?(a, a.merge(center: [1.9,0,0]))
    diagonal = Math.sqrt(0.5)
    b = { center: [1.3,1.3,0], axes: [[diagonal,diagonal,0], [-diagonal,diagonal,0], [0,0,1]], half: [0.2,1,0.2] }
    refute HomeCAD::SceneVolumes.overlap?(a, b)
  end

  def test_circuit_bounds_invalid_record_and_readonly
    id = circuit
    @model.events.clear
    result = HomeCAD::Circuits.get(@model, 'target' => target(id))
    assert_nil result['identity']['entity_id']; assert_equal 1, HomeCAD::Circuits.list(@model, {})['total']
    HomeCAD::Circuits.update(@model, 'target' => target(id), 'changes' => { 'name' => 'Kitchen' })
    assert_empty @model.events
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Circuits.list(@model, 'limit' => 101) }
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Circuits.resolve(@model, 'entity_id' => 1) }
  end

  def test_exception_aborts_updated_parameters_geometry_and_revision
    id = point; e = entity(id); before = HomeCAD::Furniture.serialize_entity(e)
    @model.events.clear
    HomeCAD::Electrical.stub(:build, ->(*) { raise 'injected kernel failure' }) do
      error = assert_raises(HomeCAD::Runtime::BridgeError) do
        HomeCAD::Electrical.dispatch(@model, 'update_electrical_point',
          'target' => target(id), 'changes' => { 'dimensions_mm' => {
            'width_mm' => 90, 'height_mm' => 90, 'depth_mm' => 30 } })
      end
      assert_equal 'geometry_error', error.category
    end
    assert_equal [:start, :abort], @model.events.map(&:first)
    assert_equal before, HomeCAD::Furniture.serialize_entity(e)
  end

  def test_scene_collision_pagination_and_point_noop
    id = point
    HomeCAD::Furniture.create_cabinet(@model, 'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720,
      'placement' => { 'mode' => 'world', 'origin_mm' => [800, 60, 0], 'rotation_degrees' => 0 })
    other = point
    @model.events.clear
    findings = HomeCAD::Electrical.validate_scene(@model, 'target' => target(id), 'limit' => 1)
    assert_equal 2, findings['total']; assert_equal true, findings['has_more']
    assert_equal 'collision', findings['findings'].first['category']
    assert_equal 1, HomeCAD::Electrical.validate_scene(@model, 'target' => target(id), 'limit' => 1, 'offset' => 1)['findings'].length
    HomeCAD::Electrical.update(@model, 'target' => target(id), 'changes' => { 'quantity' => 1 })
    assert_empty @model.events
    assert_equal 1, HomeCAD::Metadata.read(entity(id))['revision']
    refute_nil other
  end

  def test_circuit_noop_and_read_do_not_add_metadata
    raw_before = @model.get_attribute(HomeCAD::Metadata::DICTIONARY, HomeCAD::ElectricalData::CIRCUITS_KEY)
    assert_empty HomeCAD::Circuits.list(@model, {})['circuits']
    assert_nil raw_before
    assert_nil @model.get_attribute(HomeCAD::Metadata::DICTIONARY, HomeCAD::ElectricalData::CIRCUITS_KEY)
    id = circuit
    @model.events.clear
    HomeCAD::Circuits.update(@model, 'target' => target(id), 'changes' => { 'name' => 'Kitchen' })
    assert_empty @model.events
    assert_equal 1, HomeCAD::Circuits.resolve(@model, target(id))['revision']
  end
end
