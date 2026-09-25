require 'minitest/autorun'

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z) = (@x, @y, @z = x.to_f, y.to_f, z.to_f)
    def distance(other) = Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    def transform(transformation) = transformation * self
  end
  class Vector3d < Point3d
    def length = Math.sqrt(x * x + y * y + z * z)
    def cross(other) = Vector3d.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
  end
  class Transformation
    def self.axes(origin, xaxis, yaxis, zaxis) = new(origin, xaxis, yaxis, zaxis)
    def self.rotation(*) = new
    def initialize(origin = Point3d.new(0, 0, 0), xaxis = Vector3d.new(1, 0, 0),
                   yaxis = Vector3d.new(0, 1, 0), zaxis = Vector3d.new(0, 0, 1))
      @origin, @axes = origin, [xaxis, yaxis, zaxis]
    end
    def *(point)
      Point3d.new(@origin.x + @axes[0].x * point.x + @axes[1].x * point.y + @axes[2].x * point.z,
                  @origin.y + @axes[0].y * point.x + @axes[1].y * point.y + @axes[2].y * point.z,
                  @origin.z + @axes[0].z * point.x + @axes[1].z * point.y + @axes[2].z * point.z)
    end
    def to_a = [@axes[0].x, @axes[0].y, @axes[0].z, 0,
                @axes[1].x, @axes[1].y, @axes[1].z, 0,
                @axes[2].x, @axes[2].y, @axes[2].z, 0,
                @origin.x, @origin.y, @origin.z, 1]
  end
end

