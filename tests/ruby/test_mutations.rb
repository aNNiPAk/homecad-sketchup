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
    def length=(value)
      factor = value / length
      @x *= factor
      @y *= factor
      @z *= factor
    end
    def cross(other) = Vector3d.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    def parallel?(other) = cross(other).length < 1e-9
  end
  class Transformation
    attr_reader :offset
    def initialize(offset = [0, 0, 0]) = (@offset = offset)
    def self.translation(vector) = new([vector.x, vector.y, vector.z])
    def self.rotation(*) = new
    def self.scaling(*) = new
    def *(other)
      if other.is_a?(Point3d)
        Point3d.new(other.x + offset[0], other.y + offset[1], other.z + offset[2])
      else
        Transformation.new(offset.zip(other.offset).map(&:sum))
      end
    end
    def inverse = Transformation.new(offset.map { |value| -value })
    def to_a = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, *offset, 1]
  end
end

class MutationBounds
  attr_reader :min, :max
  def initialize(points)
    values = [->(p) { p.x }, ->(p) { p.y }, ->(p) { p.z }]
    @min = Geom::Point3d.new(*values.map { |value| points.map(&value).min })
    @max = Geom::Point3d.new(*values.map { |value| points.map(&value).max })
  end
  def empty? = false
  def corner(index)
    Geom::Point3d.new((index & 1).zero? ? min.x : max.x,
                      (index & 2).zero? ? min.y : max.y,
                      (index & 4).zero? ? min.z : max.z)
  end
end

class MutationDefinition
  attr_reader :source
  def initialize(source) = (@source = source)
  def manifold? = true
  def instances = [source]
end

class MutationEntities < Array
  attr_reader :model, :owner
  def initialize(model, owner = nil)
    @model, @owner = model, owner
    super()
  end
  def add_group
    group = Sketchup::Group.new(model.next_id, model, self)
    self << group
    group
  end
  def add_instance(definition, transformation)
    group = Sketchup::Group.new(model.next_id, model, self, definition.source.points.dup)
    group.transformation = transformation
    self << group
    group
  end
  def add_line(first, last)
    edge = Sketchup::Edge.new(model.next_id, model, owner, [first, last])
    self << edge
    edge
  end
end

class MutationEntity
  attr_reader :persistent_id, :entityID, :model, :parent, :name
  attr_accessor :locked
  def initialize(id, type, model, parent, points = [])
    @persistent_id = @entityID = id
    @type, @model, @parent, @points = type, model, parent, points
    @attributes = {}
    @valid = true
    @locked = false
  end
  def typename = @type
  def valid? = @valid
  def deleted? = !@valid
  def locked? = locked
  def hidden? = false
  def layer = nil
  def material = nil
  def erase! = (@valid = false)
  def attribute_dictionary(name, _create = false) = @attributes[name]
  def set_attribute(dictionary, key, value) = (@attributes[dictionary] ||= {})[key] = value
  def points = @points
  def add_points(points) = @points.concat(points)
  def bounds = @points.empty? ? nil : MutationBounds.new(@points)
end

module Sketchup
  class Group < MutationEntity
    attr_reader :entities
    attr_accessor :transformation, :fail_transform
    def initialize(id, model, parent, points = [])
      super(id, 'Group', model, parent, points)
      @entities = MutationEntities.new(model, self)
      @transformation = Geom::Transformation.new
    end
    def definition = MutationDefinition.new(self)
    def bounds
      return nil if points.empty?
      MutationBounds.new(points.map { |point| transformation * point })
    end
    def transform!(transformation)
      return false if fail_transform
      @transformation = transformation * @transformation
      true
    end
    def union(_other) = MutationBoolean.make_result(model)
    def intersect(_other) = MutationBoolean.make_result(model)
    def trim(_other)
      MutationBoolean.receiver = :target_minus_tool
      MutationBoolean.make_result(model)
    end
  end
  class ComponentInstance < Group; end
  class Face < MutationEntity
    def initialize(id, model, parent, points)
      super(id, 'Face', model, parent, points)
      parent.add_points(points)
    end
    def pushpull(distance)
      created = points.map { |point| Geom::Point3d.new(point.x, point.y, point.z + distance) }
      add_points(created)
      parent.add_points(created)
      nil
    end
    def followme(edges) = !edges.empty?
  end
  class Edge < MutationEntity
    def initialize(id, model, parent, points)
      super(id, 'Edge', model, parent, points)
    end
  end
  class Model
    attr_reader :entities, :events
    def initialize
      @next_id = 100
      @entities = MutationEntities.new(self)
      @events = []
    end
    def next_id
      @next_id += 1
    end
    def start_operation(name, *)
      @events << [:start, name]
      @snapshot = entities.length
      true
    end
    def commit_operation
      @events << [:commit]
      true
    end
    def abort_operation
      @events << [:abort]
      entities.slice!(@snapshot..)
      true
    end
  end
  def self.active_model = @active_model
  def self.active_model=(model)
    @active_model = model
  end
end

module MutationBoolean
  class << self
    attr_accessor :receiver, :argument
    def make_result(model)
      self.receiver ||= nil
      model.entities.add_group.tap { |group| group.add_points([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 1)]) }
    end
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
require_relative '../../sketchup/homecad/core/mutations'

