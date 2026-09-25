require 'minitest/autorun'

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z) = (@x, @y, @z = x, y, z)
    def distance(other) = Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    def offset(vector, distance)
      Point3d.new(x + vector.x * distance, y + vector.y * distance, z + vector.z * distance)
    end
  end

  class Vector3d
    attr_reader :x, :y, :z
    def initialize(x, y, z) = (@x, @y, @z = x, y, z)
    def length = Math.sqrt(x * x + y * y + z * z)
    def length=(value)
      factor = value / length
      @x *= factor
      @y *= factor
      @z *= factor
    end
    def cross(other)
      Vector3d.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    end
  end
end

class FakeBounds
  attr_reader :min, :max
  def initialize(points)
    @min = Geom::Point3d.new(*3.times.map { |i| points.map { |point| [point.x, point.y, point.z][i] }.min })
    @max = Geom::Point3d.new(*3.times.map { |i| points.map { |point| [point.x, point.y, point.z][i] }.max })
  end
  def empty? = false
  def corner(index)
    Geom::Point3d.new((index & 1).zero? ? min.x : max.x,
                      (index & 2).zero? ? min.y : max.y,
                      (index & 4).zero? ? min.z : max.z)
  end
end

class FakeEntities
  attr_reader :items
  def initialize(group)
    @group = group
    @items = []
  end
  def add_face(points)
    return nil if @group.fail_face
    return nil if points.length < 3
    @items << FakeFace.new(@group, points)
    @items.last
  end
  def add_line(first, last)
    @items << FakeEdge.new(@group, [first, last])
    @items.last
  end
  def add_circle(center, _normal, radius, segments)
    @group.add_points([Geom::Point3d.new(center.x - radius, center.y - radius, center.z),
                       Geom::Point3d.new(center.x + radius, center.y + radius, center.z)])
    Array.new(segments) { FakeEdge.new(@group, [center, center]) }
  end
  def add_arc(center, _x_axis, _normal, radius, start_angle, end_angle, segments)
    @group.last_arc = [start_angle, end_angle, segments]
    add_circle(center, nil, radius, segments)
  end
  def length = items.length
  def each(&block) = items.each(&block)
  def each_with_object(initial, &block) = items.each_with_object(initial, &block)
end

class FakeFace
  attr_reader :points
  def initialize(group, points)
    @group, @points = group, points
    group.add_points(points)
  end
  def pushpull(distance)
    points.each do |point|
      @group.add_points([Geom::Point3d.new(point.x, point.y, point.z + distance)])
    end
    nil
  end
  def typename = 'Face'
end

class FakeEdge
  def initialize(group, points)
    @group = group
    group.add_points(points)
  end
  def typename = 'Edge'
end

class FakeGroup
  attr_reader :entities, :persistent_id, :entityID, :parent
  attr_accessor :name, :last_arc, :fail_face
  def initialize(id)
    @persistent_id = @entityID = id
    @attributes = {}
    @points = []
    @entities = FakeEntities.new(self)
    @valid = true
  end
  def add_points(points) = @points.concat(points)
  def bounds = @points.empty? ? nil : FakeBounds.new(@points)
  def valid? = @valid
  def deleted? = !@valid
  def typename = 'Group'
  def attribute_dictionary(name, _create = false) = @attributes[name]
  def set_attribute(dictionary, key, value) = (@attributes[dictionary] ||= {})[key] = value
  def hidden? = false
  def locked? = false
  def layer = nil
  def material = nil
end

class FakeModel
  attr_reader :entities, :root_groups, :events
  def initialize
    @root_groups = []
    @events = []
    @next_id = 100
    model = self
    @entities = Object.new
    @entities.define_singleton_method(:add_group) { model.add_group }
    @entities.define_singleton_method(:length) { model.root_groups.length }
    @entities.define_singleton_method(:all?) { |&block| model.root_groups.all?(&block) }
    @entities.define_singleton_method(:first) { model.root_groups.first }
  end
  def start_operation(name, *)
    @events << [:start, name]
    @snapshot = @root_groups.length
    true
  end
  def commit_operation
    @events << [:commit]
    true
  end
  def abort_operation
    @events << [:abort]
    @root_groups.slice!(@snapshot..)
    true
  end
  def add_group
    @next_id += 1
    @root_groups << FakeGroup.new(@next_id)
    @root_groups.last
  end
end

require_relative '../../sketchup/homecad/runtime/errors'
require_relative '../../sketchup/homecad/runtime/operation'
require_relative '../../sketchup/homecad/core/units'
require_relative '../../sketchup/homecad/core/metadata'
require_relative '../../sketchup/homecad/core/mutation'
require_relative '../../sketchup/homecad/core/scene'
require_relative '../../sketchup/homecad/core/targeting'
require_relative '../../sketchup/homecad/core/serializer'
require_relative '../../sketchup/homecad/core/geometry'
require_relative '../../sketchup/homecad/core/primitives'