module Sketchup
  class Group
    attr_reader :entities, :persistent_id, :entityID, :parent
    attr_accessor :name, :transformation
    def initialize(id, parent)
      @persistent_id = @entityID = id
      @parent = parent
      @entities = Entities.new(self)
      @attributes = {}
      @name = ''
      @valid = true
    end
    def typename = 'Group'
    def model = parent.respond_to?(:model) ? parent.model : parent
    def valid? = @valid
    def deleted? = !@valid
    def erase! = (@valid = false)
    def attribute_dictionary(key, _create = false) = @attributes[key]
    def set_attribute(dictionary, key, value) = (@attributes[dictionary] ||= {})[key] = value
    def delete_attribute(dictionary, key)
      return false unless @attributes[dictionary]

      !@attributes[dictionary].delete(key).nil?
    end
    def hidden? = false
    def visible? = true
    def locked? = false
    def layer = nil
    def material = nil
    def fail_face = model.respond_to?(:fail_faces) && !!model.fail_faces
    def add_points(points) = (@points ||= []).concat(points)
    def transform!(_transformation) = true
    def bounds
      pts = entities.flat_map { |entity| entity.respond_to?(:points) ? entity.points : (entity.respond_to?(:position) ? [entity.position] : []) } + Array(@points)
      return nil if pts.empty?
      Box.new(pts)
    end
    class Box
      def initialize(points)
        @points = points
        @min = Geom::Point3d.new(*3.times.map { |i| points.map { |p| [p.x, p.y, p.z][i] }.min })
        @max = Geom::Point3d.new(*3.times.map { |i| points.map { |p| [p.x, p.y, p.z][i] }.max })
      end
      def empty? = false
      def corner(i) = Geom::Point3d.new((i & 1).zero? ? @min.x : @max.x, (i & 2).zero? ? @min.y : @max.y, (i & 4).zero? ? @min.z : @max.z)
    end
  end
  class Face
    attr_reader :points, :parent, :persistent_id, :entityID
    def initialize(parent, points)
      @parent, @points = parent, points
      @persistent_id = @entityID = parent.model.next_id
    end
    def typename = 'Face'
    def name = ''
    def valid? = true
    def deleted? = false
    def hidden? = false
    def visible? = true
    def locked? = false
    def layer = nil
    def material = nil
    def attribute_dictionary(*) = nil
    def normal
      first = @points[1]; origin = @points[0]; last = @points[2]
      ax = first.x - origin.x; ay = first.y - origin.y; az = first.z - origin.z
      bx = last.x - origin.x; by = last.y - origin.y; bz = last.z - origin.z
      vector = Geom::Vector3d.new(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
      length = vector.length
      Geom::Vector3d.new(vector.x / length, vector.y / length, vector.z / length)
    end
    def pushpull(distance)
      direction = normal
      @parent.add_points(@points.map { |point| Geom::Point3d.new(point.x + direction.x * distance,
        point.y + direction.y * distance, point.z + direction.z * distance) })
      nil
    end
  end
  class Edge
    attr_reader :points, :persistent_id, :entityID
    def initialize(points)
      @points = points
      @persistent_id = @entityID = object_id
    end
    def typename = 'Edge'
  end
  class ConstructionPoint
    attr_reader :position, :persistent_id, :entityID
    attr_accessor :hidden, :casts_shadows
    def initialize(model, position)
      @position = position
      @persistent_id = @entityID = model.next_id
    end
    def typename = 'ConstructionPoint'
    def valid? = true
    def deleted? = false
    def hidden? = !!hidden
    def visible? = !hidden?
    def locked? = false
    def layer = nil
    def material = nil
    def attribute_dictionary(*) = nil
  end
  class Entities < Array
    attr_reader :owner
    def initialize(owner) = (@owner = owner; super())
    def add_group
      group = Group.new(owner.model.next_id, owner)
      self << group
      group
    end
    def add_face(points)
      return nil if owner.fail_face
      face = Face.new(owner, points)
      self << face
      face
    end
    def add_line(first, last)
      edge = Edge.new([first, last])
      self << edge
      edge
    end
    def add_cpoint(position)
      point = ConstructionPoint.new(owner.model, position)
      self << point
      point
    end
    def clear! = (clear; true)
    def erase_entities(*items) = items.each { |item| delete(item); item.erase! if item.respond_to?(:erase!) }
    def erase_entities(*entities) = entities.each { |entity| delete(entity); entity.erase! if entity.respond_to?(:erase!) }
    def model = owner.respond_to?(:model) ? owner.model : owner
  end
  class Model
    attr_reader :entities, :events
    attr_accessor :fail_faces
    def initialize
      @entities = Entities.new(self)
      @next_id = 100
      @events = []
    end
    def model = self
    def next_id = (@next_id += 1)
    def find_entity_by_persistent_id(id) = entities.find { |entity| entity.persistent_id == id }
    def start_operation(name, *)
      @snapshot = entities.length
      @events << [:start, name]
      true
    end
    def commit_operation = (@events << [:commit]; true)
    def abort_operation
      @events << [:abort]
      entities.slice!(@snapshot..) if @snapshot
      true
    end
  end
  def self.active_model = @model
  def self.active_model=(model)
    @model = model
  end
end

root = File.expand_path('../../sketchup/homecad', __dir__)
%w[errors operation].each { |name| require File.join(root, 'runtime', name) }
%w[units metadata scene targeting serializer mutation geometry primitives architecture].each do |name|
  require File.join(root, 'core', name)
end
%w[wall_attachment furniture_data furniture].each do |name|
  require File.join(root, 'core', name)
end

class ArchitectureTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
  end

  def create_rectangular_walls(x, y, width, depth)
    points = [[x, y, 0], [x + width, y, 0], [x + width, y + depth, 0], [x, y + depth, 0]]
    points.each_with_index.map do |start, index|
      finish = points[(index + 1) % points.length]
      HomeCAD::Architecture.create_wall(@model,
        'start_mm' => start, 'end_mm' => finish, 'thickness_mm' => 120, 'height_mm' => 2700)
        .dig('created', 0, 'identity', 'homecad_id')
    end
  end

  def room_entity(homecad_id)
    @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == homecad_id }
  end

  def room_face_points(room)
    room.entities.find { |entity| entity.typename == 'Face' }.points.map do |point|
      [HomeCAD::Units.internal_to_mm(point.x), HomeCAD::Units.internal_to_mm(point.y), HomeCAD::Units.internal_to_mm(point.z)]
    end
  end

  def assert_points_equal(expected, actual)
    assert_equal expected.length, actual.length
    expected.zip(actual).each do |left, right|
      left.zip(right).each { |a, b| assert_in_delta a, b, 1e-6 }
    end
  end

  def test_wall_frame_axes_and_roundtrip_for_x_y_and_arbitrary_xy
    [[ [0, 0, 0], [4000, 0, 0], [1, 0, 0], [0, 1, 0] ],
     [[0, 0, 0], [0, 3000, 0], [0, 1, 0], [-1, 0, 0]],
     [[10, -4, 0], [13, 8, 0], [0.242535625, 0.9701425, 0], [-0.9701425, 0.242535625, 0]]].each do |start, finish, expected_u, expected_v|
      frame = HomeCAD::WallFrame.build(start, finish)
      expected_u.zip(frame.u_axis).each { |expected, actual| assert_in_delta expected, actual, 1e-6 }
      expected_v.zip(frame.v_axis).each { |expected, actual| assert_in_delta expected, actual, 1e-6 }
      world = frame.local_to_world(123.4, -56.7, 890.1)
      local = frame.world_to_local(world)
      [123.4, -56.7, 890.1].zip(local).each { |expected, actual| assert_in_delta expected, actual, 1e-7 }
      assert_in_delta 1.0, HomeCAD::WallFrame.dot(frame.u_axis, frame.u_axis), 1e-8
      cross = [frame.u_axis[1] * frame.v_axis[2] - frame.u_axis[2] * frame.v_axis[1],
               frame.u_axis[2] * frame.v_axis[0] - frame.u_axis[0] * frame.v_axis[2],
               frame.u_axis[0] * frame.v_axis[1] - frame.u_axis[1] * frame.v_axis[0]]
      cross.zip([0.0, 0.0, 1.0]).each { |actual, expected| assert_in_delta expected, actual, 1e-7 }
    end
  end

  def test_wall_frame_rejects_zero_length_and_sloped_baseline
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::WallFrame.build([0, 0, 0], [0, 0, 0]) }
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::WallFrame.build([0, 0, 0], [1000, 0, 20]) }
  end

  def test_wall_boundary_is_solid_without_cuts_and_open_at_through_cut
    plain = HomeCAD::Architecture.wall_boundary_quads(4000, 120, 2700, [])
    assert_equal 6, plain.length
    plain.each do |quad|
      a, b, c = quad.first(3)
      ab = 3.times.map { |index| b[index] - a[index] }
      ac = 3.times.map { |index| c[index] - a[index] }
      normal = [ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0]]
      center = 3.times.map { |index| quad.sum { |point| point[index] } / 4.0 }
      outward = [center[0] - 2000, center[1], center[2] - 1350]
      assert_operator 3.times.sum { |index| normal[index] * outward[index] }, :>, 0
    end
    cut = { 'type' => 'architecture.window', 'offset_mm' => 1000, 'bottom_mm' => 900,
            'width_mm' => 1200, 'height_mm' => 1200, 'side' => 'center', 'depth_mm' => 120 }
    shell = HomeCAD::Architecture.wall_boundary_quads(4000, 120, 2700, [cut])
    refute shell.any? { |quad|
      quad.all? { |point| point[1] == 60.0 } &&
        quad.map { |point| point[0] }.min >= 1000 && quad.map { |point| point[0] }.max <= 2200 &&
        quad.map { |point| point[2] }.min >= 900 && quad.map { |point| point[2] }.max <= 2100
    }
    assert_operator shell.length, :>, plain.length
  end

  def test_niche_opens_one_side_and_preserves_opposite_wall_face
    niche = { 'type' => 'architecture.niche', 'offset_mm' => 500, 'bottom_mm' => 500,
              'width_mm' => 600, 'height_mm' => 700, 'depth_mm' => 40,
              'side' => 'positive_v', 'depth_offset_mm' => 20 }
    shell = HomeCAD::Architecture.wall_boundary_quads(3000, 120, 2400, [niche])
    refute shell.any? { |quad| quad.all? { |point| point[1] == 60.0 } && quad.map { |p| p[0] }.min >= 500 && quad.map { |p| p[0] }.max <= 1100 && quad.map { |p| p[2] }.min >= 500 && quad.map { |p| p[2] }.max <= 1200 }
    assert shell.any? { |quad| quad.all? { |point| point[1] == -60.0 } && quad.map { |p| p[0] }.min >= 500 && quad.map { |p| p[0] }.max <= 1100 && quad.map { |p| p[2] }.min >= 500 && quad.map { |p| p[2] }.max <= 1200 }
  end

  def test_negative_v_niche_is_partial_depth_too
    niche = { 'type' => 'architecture.niche', 'offset_mm' => 500, 'bottom_mm' => 500,
              'width_mm' => 600, 'height_mm' => 700, 'depth_mm' => 40,
              'side' => 'negative_v', 'depth_offset_mm' => 0 }
    shell = HomeCAD::Architecture.wall_boundary_quads(3000, 120, 2400, [niche])
    assert shell.any? { |quad| quad.all? { |point| point[1] == 60.0 } && quad.map { |p| p[0] }.min >= 500 && quad.map { |p| p[0] }.max <= 1100 }
    refute shell.any? { |quad| quad.all? { |point| point[1] == -60.0 } && quad.map { |p| p[0] }.min >= 500 && quad.map { |p| p[0] }.max <= 1100 && quad.map { |p| p[2] }.min >= 500 && quad.map { |p| p[2] }.max <= 1200 }
  end

  def test_overlapping_cuts_are_rejected
    cuts = 2.times.map do |index|
      { 'type' => 'architecture.opening', 'offset_mm' => index * 20, 'bottom_mm' => 100,
        'width_mm' => 100, 'height_mm' => 100 }
    end
    error = assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Architecture.validate_cuts!(cuts) }
    assert_equal 'constraint_violation', error.category
  end

  def test_create_wall_and_get_frame_preserve_identity_and_parameters
    result = HomeCAD::Architecture.create_wall(@model,
      'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0], 'thickness_mm' => 120, 'height_mm' => 2700)
    wall = @model.entities.first
    id = result.dig('created', 0, 'identity', 'homecad_id')
    assert HomeCAD::Metadata.uuid?(id)
    assert_equal 'architecture.wall', HomeCAD::Metadata.read(wall)['type']
    assert_equal 1, HomeCAD::Metadata.read(wall)['revision']
    assert_equal 'success', result['status']
    assert_equal id, HomeCAD::Architecture.get_wall_frame(@model, 'wall' => { 'homecad_id' => id })['wall_id']
    assert_equal %i[start commit], @model.events.map(&:first)
  end

  def test_invalid_wall_fails_before_operation
    assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.create_wall(@model,
        'start_mm' => [0, 0, 0], 'end_mm' => [10, 0, 0], 'thickness_mm' => 120, 'height_mm' => 2700)
    end
    assert_empty @model.events
    assert_empty @model.entities
  end

  def test_sketchup_geometry_failure_aborts_and_removes_partial_wall
    @model.fail_faces = true
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.create_wall(@model, 'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
        'thickness_mm' => 120, 'height_mm' => 2700)
    end
    assert_equal 'geometry_error', error.category
    assert_empty @model.entities
    assert_equal %i[start abort], @model.events.map(&:first)
  end

  def test_hosted_window_update_and_delete_preserve_local_attachment_and_revisions
    wall = HomeCAD::Architecture.create_wall(@model, 'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
    window_result = HomeCAD::Architecture.create_hosted(@model, 'architecture.window',
      'wall' => { 'homecad_id' => wall }, 'offset_mm' => 1000, 'bottom_mm' => 900,
      'width_mm' => 1200, 'height_mm' => 1200)
    window = window_result.dig('created', 0, 'identity', 'homecad_id')
    window_entity = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == window }
    wall_entity = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == wall }
    assert_equal 5, window_entity.entities.length # four frame rails and one glass panel
    assert_equal 2, HomeCAD::Metadata.read(wall_entity)['revision']
    updated = HomeCAD::Architecture.update_object(@model,
      'target' => { 'homecad_id' => wall },
      'changes' => { 'start_mm' => [100, 200, 0], 'end_mm' => [100, 4200, 0] })
    assert_same wall_entity, @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == wall }
    assert_equal 3, HomeCAD::Metadata.read(wall_entity)['revision']
    assert_equal 2, HomeCAD::Metadata.read(window_entity)['revision']
    assert_equal 1000, HomeCAD::ArchitectureData.read_params(window_entity)['offset_mm']
    assert_equal [0.0, 1.0, 0.0], HomeCAD::Architecture.get_wall_frame(@model, 'wall' => { 'homecad_id' => wall })['u_axis']
    tombstone = HomeCAD::Architecture.delete_object(@model, 'target' => { 'homecad_id' => window })
    assert_equal 'architecture.window', tombstone.dig('deleted', 0, 'metadata', 'type')
    assert_equal 4, HomeCAD::Metadata.read(wall_entity)['revision']
    assert_equal %i[start commit start commit start commit start commit], @model.events.map(&:first)
  end

  def test_wall_shortening_past_hosted_object_rejects_without_revision_changes
    wall = HomeCAD::Architecture.create_wall(@model, 'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
    HomeCAD::Architecture.create_hosted(@model, 'architecture.opening',
      'wall' => { 'homecad_id' => wall }, 'offset_mm' => 3000, 'bottom_mm' => 0,
      'width_mm' => 900, 'height_mm' => 2100)
    wall_entity = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == wall }
    before = HomeCAD::Metadata.read(wall_entity)['revision']
    events = @model.events.length
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => wall },
        'changes' => { 'end_mm' => [3500, 0, 0] })
    end
    assert_equal 'constraint_violation', error.category
    assert_equal before, HomeCAD::Metadata.read(wall_entity)['revision']
    assert_equal events, @model.events.length
  end

  def test_through_cuts_and_door_have_semantic_metadata_and_single_wall_revision
    wall = HomeCAD::Architecture.create_wall(@model, 'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
    opening = HomeCAD::Architecture.create_hosted(@model, 'architecture.opening',
      'wall' => { 'homecad_id' => wall }, 'offset_mm' => 500, 'bottom_mm' => 800,
      'width_mm' => 500, 'height_mm' => 700)
    door = HomeCAD::Architecture.create_hosted(@model, 'architecture.door',
      'wall' => { 'homecad_id' => wall }, 'offset_mm' => 2000, 'width_mm' => 800, 'height_mm' => 2100)
    opening_entity = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == opening.dig('created', 0, 'identity', 'homecad_id') }
    door_entity = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == door.dig('created', 0, 'identity', 'homecad_id') }
    wall_entity = @model.entities.find { |entity| HomeCAD::Metadata.read(entity)['homecad_id'] == wall }
    assert_equal 'architecture.opening', HomeCAD::Metadata.read(opening_entity)['type']
    assert_equal 'architecture.door', HomeCAD::Metadata.read(door_entity)['type']
    assert_equal 1, opening_entity.entities.length
    assert_equal 1, door_entity.entities.length
    assert opening_entity.entities.first.hidden?
    assert door_entity.entities.first.hidden?
    assert_equal opening.dig('created', 0, 'identity', 'homecad_id'),
      HomeCAD::Targeting.identity(HomeCAD::Targeting.resolve_one(@model, { 'homecad_id' => opening.dig('created', 0, 'identity', 'homecad_id') }))['homecad_id']
    assert_equal door.dig('created', 0, 'identity', 'homecad_id'),
      HomeCAD::Targeting.identity(HomeCAD::Targeting.resolve_one(@model, { 'homecad_id' => door.dig('created', 0, 'identity', 'homecad_id') }))['homecad_id']
    assert_equal 0.0, HomeCAD::ArchitectureData.read_params(door_entity)['bottom_mm']
    assert_equal 3, HomeCAD::Metadata.read(wall_entity)['revision']
    assert_operator wall_entity.entities.length, :>, 6
  end

  def test_overlapping_hosted_cuts_reject_before_mutation
    wall = HomeCAD::Architecture.create_wall(@model, 'start_mm' => [0, 0, 0], 'end_mm' => [4000, 0, 0],
      'thickness_mm' => 120, 'height_mm' => 2700).dig('created', 0, 'identity', 'homecad_id')
    HomeCAD::Architecture.create_hosted(@model, 'architecture.opening',
      'wall' => { 'homecad_id' => wall }, 'offset_mm' => 500, 'bottom_mm' => 500,
      'width_mm' => 900, 'height_mm' => 1000)
    event_count = @model.events.length
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.create_hosted(@model, 'architecture.window',
        'wall' => { 'homecad_id' => wall }, 'offset_mm' => 1000, 'bottom_mm' => 900,
        'width_mm' => 600, 'height_mm' => 800)
    end
    assert_equal 'constraint_violation', error.category
    assert_equal event_count, @model.events.length
  end

  def test_wall_delete_requires_cascade_and_returns_tombstones
    walls = [[0, 0, 0, 1000, 0, 0], [1000, 0, 0, 1000, 1000, 0],
             [1000, 1000, 0, 0, 1000, 0], [0, 1000, 0, 0, 0, 0]].map do |x1, y1, z1, x2, y2, z2|
      HomeCAD::Architecture.create_wall(@model, 'start_mm' => [x1, y1, z1], 'end_mm' => [x2, y2, z2],
        'thickness_mm' => 100, 'height_mm' => 2400).dig('created', 0, 'identity', 'homecad_id')
    end
    hosted = HomeCAD::Architecture.create_hosted(@model, 'architecture.opening',
      'wall' => { 'homecad_id' => walls.first }, 'offset_mm' => 100, 'bottom_mm' => 100,
      'width_mm' => 200, 'height_mm' => 300).dig('created', 0, 'identity', 'homecad_id')
    room = HomeCAD::Architecture.create_room(@model, 'name' => 'Dependent', 'wall_ids' => walls)
    room_id = room.dig('created', 0, 'identity', 'homecad_id')
    target = { 'homecad_id' => walls.first }
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.delete_object(@model, 'target' => target)
    end
    assert_equal 'constraint_violation', error.category
    before = @model.events.length
    deleted = HomeCAD::Architecture.delete_object(@model, 'target' => target, 'cascade' => true)
    assert_equal before + 2, @model.events.length
    assert_equal %w[architecture.opening architecture.room architecture.wall], deleted['deleted'].map { |item| item.dig('metadata', 'type') }.sort
    assert_equal [hosted, room_id, walls.first].sort, deleted['deleted'].map { |item| item.dig('identity', 'homecad_id') }.sort
  end

  def test_column_parameters_and_locked_target_guard
    result = HomeCAD::Architecture.create_column(@model, 'origin_mm' => [100, 200, 0],
      'width_mm' => 300, 'depth_mm' => 400, 'height_mm' => 2700, 'rotation_degrees' => 45)
    id = result.dig('created', 0, 'identity', 'homecad_id')
    entity = @model.entities.find { |item| HomeCAD::Metadata.read(item)['homecad_id'] == id }
    assert_equal 45.0, HomeCAD::ArchitectureData.read_params(entity)['rotation_degrees']
    entity.define_singleton_method(:locked?) { true }
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => id }, 'changes' => { 'height_mm' => 2800 })
    end
    assert_equal 'constraint_violation', error.category
  end

  def test_room_requires_ordered_closed_walls_and_derives_room_side
    ids = []
    [[0, 0, 0, 4000, 0, 0], [4000, 0, 0, 4000, 3000, 0],
     [4000, 3000, 0, 0, 3000, 0], [0, 3000, 0, 0, 0, 0]].each do |x1, y1, z1, x2, y2, z2|
      result = HomeCAD::Architecture.create_wall(@model, 'start_mm' => [x1, y1, z1], 'end_mm' => [x2, y2, z2],
        'thickness_mm' => 120, 'height_mm' => 2700)
      ids << result.dig('created', 0, 'identity', 'homecad_id')
    end
    _points, sides = HomeCAD::Architecture.room_boundary!(@model, ids)
    assert_equal ids, sides.map(&:first)
    assert_equal %w[positive_v positive_v positive_v positive_v], sides.map(&:last)
    assert_raises(HomeCAD::Runtime::BridgeError) { HomeCAD::Architecture.room_boundary!(@model, ids.take(3)) }
    result = HomeCAD::Architecture.create_room(@model, 'name' => 'Test room', 'wall_ids' => ids)
    assert_equal 'architecture.room', result.dig('created', 0, 'metadata', 'type')
    assert_equal ids, result.dig('created', 0, 'parameters', 'wall_ids')
  end

  def test_room_wall_ids_update_rederives_boundary_area_relationships_and_face_atomically
    first_loop = create_rectangular_walls(0, 0, 4000, 3000)
    second_loop = create_rectangular_walls(10_000, 0, 5000, 2000)
    created = HomeCAD::Architecture.create_room(@model, 'name' => 'Replaceable', 'wall_ids' => first_loop)
    room_id = created.dig('created', 0, 'identity', 'homecad_id')
    room = room_entity(room_id)
    before = HomeCAD::ArchitectureData.read_params(room)
    old_revision = HomeCAD::Metadata.read(room)['revision']
    events_before = @model.events.length

    result = HomeCAD::Architecture.update_object(@model,
      'target' => { 'homecad_id' => room_id }, 'changes' => { 'wall_ids' => second_loop })
    after = HomeCAD::ArchitectureData.read_params(room)
    expected_boundary = [[10_000, 0, 0], [15_000, 0, 0], [15_000, 2000, 0], [10_000, 2000, 0]]
    expected_relationships = HomeCAD::Architecture.room_relationships(after['room_sides'])

    assert_equal room_id, result.dig('updated', 0, 'identity', 'homecad_id')
    assert_equal room_id, HomeCAD::Metadata.read(room)['homecad_id']
    assert_equal second_loop, after['wall_ids']
    assert_equal expected_boundary, after['boundary_mm']
    assert_in_delta 10_000_000, after['approx_area_mm2'], 1e-6
    assert_equal second_loop, after['room_sides'].map(&:first)
    assert_equal expected_relationships, HomeCAD::ArchitectureData.read_relationships(room)
    assert_points_equal expected_boundary, room_face_points(room)
    assert_equal old_revision + 1, HomeCAD::Metadata.read(room)['revision']
    assert_equal events_before + 2, @model.events.length
    assert_equal %i[start commit], @model.events.last(2).map(&:first)

    geometry_before_failure = room_face_points(room)
    params_before_failure = HomeCAD::ArchitectureData.read_params(room)
    relationships_before_failure = HomeCAD::ArchitectureData.read_relationships(room)
    revision_before_failure = HomeCAD::Metadata.read(room)['revision']
    event_count_before_failure = @model.events.length
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.update_object(@model,
        'target' => { 'homecad_id' => room_id }, 'changes' => { 'wall_ids' => second_loop.take(3) })
    end
    assert_equal 'constraint_violation', error.category
    assert_equal params_before_failure, HomeCAD::ArchitectureData.read_params(room)
    assert_equal relationships_before_failure, HomeCAD::ArchitectureData.read_relationships(room)
    assert_equal revision_before_failure, HomeCAD::Metadata.read(room)['revision']
    assert_equal geometry_before_failure, room_face_points(room)
    assert_equal event_count_before_failure, @model.events.length
    assert_equal before['name'], HomeCAD::ArchitectureData.read_params(room)['name']
  end

  def test_reversing_wall_direction_refreshes_room_sides_relationships_and_revisions
    walls = create_rectangular_walls(0, 0, 4000, 3000)
    room_id = HomeCAD::Architecture.create_room(@model, 'name' => 'Direction', 'wall_ids' => walls)
      .dig('created', 0, 'identity', 'homecad_id')
    room = room_entity(room_id)
    wall = room_entity(walls.first)
    old_params = HomeCAD::ArchitectureData.read_params(room)
    old_room_revision = HomeCAD::Metadata.read(room)['revision']
    old_wall_revision = HomeCAD::Metadata.read(wall)['revision']
    before_events = @model.events.length

    HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => walls.first },
      'changes' => { 'start_mm' => [4000, 0, 0], 'end_mm' => [0, 0, 0] })

    new_params = HomeCAD::ArchitectureData.read_params(room)
    relationships = HomeCAD::ArchitectureData.read_relationships(room)
    assert_equal old_params['boundary_mm'], new_params['boundary_mm']
    assert_equal old_params['approx_area_mm2'], new_params['approx_area_mm2']
    assert_equal 'positive_v', old_params['room_sides'].find { |id, _| id == walls.first }.last
    assert_equal 'negative_v', new_params['room_sides'].find { |id, _| id == walls.first }.last
    assert_equal HomeCAD::Architecture.room_relationships(new_params['room_sides']), relationships
    assert_equal new_params['room_sides'].to_h { |id, side| ["wall_#{id}", side] }, relationships
    assert_points_equal new_params['boundary_mm'], room_face_points(room)
    assert_equal old_room_revision + 1, HomeCAD::Metadata.read(room)['revision']
    assert_equal old_wall_revision + 1, HomeCAD::Metadata.read(wall)['revision']
    assert_equal before_events + 2, @model.events.length
    assert_equal %i[start commit], @model.events.last(2).map(&:first)
  end

  def test_valid_wall_relocation_rederives_room_state_and_invalid_relocation_is_atomic
    walls = create_rectangular_walls(0, 0, 4000, 3000)
    room_id = HomeCAD::Architecture.create_room(@model, 'name' => 'Relocate', 'wall_ids' => walls)
      .dig('created', 0, 'identity', 'homecad_id')
    room = room_entity(room_id)
    wall = room_entity(walls.first)
    area_before = HomeCAD::ArchitectureData.read_params(room)['approx_area_mm2']
    room_revision = HomeCAD::Metadata.read(room)['revision']
    wall_revision = HomeCAD::Metadata.read(wall)['revision']

    HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => walls.first },
      'changes' => { 'start_mm' => [0, 0.5, 0], 'end_mm' => [4000, 0.5, 0] })
    moved_params = HomeCAD::ArchitectureData.read_params(room)
    assert_equal walls, moved_params['wall_ids']
    assert_equal walls, moved_params['room_sides'].map(&:first)
    assert_in_delta 11_999_000, moved_params['approx_area_mm2'], 1e-6
    refute_equal area_before, moved_params['approx_area_mm2']
    assert_equal HomeCAD::Architecture.room_relationships(moved_params['room_sides']),
      HomeCAD::ArchitectureData.read_relationships(room)
    assert_points_equal moved_params['boundary_mm'], room_face_points(room)
    assert_equal room_revision + 1, HomeCAD::Metadata.read(room)['revision']
    assert_equal wall_revision + 1, HomeCAD::Metadata.read(wall)['revision']

    params_before = HomeCAD::ArchitectureData.read_params(room)
    relationships_before = HomeCAD::ArchitectureData.read_relationships(room)
    room_revision_before = HomeCAD::Metadata.read(room)['revision']
    wall_params_before = HomeCAD::ArchitectureData.read_params(wall)
    wall_revision_before = HomeCAD::Metadata.read(wall)['revision']
    geometry_before = room_face_points(room)
    event_count_before = @model.events.length
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Architecture.update_object(@model, 'target' => { 'homecad_id' => walls.first },
        'changes' => { 'start_mm' => [0, 2.5, 0], 'end_mm' => [4000, 2.5, 0] })
    end
    assert_equal 'constraint_violation', error.category
    assert_equal params_before, HomeCAD::ArchitectureData.read_params(room)
    assert_equal relationships_before, HomeCAD::ArchitectureData.read_relationships(room)
    assert_equal room_revision_before, HomeCAD::Metadata.read(room)['revision']
    assert_equal geometry_before, room_face_points(room)
    assert_equal wall_params_before, HomeCAD::ArchitectureData.read_params(wall)
    assert_equal wall_revision_before, HomeCAD::Metadata.read(wall)['revision']
    assert_equal event_count_before, @model.events.length
  end

  def test_detect_rooms_is_read_only_and_finds_simple_loop
    ids = []
    [[0, 0, 0, 1000, 0, 0], [1000, 0, 0, 1000, 1000, 0],
     [1000, 1000, 0, 0, 1000, 0], [0, 1000, 0, 0, 0, 0]].each do |x1, y1, z1, x2, y2, z2|
      ids << HomeCAD::Architecture.create_wall(@model, 'start_mm' => [x1, y1, z1], 'end_mm' => [x2, y2, z2],
        'thickness_mm' => 100, 'height_mm' => 2400).dig('created', 0, 'identity', 'homecad_id')
    end
    count = @model.entities.length
    result = HomeCAD::Architecture.detect_rooms(@model, {})
    assert_equal 1, result['candidates'].length
    assert_in_delta 1_000_000, result.dig('candidates', 0, 'approx_area_mm2'), 1e-6
    assert_equal count, @model.entities.length
    HomeCAD::Architecture.create_wall(@model, 'start_mm' => [3000, 3000, 0], 'end_mm' => [4000, 3000, 0],
      'thickness_mm' => 100, 'height_mm' => 2400)
    with_open_wall = HomeCAD::Architecture.detect_rooms(@model, {})
    assert_equal 1, with_open_wall['candidates'].length
    assert with_open_wall['warnings'].any?
  end

  def test_detect_rooms_skips_t_junctions_with_warning
    [[0, 0, 0, 1000, 0, 0], [1000, 0, 0, 1000, 1000, 0],
     [1000, 1000, 0, 0, 1000, 0], [0, 1000, 0, 0, 0, 0],
     [500, 0, 0, 500, -500, 0]].each do |x1, y1, z1, x2, y2, z2|
      HomeCAD::Architecture.create_wall(@model, 'start_mm' => [x1, y1, z1], 'end_mm' => [x2, y2, z2],
        'thickness_mm' => 100, 'height_mm' => 2400)
    end
    result = HomeCAD::Architecture.detect_rooms(@model, {})
    assert_empty result['candidates']
    assert_match(/crossing|T-junction/, result['warnings'].join)
  end
end