class MutationsTest < Minitest::Test
  def setup
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
    @group = @model.entities.add_group
    HomeCAD::Metadata.create!(@group, type: 'primitive.box')
    @group.add_points([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(100.0 / 25.4, 100.0 / 25.4, 0)])
    @face = Sketchup::Face.new(@model.next_id, @model, @group,
                               [Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(10.0 / 25.4, 0, 0),
                                Geom::Point3d.new(10.0 / 25.4, 10.0 / 25.4, 0)])
    @group.entities << @face
    @group_entry = HomeCAD::Scene::Entry.new(entity: @group, parent: nil,
                                              path: [@group.persistent_id], transform: nil)
    @face_entry = HomeCAD::Scene::Entry.new(entity: @face, parent: @group,
                                             path: [@group.persistent_id, @face.persistent_id], transform: nil)
    @resolver = HomeCAD::Targeting.method(:resolve_one)
  end

  def teardown
    HomeCAD::Targeting.define_singleton_method(:resolve_one, @resolver)
  end

  def resolve_to(entry)
    HomeCAD::Targeting.define_singleton_method(:resolve_one) { |_model, _selector| entry }
  end

  def test_transform_uses_one_operation_and_increments_object_revision
    resolve_to(@group_entry)
    result = HomeCAD::Mutations.transform_object(@model,
      'target' => { 'homecad_id' => HomeCAD::Metadata.read(@group)['homecad_id'] },
      'transform' => { 'type' => 'translate', 'vector_mm' => [25.4, 0, 0] })
    assert_equal %i[start commit], @model.events.map(&:first)
    assert_equal 'success', result['status']
    assert_equal 2, result['revision']
    assert_equal 2, result.dig('updated', 0, 'metadata', 'revision')
    assert_in_delta 25.4, result.dig('updated', 0, 'bbox_mm', 'min', 0), 1e-9
  end

  def test_ambiguous_or_locked_targets_fail_before_starting_an_operation
    HomeCAD::Targeting.define_singleton_method(:resolve_one) do |_model, _selector|
      raise HomeCAD::Runtime::BridgeError.new(-32003, 'ambiguous_target', 'target is ambiguous')
    end
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Mutations.transform_object(@model, 'target' => { 'entity_id' => 7 },
        'transform' => { 'type' => 'translate', 'vector_mm' => [10, 0, 0] })
    end
    assert_equal 'ambiguous_target', error.category
    assert_empty @model.events

    resolve_to(@group_entry)
    @group.locked = true
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Mutations.transform_object(@model, 'target' => { 'persistent_id' => @group.persistent_id },
        'transform' => { 'type' => 'translate', 'vector_mm' => [10, 0, 0] })
    end
    assert_equal 'constraint_violation', error.category
    assert_empty @model.events
  end

  def test_mutation_failure_aborts_operation_without_revision_update
    resolve_to(@group_entry)
    @group.fail_transform = true
    error = assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Mutations.transform_object(@model,
        'target' => { 'homecad_id' => HomeCAD::Metadata.read(@group)['homecad_id'] },
        'transform' => { 'type' => 'translate', 'vector_mm' => [25.4, 0, 0] })
    end
    assert_equal 'geometry_error', error.category
    assert_equal %i[start abort], @model.events.map(&:first)
    assert_equal 1, HomeCAD::Metadata.read(@group)['revision']
  end

  def test_push_pull_updates_the_managed_group_once
    resolve_to(@face_entry)
    result = HomeCAD::Mutations.push_pull(@model,
      'target' => { 'persistent_id' => @face.persistent_id }, 'distance_mm' => 25.4)
    assert_equal %i[start commit], @model.events.map(&:first)
    assert_equal 2, result['revision']
    assert_in_delta 25.4, result.dig('updated', 0, 'bbox_dimensions_mm', 'height'), 1e-9
  end

  def test_follow_me_creates_bounded_path_in_the_face_context
    resolve_to(@face_entry)
    result = HomeCAD::Mutations.follow_me(@model,
      'target' => { 'persistent_id' => @face.persistent_id },
      'path_points_mm' => [[0, 0, 0], [0, 0, 25.4]])
    assert_equal 'success', result['status']
    assert_equal 2, result['revision']
    assert_equal %i[start commit], @model.events.map(&:first)
    assert_equal 1, @group.entities.grep(Sketchup::Edge).length
  end

  def test_boolean_difference_uses_target_minus_tool_and_preserves_inputs
    target = @group
    tool = @model.entities.add_group
    HomeCAD::Metadata.create!(tool, type: 'primitive.box')
    tool.add_points([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(10, 10, 10)])
    target_entry = HomeCAD::Scene::Entry.new(entity: target, parent: nil,
                                              path: [target.persistent_id], transform: nil)
    tool_entry = HomeCAD::Scene::Entry.new(entity: tool, parent: nil,
                                            path: [tool.persistent_id], transform: nil)
    HomeCAD::Targeting.define_singleton_method(:resolve_one) do |_model, selector|
      selector['homecad_id'] == HomeCAD::Metadata.read(target)['homecad_id'] ? target_entry : tool_entry
    end
    result = HomeCAD::Mutations.boolean_operation(@model,
      'target' => { 'homecad_id' => HomeCAD::Metadata.read(target)['homecad_id'] },
      'tool' => { 'persistent_id' => tool.persistent_id }, 'operation' => 'difference')
    assert_equal 'primitive.boolean', result.dig('created', 0, 'metadata', 'type')
    assert_equal 1, result['revision']
    assert target.valid?
    assert tool.valid?
    assert_equal :target_minus_tool, MutationBoolean.receiver
  end
end