class PrimitivesTest < Minitest::Test
  def setup
    @model = FakeModel.new
  end

  def test_box_is_one_homecad_group_with_expected_millimeter_bounds
    result = HomeCAD::Primitives.create_box(@model,
      'width_mm' => 600, 'depth_mm' => 560, 'height_mm' => 720, 'origin_mm' => [100, 200, 30])
    object = result['created'].first
    assert_equal 'success', result['status']
    assert_equal 'create_box', result['operation']
    assert_equal 1, result['revision']
    assert HomeCAD::Metadata.uuid?(object.dig('identity', 'homecad_id'))
    assert_equal 'primitive.box', object.dig('metadata', 'type')
    assert_equal true, object.dig('metadata', 'generated')
    assert_equal 1, object.dig('metadata', 'revision')
    assert_in_delta 600, object.dig('bbox_dimensions_mm', 'width'), 1e-8
    assert_in_delta 560, object.dig('bbox_dimensions_mm', 'depth'), 1e-8
    assert_in_delta 720, object.dig('bbox_dimensions_mm', 'height'), 1e-8
    assert_equal %i[start commit], @model.events.map(&:first)
  end

  def test_invalid_box_dimensions_do_not_open_operation_or_create_geometry
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Primitives.create_box(@model,
        'width_mm' => 0, 'depth_mm' => 560, 'height_mm' => 720)
    end
    assert_equal 'invalid_request', error.category
    assert_empty @model.root_groups
    assert_empty @model.events
  end

  def test_creation_helpers_containerize_edges_and_faces
    edge = HomeCAD::Primitives.create_edge(@model,
      'start_mm' => [0, 0, 0], 'end_mm' => [100, 0, 0])
    face = HomeCAD::Primitives.create_face(@model,
      'points_mm' => [[0, 0, 0], [100, 0, 0], [100, 50, 0]])
    assert_equal 'primitive.edge', edge.dig('created', 0, 'metadata', 'type')
    assert_equal 'primitive.face', face.dig('created', 0, 'metadata', 'type')
    assert_equal 2, @model.root_groups.length
    assert @model.root_groups.all? { |group| group.is_a?(FakeGroup) }
  end

  def test_arc_angles_are_converted_from_degrees
    HomeCAD::Primitives.create_arc(@model, 'radius_mm' => 50, 'start_angle_degrees' => 30,
                                    'end_angle_degrees' => 120, 'segments' => 8)
    group = @model.root_groups.first
    start_angle, end_angle, segment_count = group.last_arc
    assert_in_delta Math::PI / 6, start_angle, 1e-12
    assert_in_delta 2 * Math::PI / 3, end_angle, 1e-12
    assert_equal 8, segment_count
  end

  def test_invalid_arc_basis_and_unbounded_segments_fail_before_operation
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Primitives.create_arc(@model, 'radius_mm' => 10, 'normal' => [0, 0, 1],
        'x_axis' => [0, 0, 2], 'start_angle_degrees' => 0, 'end_angle_degrees' => 90)
    end
    assert_equal 'invalid_request', error.category
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Primitives.create_circle(@model, 'radius_mm' => 10, 'segments' => 513)
    end
    assert_equal 'invalid_request', error.category
    assert_empty @model.events
  end

  def test_failed_geometry_creation_aborts_and_removes_partial_group
    @model.define_singleton_method(:add_group) do
      group = super()
      group.fail_face = true
      group
    end
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Primitives.create_face(@model,
        'points_mm' => [[0, 0, 0], [100, 0, 0], [0, 100, 0]])
    end
    assert_equal 'geometry_error', error.category
    assert_empty @model.root_groups
    assert_equal %i[start abort], @model.events.map(&:first)
  end

  def test_circle_and_polygon_are_managed_and_use_unit_conversion
    circle = HomeCAD::Primitives.create_circle(@model, 'radius_mm' => 25.4, 'segments' => 16)
    polygon = HomeCAD::Primitives.create_polygon(@model,
      'radius_mm' => 100, 'sides' => 6, 'center_mm' => [254, 0, 0])
    assert_equal 'primitive.circle', circle.dig('created', 0, 'metadata', 'type')
    assert_equal 'primitive.polygon', polygon.dig('created', 0, 'metadata', 'type')
    assert_in_delta 50.8, circle.dig('created', 0, 'bbox_dimensions_mm', 'width'), 1e-8
    assert_in_delta 100 * Math.sqrt(3), polygon.dig('created', 0, 'bbox_dimensions_mm', 'width'), 1e-8
  end
end
